const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const download = @import("../download.zig");
const Download = download.Download;
const Bottle = @import("../bottle.zig").Bottle;
const Linker = @import("../linker.zig").Linker;
const tab_mod = @import("../tab.zig");
const Tab = tab_mod.Tab;
const RuntimeDep = tab_mod.RuntimeDep;
const Output = @import("../output.zig").Output;
const fuzzy = @import("../fuzzy.zig");

/// Install a formula from a pre-built bottle.
///
/// Usage: bru install <formula>
///
/// Looks up the formula in the binary index, downloads the bottle from GHCR,
/// extracts it into the cellar, replaces placeholders, writes an install
/// receipt, and links the keg into the prefix.
pub fn installCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    // 1. Parse args — find first non-flag argument as formula name.
    var formula_name: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        formula_name = arg;
        break;
    }

    const name = formula_name orelse {
        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;
        try stderr.print("Usage: bru install <formula>\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // 2. Look up in index.
    var idx = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call idx.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.

    const entry = idx.lookup(name) orelse {
        err_out.err("No available formula with the name \"{s}\".", .{name});
        const similar = fuzzy.findSimilar(&idx, allocator, name, 3, 3) catch &.{};
        defer if (similar.len > 0) allocator.free(similar);
        if (similar.len > 0) {
            err_out.print("Did you mean?\n", .{});
            for (similar) |s| err_out.print("  {s}\n", .{s});
        }
        std.process.exit(1);
    };

    // 3. Check if already installed.
    const cellar = Cellar.init(config.cellar);
    if (cellar.isInstalled(name)) {
        out.warn("{s} is already installed.", .{name});
        return;
    }

    // 4. Check and install dependencies.
    {
        const dep_names_for_install = try idx.getStringList(allocator, entry.deps_offset);
        defer allocator.free(dep_names_for_install);

        var missing_deps = std.ArrayList([]const u8){};
        defer missing_deps.deinit(allocator);

        for (dep_names_for_install) |dep_name| {
            if (!cellar.isInstalled(dep_name)) {
                try missing_deps.append(allocator, dep_name);
            }
        }

        if (missing_deps.items.len > 0) {
            out.section("Installing dependencies");
            for (missing_deps.items) |dep_name| {
                out.print("Installing dependency: {s}...\n", .{dep_name});
                const dep_args = &[_][]const u8{dep_name};
                installCmd(allocator, dep_args, config) catch |install_err| {
                    err_out.err("Failed to install dependency \"{s}\": {s}", .{ dep_name, @errorName(install_err) });
                    err_out.err("Install dependencies manually or use: brew install {s}", .{name});
                    return install_err;
                };
            }
            out.print("\n", .{});
        }
    }

    // 5. Check bottle availability.
    const bottle_root_url = idx.getString(entry.bottle_root_url_offset);
    const bottle_sha256 = idx.getString(entry.bottle_sha256_offset);

    if (bottle_root_url.len == 0 or bottle_sha256.len == 0) {
        err_out.err("No bottle available for \"{s}\". Try: brew install {s}", .{ name, name });
        return error.BottleNotAvailable;
    }

    // 5. Get version from index.
    const version = idx.getString(entry.version_offset);

    // 6. Print section header.
    const install_title = try std.fmt.allocPrint(allocator, "Installing {s} {s}", .{ name, version });
    defer allocator.free(install_title);
    out.section(install_title);

    // 7. Download bottle.
    const image_name = try download.ghcrImageName(allocator, name);
    defer allocator.free(image_name);

    const url = try std.fmt.allocPrint(allocator, "{s}/{s}/blobs/sha256:{s}", .{ bottle_root_url, image_name, bottle_sha256 });
    defer allocator.free(url);

    out.print("Downloading {s}...\n", .{name});

    var dl = Download.init(allocator, config.cache);
    const archive_path = try dl.fetchBottle(url, name, bottle_sha256);
    defer allocator.free(archive_path);

    // 8. Extract bottle.
    out.print("Pouring {s} {s}...\n", .{ name, version });

    var bottle = Bottle.init(allocator, config);
    const keg_path = try bottle.pour(archive_path, name, version);
    defer allocator.free(keg_path);

    // 9. Replace placeholders.
    try bottle.replacePlaceholders(keg_path);

    // 10. Build runtime_dependencies from the formula's dependency list.
    const dep_names = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(dep_names);

    var runtime_deps = try std.ArrayList(RuntimeDep).initCapacity(allocator, dep_names.len);
    defer {
        for (runtime_deps.items) |dep| {
            allocator.free(dep.full_name);
            allocator.free(dep.version);
            allocator.free(dep.pkg_version);
        }
        runtime_deps.deinit(allocator);
    }

    for (dep_names) |dep_name| {
        const dep_entry = idx.lookup(dep_name) orelse continue;
        const dep_version = idx.getString(dep_entry.version_offset);
        const dep_revision = dep_entry.revision;

        // Build pkg_version: "version" or "version_revision"
        var pkg_ver_buf: [256]u8 = undefined;
        const pkg_version = if (dep_revision > 0)
            std.fmt.bufPrint(&pkg_ver_buf, "{s}_{d}", .{ dep_version, dep_revision }) catch continue
        else
            dep_version;

        const full_name = try allocator.dupe(u8, dep_name);
        errdefer allocator.free(full_name);

        const version_str = try allocator.dupe(u8, dep_version);
        errdefer allocator.free(version_str);

        const pkg_ver = try allocator.dupe(u8, pkg_version);

        runtime_deps.appendAssumeCapacity(.{
            .full_name = full_name,
            .version = version_str,
            .revision = dep_revision,
            .pkg_version = pkg_ver,
            .declared_directly = true,
        });
    }

    // 11. Write install receipt (tab).
    const tab = Tab{
        .installed_on_request = true,
        .poured_from_bottle = true,
        .loaded_from_api = true,
        .time = std.time.timestamp(),
        .runtime_dependencies = runtime_deps.items,
        .compiler = "clang",
        .homebrew_version = "bru 0.1.0",
    };
    try tab.writeToKeg(allocator, keg_path);

    // 12. Link into prefix.
    const keg_only = (entry.flags & 1) != 0;
    var linker = Linker.init(allocator, config.prefix);

    if (keg_only) {
        try linker.optLink(name, keg_path);
    } else {
        try linker.link(name, keg_path);
    }

    // 13. Print completion.
    const done_title = try std.fmt.allocPrint(allocator, "{s} {s} is installed", .{ name, version });
    defer allocator.free(done_title);
    out.section(done_title);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "installCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = installCmd;
    _ = handler;
}
