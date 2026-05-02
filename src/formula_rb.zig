const std = @import("std");
const Allocator = std.mem.Allocator;
const HttpClient = @import("http.zig").HttpClient;

/// Fetch a formula's `.rb` source, using an on-disk cache.
/// Cache key: `<cache_dir>/formula-rb/<name>-<pkg_version>.rb`.
/// Caller owns the returned slice.
pub fn fetchSource(
    allocator: Allocator,
    cache_dir: []const u8,
    formula_name: []const u8,
    pkg_version: []const u8,
) ![]u8 {
    const cache_path = try std.fmt.allocPrint(
        allocator, "{s}/formula-rb/{s}-{s}.rb",
        .{ cache_dir, formula_name, pkg_version },
    );
    defer allocator.free(cache_path);

    // Try cache first.
    if (std.fs.cwd().openFile(cache_path, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        const buf = try allocator.alloc(u8, stat.size);
        const n = file.readAll(buf) catch |e| {
            allocator.free(buf);
            return e;
        };
        if (n == stat.size) return buf;
        // Partial read — discard and fall through to network fetch.
        allocator.free(buf);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Not cached — fetch from raw.githubusercontent.com.
    if (formula_name.len == 0) return error.InvalidName;
    const first = std.ascii.toLower(formula_name[0]);
    const url = try std.fmt.allocPrint(
        allocator,
        "https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/{c}/{s}.rb",
        .{ first, formula_name },
    );
    defer allocator.free(url);

    var client = HttpClient.init(allocator);
    defer client.deinit();
    const body = try client.fetchToMemory(allocator, url);
    errdefer allocator.free(body);

    // Write to cache (best-effort; ignore failure).
    if (std.fs.path.dirname(cache_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    if (std.fs.cwd().createFile(cache_path, .{})) |cf| {
        defer cf.close();
        cf.writeAll(body) catch {};
    } else |_| {}

    return body;
}

// Tests --------------------------------------------------------------------

test "fetchSource caches by name+pkg_version" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = try tmp.dir.realpath(".", &path_buf);

    // Pre-populate the cache file so we don't actually fetch.
    const cache_subpath = try std.fmt.allocPrint(
        allocator, "{s}/formula-rb/node-21.0.0.rb", .{cache_dir},
    );
    defer allocator.free(cache_subpath);
    try std.fs.cwd().makePath(std.fs.path.dirname(cache_subpath).?);
    const cached = try std.fs.cwd().createFile(cache_subpath, .{});
    try cached.writeAll("class Node\n  def post_install\n    :ok\n  end\nend\n");
    cached.close();

    const source = try fetchSource(allocator, cache_dir, "node", "21.0.0");
    defer allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "def post_install") != null);
}
