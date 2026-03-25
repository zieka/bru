const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("config.zig").Config;
const clonefile_mod = @import("clonefile.zig");

/// Pre-allocated pool of 1MB buffers for parallel file extraction.
/// Main thread claims buffers to read tar file content into, then hands
/// them to worker threads. Workers release buffers when the write is done.
/// Buffers are heap-allocated to avoid 8MB stack usage.
const BufferPool = struct {
    const pool_size = 8;
    const buf_size = 1024 * 1024; // 1MB per buffer
    const Bufs = [pool_size][buf_size]u8;

    buffers: *Bufs,
    /// Bitmask: bit i is set when buffer i is available.
    available: u8 = 0xFF,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    fn init() !BufferPool {
        return .{
            .buffers = try std.heap.page_allocator.create(Bufs),
        };
    }

    fn deinit(self: *BufferPool) void {
        std.heap.page_allocator.destroy(self.buffers);
    }

    const Slot = struct {
        index: u8,
        buf: *[buf_size]u8,
    };

    /// Claim a buffer, blocking until one is available.
    fn claim(self: *BufferPool) ?Slot {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.available == 0) {
            self.cond.wait(&self.mutex);
        }

        return self.claimLocked();
    }

    /// Try to claim a buffer without blocking. Returns null if none available.
    fn tryClaim(self: *BufferPool) ?Slot {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.claimLocked();
    }

    fn claimLocked(self: *BufferPool) ?Slot {
        if (self.available == 0) return null;

        const index = @ctz(self.available);
        self.available &= ~(@as(u8, 1) << @intCast(index));
        return .{
            .index = index,
            .buf = &self.buffers[index],
        };
    }

    /// Release a buffer back to the pool after the worker is done writing.
    fn release(self: *BufferPool, index: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.available |= @as(u8, 1) << @intCast(index);
        self.cond.signal();
    }
};

/// A file-write job dispatched to a worker thread during extraction.
const WriteTask = struct {
    dir: fs.Dir,
    file_name: [fs.max_path_bytes]u8,
    file_name_len: usize,
    content_len: usize,
    mode: fs.File.Mode,
    pool: *BufferPool,
    pool_index: u8,
    err: ?anyerror,

    fn fileName(self: *const WriteTask) []const u8 {
        return self.file_name[0..self.file_name_len];
    }
};

const WriteWorkerCtx = struct {
    tasks: []WriteTask,
    next_index: *usize,
    pool: *BufferPool,
};

/// Spawn worker threads to drain all pending write tasks, then join.
/// Returns the first write error encountered, if any.
fn spawnAndDrain(tasks: []WriteTask, pool: *BufferPool) !void {
    if (tasks.len == 0) return;

    const cpu_count = std.Thread.getCpuCount() catch 4;
    const max_workers = 8;
    const worker_count = @min(max_workers, @min(cpu_count, tasks.len));

    var next_index: usize = 0;
    const ctx = WriteWorkerCtx{
        .tasks = tasks,
        .next_index = &next_index,
        .pool = pool,
    };

    var threads: [max_workers]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..worker_count) |ti| {
        threads[ti] = std.Thread.spawn(.{}, writeWorker, .{ctx}) catch break;
        spawned += 1;
    }
    for (0..spawned) |ti| {
        threads[ti].join();
    }

    for (tasks) |task| {
        if (task.err) |err| return err;
    }
}

/// Worker thread: claims tasks via atomic counter, writes file content,
/// releases buffer back to pool.
fn writeWorker(ctx: WriteWorkerCtx) void {
    while (true) {
        const i = @atomicRmw(usize, ctx.next_index, .Add, 1, .seq_cst);
        if (i >= ctx.tasks.len) return;

        var task = &ctx.tasks[i];
        defer ctx.pool.release(task.pool_index);

        const file_name = task.fileName();
        const content = ctx.pool.buffers[task.pool_index][0..task.content_len];

        // Create parent directories if needed, then write the file.
        const file = createFile(task.dir, file_name, task.mode) catch |err| {
            task.err = err;
            continue;
        };
        defer file.close();

        file.writeAll(content) catch |err| {
            task.err = err;
        };
    }
}

/// Create a file, making parent directories on demand (mirrors stdlib tar behavior).
fn createFile(dir: fs.Dir, file_name: []const u8, mode: fs.File.Mode) !fs.File {
    return dir.createFile(file_name, .{ .exclusive = true, .mode = mode }) catch |err| {
        if (err == error.FileNotFound) {
            if (std.fs.path.dirname(file_name)) |dir_name| {
                try dir.makePath(dir_name);
                return try dir.createFile(file_name, .{ .exclusive = true, .mode = mode });
            }
        }
        return err;
    };
}

