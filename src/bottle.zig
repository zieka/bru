const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("config.zig").Config;

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

    /// Extract a .tar.gz bottle into the cellar.
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

        // Set up gzip decompression: buffered reader -> gzip decompressor -> tar extraction.
        var read_buf: [4096]u8 = undefined;
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

        // Extract the tar contents into the cellar.
        // Bottle tars contain entries like {name}/{version}/bin/... so they
        // extract directly to {cellar}/{name}/{version}/...
        try std.tar.pipeToFileSystem(cellar_dir, &decompressor.reader, .{});

        // Construct and return the keg path.
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
            self.cellar,
            name,
            version,
        });
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

