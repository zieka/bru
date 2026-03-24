const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Output = @import("../output.zig").Output;

/// Manage background services for installed formulae via launchctl.
///
/// Usage: bru services [list]
///        bru services start <formula>
///        bru services stop <formula>
///        bru services restart <formula>
///        bru services run <formula>
///        bru services info <formula>
pub fn servicesCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const err_out = Output.initErr(config.no_color);

    // Parse subcommand and formula name from positional args (skip flags).
    var subcommand: ?[]const u8 = null;
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (mem.startsWith(u8, arg, "-")) continue;
        if (subcommand == null) {
            subcommand = arg;
        } else if (formula_name == null) {
            formula_name = arg;
        } else break;
    }

    const subcmd = subcommand orelse "list";

    if (mem.eql(u8, subcmd, "list")) {
        return servicesList(allocator, config);
    } else if (mem.eql(u8, subcmd, "start")) {
        const name = formula_name orelse {
            err_out.err("Usage: bru services start <formula>", .{});
            std.process.exit(1);
        };
        return servicesStart(allocator, config, name);
    } else if (mem.eql(u8, subcmd, "stop")) {
        const name = formula_name orelse {
            err_out.err("Usage: bru services stop <formula>", .{});
            std.process.exit(1);
        };
        return servicesStop(allocator, config, name);
    } else if (mem.eql(u8, subcmd, "restart")) {
        const name = formula_name orelse {
            err_out.err("Usage: bru services restart <formula>", .{});
            std.process.exit(1);
        };
        return servicesRestart(allocator, config, name);
    } else if (mem.eql(u8, subcmd, "run")) {
        const name = formula_name orelse {
            err_out.err("Usage: bru services run <formula>", .{});
            std.process.exit(1);
        };
        return servicesRun(allocator, config, name);
    } else if (mem.eql(u8, subcmd, "info")) {
        const name = formula_name orelse {
            err_out.err("Usage: bru services info <formula>", .{});
            std.process.exit(1);
        };
        return servicesInfo(allocator, config, name);
    } else {
        err_out.err("Unknown services subcommand: {s}", .{subcmd});
        std.process.exit(1);
    }
}

/// Find a plist file for the given formula.
/// Returns an allocated path (caller frees), or null if no plist found.
pub fn findPlist(allocator: Allocator, config: Config, name: []const u8) ?[]const u8 {
    // First check the standard path: {prefix}/opt/{name}/homebrew.mxcl.{name}.plist
    var std_buf: [fs.max_path_bytes]u8 = undefined;
    const std_path = std.fmt.bufPrint(&std_buf, "{s}/opt/{s}/homebrew.mxcl.{s}.plist", .{ config.prefix, name, name }) catch return null;

    if (fileExists(std_path)) {
        return allocator.dupe(u8, std_path) catch null;
    }

    // Fallback: scan {prefix}/opt/{name}/ for any .plist file
    var dir_buf: [fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/opt/{s}", .{ config.prefix, name }) catch return null;

    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (mem.endsWith(u8, entry.name, ".plist")) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch null;
        }
    }

    return null;
}

/// Return the LaunchAgents destination path for a plist basename.
/// Returns an allocated path (caller frees), or null on failure.
fn launchAgentDest(allocator: Allocator, plist_basename: []const u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/{s}", .{ home, plist_basename }) catch null;
}

/// List all installed formulae and their service status.
fn servicesList(allocator: Allocator, config: Config) void {
    const out = Output.init(config.no_color);
    const cellar = Cellar.init(config.cellar);
    const formulae = cellar.installedFormulae(allocator);

    // Print header.
    out.print("{s:<20} {s:<12} {s}\n", .{ "Name", "Status", "Plist" });

    var found_any = false;
    for (formulae) |formula| {
        const plist = findPlist(allocator, config, formula.name) orelse continue;
        defer allocator.free(plist);

        found_any = true;
        const basename = fs.path.basename(plist);
        const dest = launchAgentDest(allocator, basename);
        defer if (dest) |d| allocator.free(d);

        const is_loaded = if (dest) |d| fileExists(d) else false;
        const status: []const u8 = if (is_loaded) "started" else "stopped";

        out.print("{s:<20} {s:<12} {s}\n", .{ formula.name, status, plist });
    }

    if (!found_any) {
        out.print("No services available.\n", .{});
    }
}

/// Start a service: copy plist to LaunchAgents, load via launchctl.
fn servicesStart(allocator: Allocator, config: Config, name: []const u8) void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    const plist = findPlist(allocator, config, name) orelse {
        err_out.err("No plist found for {s}.", .{name});
        std.process.exit(1);
    };
    defer allocator.free(plist);

    const basename = fs.path.basename(plist);
    const dest = launchAgentDest(allocator, basename) orelse {
        err_out.err("Could not determine LaunchAgents path.", .{});
        std.process.exit(1);
    };
    defer allocator.free(dest);

    // Copy plist to ~/Library/LaunchAgents/
    fs.copyFileAbsolute(plist, dest, .{}) catch {
        err_out.err("Could not copy plist to {s}.", .{dest});
        std.process.exit(1);
    };

    // Load via launchctl
    const argv = [_][]const u8{ "launchctl", "load", "-w", dest };
    var child = std.process.Child.init(&argv, allocator);
    const term = child.spawnAndWait() catch {
        err_out.err("Failed to run launchctl.", .{});
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                err_out.err("launchctl load failed (exit code {d}).", .{code});
                std.process.exit(1);
            }
        },
        else => {
            err_out.err("launchctl load terminated abnormally.", .{});
            std.process.exit(1);
        },
    }

    out.print("==> Successfully started {s}\n", .{name});
}