/// Create a symbolic link, making parent directories on demand.
fn createSymlink(dir: fs.Dir, link_name: []const u8, file_name: []const u8) !void {
    dir.symLink(link_name, file_name, .{}) catch |err| {
        if (err == error.FileNotFound) {
            if (std.fs.path.dirname(file_name)) |dir_name| {
                try dir.makePath(dir_name);
                return try dir.symLink(link_name, file_name, .{});
            }
        }
        return err;
    };
}

/// Check whether a directory exists at the given absolute path.
fn dirExists(path: []const u8) bool {
    var dir = fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Handles extraction and post-processing of Homebrew bottle archives.
pub const Bottle = struct {
    allocator: Allocator,
    cellar: []const u8,
    prefix: []const u8,

    pub fn init(allocator: Allocator, config: Config) Bottle {
        return .{
            .allocator = allocator,
            .cellar = config.cellar,
            .prefix = config.prefix,
        };
    }

    /// Extract a .tar.gz bottle into the cellar using parallel file writes.
    /// Returns the keg path (e.g., "/opt/homebrew/Cellar/bat/0.26.1").
    /// Caller owns the returned string.
    pub fn pour(self: Bottle, archive_path: []const u8, name: []const u8, version: []const u8) ![]const u8 {
        // Ensure the cellar directory exists.
        fs.makeDirAbsolute(self.cellar) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Open the archive file.
        const archive_file = try fs.openFileAbsolute(archive_path, .{});
        defer archive_file.close();

        // Set up gzip decompression with a 64KB read buffer.
        var read_buf: [64 * 1024]u8 = undefined;
        var buffered_reader = archive_file.reader(&read_buf);

        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(
            &buffered_reader.interface,
            .gzip,
            &window,
        );

        // Open the cellar directory as the extraction target.
        var cellar_dir = try fs.openDirAbsolute(self.cellar, .{});
        defer cellar_dir.close();

        // Pre-allocated buffer pool for parallel file writes.
        var pool = try BufferPool.init();
        defer pool.deinit();

        // Task list for worker threads.
        var tasks: std.ArrayList(WriteTask) = .{};
        defer tasks.deinit(self.allocator);

        // Tar iterator buffers.
        var file_name_buffer: [fs.max_path_bytes]u8 = undefined;
        var link_name_buffer: [fs.max_path_bytes]u8 = undefined;

        var it: std.tar.Iterator = .init(&decompressor.reader, .{
            .file_name_buffer = &file_name_buffer,
            .link_name_buffer = &link_name_buffer,
        });

        // Iterate tar entries: dirs/symlinks inline, files dispatched to workers.
        while (try it.next()) |file| {
            switch (file.kind) {
                .directory => {
                    if (file.name.len > 0) {
                        try cellar_dir.makePath(file.name);
                    }
                },
                .sym_link => {
                    // Matches stdlib pipeToFileSystem: symlink errors are
                    // non-fatal (e.g., target not yet extracted).
                    createSymlink(cellar_dir, file.link_name, file.name) catch {};
                },
                .file => {
                    if (file.size == 0) {
                        // Empty file: create inline, no buffer needed.
                        const f = try createFile(cellar_dir, file.name, fileMode(file.mode));
                        f.close();
                    } else if (file.size > BufferPool.buf_size) {
                        // Large file: stream synchronously.
                        try syncWriteFile(cellar_dir, file.name, &it, file);
                    } else {
                        // Claim a buffer; if all in use, flush pending tasks first.
                        const slot = pool.tryClaim() orelse blk: {
                            try spawnAndDrain(tasks.items, &pool);
                            tasks.clearRetainingCapacity();
                            break :blk pool.tryClaim().?;
                        };
                        errdefer pool.release(slot.index);

                        const content = slot.buf[0..@intCast(file.size)];
                        try it.reader.readSliceAll(content);
                        it.unread_file_bytes = 0;

                        var task_name: [fs.max_path_bytes]u8 = undefined;
                        @memcpy(task_name[0..file.name.len], file.name);

                        try tasks.append(self.allocator, .{
                            .dir = cellar_dir,
                            .file_name = task_name,
                            .file_name_len = file.name.len,
                            .content_len = @intCast(file.size),
                            .mode = fileMode(file.mode),
                            .pool = &pool,
                            .pool_index = slot.index,
                            .err = null,
                        });
                    }
                },
            }
        }

        // Drain any remaining tasks.
        try spawnAndDrain(tasks.items, &pool);

        // Construct and return the keg path.
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
            self.cellar,
            name,
            version,
        });
    }

    /// Extract a bottle with a two-tier extracted-keg cache.
    ///
    /// Fast path: if an extracted keg for `bottle_sha256` already exists in
    /// `keg_cache_dir`, clone it straight into the cellar.
    /// Slow path: extract via `pour`, then best-effort clone the result into
    /// the cache for next time.
    ///
    /// Cache layout: `{keg_cache_dir}/{sha256}/{name}/{version}/...`
    /// Caller owns the returned keg path string.
    pub fn pourWithCache(
        self: Bottle,
        archive_path: []const u8,
        name: []const u8,
        version: []const u8,
        bottle_sha256: []const u8,
        keg_cache_dir: []const u8,
    ) ![]const u8 {
        // Build the cache source path: {keg_cache_dir}/{sha256}
        const cache_sha_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
            keg_cache_dir,
            bottle_sha256,
        });
        defer self.allocator.free(cache_sha_dir);

        // Build the full cache keg path: {keg_cache_dir}/{sha256}/{name}/{version}
        const cache_keg_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
            cache_sha_dir,
            name,
            version,
        });
        defer self.allocator.free(cache_keg_path);

        // Build the cellar keg path: {cellar}/{name}/{version}
        const keg_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
            self.cellar,
            name,
            version,
        });
        errdefer self.allocator.free(keg_path);

        // --- Fast path: cache hit ----------------------------------------
        if (dirExists(cache_sha_dir)) {
            // Ensure the cellar name directory exists ({cellar}/{name}).
            const cellar_name_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
                self.cellar,
                name,
            });
            defer self.allocator.free(cellar_name_dir);

            fs.makeDirAbsolute(self.cellar) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            fs.makeDirAbsolute(cellar_name_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };

            // Clone from cache to cellar.
            if (clonefile_mod.cloneTree(cache_keg_path, keg_path)) |_| {
                return keg_path;
            } else |_| {
                // cloneTree failed — clean up any partial clone before
                // falling through to slow path (pour needs a clean slate).
                fs.deleteTreeAbsolute(keg_path) catch {};
            }
        }

        // --- Slow path: extract normally ---------------------------------
        // pour() allocates and returns its own keg path string. We already
        // have keg_path with the same value, so free the duplicate from pour.
        const pour_keg_path = try self.pour(archive_path, name, version);
        self.allocator.free(pour_keg_path);

        // Best-effort: populate the cache for next time.
        // Create cache parent dirs: {keg_cache_dir}/{sha256}/{name}
        const cache_name_dir = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
            cache_sha_dir,
            name,
        }) catch return keg_path;
        defer self.allocator.free(cache_name_dir);

        fs.makeDirAbsolute(keg_cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return keg_path,
        };
        fs.makeDirAbsolute(cache_sha_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return keg_path,
        };
        fs.makeDirAbsolute(cache_name_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return keg_path,
        };

        _ = clonefile_mod.cloneTree(keg_path, cache_keg_path) catch return keg_path;

        return keg_path;
    }

    /// Compute file mode from tar header mode (owner executable -> all executable).
    fn fileMode(mode: u32) fs.File.Mode {
        const S = std.posix.S;
        if (mode & S.IXUSR == 0) return fs.File.default_mode;
        return fs.File.default_mode | S.IXUSR | S.IXGRP | S.IXOTH;
    }

    /// Write a large file synchronously by streaming from the tar iterator.
    fn syncWriteFile(dir: fs.Dir, file_name: []const u8, it: *std.tar.Iterator, file: std.tar.Iterator.File) !void {
        const out_file = try createFile(dir, file_name, fileMode(file.mode));
        defer out_file.close();

        var write_buf: [8192]u8 = undefined;
        var file_writer = out_file.writer(&write_buf);
        try it.streamRemaining(file, &file_writer.interface);
        try file_writer.interface.flush();
    }

    /// Replace @@HOMEBREW_*@@ placeholders in text files within a keg.
    pub fn replacePlaceholders(self: Bottle, keg_path: []const u8) !void {
        var dir = try fs.openDirAbsolute(keg_path, .{});
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            try self.processFileForPlaceholders(dir, entry.path);
        }
    }

    /// Process a single file, replacing placeholders if it is a text file.
    fn processFileForPlaceholders(self: Bottle, dir: fs.Dir, sub_path: []const u8) !void {
        const content = dir.readFileAlloc(self.allocator, sub_path, 10 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return,
            error.AccessDenied => return,
            error.IsDir => return,
            error.FileTooBig => return,
            else => return err,
        };
        defer self.allocator.free(content);

        // Skip empty files.
        if (content.len == 0) return;

        // Skip binary files: check first 512 bytes for null bytes.
        const check_len = @min(content.len, 512);
        if (mem.indexOfScalar(u8, content[0..check_len], 0)) |_| {
            return;
        }

        // Apply all placeholder replacements.
        var library_buf: [std.fs.max_path_bytes]u8 = undefined;
        const library = std.fmt.bufPrint(&library_buf, "{s}/Library", .{self.prefix}) catch self.prefix;

        const placeholders = [_]struct { needle: []const u8, replacement: []const u8 }{
            .{ .needle = "@@HOMEBREW_PREFIX@@", .replacement = self.prefix },
            .{ .needle = "@@HOMEBREW_CELLAR@@", .replacement = self.cellar },
            .{ .needle = "@@HOMEBREW_REPOSITORY@@", .replacement = self.prefix },
            .{ .needle = "@@HOMEBREW_LIBRARY@@", .replacement = library },
        };

        var current = self.allocator.dupe(u8, content) catch return;
        var changed = false;

        for (placeholders) |ph| {
            const count = mem.count(u8, current, ph.needle);
            if (count == 0) continue;

            changed = true;
            const new_len = current.len - (ph.needle.len * count) + (ph.replacement.len * count);
            const new_buf = self.allocator.alloc(u8, new_len) catch {
                self.allocator.free(current);
                return;
            };
            _ = mem.replace(u8, current, ph.needle, ph.replacement, new_buf);
            self.allocator.free(current);
            current = new_buf;
        }

        if (changed) {
            dir.writeFile(.{ .sub_path = sub_path, .data = current }) catch {};
        }

        self.allocator.free(current);
    }

    /// Relocate Mach-O binaries by replacing @@HOMEBREW_*@@ placeholders in
    /// load commands using install_name_tool. Required on macOS because
    /// Homebrew bottles embed placeholder paths in binary load commands that
    /// the text-only replacePlaceholders cannot handle.
    pub fn relocateMachO(self: Bottle, keg_path: []const u8) !void {
        const builtin = @import("builtin");
        if (comptime builtin.os.tag != .macos) return;

        var dir = try fs.openDirAbsolute(keg_path, .{});
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            self.relocateFileIfMachO(dir, keg_path, entry.path) catch continue;
        }
    }

    /// Check if 4-byte magic indicates a Mach-O binary.
    fn isMachOMagic(magic: *const [4]u8) bool {
        const m = mem.readInt(u32, magic, .big);
        return switch (m) {
            0xFEEDFACE, 0xFEEDFACF, // big-endian 32/64-bit
            0xCEFAEDFE, 0xCFFAEDFE, // little-endian 32/64-bit
            0xCAFEBABE, // universal/fat binary
            => true,
            else => false,
        };
    }

    /// Inspect a single file; if it is a Mach-O binary with @@HOMEBREW_*@@
    /// placeholders in its load commands, rewrite them with install_name_tool
    /// and re-sign.
    fn relocateFileIfMachO(self: Bottle, dir: fs.Dir, keg_path: []const u8, sub_path: []const u8) !void {
        // Read first 4 bytes to check Mach-O magic.
        var magic: [4]u8 = undefined;
        {
            var file = dir.openFile(sub_path, .{}) catch return;
            defer file.close();
            var read_buf: [16]u8 = undefined;
            var reader = file.reader(&read_buf);
            reader.interface.readSliceAll(&magic) catch return;
        }
        if (!isMachOMagic(&magic)) return;

        // Build absolute path.
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ keg_path, sub_path });
        defer self.allocator.free(full_path);

        // Run otool -D to get dylib ID and otool -L to get linked libraries.
        const otool_d = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "otool", "-D", full_path },
        }) catch return;
        defer self.allocator.free(otool_d.stdout);
        defer self.allocator.free(otool_d.stderr);

        const otool_l = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "otool", "-L", full_path },
        }) catch return;
        defer self.allocator.free(otool_l.stdout);
        defer self.allocator.free(otool_l.stderr);

        // Collect install_name_tool arguments.
        var args = std.ArrayList([]const u8){};
        defer {
            // Free all allocated arg strings (skip argv[0] = literal).
            for (args.items) |arg| {
                if (isPlaceholderAllocated(arg)) self.allocator.free(arg);
            }
            args.deinit(self.allocator);
        }

        try args.append(self.allocator, "install_name_tool");
        var has_changes = false;

        // Parse otool -D output for dylib ID with placeholder.
        {
            var lines = mem.splitScalar(u8, otool_d.stdout, '\n');
            _ = lines.next(); // skip filename line
            if (lines.next()) |id_line| {
                const trimmed = mem.trim(u8, id_line, " \t");
                if (hasPlaceholder(trimmed)) {
                    const new_id = try self.replacePlaceholderPath(trimmed);
                    try args.append(self.allocator, "-id");
                    try args.append(self.allocator, new_id);
                    has_changes = true;
                }
            }
        }

        // Parse otool -L output for linked libraries with placeholders.
        {
            var lines = mem.splitScalar(u8, otool_l.stdout, '\n');
            while (lines.next()) |line| {
                const trimmed = mem.trim(u8, line, " \t");
                if (!hasPlaceholder(trimmed)) continue;

                // Extract path: everything before " (compatibility".
                const end = mem.indexOf(u8, trimmed, " (") orelse continue;
                const old_path = trimmed[0..end];

                const new_path = try self.replacePlaceholderPath(old_path);

                try args.append(self.allocator, "-change");
                try args.append(self.allocator, try self.allocator.dupe(u8, old_path));
                try args.append(self.allocator, new_path);
                has_changes = true;
            }
        }

        if (!has_changes) return;

        try args.append(self.allocator, try self.allocator.dupe(u8, full_path));

        // Run install_name_tool.
        const int_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = args.items,
        }) catch return;
        self.allocator.free(int_result.stdout);
        self.allocator.free(int_result.stderr);

        // Re-sign with ad-hoc signature (required on Apple Silicon).
        const cs_result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "codesign", "--force", "--sign", "-", full_path },
        }) catch return;
        self.allocator.free(cs_result.stdout);
        self.allocator.free(cs_result.stderr);
    }

    fn hasPlaceholder(s: []const u8) bool {
        return mem.indexOf(u8, s, "@@HOMEBREW_CELLAR@@") != null or
            mem.indexOf(u8, s, "@@HOMEBREW_PREFIX@@") != null;
    }

    /// Check if a string was heap-allocated (not a string literal from argv).
    /// We know literals are "install_name_tool", "-id", "-change"; everything
    /// else was allocated.
    fn isPlaceholderAllocated(s: []const u8) bool {
        return !mem.eql(u8, s, "install_name_tool") and
            !mem.eql(u8, s, "-id") and
            !mem.eql(u8, s, "-change");
    }

    /// Replace @@HOMEBREW_CELLAR@@ and @@HOMEBREW_PREFIX@@ in a path string.
    /// Caller owns the returned string.
    fn replacePlaceholderPath(self: Bottle, path: []const u8) ![]const u8 {
        var current = try self.allocator.dupe(u8, path);

        const placeholders = [_]struct { needle: []const u8, replacement: []const u8 }{
            .{ .needle = "@@HOMEBREW_CELLAR@@", .replacement = self.cellar },
            .{ .needle = "@@HOMEBREW_PREFIX@@", .replacement = self.prefix },
        };

        for (placeholders) |ph| {
            const count = mem.count(u8, current, ph.needle);
            if (count == 0) continue;
            const new_len = current.len - (ph.needle.len * count) + (ph.replacement.len * count);
            const new_buf = try self.allocator.alloc(u8, new_len);
            _ = mem.replace(u8, current, ph.needle, ph.replacement, new_buf);
            self.allocator.free(current);
            current = new_buf;
        }

        return current;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "replacePlaceholders replaces in text file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a subdirectory structure simulating a keg.
    try tmp.dir.makePath("bin");

    // Write a text file containing placeholders.
    try tmp.dir.writeFile(.{
        .sub_path = "bin/mytool",
        .data = "#!/bin/sh\nexec @@HOMEBREW_PREFIX@@/bin/real-tool --cellar=@@HOMEBREW_CELLAR@@ --repo=@@HOMEBREW_REPOSITORY@@\n",
    });

    // Get the absolute path of the tmp dir.
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_path = try tmp.dir.realpath(".", &path_buf);

    const bottle = Bottle{
        .allocator = allocator,
        .cellar = "/opt/homebrew/Cellar",
        .prefix = "/opt/homebrew",
    };

    try bottle.replacePlaceholders(keg_path);

    // Read the file back and verify.
    const result = try tmp.dir.readFileAlloc(allocator, "bin/mytool", 1024 * 1024);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "#!/bin/sh\nexec /opt/homebrew/bin/real-tool --cellar=/opt/homebrew/Cellar --repo=/opt/homebrew\n",
        result,
    );
}

