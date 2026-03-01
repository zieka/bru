const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const HttpClient = @import("../http.zig").HttpClient;
const Index = @import("../index.zig").Index;
const CaskIndex = @import("../cask_index.zig").CaskIndex;
const Output = @import("../output.zig").Output;

/// Fetch fresh API data and rebuild the binary index.
///
/// Usage: bru update
///
/// Downloads the latest formula.jws.json from the Homebrew API,
/// deletes any stale binary index, and rebuilds it from the fresh data.
pub fn updateCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    _ = args;

    const out = Output.init(config.no_color);
    out.section("Updating formulae");

    // Construct paths for the JWS file and binary index.
    var jws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const jws_path = std.fmt.bufPrint(&jws_buf, "{s}/api/formula.jws.json", .{config.cache}) catch
        return error.PathTooLong;

    var idx_buf: [std.fs.max_path_bytes]u8 = undefined;
    const idx_path = std.fmt.bufPrint(&idx_buf, "{s}/api/formula.bru.idx", .{config.cache}) catch
        return error.PathTooLong;

    // Ensure the api/ directory exists.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const api_dir = std.fmt.bufPrint(&dir_buf, "{s}/api", .{config.cache}) catch
        return error.PathTooLong;
    std.fs.cwd().makePath(api_dir) catch |err| {
        const err_out = Output.initErr(config.no_color);
        err_out.err("Failed to create cache directory: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // Download fresh formula.jws.json from the Homebrew API.
    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.fetch("https://formulae.brew.sh/api/formula.jws.json", jws_path) catch |err| {
        const err_out = Output.initErr(config.no_color);
        err_out.err("Failed to download formula data: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // Delete old binary index to force a rebuild.
    std.fs.deleteFileAbsolute(idx_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            const err_out = Output.initErr(config.no_color);
            err_out.err("Failed to remove old index: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
    };

    // Rebuild the index from the fresh JWS data.
    var idx = try Index.loadOrBuild(allocator, config.cache);
    idx.deinit();

    // Also download cask data
    out.print("Downloading cask data...\n", .{});

    var cask_jws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cask_jws_path = std.fmt.bufPrint(&cask_jws_buf, "{s}/api/cask.jws.json", .{config.cache}) catch
        return error.PathTooLong;

    var cask_idx_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cask_idx_path = std.fmt.bufPrint(&cask_idx_buf, "{s}/api/cask.bru.idx", .{config.cache}) catch
        return error.PathTooLong;

    client.fetch("https://formulae.brew.sh/api/cask.jws.json", cask_jws_path) catch |err| {
        out.warn("Failed to download cask data: {s}", .{@errorName(err)});
    };

    // Delete old cask index to force rebuild
    std.fs.deleteFileAbsolute(cask_idx_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            out.warn("Failed to remove old cask index: {s}", .{@errorName(err)});
        },
    };

    // Rebuild cask index (best effort)
    var cask_idx = CaskIndex.loadOrBuild(allocator, config.cache) catch null;
    if (cask_idx) |*ci| ci.deinit();

    out.section("Updated successfully");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "updateCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = updateCmd;
    _ = handler;
}
