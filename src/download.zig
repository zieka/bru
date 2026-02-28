const std = @import("std");
const HttpClient = @import("http.zig").HttpClient;

pub const Download = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    http_client: *HttpClient,

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8, http_client: *HttpClient) Download {
        return .{ .allocator = allocator, .cache_dir = cache_dir, .http_client = http_client };
    }

    /// Return the cache path for a URL.
    /// Format: {cache_dir}/downloads/{sha256_of_url}--{safe_name}
    pub fn cachePath(self: Download, url: []const u8, name: []const u8) ![]const u8 {
        // Hash the URL with SHA-256.
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(url);
        const digest = hasher.finalResult();
        const hex = std.fmt.bytesToHex(digest, .lower);

        // Build the path: {cache_dir}/downloads/{hex}--{name}
        return std.fmt.allocPrint(self.allocator, "{s}/downloads/{s}--{s}", .{ self.cache_dir, hex, name });
    }

    /// Download a bottle, using cache if available and checksum matches.
    /// Returns the cache path (caller owns the string).
    pub fn fetchBottle(self: Download, url: []const u8, name: []const u8, expected_sha256: []const u8) ![]const u8 {
        const path = try self.cachePath(url, name);
        errdefer self.allocator.free(path);

        // Check if cached file exists and checksum matches.
        if (verifySha256(path, expected_sha256) catch false) {
            return path;
        }

        // Ensure the downloads directory exists.
        const downloads_dir = try std.fmt.allocPrint(self.allocator, "{s}/downloads", .{self.cache_dir});
        defer self.allocator.free(downloads_dir);
        std.fs.cwd().makePath(downloads_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Download via HttpClient.fetchGhcr.
        try self.http_client.fetchGhcr(url, path);

        // Verify checksum after download.
        const valid = try verifySha256(path, expected_sha256);
        if (!valid) {
            // Delete the bad file and return error.
            std.fs.cwd().deleteFile(path) catch {};
            return error.ChecksumMismatch;
        }

        return path;
    }
};

/// Verify a file's SHA-256 matches the expected hex hash.
/// Returns false (not error) if the file doesn't exist.
pub fn verifySha256(path: []const u8, expected_hex: []const u8) !bool {
    if (expected_hex.len != 64) return error.InvalidChecksum;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        const bytes_read = file.read(&buf) catch |err| return err;
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
    }

    const digest = hasher.finalResult();
    const actual_hex = std.fmt.bytesToHex(digest, .lower);

    return std.mem.eql(u8, &actual_hex, expected_hex);
}

/// Transform a formula name into a GHCR image name.
/// Replaces '@' with '/' and '+' with 'x'.
/// Returns an allocator-owned string.
pub fn ghcrImageName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = switch (c) {
            '@' => '/',
            '+' => 'x',
            else => c,
        };
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cachePath produces deterministic path" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();
    const dl = Download.init(allocator, "/tmp/bru-test-cache", &client);

    const path1 = try dl.cachePath("https://example.com/bottle.tar.gz", "myformula");
    defer allocator.free(path1);

    const path2 = try dl.cachePath("https://example.com/bottle.tar.gz", "myformula");
    defer allocator.free(path2);

    // Same URL+name should produce identical paths.
    try std.testing.expectEqualStrings(path1, path2);

    // Path should contain "downloads/".
    try std.testing.expect(std.mem.indexOf(u8, path1, "downloads/") != null);

    // Path should end with "--myformula".
    try std.testing.expect(std.mem.endsWith(u8, path1, "--myformula"));
}

test "verifySha256 on known content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write known content.
    const content = "hello world\n";
    const file = try tmp.dir.createFile("testfile.txt", .{});
    try file.writeAll(content);
    file.close();

    // Compute expected SHA-256 of "hello world\n".
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);
    const digest = hasher.finalResult();
    const expected_hex = std.fmt.bytesToHex(digest, .lower);

    // Build the full path to the temp file.
    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache/tmp",
        &tmp.sub_path,
        "testfile.txt",
    });
    defer allocator.free(path);

    const result = try verifySha256(path, &expected_hex);
    try std.testing.expect(result);

    // Also verify that a wrong hash returns false.
    const wrong = try verifySha256(path, "0000000000000000000000000000000000000000000000000000000000000000");
    try std.testing.expect(!wrong);
}

test "verifySha256 returns false for nonexistent file" {
    const result = try verifySha256("/tmp/__bru_nonexistent_file_abc123__.dat", "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234");
    try std.testing.expect(!result);
}

test "ghcrImageName simple name unchanged" {
    const allocator = std.testing.allocator;
    const result = try ghcrImageName(allocator, "bat");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("bat", result);
}

test "ghcrImageName replaces @ with /" {
    const allocator = std.testing.allocator;
    const result = try ghcrImageName(allocator, "python@3.12");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("python/3.12", result);
}

test "ghcrImageName replaces + with x" {
    const allocator = std.testing.allocator;
    const result = try ghcrImageName(allocator, "c++tools");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("cxxtools", result);
}

test "ghcrImageName replaces both @ and +" {
    const allocator = std.testing.allocator;
    const result = try ghcrImageName(allocator, "lib+tool@2");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("libxtool/2", result);
}