test "replacePlaceholders skips binary files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a binary file with null bytes and a placeholder.
    var binary_content: [64]u8 = undefined;
    @memset(&binary_content, 0);
    // Put a placeholder in the middle (after the null bytes in the first 512).
    const placeholder = "@@HOMEBREW_PREFIX@@";
    @memcpy(binary_content[10 .. 10 + placeholder.len], placeholder);

    try tmp.dir.writeFile(.{
        .sub_path = "binary_file",
        .data = &binary_content,
    });

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_path = try tmp.dir.realpath(".", &path_buf);

    const bottle = Bottle{
        .allocator = allocator,
        .cellar = "/opt/homebrew/Cellar",
        .prefix = "/opt/homebrew",
    };

    try bottle.replacePlaceholders(keg_path);

    // Verify the binary file was NOT modified.
    var read_buf: [64]u8 = undefined;
    const result = try tmp.dir.readFile("binary_file", &read_buf);
    try std.testing.expectEqual(@as(usize, 64), result.len);
    try std.testing.expectEqual(@as(u8, 0), result[0]);
    try std.testing.expectEqual(@as(u8, 0), result[9]);
}

test "replacePlaceholders leaves files without placeholders unchanged" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "This is a plain text file with no placeholders.\n";
    try tmp.dir.writeFile(.{
        .sub_path = "plain.txt",
        .data = original,
    });

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_path = try tmp.dir.realpath(".", &path_buf);

    const bottle = Bottle{
        .allocator = allocator,
        .cellar = "/opt/homebrew/Cellar",
        .prefix = "/opt/homebrew",
    };

    try bottle.replacePlaceholders(keg_path);

    const result = try tmp.dir.readFileAlloc(allocator, "plain.txt", 1024 * 1024);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(original, result);
}

