const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;
const cellar_mod = @import("../cellar.zig");
const Cellar = cellar_mod.Cellar;
const Index = @import("../index.zig").Index;
const PkgVersion = @import("../version.zig").PkgVersion;
const Output = @import("../output.zig").Output;
const download = @import("../download.zig");
const Download = download.Download;
const Bottle = @import("../bottle.zig").Bottle;
const Linker = @import("../linker.zig").Linker;
const tab_mod = @import("../tab.zig");
const Tab = tab_mod.Tab;
const RuntimeDep = tab_mod.RuntimeDep;
const HttpClient = @import("../http.zig").HttpClient;
const batch_download = @import("../batch_download.zig");
const installCmd = @import("install.zig").installCmd;
const isPinned = @import("pin.zig").isPinned;

/// An outdated formula pending upgrade.
const OutdatedFormula = struct {
    name: []const u8,
    installed_version: []const u8,
    index_version: PkgVersion,
};

/// Upgrade outdated formulae natively: parallel bottle prefetch, then
/// sequential download/extract/link for each outdated formula.
///
/// Usage:
///   bru upgrade              — upgrade all outdated formulae
///   bru upgrade <formula>    — upgrade a specific formula
pub fn upgradeCmd(allocator: Allocator, args: []const []const u8, config: Config) anyerror!void {
    const out = Output.init(config.no_color);
    const err_out = Output.initErr(config.no_color);

    // Parse args — find the first non-flag argument as formula name.
    var formula_name: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        formula_name = arg;
        break;
    }

    // Load index.
    var index = try Index.loadOrBuild(allocator, config.cache);
    // Note: do not call index.deinit() -- the index may be mmap'd (from disk)
    // in which case the allocator field is undefined. The process exits after
    // this command so OS reclamation is sufficient.
    _ = &index;

    // Load cellar.
    const cellar = Cellar.init(config.cellar);

    // Collect outdated formulae to upgrade.
    var to_upgrade: std.ArrayList(OutdatedFormula) = .{};
    defer {
        for (to_upgrade.items) |item| {
            allocator.free(item.name);
            allocator.free(item.installed_version);
        }
        to_upgrade.deinit(allocator);
    }

    if (formula_name) |name| {
        // Specific formula requested — check if installed and outdated.
        if (!cellar.isInstalled(name)) {
            err_out.err("{s} is not installed.", .{name});
            std.process.exit(1);
        }

        const entry = index.lookup(name) orelse {
            err_out.err("No available formula with the name \"{s}\".", .{name});
            err_out.print("Searched: {s}/api/formula.jws.json\n", .{config.cache});
            std.process.exit(1);
        };

        const installed_versions = cellar.installedVersions(allocator, name) orelse {
            err_out.err("{s} is not installed.", .{name});
            std.process.exit(1);
        };
        defer {
            for (installed_versions) |v| allocator.free(v);
            allocator.free(installed_versions);
        }

        const installed_latest = installed_versions[installed_versions.len - 1];
        const installed_pv = PkgVersion.parse(installed_latest);
        const index_pv = PkgVersion{
            .version = index.getString(entry.version_offset),
            .revision = @as(u32, entry.revision),
        };

        if (installed_pv.order(index_pv) == .lt) {
            try to_upgrade.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .installed_version = try allocator.dupe(u8, installed_latest),
                .index_version = index_pv,
            });
        } else {
            var fmt_buf: [128]u8 = undefined;
            const current_formatted = installed_pv.format(&fmt_buf);
            out.print("{s} {s} already up-to-date.\n", .{ name, current_formatted });
            return;
        }
    } else {
        // No specific formula — scan all installed for outdated ones.
        const installed = cellar.installedFormulae(allocator);
        defer {
            for (installed) |f| {
                for (f.versions) |v| allocator.free(v);
                allocator.free(f.versions);
                allocator.free(f.name);
            }
            allocator.free(installed);
        }

        for (installed) |formula| {
            // Skip pinned formulae when upgrading all.
            if (isPinned(config.prefix, formula.name)) continue;

            const entry = index.lookup(formula.name) orelse continue;

            const installed_pv = PkgVersion.parse(formula.latestVersion());
            const index_pv = PkgVersion{
                .version = index.getString(entry.version_offset),
                .revision = @as(u32, entry.revision),
            };

            if (installed_pv.order(index_pv) == .lt) {
                try to_upgrade.append(allocator, .{
                    .name = try allocator.dupe(u8, formula.name),
                    .installed_version = try allocator.dupe(u8, formula.latestVersion()),
                    .index_version = index_pv,
                });
            }
        }
    }

    // Nothing to upgrade.
    if (to_upgrade.items.len == 0) {
        out.print("Already up-to-date.\n", .{});
        return;
    }

    // Print summary of what will be upgraded.
    const count_str = try std.fmt.allocPrint(allocator, "Upgrading {d} outdated package{s}", .{
        to_upgrade.items.len,
        if (to_upgrade.items.len == 1) "" else "s",
    });
    defer allocator.free(count_str);
    out.section(count_str);

    for (to_upgrade.items) |item| {
        var fmt_buf: [128]u8 = undefined;
        const new_formatted = item.index_version.format(&fmt_buf);
        out.print("{s} {s} -> {s}\n", .{ item.name, item.installed_version, new_formatted });
    }

    // --- Parallel prefetch phase ---
    var http_client = HttpClient.init(allocator);
    defer http_client.deinit();

    var tasks = std.ArrayList(batch_download.DownloadTask){};
    defer {
        for (tasks.items) |task| allocator.free(task.url);
        tasks.deinit(allocator);
    }

    for (to_upgrade.items) |item| {
        batch_download.addDownloadTask(allocator, &index, &tasks, item.name) catch continue;
    }

    if (tasks.items.len > 0) {
        out.print("\nPrefetching {d} bottle{s}...\n", .{
            tasks.items.len,
            if (tasks.items.len == 1) "" else "s",
        });
        batch_download.fetchAll(tasks.items, config.cache, &http_client);
    }

    // --- Sequential install phase ---
    var linker = Linker.init(allocator, config.prefix);

    for (to_upgrade.items) |item| {
        var fmt_buf: [128]u8 = undefined;
        const new_formatted = item.index_version.format(&fmt_buf);

        const title = try std.fmt.allocPrint(allocator, "Upgrading {s} {s} -> {s}", .{
            item.name,
            item.installed_version,
            new_formatted,
        });
        defer allocator.free(title);
        out.section(title);

        const entry = index.lookup(item.name) orelse continue;

        // 1. Check for missing dependencies and install them.
        var dep_failed = false;
        {
            const dep_names = try index.getStringList(allocator, entry.deps_offset);
            defer allocator.free(dep_names);

            for (dep_names) |dep_name| {
                if (!cellar.isInstalled(dep_name)) {
                    out.print("Installing missing dependency: {s}...\n", .{dep_name});
                    const dep_args = &[_][]const u8{dep_name};
                    installCmd(allocator, dep_args, config) catch |install_err| {
                        err_out.err("Failed to install dependency \"{s}\": {s}", .{ dep_name, @errorName(install_err) });
                        dep_failed = true;
                        break;
                    };
                }
            }
        }
        if (dep_failed) {
            err_out.err("Skipping {s} due to dependency failure.", .{item.name});
            continue;
        }

        // 2. Download bottle (should be a cache hit from prefetch).
        const bottle_root_url = index.getString(entry.bottle_root_url_offset);
        const bottle_sha256 = index.getString(entry.bottle_sha256_offset);

        if (bottle_root_url.len == 0 or bottle_sha256.len == 0) {
            err_out.err("No bottle available for \"{s}\". Skipping.", .{item.name});
            continue;
        }

        const version = index.getString(entry.version_offset);

        const image_name = try download.ghcrImageName(allocator, item.name);
        defer allocator.free(image_name);

        const url = try std.fmt.allocPrint(allocator, "{s}/{s}/blobs/sha256:{s}", .{
            bottle_root_url, image_name, bottle_sha256,
        });
        defer allocator.free(url);

        var dl = Download.init(allocator, config.cache, &http_client);
        const archive_path = dl.fetchBottle(url, item.name, bottle_sha256) catch |err| {
            err_out.err("Download failed for {s}: {s}", .{ item.name, @errorName(err) });
            continue;
        };
        defer allocator.free(archive_path);

        // 3. Extract new bottle into cellar.
        out.print("Pouring {s} {s}...\n", .{ item.name, version });
        var bottle_inst = Bottle.init(allocator, config);
        const keg_cache_dir = std.fmt.allocPrint(allocator, "{s}/kegs", .{config.cache}) catch continue;
        defer allocator.free(keg_cache_dir);
        const keg_path = bottle_inst.pourWithCache(archive_path, item.name, version, bottle_sha256, keg_cache_dir) catch |err| {
            err_out.err("Extraction failed for {s}: {s}", .{ item.name, @errorName(err) });
            continue;
        };
        defer allocator.free(keg_path);

        // 4. Replace placeholders.
        bottle_inst.replacePlaceholders(keg_path) catch |err| {
            err_out.err("Placeholder replacement failed for {s}: {s}", .{ item.name, @errorName(err) });
        };

        // 5. Build runtime_dependencies and write install receipt.
        {
            const dep_names = try index.getStringList(allocator, entry.deps_offset);
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
                const dep_entry = index.lookup(dep_name) orelse continue;
                const dep_version = index.getString(dep_entry.version_offset);
                const dep_revision = dep_entry.revision;

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

            const tab = Tab{
                .installed_on_request = true,
                .poured_from_bottle = true,
                .loaded_from_api = true,
                .time = std.time.timestamp(),
                .runtime_dependencies = runtime_deps.items,
                .compiler = "clang",
                .homebrew_version = "bru 0.1.0",
                .source_tap = "homebrew/core",
            };
            tab.writeToKeg(allocator, keg_path) catch |err| {
                err_out.err("Failed to write receipt for {s}: {s}", .{ item.name, @errorName(err) });
            };
        }

        // 6. Unlink old version from prefix, link new, remove old keg.
        var old_keg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const old_keg_path = std.fmt.bufPrint(&old_keg_buf, "{s}/{s}/{s}", .{
            config.cellar, item.name, item.installed_version,
        }) catch continue;

        linker.unlink(old_keg_path) catch |err| {
            out.warn("Failed to unlink old {s} {s}: {s}", .{
                item.name, item.installed_version, @errorName(err),
            });
        };

        // 7. Link new version into prefix.
        const keg_only = (entry.flags & 1) != 0;
        if (keg_only) {
            linker.optLink(item.name, keg_path) catch |err| {
                err_out.err("Failed to link {s}: {s}", .{ item.name, @errorName(err) });
            };
        } else {
            linker.link(item.name, keg_path) catch |err| {
                err_out.err("Failed to link {s}: {s}", .{ item.name, @errorName(err) });
            };
        }

        // 8. Remove old keg directory.
        std.fs.deleteTreeAbsolute(old_keg_path) catch |err| {
            out.warn("Could not remove old keg {s}/{s}: {s}", .{
                item.name, item.installed_version, @errorName(err),
            });
        };

        out.print("{s} {s} upgraded.\n", .{ item.name, version });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "upgradeCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = upgradeCmd;
    _ = handler;
}
