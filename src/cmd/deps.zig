const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Output = @import("../output.zig").Output;

/// List dependencies for a formula.
///
/// Usage: bru deps [--include-build] <formula>
///
/// Prints runtime dependencies one per line. With --include-build, also
/// prints build-time dependencies.
pub fn depsCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    var include_build = false;
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--include-build")) {
            include_build = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (formula_name == null) {
                formula_name = arg;
            }
        }
    }

    if (formula_name == null) {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru deps [--include-build] <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var idx = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.

    const entry = idx.lookup(formula_name.?) orelse {
        const err_out = Output.initErr(config.no_color);
        err_out.err("No available formula with the name \"{s}\".", .{formula_name.?});
        std.process.exit(1);
    };

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    const deps = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(deps);

    for (deps) |dep| {
        try stdout.print("{s}\n", .{dep});
    }

    if (include_build) {
        const build_deps = try idx.getStringList(allocator, entry.build_deps_offset);
        defer allocator.free(build_deps);

        for (build_deps) |dep| {
            try stdout.print("{s}\n", .{dep});
        }
    }

    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "depsCmd compiles and has correct signature" {
    // Smoke test: verifies the function signature is correct and the module compiles.
    const handler: @import("../dispatch.zig").CommandFn = depsCmd;
    _ = handler;
}