test "pour extracts tar.gz into cellar" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create the structure that would appear inside a bottle: {name}/{version}/bin/tool
    try tmp.dir.makePath("bat/0.26.1/bin");
    try tmp.dir.writeFile(.{
        .sub_path = "bat/0.26.1/bin/bat",
        .data = "#!/bin/sh\necho bat\n",
    });

    // Get absolute path for the tmp dir.
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Create a tar.gz of the bat directory using system tar.
    const archive_name = "bat-0.26.1.tar.gz";
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "czf", archive_name, "bat" },
        .cwd_dir = tmp.dir,
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    // Set up a "cellar" directory.
    try tmp.dir.makeDir("cellar");
    var cellar_buf: [fs.max_path_bytes]u8 = undefined;
    const cellar_path = try tmp.dir.realpath("cellar", &cellar_buf);

    // Build the archive absolute path.
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, archive_name });
    defer allocator.free(archive_path);

    const bottle = Bottle{
        .allocator = allocator,
        .cellar = cellar_path,
        .prefix = "/opt/homebrew",
    };

    const keg_path = try bottle.pour(archive_path, "bat", "0.26.1");
    defer allocator.free(keg_path);

    // Verify the keg path is correct.
    const expected_keg = try std.fmt.allocPrint(allocator, "{s}/bat/0.26.1", .{cellar_path});
    defer allocator.free(expected_keg);
    try std.testing.expectEqualStrings(expected_keg, keg_path);

    // Verify the extracted file exists and has correct content.
    const extracted = try tmp.dir.readFileAlloc(allocator, "cellar/bat/0.26.1/bin/bat", 1024 * 1024);
    defer allocator.free(extracted);
    try std.testing.expectEqualStrings("#!/bin/sh\necho bat\n", extracted);
}