/// Stop a service: unload via launchctl, remove plist from LaunchAgents.
fn servicesStop(allocator: Allocator, config: Config, name: []const u8) void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    const plist = findPlist(allocator, config, name) orelse {
        err_out.err("No plist found for {s}.", .{name});
        std.process.exit(1);
    };
    defer allocator.free(plist);

    const basename = fs.path.basename(plist);
    const dest = launchAgentDest(allocator, basename) orelse {
        err_out.err("Could not determine LaunchAgents path.", .{});
        std.process.exit(1);
    };
    defer allocator.free(dest);

    // Unload via launchctl
    const argv = [_][]const u8{ "launchctl", "unload", "-w", dest };
    var child = std.process.Child.init(&argv, allocator);
    const term = child.spawnAndWait() catch {
        err_out.err("Failed to run launchctl.", .{});
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                err_out.err("launchctl unload failed (exit code {d}).", .{code});
                std.process.exit(1);
            }
        },
        else => {
            err_out.err("launchctl unload terminated abnormally.", .{});
            std.process.exit(1);
        },
    }

    // Remove plist from LaunchAgents
    fs.deleteFileAbsolute(dest) catch {};

    out.print("==> Successfully stopped {s}\n", .{name});
}

/// Restart a service: stop then start.
fn servicesRestart(allocator: Allocator, config: Config, name: []const u8) void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    const plist = findPlist(allocator, config, name) orelse {
        err_out.err("No plist found for {s}.", .{name});
        std.process.exit(1);
    };
    defer allocator.free(plist);

    const basename = fs.path.basename(plist);
    const dest = launchAgentDest(allocator, basename) orelse {
        err_out.err("Could not determine LaunchAgents path.", .{});
        std.process.exit(1);
    };
    defer allocator.free(dest);

    // Stop: unload and remove (ignore errors if not currently loaded)
    if (fileExists(dest)) {
        const unload_argv = [_][]const u8{ "launchctl", "unload", "-w", dest };
        var unload_child = std.process.Child.init(&unload_argv, allocator);
        _ = unload_child.spawnAndWait() catch {};
        fs.deleteFileAbsolute(dest) catch {};
    }

    // Start: copy and load
    fs.copyFileAbsolute(plist, dest, .{}) catch {
        err_out.err("Could not copy plist to {s}.", .{dest});
        std.process.exit(1);
    };

    const load_argv = [_][]const u8{ "launchctl", "load", "-w", dest };
    var load_child = std.process.Child.init(&load_argv, allocator);
    const term = load_child.spawnAndWait() catch {
        err_out.err("Failed to run launchctl.", .{});
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                err_out.err("launchctl load failed (exit code {d}).", .{code});
                std.process.exit(1);
            }
        },
        else => {
            err_out.err("launchctl load terminated abnormally.", .{});
            std.process.exit(1);
        },
    }

    out.print("==> Successfully restarted {s}\n", .{name});
}

/// Run a service's binary directly in the foreground.
fn servicesRun(allocator: Allocator, config: Config, name: []const u8) void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Find binary at {prefix}/opt/{name}/bin/{name}
    var bin_buf: [fs.max_path_bytes]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/opt/{s}/bin/{s}", .{ config.prefix, name, name }) catch {
        err_out.err("Path too long.", .{});
        std.process.exit(1);
    };

    if (!fileExists(bin_path)) {
        err_out.err("Binary not found at {s}.", .{bin_path});
        std.process.exit(1);
    }

    out.print("==> Running {s} in foreground...\n", .{name});

    const argv = [_][]const u8{bin_path};
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch {
        err_out.err("Failed to run {s}.", .{name});
        std.process.exit(1);
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.process.exit(code);
            }
        },
        else => std.process.exit(1),
    }
}

/// Show detailed info about a service.
fn servicesInfo(allocator: Allocator, config: Config, name: []const u8) void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    const plist = findPlist(allocator, config, name) orelse {
        err_out.err("No plist found for {s}.", .{name});
        std.process.exit(1);
    };
    defer allocator.free(plist);

    const basename = fs.path.basename(plist);
    const dest = launchAgentDest(allocator, basename);
    defer if (dest) |d| allocator.free(d);

    const is_loaded = if (dest) |d| fileExists(d) else false;
    const status: []const u8 = if (is_loaded) "started" else "stopped";

    out.print("Name:      {s}\n", .{name});
    out.print("Status:    {s}\n", .{status});
    out.print("Plist:     {s}\n", .{plist});
    if (dest) |d| {
        out.print("Loaded:    {s}\n", .{if (is_loaded) d else "not loaded"});
    }

    // Log file path (standard Homebrew log location)
    var log_buf: [fs.max_path_bytes]u8 = undefined;
    const log_path = std.fmt.bufPrint(&log_buf, "{s}/var/log/{s}.log", .{ config.prefix, name }) catch return;
    out.print("Log:       {s}\n", .{log_path});
}

/// Check whether a file exists at the given absolute path.
fn fileExists(path: []const u8) bool {
    fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "servicesCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = servicesCmd;
    _ = handler;
}

test "findPlist returns null for nonexistent formula" {
    const allocator = std.testing.allocator;
    const config = Config{
        .prefix = "/nonexistent/__bru_test_prefix__",
        .cellar = "/nonexistent/__bru_test_cellar__",
        .caskroom = "/nonexistent/__bru_test_caskroom__",
        .repository = "/nonexistent/__bru_test_repo__",
        .cache = "/nonexistent/__bru_test_cache__",
        .brew_file = null,
        .no_color = true,
        .no_emoji = false,
        .verbose = false,
        .debug = false,
        .quiet = false,
        .timing = false,
        .allocator = allocator,
    };
    const result = findPlist(allocator, config, "nonexistent_formula_xyz");
    try std.testing.expect(result == null);
}
