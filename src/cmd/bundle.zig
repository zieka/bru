const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Output = @import("../output.zig").Output;
const install = @import("install.zig");

/// Create and install from Brewfile package lists.
///
/// Usage: bru bundle dump [--file=PATH] [--describe]
///        bru bundle install [--file=PATH] [--no-cask]
pub fn bundleCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const err_out = Output.initErr(config.no_color);

    // Parse subcommand from first non-flag argument.
    var subcommand: ?[]const u8 = null;
    for (args) |arg| {
        if (!mem.startsWith(u8, arg, "-")) {
            subcommand = arg;
            break;
        }
    }

    const sub = subcommand orelse {
        err_out.err("Usage: bru bundle <dump|install> [options]", .{});
        std.process.exit(1);
    };

    if (mem.eql(u8, sub, "dump")) {
        return bundleDump(allocator, args, config);
    }

    if (mem.eql(u8, sub, "install")) {
        return bundleInstall(allocator, args, config);
    }

    err_out.err("Unknown bundle subcommand: {s}", .{sub});
    std.process.exit(1);
}

/// Export installed formulae and casks to a Brewfile.
fn bundleDump(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse flags.
    var file_path: []const u8 = "./Brewfile";
    for (args) |arg| {
        if (mem.startsWith(u8, arg, "--file=")) {
            file_path = arg["--file=".len..];
        }
    }

    // Read installed formulae from cellar.
    const cellar = Cellar.init(config.cellar);
    const formulae = cellar.installedFormulae(allocator);
    defer {
        for (formulae) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(formulae);
    }

    // Read installed casks from caskroom.
    const caskroom = Cellar.init(config.caskroom);
    const casks = caskroom.installedFormulae(allocator);
    defer {
        for (casks) |c| {
            for (c.versions) |v| allocator.free(v);
            allocator.free(c.versions);
            allocator.free(c.name);
        }
        allocator.free(casks);
    }

    // Write Brewfile.
    const file = std.fs.cwd().createFile(file_path, .{}) catch {
        err_out.err("Could not create file: {s}", .{file_path});
        std.process.exit(1);
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    const writer = &w.interface;

    for (formulae) |f| {
        writer.print("brew \"{s}\"\n", .{f.name}) catch {
            err_out.err("Failed to write to Brewfile.", .{});
            std.process.exit(1);
        };
    }

    for (casks) |c| {
        writer.print("cask \"{s}\"\n", .{c.name}) catch {
            err_out.err("Failed to write to Brewfile.", .{});
            std.process.exit(1);
        };
    }

    writer.flush() catch {
        err_out.err("Failed to flush Brewfile.", .{});
        std.process.exit(1);
    };

    out.print("Wrote {d} formulae and {d} casks to {s}\n", .{ formulae.len, casks.len, file_path });
}

/// Install packages from a Brewfile.
fn bundleInstall(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse flags.
    var file_path: []const u8 = "./Brewfile";
    var no_cask = false;
    for (args) |arg| {
        if (mem.startsWith(u8, arg, "--file=")) {
            file_path = arg["--file=".len..];
        } else if (mem.eql(u8, arg, "--no-cask")) {
            no_cask = true;
        }
    }

    // Read Brewfile.
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        err_out.err("Could not open Brewfile: {s}", .{file_path});
        std.process.exit(1);
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        err_out.err("Could not read Brewfile: {s}", .{file_path});
        std.process.exit(1);
    };
    defer allocator.free(content);

    const cellar = Cellar.init(config.cellar);
    const caskroom = Cellar.init(config.caskroom);

    var installed_count: usize = 0;
    var up_to_date_count: usize = 0;

    // Parse lines.
    var line_iter = mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = mem.trim(u8, line, &std.ascii.whitespace);

        // Skip empty lines and comments.
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        const is_brew = mem.startsWith(u8, trimmed, "brew ");
        const is_cask = mem.startsWith(u8, trimmed, "cask ");

        if (!is_brew and !is_cask) continue;

        // Skip cask entries if --no-cask is set.
        if (is_cask and no_cask) continue;

        const name = extractQuotedName(trimmed) orelse continue;

        if (is_brew) {
            if (cellar.isInstalled(name)) {
                up_to_date_count += 1;
                continue;
            }
            const install_args = &[_][]const u8{name};
            install.installCmd(allocator, install_args, config) catch |e| {
                err_out.err("Failed to install {s}: {s}", .{ name, @errorName(e) });
                continue;
            };
            installed_count += 1;
        } else {
            // cask
            if (caskroom.isInstalled(name)) {
                up_to_date_count += 1;
                continue;
            }
            const install_args = &[_][]const u8{ "--cask", name };
            install.installCmd(allocator, install_args, config) catch |e| {
                err_out.err("Failed to install cask {s}: {s}", .{ name, @errorName(e) });
                continue;
            };
            installed_count += 1;
        }
    }

    out.print("{d} installed, {d} already up-to-date\n", .{ installed_count, up_to_date_count });
}

/// Extract the name between double quotes from a Brewfile line.
/// Returns null if no valid quoted name is found.
pub fn extractQuotedName(line: []const u8) ?[]const u8 {
    const start = mem.indexOf(u8, line, "\"") orelse return null;
    if (start + 1 >= line.len) return null;
    const rest = line[start + 1 ..];
    const end = mem.indexOf(u8, rest, "\"") orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bundleCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = bundleCmd;
    _ = handler;
}

test "extractQuotedName extracts brew formula name" {
    const result = extractQuotedName("brew \"ripgrep\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("ripgrep", result.?);
}

test "extractQuotedName extracts cask name" {
    const result = extractQuotedName("cask \"firefox\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("firefox", result.?);
}

test "extractQuotedName returns null for comments" {
    const result = extractQuotedName("# comment");
    try std.testing.expect(result == null);
}

test "extractQuotedName returns null for empty quotes" {
    const result = extractQuotedName("brew \"\"");
    try std.testing.expect(result == null);
}

test "extractQuotedName returns null for bare empty quotes" {
    const result = extractQuotedName("\"\"");
    try std.testing.expect(result == null);
}