test "writeWorker writes files from tasks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create parent directory.
    try tmp.dir.makePath("pkg/bin");

    var pool = try BufferPool.init();
    defer pool.deinit();

    // Build two write tasks.
    var tasks: [2]WriteTask = undefined;

    // Task 0: write "hello" to pkg/bin/tool1
    const slot0 = pool.claim().?;
    @memcpy(slot0.buf[0..5], "hello");
    var name0: [fs.max_path_bytes]u8 = undefined;
    const path0 = "pkg/bin/tool1";
    @memcpy(name0[0..path0.len], path0);
    tasks[0] = .{
        .dir = tmp.dir,
        .file_name = name0,
        .file_name_len = path0.len,
        .content_len = 5,
        .mode = fs.File.default_mode,
        .pool = &pool,
        .pool_index = slot0.index,
        .err = null,
    };

    // Task 1: write "world!" to pkg/bin/tool2
    const slot1 = pool.claim().?;
    @memcpy(slot1.buf[0..6], "world!");
    var name1: [fs.max_path_bytes]u8 = undefined;
    const path1 = "pkg/bin/tool2";
    @memcpy(name1[0..path1.len], path1);
    tasks[1] = .{
        .dir = tmp.dir,
        .file_name = name1,
        .file_name_len = path1.len,
        .content_len = 6,
        .mode = fs.File.default_mode,
        .pool = &pool,
        .pool_index = slot1.index,
        .err = null,
    };

    // Run worker synchronously (single-threaded test).
    var next_index: usize = 0;
    writeWorker(.{
        .tasks = &tasks,
        .next_index = &next_index,
        .pool = &pool,
    });

    // Verify files were written.
    const content0 = try tmp.dir.readFileAlloc(std.testing.allocator, "pkg/bin/tool1", 1024);
    defer std.testing.allocator.free(content0);
    try std.testing.expectEqualStrings("hello", content0);

    const content1 = try tmp.dir.readFileAlloc(std.testing.allocator, "pkg/bin/tool2", 1024);
    defer std.testing.allocator.free(content1);
    try std.testing.expectEqualStrings("world!", content1);

    // Verify both buffers were released back to pool.
    try std.testing.expectEqual(@as(u8, 0xFF), pool.available);
}

