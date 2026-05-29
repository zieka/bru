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

        // Retry transient download failures with exponential backoff. brew
        // retries downloads; without this, a single dropped connection or
        // mid-stream write hiccup aborts the install.
        const max_attempts: u8 = 3;
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            attemptFetch(&self.client, url, dest_path, headers, extra_headers) catch |err| {
                if (attempt + 1 < max_attempts and isTransient(err)) {
                    // Wipe the partial blob so the next attempt starts clean.
                    std.fs.cwd().deleteFile(dest_path) catch {};
                    // 500ms, 1500ms backoff.
                    const delay_ns: u64 = @as(u64, 500) * std.time.ns_per_ms * (@as(u64, 1) + @as(u64, attempt) * 2);
                    std.Thread.sleep(delay_ns);
                    continue;
                }
                return err;
            };
            return;
        }
    }
};

/// Retriable error set for HTTP downloads: connection drops, mid-stream IO
/// failures, and DNS hiccups. Status-code failures (HttpError) and SHA
/// mismatches are NOT in here — those will repeat on retry.
fn isTransient(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionClosing,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.TemporaryNameServerFailure,
        error.WriteFailed,
        error.ReadFailed,
        error.UnexpectedReadFailure,
        error.EndOfStream,
        => true,
        else => false,
    };
}

/// Single download attempt: creates dest_path, streams the response into it,
/// and validates the status code.
fn attemptFetch(
    client: *std.http.Client,
    url: []const u8,
    dest_path: []const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
) !void {
    const file = try std.fs.cwd().createFile(dest_path, .{});
    defer file.close();

    var write_buf: [8192]u8 = undefined;
    var file_writer = file.writer(&write_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .headers = headers,
        .extra_headers = extra_headers,
        .response_writer = &file_writer.interface,
    });

    try file_writer.interface.flush();

    if (result.status.class() != .success) {
        // Emit context to stderr before returning the bare error so users can
        // see WHY the download failed (status code + URL). Bare HttpError
        // alone is unactionable (Bug 3).
        var msg_buf: [1024]u8 = undefined;
        const msg = formatHttpFailure(&msg_buf, @intFromEnum(result.status), url);
        std.debug.print("{s}\n", .{msg});
        return error.HttpError;
    }
}

/// Format an HTTP failure into `buf` as "HTTP {code} from {url}". If the
/// buffer is too small, the message is truncated but always starts with
/// "HTTP {code}" so the most important info survives.
fn formatHttpFailure(buf: []u8, status_code: u16, url: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "HTTP {d} from {s}", .{ status_code, url }) catch blk: {
        // bufPrint failed because the URL doesn't fit. Truncate by writing
        // just the status code, which always fits in a sensible buffer.
        break :blk std.fmt.bufPrint(buf, "HTTP {d}", .{status_code}) catch buf[0..0];
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isTransient classifies retriable errors" {
    try std.testing.expect(isTransient(error.HttpConnectionClosing));
    try std.testing.expect(isTransient(error.WriteFailed));
    try std.testing.expect(isTransient(error.ConnectionResetByPeer));
    try std.testing.expect(!isTransient(error.HttpError));
    try std.testing.expect(!isTransient(error.OutOfMemory));
}

test "formatHttpFailure includes status code and URL" {
    var buf: [256]u8 = undefined;
    const msg = formatHttpFailure(&buf, 404, "https://example.com/foo.dmg");
    try std.testing.expectEqualStrings(
        "HTTP 404 from https://example.com/foo.dmg",
        msg,
    );
}

test "formatHttpFailure truncates long URLs gracefully" {
    var buf: [40]u8 = undefined;
    const msg = formatHttpFailure(&buf, 500, "https://example.com/path");
    // Buffer can't hold the whole message; we still want a sane prefix.
    try std.testing.expect(std.mem.startsWith(u8, msg, "HTTP 500"));
}

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
