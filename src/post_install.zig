const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const formula_rb = @import("formula_rb.zig");

pub const Outcome = enum {
    ran,
    skipped_no_block,
    skipped_user,
    skipped_no_ruby,
    failed,

    pub fn toString(self: Outcome) []const u8 {
        return switch (self) {
            .ran => "ran",
            .skipped_no_block => "skipped_no_block",
            .skipped_user => "skipped_user",
            .skipped_no_ruby => "skipped_no_ruby",
            .failed => "failed",
        };
    }
};

pub const Result = struct {
    outcome: Outcome,
    error_summary: ?[]const u8 = null,
    log_path: ?[]const u8 = null,

    pub fn free(self: Result, allocator: Allocator) void {
        if (self.error_summary) |s| allocator.free(s);
        if (self.log_path) |p| allocator.free(p);
    }
};

const harness_rb = @embedFile("post_install_harness.rb"); // copied from assets/post_install_harness.rb

pub fn run(
    allocator: Allocator,
    config: Config,
    formula_name: []const u8,
    pkg_version: []const u8,
    keg_path: []const u8,
    post_install_defined: bool,
) !Result {
    if (!post_install_defined) {
        return .{ .outcome = .skipped_no_block };
    }
    if (config.no_post_install) {
        return .{ .outcome = .skipped_user };
    }
    // Check ruby exists.
    std.fs.accessAbsolute(config.ruby_path, .{}) catch {
        return .{ .outcome = .skipped_no_ruby };
    };

    return runActual(allocator, config, formula_name, pkg_version, keg_path);
}

fn runActual(
    allocator: Allocator,
    config: Config,
    formula_name: []const u8,
    pkg_version: []const u8,
    keg_path: []const u8,
) !Result {
    // 1. Fetch the .rb source (also caches to disk at <cache>/formula-rb/<name>-<ver>.rb).
    const source = formula_rb.fetchSource(allocator, config.cache, formula_name, pkg_version) catch |err| {
        const summary = try std.fmt.allocPrint(allocator, "fetch failed: {s}", .{@errorName(err)});
        errdefer allocator.free(summary);
        return failedResult(allocator, config.cache, formula_name, summary, "");
    };
    allocator.free(source);

    // 2. Resolve the cached .rb path — fetchSource just wrote it. Pass the path
    // (not the contents) to the harness, so the harness can load the full
    // formula class.
    const rb_path = try std.fmt.allocPrint(
        allocator, "{s}/formula-rb/{s}-{s}.rb",
        .{ config.cache, formula_name, pkg_version },
    );
    defer allocator.free(rb_path);

    // 3. Write the harness to a temp file.
    const tmp_dir = "/tmp";
    const ts = std.time.milliTimestamp();
    const harness_path = try std.fmt.allocPrint(
        allocator, "{s}/bru-pi-harness-{d}.rb", .{ tmp_dir, ts },
    );
    defer allocator.free(harness_path);
    {
        const f = try std.fs.cwd().createFile(harness_path, .{});
        defer f.close();
        try f.writeAll(harness_rb);
    }
    defer std.fs.cwd().deleteFile(harness_path) catch {};

    // 4. Build env map.
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    if (std.posix.getenv("HOME")) |v| try env.put("HOME", v);
    if (std.posix.getenv("PATH")) |v| try env.put("PATH", v);
    try env.put("HOMEBREW_PREFIX", config.prefix);
    try env.put("HOMEBREW_CELLAR", config.cellar);
    try env.put("HOMEBREW_REPOSITORY", config.repository);
    try env.put("HOMEBREW_FORMULA_PREFIX", keg_path);
    try env.put("BRU_FORMULA_NAME", formula_name);
    try env.put("BRU_FORMULA_VERSION", pkg_version);
    if (config.verbose) try env.put("HOMEBREW_VERBOSE", "1");

    // 5. Spawn /usr/bin/ruby with the harness — the harness reads the full .rb,
    // stubs the Homebrew DSL, and invokes klass.new.post_install.
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ config.ruby_path, "--disable-gems", harness_path, rb_path },
        .env_map = &env,
        .max_output_bytes = 1 << 20,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: i32 = switch (result.term) {
        .Exited => |c| c,
        else => -1,
    };
    if (exit_code == 0) {
        return .{ .outcome = .ran };
    }

    // Failure path: write log file.
    const summary = try summaryFromStderr(allocator, result.stderr);
    errdefer allocator.free(summary);
    return failedResult(allocator, config.cache, formula_name, summary, result.stderr);
}

fn summaryFromStderr(allocator: Allocator, stderr: []const u8) ![]u8 {
    // First non-empty line, truncated to 200 chars.
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const len = @min(trimmed.len, 200);
        return allocator.dupe(u8, trimmed[0..len]);
    }
    return allocator.dupe(u8, "post_install exited non-zero with no stderr output");
}

fn failedResult(
    allocator: Allocator,
    cache: []const u8,
    formula_name: []const u8,
    summary: []const u8,
    stderr_content: []const u8,
) !Result {
    const ts = std.time.timestamp();
    const log_dir = try std.fmt.allocPrint(allocator, "{s}/post-install-logs", .{cache});
    defer allocator.free(log_dir);
    std.fs.cwd().makePath(log_dir) catch {};
    const log_path = try std.fmt.allocPrint(
        allocator, "{s}/{s}-{d}.log", .{ log_dir, formula_name, ts },
    );
    if (std.fs.cwd().createFile(log_path, .{})) |f| {
        defer f.close();
        f.writeAll(stderr_content) catch {};
    } else |_| {}
    return .{ .outcome = .failed, .error_summary = summary, .log_path = log_path };
}

// Tests ----------------------------------------------------------------------

test "skipped_no_block when post_install not defined" {
    const allocator = std.testing.allocator;
    var cfg = try Config.load(allocator);
    defer cfg.deinit();
    const r = try run(allocator, cfg, "tree", "2.1.0", "/tmp/keg-doesnt-matter", false);
    defer r.free(allocator);
    try std.testing.expectEqual(Outcome.skipped_no_block, r.outcome);
}

test "skipped_user when no_post_install set" {
    const allocator = std.testing.allocator;
    var cfg = try Config.load(allocator);
    defer cfg.deinit();
    cfg.no_post_install = true;
    const r = try run(allocator, cfg, "node", "21.0.0", "/tmp/keg", true);
    defer r.free(allocator);
    try std.testing.expectEqual(Outcome.skipped_user, r.outcome);
}

test "skipped_no_ruby when ruby_path absent" {
    const allocator = std.testing.allocator;
    var cfg = try Config.load(allocator);
    defer cfg.deinit();
    cfg.ruby_path = "/nonexistent/path/to/ruby";
    const r = try run(allocator, cfg, "node", "21.0.0", "/tmp/keg", true);
    defer r.free(allocator);
    try std.testing.expectEqual(Outcome.skipped_no_ruby, r.outcome);
}
