const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const download = @import("../download.zig");
const Download = download.Download;
const HttpClient = @import("../http.zig").HttpClient;
const Output = @import("../output.zig").Output;

/// Download a bottle for a formula without installing it.
///
/// Usage: bru fetch <formula>
///
/// Looks up the formula in the binary index, constructs the GHCR blob URL,
/// and downloads the bottle to the cache directory.
pub fn fetchCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    if (args.len == 0) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru fetch <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const formula_name = args[0];

    var idx = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.

    const entry = idx.lookup(formula_name) orelse {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula with the name \"{s}\".", .{formula_name});
        err_out.print("Searched: {s}/api/formula.jws.json\n", .{config.cache});
        std.process.exit(1);
    };

    const bottle_root_url = idx.getString(entry.bottle_root_url_offset);
    const bottle_sha256 = idx.getString(entry.bottle_sha256_offset);

    if (bottle_root_url.len == 0 or bottle_sha256.len == 0) {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No bottle available for \"{s}\".", .{formula_name});
        std.process.exit(1);
    }

    // Construct the GHCR blob URL: {root_url}/{image_name}/blobs/sha256:{sha256}
    const image_name = try download.ghcrImageName(allocator, formula_name);
    defer allocator.free(image_name);

    const url = try std.fmt.allocPrint(allocator, "{s}/{s}/blobs/sha256:{s}", .{ bottle_root_url, image_name, bottle_sha256 });
    defer allocator.free(url);

    const out = Output.init(config.no_color);

    const section_title = try std.fmt.allocPrint(allocator, "Fetching {s}", .{formula_name});
    defer allocator.free(section_title);
    out.section(section_title);

    var http_client = HttpClient.init(allocator);
    defer http_client.deinit();

    var dl = Download.init(allocator, config.cache, &http_client);
    const cached_path = try dl.fetchBottle(url, formula_name, bottle_sha256);
    defer allocator.free(cached_path);

    out.print("Downloaded to: {s}\n", .{cached_path});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fetchCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = fetchCmd;
    _ = handler;
}
