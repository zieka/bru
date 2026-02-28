const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("config.zig").Config;

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