test "BufferPool claim and release" {
    var pool = try BufferPool.init();
    defer pool.deinit();

    // Claim all 8 buffers.
    var indices: [BufferPool.pool_size]u8 = undefined;
    for (0..BufferPool.pool_size) |i| {
        const slot = pool.claim().?;
        indices[i] = slot.index;
        // Write something to verify the buffer is usable.
        slot.buf[0] = @intCast(i);
    }

    // All buffers claimed — tryClaim should return null.
    try std.testing.expect(pool.tryClaim() == null);

    // Release one buffer.
    pool.release(indices[3]);

    // Now we can claim again and get that same index back.
    const reclaimed = pool.claim().?;
    try std.testing.expectEqual(indices[3], reclaimed.index);
}

test "pour extracts tar.gz with multiple files in parallel" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a bottle structure with multiple files across directories.
    try tmp.dir.makePath("mypkg/1.0.0/bin");
    try tmp.dir.makePath("mypkg/1.0.0/lib");
    try tmp.dir.makePath("mypkg/1.0.0/share/doc");

    try tmp.dir.writeFile(.{ .sub_path = "mypkg/1.0.0/bin/tool1", .data = "#!/bin/sh\necho tool1\n" });
    try tmp.dir.writeFile(.{ .sub_path = "mypkg/1.0.0/bin/tool2", .data = "#!/bin/sh\necho tool2\n" });
    try tmp.dir.writeFile(.{ .sub_path = "mypkg/1.0.0/lib/libfoo.dylib", .data = "fake dylib content" });
    try tmp.dir.writeFile(.{ .sub_path = "mypkg/1.0.0/lib/libbar.dylib", .data = "fake bar content" });
    try tmp.dir.writeFile(.{ .sub_path = "mypkg/1.0.0/share/doc/README", .data = "This is the readme.\n" });

    // Get absolute path for the tmp dir.
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Create a tar.gz of the package directory.
    const archive_name = "mypkg-1.0.0.tar.gz";
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "czf", archive_name, "mypkg" },
        .cwd_dir = tmp.dir,
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    // Set up a "cellar" directory.
    try tmp.dir.makeDir("cellar");
    var cellar_buf: [fs.max_path_bytes]u8 = undefined;
    const cellar_path = try tmp.dir.realpath("cellar", &cellar_buf);

    // Build the archive absolute path.
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, archive_name });
    defer allocator.free(archive_path);

    const bottle = Bottle{
        .allocator = allocator,
        .cellar = cellar_path,
        .prefix = "/opt/homebrew",
    };

    const keg_path = try bottle.pour(archive_path, "mypkg", "1.0.0");
    defer allocator.free(keg_path);

    // Verify all files were extracted with correct content.
    const t1 = try tmp.dir.readFileAlloc(allocator, "cellar/mypkg/1.0.0/bin/tool1", 1024 * 1024);
    defer allocator.free(t1);
    try std.testing.expectEqualStrings("#!/bin/sh\necho tool1\n", t1);

    const t2 = try tmp.dir.readFileAlloc(allocator, "cellar/mypkg/1.0.0/bin/tool2", 1024 * 1024);
    defer allocator.free(t2);
    try std.testing.expectEqualStrings("#!/bin/sh\necho tool2\n", t2);

    const lib = try tmp.dir.readFileAlloc(allocator, "cellar/mypkg/1.0.0/lib/libfoo.dylib", 1024 * 1024);
    defer allocator.free(lib);
    try std.testing.expectEqualStrings("fake dylib content", lib);

    const bar = try tmp.dir.readFileAlloc(allocator, "cellar/mypkg/1.0.0/lib/libbar.dylib", 1024 * 1024);
    defer allocator.free(bar);
    try std.testing.expectEqualStrings("fake bar content", bar);

    const readme = try tmp.dir.readFileAlloc(allocator, "cellar/mypkg/1.0.0/share/doc/README", 1024 * 1024);
    defer allocator.free(readme);
    try std.testing.expectEqualStrings("This is the readme.\n", readme);
}

