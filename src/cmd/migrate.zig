const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;
const Index = @import("../index.zig").Index;
const TapMigrations = @import("../tap_migrations.zig").TapMigrations;
const fallback = @import("../fallback.zig");
const pin_mod = @import("pin.zig");

/// Migrate renamed or deprecated formulae to their replacements.
///
/// Usage: bru migrate [--force] [--dry-run/-n] [--formula] [--cask] <formula> [...]
pub fn migrateCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse flags and formula names.
    var names: std.ArrayList([]const u8) = .{};
    defer names.deinit(allocator);

    var dry_run = false;

    for (args) |arg| {
        if (mem.eql(u8, arg, "--dry-run") or mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            // Skip other flags (--force, --formula, --formulae, --cask, --casks, etc.)
            // These are accepted for compatibility but handled via fallback args passthrough.
            continue;
        } else {
            try names.append(allocator, arg);
        }
    }

    if (names.items.len == 0) {
        err_out.err("This command requires at least one installed formula or cask argument.", .{});
        std.process.exit(1);
    }

    const cellar = Cellar.init(config.cellar);

    // Load the formula index.
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // and the arena allocator handles cleanup on process exit.
    var idx = Index.loadOrBuild(allocator, config.cache) catch {
        err_out.err("Could not load formula index.", .{});
        std.process.exit(1);
    };
    _ = &idx;

    // Load tap migrations (optional — may not exist).
    var tap_migrations = TapMigrations.load(allocator, config.cache);
    defer if (tap_migrations) |*tm| tm.deinit();

    for (names.items) |name| {
        // 1. Check if installed.
        if (!cellar.isInstalled(name)) {
            err_out.err("{s} is not installed.", .{name});
            std.process.exit(1);
        }

        // 2. Check tap migrations first — these require fallback to brew.
        if (tap_migrations) |*tm| {
            if (tm.lookup(name)) |_| {
                // Tap migration detected — fall back to brew for this.
                out.print("==> {s} has been migrated to a different tap.\n", .{name});
                out.print("Falling back to brew migrate...\n", .{});
                fallbackToBrew(allocator, args);
            }
        }

        // 3. Check reverse lookup (old name -> new formula).
        if (idx.lookupByOldname(name)) |entry| {
            const new_name = idx.getString(entry.name_offset);

            // Check if the new name is already installed.
            if (cellar.isInstalled(new_name)) {
                err_out.err("{s} is already installed as {s}.", .{ name, new_name });
                std.process.exit(1);
            }

            // Perform native rename migration.
            if (dry_run) {
                out.print("Would migrate {s} to {s}\n", .{ name, new_name });
                continue;
            }

            migrateRename(allocator, config, name, new_name, out, err_out);
            continue;
        }

        // 4. Check forward lookup for deprecation replacement.
        if (idx.lookup(name)) |entry| {
            const replacement = idx.getString(entry.replacement_offset);
            if (replacement.len > 0) {
                out.print("==> {s} is deprecated, replacement is {s}.\n", .{ name, replacement });
                out.print("Falling back to brew migrate...\n", .{});
                fallbackToBrew(allocator, args);
            }

            // Formula exists by current name with no replacement — already migrated or no migration needed.
            out.print("{s} is already using its current name. Nothing to migrate.\n", .{name});
            continue;
        }

        // 5. Not found anywhere.
        err_out.err("No migration available for {s}.", .{name});
        std.process.exit(1);
    }
}

