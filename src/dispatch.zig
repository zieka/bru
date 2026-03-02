const std = @import("std");
const Config = @import("config.zig").Config;
const prefix = @import("cmd/prefix.zig");
const list = @import("cmd/list.zig");
const search = @import("cmd/search.zig");
const info = @import("cmd/info.zig");
const outdated = @import("cmd/outdated.zig");
const deps = @import("cmd/deps.zig");
const leaves = @import("cmd/leaves.zig");
const config_cmd = @import("cmd/config_cmd.zig");
const fetch_cmd = @import("cmd/fetch_cmd.zig");
const install = @import("cmd/install.zig");
const uninstall = @import("cmd/uninstall.zig");
const link_cmd = @import("cmd/link.zig");
const upgrade = @import("cmd/upgrade.zig");
const cleanup = @import("cmd/cleanup.zig");
const autoremove = @import("cmd/autoremove.zig");
const update = @import("cmd/update.zig");
const uses = @import("cmd/uses.zig");
const shellenv = @import("cmd/shellenv.zig");
const log = @import("cmd/log.zig");
const casks = @import("cmd/casks.zig");
const home = @import("cmd/home.zig");
const commands = @import("cmd/commands.zig");

/// Result of parsing process arguments into global flags, command name, and command args.
pub const ParsedArgs = struct {
    /// Resolved command name, null if none provided.
    command: ?[]const u8,
    /// Arguments that follow the command name.
    command_args: []const []const u8,
    verbose: bool,
    debug: bool,
    quiet: bool,
    timing: bool,
    help: bool,
    version: bool,
};

/// Signature for built-in command handler functions.
pub const CommandFn = *const fn (allocator: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void;

/// Entry in the comptime native-commands dispatch table.
pub const CommandEntry = struct {
    name: []const u8,
    handler: CommandFn,
};

/// Native commands dispatch table.
pub const native_commands = [_]CommandEntry{
    .{ .name = "__prefix", .handler = prefix.prefixCmd },
    .{ .name = "__cellar", .handler = prefix.cellarCmd },
    .{ .name = "__cache", .handler = prefix.cacheCmd },
    .{ .name = "__caskroom", .handler = prefix.caskroomCmd },
    .{ .name = "__repo", .handler = prefix.repoCmd },
    .{ .name = "shellenv", .handler = shellenv.shellenvCmd },
    .{ .name = "list", .handler = list.listCmd },
    .{ .name = "search", .handler = search.searchCmd },
    .{ .name = "info", .handler = info.infoCmd },
    .{ .name = "outdated", .handler = outdated.outdatedCmd },
    .{ .name = "deps", .handler = deps.depsCmd },
    .{ .name = "leaves", .handler = leaves.leavesCmd },
    .{ .name = "config", .handler = config_cmd.configCmd },
    .{ .name = "fetch", .handler = fetch_cmd.fetchCmd },
    .{ .name = "install", .handler = install.installCmd },
    .{ .name = "uninstall", .handler = uninstall.uninstallCmd },
    .{ .name = "link", .handler = link_cmd.linkCmd },
    .{ .name = "unlink", .handler = link_cmd.unlinkCmd },
    .{ .name = "upgrade", .handler = upgrade.upgradeCmd },
    .{ .name = "cleanup", .handler = cleanup.cleanupCmd },
    .{ .name = "autoremove", .handler = autoremove.autoremoveCmd },
    .{ .name = "update", .handler = update.updateCmd },
    .{ .name = "uses", .handler = uses.usesCmd },
    .{ .name = "log", .handler = log.logCmd },
    .{ .name = "casks", .handler = casks.casksCmd },
    .{ .name = "home", .handler = home.homeCmd },
    .{ .name = "commands", .handler = commands.commandsCmd },
};

/// Parse process argv into global flags, command name, and remaining args.
///
/// - Skips argv[0] (the program name).
/// - Before finding a command, collects global flags (--verbose/-v, --debug/-d,
///   --quiet/-q, --help/-h, --version).
/// - The first non-flag argument becomes the command name (resolved via alias table).
/// - Everything after the command name is placed in command_args.
/// - Special long flags like --prefix, --cellar, etc. are resolved as commands
///   through the alias table.
pub fn parseArgs(argv: []const []const u8) ParsedArgs {
    var result = ParsedArgs{
        .command = null,
        .command_args = &.{},
        .verbose = false,
        .debug = false,
        .quiet = false,
        .timing = false,
        .help = false,
        .version = false,
    };

    if (argv.len <= 1) return result;

    const args = argv[1..];
    var i: usize = 0;

    // Phase 1: collect global flags until we find a command.
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            result.verbose = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            result.debug = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            result.quiet = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--timing")) {
            result.timing = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            result.version = true;
            i += 1;
            continue;
        }

        // Check if this arg resolves to a command through the alias table.
        // This handles --prefix, --cellar, --cache, etc.
        const resolved = resolveAlias(arg);
        if (!std.mem.eql(u8, resolved, arg) or !std.mem.startsWith(u8, arg, "-")) {
            // It's either an alias that resolved to something different, or a
            // non-flag argument — either way it is the command name.
            result.command = resolved;
            i += 1;
            break;
        }

        // Unknown flag before command — skip it (will be ignored).
        i += 1;
    }

    // Phase 2: everything remaining is command_args.
    if (i < args.len) {
        result.command_args = args[i..];
    }

    return result;
}