test "pour handles files larger than buffer pool size" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a file slightly larger than the 1MB buffer pool slot.
    const large_size = BufferPool.buf_size + 1024;
    const large_content = try allocator.alloc(u8, large_size);
    defer allocator.free(large_content);
    // Fill with a repeating pattern so we can verify content.
    for (large_content, 0..) |*byte, i| {
        byte.* = @intCast(i % 251); // prime number for pattern
    }

    try tmp.dir.makePath("bigpkg/2.0.0/lib");
    try tmp.dir.writeFile(.{ .sub_path = "bigpkg/2.0.0/lib/bigfile.bin", .data = large_content });
    // Also include a small file to test mixed sync/async.
    try tmp.dir.makePath("bigpkg/2.0.0/bin");
    try tmp.dir.writeFile(.{ .sub_path = "bigpkg/2.0.0/bin/tool", .data = "small file" });

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const archive_name = "bigpkg-2.0.0.tar.gz";
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "czf", archive_name, "bigpkg" },
        .cwd_dir = tmp.dir,
    });
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    try tmp.dir.makeDir("cellar");
    var cellar_buf: [fs.max_path_bytes]u8 = undefined;
    const cellar_path = try tmp.dir.realpath("cellar", &cellar_buf);

    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, archive_name });
    defer allocator.free(archive_path);

    const bottle = Bottle{
        .allocator = allocator,
        .cellar = cellar_path,
        .prefix = "/opt/homebrew",
    };

    const keg_path = try bottle.pour(archive_path, "bigpkg", "2.0.0");
    defer allocator.free(keg_path);

    // Verify the large file was extracted correctly.
    const extracted = try tmp.dir.readFileAlloc(allocator, "cellar/bigpkg/2.0.0/lib/bigfile.bin", large_size + 1);
    defer allocator.free(extracted);
    try std.testing.expectEqual(large_size, extracted.len);
    try std.testing.expectEqualSlices(u8, large_content, extracted);

    // Verify the small file was also extracted.
    const small = try tmp.dir.readFileAlloc(allocator, "cellar/bigpkg/2.0.0/bin/tool", 1024);
    defer allocator.free(small);
    try std.testing.expectEqualStrings("small file", small);
}

