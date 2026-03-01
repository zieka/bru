const std = @import("std");

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{ .allocator = allocator, .client = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Download a URL to a file path.
    pub fn fetch(self: *HttpClient, url: []const u8, dest_path: []const u8) !void {
        try self.fetchInner(url, dest_path, .{}, &.{});
    }

    /// Fetch a URL and return the response body as an owned slice.
    /// Downloads to a temporary file and reads it back into memory.
    /// Caller owns the returned memory and must free it with the provided allocator.
    pub fn fetchToMemory(self: *HttpClient, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
        // Create a unique temp path using a hash of the URL.
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(url);
        const digest = hasher.finalResult();
        const hex = std.fmt.bytesToHex(digest, .lower);

        const nonce = std.time.nanoTimestamp();
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/bru-fetch-{d}-{s}", .{ nonce, hex });

        // Download to temp file.
        try self.fetch(url, tmp_path);
        defer std.fs.cwd().deleteFile(tmp_path) catch {};

        // Read into memory.
        const file = try std.fs.cwd().openFile(tmp_path, .{});
        defer file.close();

        const stat = try file.stat();
        const body = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(body);

        const bytes_read = try file.readAll(body);
        if (bytes_read != stat.size) return error.UnexpectedEof;

        return body;
    }

    /// Download from GHCR with anonymous auth header (Authorization: Bearer QQ==).
    pub fn fetchGhcr(self: *HttpClient, url: []const u8, dest_path: []const u8) !void {
        try self.fetchInner(url, dest_path, .{
            .authorization = .{ .override = "Bearer QQ==" },
        }, &.{});
    }

    fn fetchInner(
        self: *HttpClient,
        url: []const u8,
        dest_path: []const u8,
        headers: std.http.Client.Request.Headers,
        extra_headers: []const std.http.Header,
    ) !void {
        // Create parent directories for dest_path if needed.
        if (std.fs.path.dirname(dest_path)) |parent| {
            if (parent.len > 0) {
                std.fs.cwd().makePath(parent) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }
        }

        // Open destination file for writing.
        const file = try std.fs.cwd().createFile(dest_path, .{});
        defer file.close();

        // Create a file-backed writer for the response body.
        var write_buf: [8192]u8 = undefined;
        var file_writer = file.writer(&write_buf);

        // Use the high-level fetch API which handles redirects automatically.
        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .headers = headers,
            .extra_headers = extra_headers,
            .response_writer = &file_writer.interface,
        });

        // Flush any remaining buffered data.
        try file_writer.interface.flush();

        // Check for non-success status.
        if (result.status.class() != .success) {
            return error.HttpError;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "HttpClient fetch downloads a file" {
    // Skip network tests in CI or when explicitly requested.
    if (std.posix.getenv("BRU_SKIP_NET_TESTS") != null) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dest_path = try std.fs.path.join(allocator, &.{
        ".zig-cache/tmp",
        &tmp.sub_path,
        "response.json",
    });
    defer allocator.free(dest_path);

    var client = HttpClient.init(allocator);
    defer client.deinit();
    try client.fetch(
        "https://httpbin.org/get",
        dest_path,
    );

    const file = try std.fs.cwd().openFile(dest_path, .{});
    defer file.close();

    const stat = try file.stat();
    try std.testing.expect(stat.size > 100);
}

test "HttpClient fetchGhcr with auth header" {
    // Skip network tests in CI or when explicitly requested.
    if (std.posix.getenv("BRU_SKIP_NET_TESTS") != null) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dest_path = try std.fs.path.join(allocator, &.{
        ".zig-cache/tmp",
        &tmp.sub_path,
        "config.json",
    });
    defer allocator.free(dest_path);

    var client = HttpClient.init(allocator);
    defer client.deinit();
    try client.fetchGhcr(
        "https://ghcr.io/v2/homebrew/core/jq/blobs/sha256:4b3576df4065747bf8c3b95c0a3eebc5f003a30819a645d9cc459bb06259c8ae",
        dest_path,
    );

    const file = try std.fs.cwd().openFile(dest_path, .{});
    defer file.close();

    const stat = try file.stat();
    try std.testing.expect(stat.size > 0);
}