/// Alias entries mapping alias names to canonical command names.
pub const alias_entries = .{
    .{ "ls", "list" },
    .{ "rm", "uninstall" },
    .{ "remove", "uninstall" },
    .{ "dr", "doctor" },
    .{ "-S", "search" },
    .{ "ln", "link" },
    .{ "instal", "install" },
    .{ "uninstal", "uninstall" },
    .{ "--prefix", "__prefix" },
    .{ "--cellar", "__cellar" },
    .{ "--cache", "__cache" },
    .{ "--caskroom", "__caskroom" },
    .{ "--repo", "__repo" },
    .{ "--repository", "__repo" },
    .{ "homepage", "home" },
    .{ "--config", "config" },
    .{ "--env", "env" },
};

/// Resolve a command alias to its canonical command name.
/// Returns the input unchanged if no alias matches.
pub fn resolveAlias(name: []const u8) []const u8 {
    inline for (alias_entries) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return name;
}

/// Look up a built-in command handler by name. Returns null if the command is
/// not in the native dispatch table (will fall back to exec in Task 4).
pub fn getCommand(name: []const u8) ?CommandFn {
    inline for (native_commands) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.handler;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseArgs extracts command and flags" {
    const argv = &[_][]const u8{ "bru", "--verbose", "list", "--formula" };
    const parsed = parseArgs(argv);

    try std.testing.expect(parsed.verbose);
    try std.testing.expect(!parsed.debug);
    try std.testing.expect(!parsed.quiet);
    try std.testing.expect(!parsed.help);
    try std.testing.expect(!parsed.version);

    try std.testing.expectEqualStrings("list", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.command_args.len);
    try std.testing.expectEqualStrings("--formula", parsed.command_args[0]);
}

test "parseArgs with --version flag" {
    const argv = &[_][]const u8{ "bru", "--version" };
    const parsed = parseArgs(argv);

    try std.testing.expect(parsed.version);
    try std.testing.expect(parsed.command == null);
}

test "parseArgs no command" {
    const argv = &[_][]const u8{"bru"};
    const parsed = parseArgs(argv);

    try std.testing.expect(parsed.command == null);
    try std.testing.expect(!parsed.verbose);
    try std.testing.expect(!parsed.version);
    try std.testing.expectEqual(@as(usize, 0), parsed.command_args.len);
}

test "parseArgs resolves alias" {
    const argv = &[_][]const u8{ "bru", "ls" };
    const parsed = parseArgs(argv);

    try std.testing.expectEqualStrings("list", parsed.command.?);
}
