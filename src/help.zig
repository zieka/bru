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
        \\Discovery commands:
        \\  desc       Show description for a formula or cask
        \\  home       Open homepage of a formula or cask
        \\  casks      List all available cask names
        \\  formulae   List all available formula names
        \\
        \\Package management commands:
        \\  pin        Prevent a formula from being upgraded
        \\  unpin      Allow a pinned formula to be upgraded again
        \\  tap        Manage third-party formula repositories
        \\  untap      Remove a tapped formula repository
        \\
        \\Maintenance commands:
        \\  cleanup    Remove old versions and stale downloads
        \\  outdated   Show outdated formulae
        \\  fetch      Download a formula without installing
        \\  config     Show Homebrew configuration
        \\  log        Show the git log for a formula or cask
        \\  commands   List available commands
        \\
        \\Environment commands:
        \\  shellenv   Print export statements for shell integration
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
        .{ "log",
            \\Usage: bru log [options] [formula|cask]
            \\
            \\Show the git log for a formula or cask, or show the log
            \\for the Homebrew repository if no formula or cask is provided.
            \\
            \\Options:
            \\  -p, --patch      Also print patch from commit
            \\  --stat           Also print diffstat from commit
            \\  --oneline        Print only one line per commit
            \\  -1               Print only one commit
            \\  -n, --max-count  Print only a specified number of commits
            \\  --formula        Treat argument as a formula
            \\  --cask           Treat argument as a cask
            \\
        },
        .{ "home",
            \\Usage: bru home [formula|cask]
            \\
            \\Open the homepage of a formula or cask in the default browser.
            \\With no arguments, opens Homebrew's homepage (https://brew.sh).
            \\
            \\Options:
            \\  --formula  Treat argument as a formula
            \\  --cask     Treat argument as a cask
            \\
            \\Alias: homepage
            \\
        },
        .{ "casks",
            \\Usage: bru casks [--json]
            \\
            \\List all available cask names from the Homebrew API.
            \\
            \\Options:
            \\  --json  Output as JSON array
            \\
        },
        .{ "formulae",
            \\Usage: bru formulae [--json]
            \\
            \\List all available formula names from the Homebrew API.
            \\
            \\Options:
            \\  --json  Output as JSON array
            \\
        },
        .{ "desc",
            \\Usage: bru desc [options] <formula|cask> [...]
            \\       bru desc --search <text>
            \\
            \\Display a formula or cask's name and one-line description.
            \\
            \\Options:
            \\  -s, --search       Search both names and descriptions for text
            \\  -n, --name         Search just names for text
            \\  -d, --description  Search just descriptions for text
            \\  --formula          Treat arguments as formulae
            \\  --cask             Treat arguments as casks
            \\
        },
        .{ "shellenv",
            \\Usage: bru shellenv [bash|csh|fish|zsh]
            \\
            \\Print export statements for Homebrew shell integration.
            \\Detects the current shell from $SHELL if no argument is given.
            \\
            \\Add to your shell profile: eval "$(bru shellenv)"
            \\
        },
        .{ "pin",
            \\Usage: bru pin <formula>
            \\
            \\Prevent a formula from being upgraded when running bru upgrade.
            \\No output on success.
            \\
        },
        .{ "unpin",
            \\Usage: bru unpin <formula>
            \\
            \\Allow a previously pinned formula to be upgraded again.
            \\No output on success.
            \\
        },
        .{ "commands",
            \\Usage: bru commands [--include-aliases] [--quiet]
            \\
            \\List all available commands (built-in and external).
            \\
            \\Options:
            \\  --include-aliases  Include command aliases in output
            \\  --quiet, -q        List command names only (no section headers)
            \\
        },
        .{ "tap",
            \\Usage: bru tap [options] [user/repo] [URL]
            \\
            \\List or add third-party formula repositories (taps).
            \\
            \\With no arguments, list all installed taps.
            \\With user/repo, clone the tap into Homebrew's Library/Taps.
            \\
            \\Options:
            \\  --shallow  Perform a shallow clone (--depth=1)
            \\  --force    Force re-clone of an existing tap
            \\
        },
        .{ "untap",
            \\Usage: bru untap [--force] <tap> [...]
            \\
            \\Remove a tapped formula repository.
            \\
            \\Options:
            \\  --force, -f  Untap even if formulae or casks from this tap are currently installed
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
    try std.testing.expect(getCommandHelp("desc") != null);
    try std.testing.expect(getCommandHelp("pin") != null);
    try std.testing.expect(getCommandHelp("unpin") != null);
}

test "getCommandHelp returns null for unknown commands" {
    try std.testing.expect(getCommandHelp("nonexistent") == null);
}

test "help text documents --json flag for supported commands" {
    const json_commands = .{ "search", "info", "list", "deps", "leaves", "outdated", "casks", "formulae" };
    inline for (json_commands) |cmd| {
        const help = getCommandHelp(cmd) orelse unreachable;
        try std.testing.expect(std.mem.indexOf(u8, help, "--json") != null);
    }
}

test "list help text documents --cask flag" {
    const help = getCommandHelp("list") orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, help, "--cask") != null);
}