test "pourWithCache returns cached keg on second call" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a bottle structure: {name}/{version}/bin/tool
    try tmp.dir.makePath("cachepkg/1.0.0/bin");
    try tmp.dir.writeFile(.{
        .sub_path = "cachepkg/1.0.0/bin/tool",
        .data = "#!/bin/sh\necho cachepkg\n",
    });

    // Get absolute path for the tmp dir.
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Create a tar.gz of the package directory.
    const archive_name = "cachepkg-1.0.0.tar.gz";
    const tar_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "czf", archive_name, "cachepkg" },
        .cwd_dir = tmp.dir,
    });
    allocator.free(tar_result.stdout);
    allocator.free(tar_result.stderr);

    // Set up "cellar" and "keg_cache" directories.
    try tmp.dir.makeDir("cellar");
    try tmp.dir.makeDir("keg_cache");
    var cellar_buf: [fs.max_path_bytes]u8 = undefined;
    const cellar_path = try tmp.dir.realpath("cellar", &cellar_buf);
    var cache_buf: [fs.max_path_bytes]u8 = undefined;
    const keg_cache_path = try tmp.dir.realpath("keg_cache", &cache_buf);

    // Build the archive absolute path.
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, archive_name });
    defer allocator.free(archive_path);

    const bottle = Bottle{
        .allocator = allocator,
        .cellar = cellar_path,
        .prefix = "/opt/homebrew",
    };

    const fake_sha = "abc123deadbeef";

    // --- First call: slow path (extract + populate cache) ---
    const keg_path1 = try bottle.pourWithCache(archive_path, "cachepkg", "1.0.0", fake_sha, keg_cache_path);
    defer allocator.free(keg_path1);

    // Verify the keg was extracted in the cellar.
    const extracted1 = try tmp.dir.readFileAlloc(allocator, "cellar/cachepkg/1.0.0/bin/tool", 1024 * 1024);
    defer allocator.free(extracted1);
    try std.testing.expectEqualStrings("#!/bin/sh\necho cachepkg\n", extracted1);

    // Verify the cache was populated.
    const cache_tool_path = try std.fmt.allocPrint(allocator, "keg_cache/{s}/cachepkg/1.0.0/bin/tool", .{fake_sha});
    defer allocator.free(cache_tool_path);
    const cached = try tmp.dir.readFileAlloc(allocator, cache_tool_path, 1024 * 1024);
    defer allocator.free(cached);
    try std.testing.expectEqualStrings("#!/bin/sh\necho cachepkg\n", cached);

    // --- Delete the cellar keg to prove the second call uses the cache ---
    try tmp.dir.deleteTree("cellar/cachepkg");

    // --- Second call: fast path (clone from cache) ---
    const keg_path2 = try bottle.pourWithCache(archive_path, "cachepkg", "1.0.0", fake_sha, keg_cache_path);
    defer allocator.free(keg_path2);

    // Verify the keg was restored from cache.
    const extracted2 = try tmp.dir.readFileAlloc(allocator, "cellar/cachepkg/1.0.0/bin/tool", 1024 * 1024);
    defer allocator.free(extracted2);
    try std.testing.expectEqualStrings("#!/bin/sh\necho cachepkg\n", extracted2);
}

