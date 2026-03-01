const std = @import("std");

/// Print general help text.
pub fn printGeneralHelp(stdout: anytype) !void {
    try stdout.writeAll(
        \\bru - a fast, native Homebrew CLI replacement
        \\
        \\Usage: bru <command> [options] [arguments]
        \\
        \\Core commands:
        \\  install    Install a formula or cask
        \\  uninstall  Uninstall a formula
        \\  upgrade    Upgrade outdated formulae
        \\  update     Fetch latest formulae data
        \\  search     Search for formulae
        \\  info       Show formula info
        \\  list       List installed formulae
        \\
        \\Dependency commands:
        \\  deps       Show dependencies for a formula
        \\  uses       Show which formulae depend on a formula
        \\  leaves     Show installed formulae not depended on
        \\  autoremove Remove orphaned dependencies
        \\
        \\Linking commands:
        \\  link       Symlink a formula into the prefix
        \\  unlink     Remove symlinks from the prefix
        \\
        \\Maintenance commands:
        \\  cleanup    Remove old versions and stale downloads
        \\  outdated   Show outdated formulae
        \\  fetch      Download a formula without installing
        \\  config     Show Homebrew configuration
        \\
        \\Global options:
        \\  --help, -h       Show this help
        \\  --version        Show version
        \\  --verbose, -v    Verbose output
        \\  --quiet, -q      Quiet output
        \\  --debug, -d      Debug output
        \\
        \\Any command not listed above is forwarded to brew.
        \\
    );
    try stdout.flush();
}

/// Print help for a specific command. Returns true if help was found.
pub fn printCommandHelp(stdout: anytype, command: []const u8) !bool {
    const help_text = getCommandHelp(command) orelse return false;
    try stdout.writeAll(help_text);
    try stdout.flush();
    return true;
}

fn getCommandHelp(command: []const u8) ?[]const u8 {
    const entries = .{
        .{ "install",
            \\Usage: bru install [--cask] <formula|cask>
            \\
            \\Install a formula or cask.
            \\Automatically installs missing dependencies for formulae.
            \\
            \\Options:
            \\  --cask  Install a cask (binary-only, CLI tools extracted)
            \\
        },
        .{ "uninstall",
            \\Usage: bru uninstall <formula>
            \\
            \\Uninstall a formula and remove its symlinks.
            \\Aliases: rm, remove
            \\
        },
        .{ "search",
            \\Usage: bru search [--json] <query>
            \\
            \\Search for formulae and casks matching the query substring.
            \\
            \\Options:
            \\  --json  Output as JSON ({"formulae":[...],"casks":[...]})
            \\
            \\Alias: -S
            \\
        },
        .{ "info",
            \\Usage: bru info [--json] <formula>
            \\
            \\Show detailed information about a formula.
            \\
            \\Options:
            \\  --json  Output as JSON
            \\
        },
        .{ "list",
            \\Usage: bru list [--cask] [--json] [--versions] [--pinned]
            \\
            \\List installed formulae and casks.
            \\
            \\Options:
            \\  --cask, --casks  Only list casks
            \\  --json           Output as JSON
            \\
            \\Alias: ls
            \\
        },
        .{ "deps",
            \\Usage: bru deps [--json] [--tree] [--1] [--include-build] <formula>
            \\
            \\Show dependencies for a formula.
            \\
            \\Options:
            \\  --json           Output as JSON
            \\  --tree           Show as indented tree
            \\  --1, --direct    Show only direct dependencies
            \\  --include-build  Include build-time dependencies
            \\
        },
        .{ "uses",
            \\Usage: bru uses [--installed] [--include-build] <formula>
            \\
            \\Show which formulae depend on the given formula.
            \\
            \\Options:
            \\  --installed      Only show installed formulae
            \\  --include-build  Include build-time dependency relationships
            \\
        },
        .{ "leaves",
            \\Usage: bru leaves [--json]
            \\
            \\Show installed formulae that are not dependencies of other formulae.
            \\
            \\Options:
            \\  --json  Output as JSON
            \\
        },
        .{ "link",
            \\Usage: bru link [--force] <formula>
            \\
            \\Symlink a formula's keg into the prefix.
            \\
            \\Options:
            \\  --force, -f  Force linking of keg-only formulae
            \\
            \\Alias: ln
            \\
        },
        .{ "unlink",
            \\Usage: bru unlink <formula>
            \\
            \\Remove symlinks from the prefix for a formula.
            \\
        },
        .{ "upgrade",
            \\Usage: bru upgrade [<formula>]
            \\
            \\Upgrade outdated formulae. Delegates to brew for the actual upgrade.
            \\
        },
        .{ "update",
            \\Usage: bru update
            \\
            \\Fetch the latest formula data and rebuild the index.
            \\
        },
        .{ "outdated",
            \\Usage: bru outdated [--json]
            \\
            \\Show formulae with available upgrades.
            \\
            \\Options:
            \\  --json  Output as JSON
            \\
        },
        .{ "cleanup",
            \\Usage: bru cleanup [--dry-run/-n] [--prune=DAYS]
            \\
            \\Remove old formula versions and stale downloads.
            \\
            \\Options:
            \\  --dry-run, -n    Show what would be removed
            \\  --prune=DAYS     Override default 120-day retention
            \\
        },
        .{ "autoremove",
            \\Usage: bru autoremove [--dry-run/-n]
            \\
            \\Remove orphaned dependencies no longer needed.
            \\
            \\Options:
            \\  --dry-run, -n  Show what would be removed
            \\
        },
        .{ "fetch",
            \\Usage: bru fetch <formula>
            \\
            \\Download a formula's bottle without installing.
            \\
        },
        .{ "config",
            \\Usage: bru config
            \\
            \\Show Homebrew and bru configuration.
            \\
        },
    };

    inline for (entries) |pair| {
        if (std.mem.eql(u8, command, pair[0])) return pair[1];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getCommandHelp returns help for known commands" {
    try std.testing.expect(getCommandHelp("install") != null);
    try std.testing.expect(getCommandHelp("deps") != null);
    try std.testing.expect(getCommandHelp("uses") != null);
}

test "getCommandHelp returns null for unknown commands" {
    try std.testing.expect(getCommandHelp("nonexistent") == null);
}

test "help text documents --json flag for supported commands" {
    const json_commands = .{ "search", "info", "list", "deps", "leaves", "outdated" };
    inline for (json_commands) |cmd| {
        const help = getCommandHelp(cmd) orelse unreachable;
        try std.testing.expect(std.mem.indexOf(u8, help, "--json") != null);
    }
}

test "list help text documents --cask flag" {
    const help = getCommandHelp("list") orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, help, "--cask") != null);
}