/// Perform a native rename migration: unlink old -> rename cellar dir -> relink new.
/// Only the latest version's symlinks are managed. The cellar rename moves all
/// versions. This matches Homebrew's behavior (only one keg is linked at a time).
fn migrateRename(
    allocator: Allocator,
    config: Config,
    old_name: []const u8,
    new_name: []const u8,
    out: Output,
    err_out: Output,
) void {
    const cellar = Cellar.init(config.cellar);

    // Get installed versions for unlinking.
    const versions = cellar.installedVersions(allocator, old_name) orelse {
        err_out.err("{s} has no installed versions.", .{old_name});
        std.process.exit(1);
    };
    defer {
        for (versions) |v| allocator.free(v);
        allocator.free(versions);
    }

    // Use the latest version.
    const latest = blk: {
        const PkgVersion = @import("../version.zig").PkgVersion;
        var best = versions[0];
        for (versions[1..]) |v| {
            if (PkgVersion.parse(v).order(PkgVersion.parse(best)) == .gt) best = v;
        }
        break :blk best;
    };

    out.print("==> Migrating {s} to {s}\n", .{ old_name, new_name });

    // Step 1: Unlink old name.
    out.print("Unlinking {s}...\n", .{old_name});
    {
        var keg_buf: [fs.max_path_bytes]u8 = undefined;
        const old_keg = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, old_name, latest }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };
        var linker = Linker.init(allocator, config.prefix);
        linker.unlink(old_keg) catch {
            err_out.err("Failed to unlink {s}.", .{old_name});
            std.process.exit(1);
        };
    }

    // Step 2: Rename cellar directory.
    out.print("Renaming Cellar directory...\n", .{});
    {
        var old_dir_buf: [fs.max_path_bytes]u8 = undefined;
        const old_dir = std.fmt.bufPrint(&old_dir_buf, "{s}/{s}", .{ config.cellar, old_name }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };
        var new_dir_buf: [fs.max_path_bytes]u8 = undefined;
        const new_dir = std.fmt.bufPrint(&new_dir_buf, "{s}/{s}", .{ config.cellar, new_name }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };
        std.fs.renameAbsolute(old_dir, new_dir) catch {
            err_out.err("Failed to rename {s} to {s} in Cellar.", .{ old_name, new_name });
            std.process.exit(1);
        };
    }

    // Step 3: Relink with new name.
    out.print("Linking {s}...\n", .{new_name});
    {
        var keg_buf: [fs.max_path_bytes]u8 = undefined;
        const new_keg = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, new_name, latest }) catch {
            err_out.err("Path too long.", .{});
            std.process.exit(1);
        };
        var linker = Linker.init(allocator, config.prefix);
        linker.link(new_name, new_keg) catch {
            err_out.err("Failed to link {s}.", .{new_name});
            std.process.exit(1);
        };
    }

    // Step 4: Update pin if pinned.
    if (pin_mod.isPinned(config.prefix, old_name)) {
        out.print("Updating pin...\n", .{});
        var old_pin_buf: [fs.max_path_bytes]u8 = undefined;
        const old_pin = std.fmt.bufPrint(&old_pin_buf, "{s}/var/homebrew/pinned/{s}", .{ config.prefix, old_name }) catch return;
        var new_pin_buf: [fs.max_path_bytes]u8 = undefined;
        const new_pin = std.fmt.bufPrint(&new_pin_buf, "{s}/var/homebrew/pinned/{s}", .{ config.prefix, new_name }) catch return;
        std.fs.renameAbsolute(old_pin, new_pin) catch {};
    }

    out.print("==> Migration complete: {s} -> {s}\n", .{ old_name, new_name });
}

/// Fall back to the real brew binary for migrate.
/// Note: global flags (--verbose, --debug) are not forwarded since the command
/// handler only receives command_args. This matches the dispatch architecture.
fn fallbackToBrew(allocator: Allocator, args: []const []const u8) noreturn {
    // Build argv: ["brew", "migrate"] ++ args
    const new_argv = allocator.alloc([]const u8, args.len + 2) catch {
        std.process.exit(1);
    };
    new_argv[0] = "brew";
    new_argv[1] = "migrate";
    if (args.len > 0) {
        @memcpy(new_argv[2..], args);
    }
    fallback.execBrew(allocator, new_argv);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "migrateCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = migrateCmd;
    _ = handler;
}
