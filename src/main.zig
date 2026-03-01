const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const dispatch = @import("dispatch.zig");
const fallback = @import("fallback.zig");
const help = @import("help.zig");

pub fn main() !void {
    // Release builds: arena allocator with thread-safe wrapper. Every alloc()
    // is a pointer bump; every free() is a no-op. The process exits after one
    // command, so OS reclamation handles cleanup — "the missile knows when it
    // hits."
    //
    // Debug builds: GPA for leak detection during development.
    if (builtin.mode == .Debug) {
        var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa_instance.deinit();
        try run(gpa_instance.allocator());
    } else {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        var ts = std.heap.ThreadSafeAllocator{ .child_allocator = arena.allocator() };
        try run(ts.allocator());
    }
}

fn run(allocator: std.mem.Allocator) !void {
    var cfg = try Config.load(allocator);
    defer cfg.deinit();

    // Collect process arguments.
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parsed = dispatch.parseArgs(argv);

    // Propagate flag overrides into config.
    if (parsed.verbose) cfg.verbose = true;
    if (parsed.debug) cfg.debug = true;
    if (parsed.quiet) cfg.quiet = true;
    if (parsed.timing) cfg.timing = true;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // --help: print help and exit.
    if (parsed.help) {
        if (parsed.command) |cmd| {
            if (!try help.printCommandHelp(stdout, cmd)) {
                try help.printGeneralHelp(stdout);
            }
        } else {
            try help.printGeneralHelp(stdout);
        }
        return;
    }

    // --version: print version and exit.
    if (parsed.version) {
        try stdout.print("bru 0.1.0\n", .{});
        try stdout.flush();
        return;
    }

    // No command provided: print version and usage hint.
    const command_name = parsed.command orelse {
        try help.printGeneralHelp(stdout);
        return;
    };

    // Look up in the native dispatch table.
    if (dispatch.getCommand(command_name)) |handler| {
        // Check if --help is passed as a command argument
        for (parsed.command_args) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                if (try help.printCommandHelp(stdout, command_name)) {
                    return;
                }
                break;
            }
        }
        try handler(allocator, parsed.command_args, cfg);
        return;
    }

    // No native handler — fall back to the real brew binary.
    fallback.execBrew(allocator, argv);
}

test {
    _ = @import("cellar.zig");
    _ = @import("cmd/list.zig");
    _ = @import("cmd/info.zig");
    _ = @import("cmd/deps.zig");
    _ = @import("cmd/leaves.zig");
    _ = @import("cmd/outdated.zig");
    _ = @import("cmd/config_cmd.zig");
    _ = @import("cmd/fetch_cmd.zig");
    _ = @import("cmd/install.zig");
    _ = @import("cmd/uninstall.zig");
    _ = @import("cmd/link.zig");
    _ = @import("cmd/upgrade.zig");
    _ = @import("cmd/cleanup.zig");
    _ = @import("cmd/autoremove.zig");
    _ = @import("cmd/update.zig");
    _ = @import("cmd/uses.zig");
    _ = @import("cmd/search.zig");
    _ = @import("cmd/prefix.zig");
    _ = @import("cmd/shellenv.zig");
    _ = @import("help.zig");
    _ = @import("config.zig");
    _ = @import("dispatch.zig");
    _ = @import("fallback.zig");
    _ = @import("output.zig");
    _ = @import("tab.zig");
    _ = @import("formula.zig");
    _ = @import("index.zig");
    _ = @import("cask.zig");
    _ = @import("cask_index.zig");
    _ = @import("cask_install.zig");
    _ = @import("version.zig");
    _ = @import("http.zig");
    _ = @import("batch_download.zig");
    _ = @import("download.zig");
    _ = @import("bottle.zig");
    _ = @import("linker.zig");
    _ = @import("json_helpers.zig");
    _ = @import("fuzzy.zig");
    _ = @import("timer.zig");
    _ = @import("clonefile.zig");
}
