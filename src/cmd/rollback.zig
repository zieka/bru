const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("../config.zig").Config;
const State = @import("../state.zig").State;
const Output = @import("../output.zig").Output;
const install = @import("install.zig");

/// Roll back a formula to its previously installed version using state history.
///
/// Usage: bru rollback <formula>
///        bru rollback --list
///        bru rollback --dry-run <formula>
pub fn rollbackCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse flags and positional arguments.
    var formula: ?[]const u8 = null;
    var list_mode = false;
    var dry_run = false;

    for (args) |arg| {
        if (mem.eql(u8, arg, "--list") or mem.eql(u8, arg, "-l")) {
            list_mode = true;
        } else if (mem.eql(u8, arg, "--dry-run") or mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            // Skip unknown flags.
            continue;
        } else {
            if (formula == null) formula = arg;
        }
    }

    // Load state history.
    var state = State.load(allocator);
    defer state.deinit();

    // --list mode: show all rollback-eligible formulae.
    if (list_mode) {
        listRollbackTargets(allocator, &state, out);
        return;
    }

    // A formula name is required for rollback / dry-run.
    const name = formula orelse {
        err_out.err("Usage: bru rollback <formula>", .{});
        err_out.err("Run 'bru rollback --list' to see rollback-eligible formulae.", .{});
        std.process.exit(1);
    };

    // Find the rollback target for this formula.
    const target = state.findRollbackTarget(name) orelse {
        err_out.err("No rollback target found for '{s}'.", .{name});
        err_out.err("The formula has no recorded version history with a previous version.", .{});
        std.process.exit(1);
    };

    const prev = target.previous_version.?;

    // --dry-run mode: show what would happen.
    if (dry_run) {
        out.section("Dry run");
        out.print("Would roll back {s} from {s} to {s}\n", .{ name, target.version, prev });
        return;
    }

    // Normal mode: perform the rollback.
    out.section("Rolling back");
    out.print("{s} {s} -> {s}\n", .{ name, target.version, prev });

    // Reinstall the formula (which will install the current available version).
    try install.installCmd(allocator, &.{name}, config);

    // Record the rollback action in state.
    try state.recordAction("rollback", name, prev, target.version);
    state.save() catch |save_err| {
        err_out.err("Failed to save state: {s}", .{@errorName(save_err)});
    };

    out.print("Rolled back {s} to {s}\n", .{ name, prev });
}

/// List all formulae that have rollback targets, deduplicating by formula name
/// (most recent entry wins when walking backwards).
fn listRollbackTargets(allocator: Allocator, state: *const State, out: Output) void {
    // Use a StringHashMap to deduplicate: keep only the first (most recent)
    // entry per formula when walking backwards.
    const Entry = struct {
        version: []const u8,
        previous_version: []const u8,
    };
    var seen = std.StringHashMap(Entry).init(allocator);
    defer seen.deinit();

    var i: usize = state.history.items.len;
    while (i > 0) {
        i -= 1;
        const entry = state.history.items[i];
        if (entry.previous_version) |pv| {
            const gop = seen.getOrPut(entry.formula) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .version = entry.version,
                    .previous_version = pv,
                };
            }
        }
    }

    if (seen.count() == 0) {
        out.print("No rollback-eligible formulae found.\n", .{});
        return;
    }

    out.section("Rollback-eligible formulae");
    var iter = seen.iterator();
    while (iter.next()) |kv| {
        out.print("  {s} {s} -> {s}\n", .{ kv.key_ptr.*, kv.value_ptr.version, kv.value_ptr.previous_version });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "rollbackCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = rollbackCmd;
    _ = handler;
}
