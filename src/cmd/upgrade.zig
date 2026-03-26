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
const installCmd = @import("install.zig").installCmd;
const isPinned = @import("pin.zig").isPinned;

/// An outdated formula pending upgrade.
const OutdatedFormula = struct {
    name: []const u8,
    installed_version: []const u8,
    index_version: PkgVersion,
};

/// Result of preparing a single package for upgrade (download, extract,
/// placeholders, receipt). Returned by `prepareOne`.
const PrepareResult = union(enum) {
    success: struct {
        keg_path: []const u8,
        version: []const u8,
        keg_only: bool,
    },
    failure: struct {
        err_name: []const u8,
    },
};

/// Read-only shared state passed to `prepareOne`. Contains references to
/// structures that are safe to share across worker threads.
const PrepareContext = struct {
    index: *Index,
    config: Config,
};

/// Prepare a single outdated formula for upgrade: download the bottle,
/// extract it, replace placeholders, and write the install receipt.
///
/// This function is self-contained — it creates its own HttpClient and
/// allocates exclusively from the provided arena. It never touches the
/// linker, state, or any shared mutable state, making it safe to call
/// from a worker thread.
///
/// Returns `.success` with the keg path, version, and keg_only flag on
/// success, or `.failure` with the error name if anything goes wrong.
fn prepareOne(arena: Allocator, ctx: PrepareContext, item: OutdatedFormula) PrepareResult {
    const entry = ctx.index.lookup(item.name) orelse {
        return .{ .failure = .{ .err_name = "FormulaNotFound" } };
    };

    // Check that a bottle is available.
    const bottle_root_url = ctx.index.getString(entry.bottle_root_url_offset);
    const bottle_sha256 = ctx.index.getString(entry.bottle_sha256_offset);

    if (bottle_root_url.len == 0 or bottle_sha256.len == 0) {
        return .{ .failure = .{ .err_name = "NoBottleAvailable" } };
    }

    const version_base = ctx.index.getString(entry.version_offset);
    var pkg_ver_buf_main: [256]u8 = undefined;
    const version = if (entry.revision > 0)
        std.fmt.bufPrint(&pkg_ver_buf_main, "{s}_{d}", .{ version_base, entry.revision }) catch version_base
    else
        version_base;

    // Build the download URL.
    const image_name = download.ghcrImageName(arena, item.name) catch |err| {
        return .{ .failure = .{ .err_name = @errorName(err) } };
    };

    const url = std.fmt.allocPrint(arena, "{s}/{s}/blobs/sha256:{s}", .{
        bottle_root_url, image_name, bottle_sha256,
    }) catch |err| {
        return .{ .failure = .{ .err_name = @errorName(err) } };
    };

    // Download bottle.
    var http_client = HttpClient.init(arena);
    defer http_client.deinit();

    var dl = Download.init(arena, ctx.config.cache, &http_client);
    const archive_path = dl.fetchBottle(url, item.name, bottle_sha256) catch |err| {
        return .{ .failure = .{ .err_name = @errorName(err) } };
    };

    // Extract new bottle into cellar.
    var bottle_inst = Bottle.init(arena, ctx.config);
    const keg_cache_dir = std.fmt.allocPrint(arena, "{s}/kegs", .{ctx.config.cache}) catch |err| {
        return .{ .failure = .{ .err_name = @errorName(err) } };
    };
    const keg_path = bottle_inst.pourWithCache(archive_path, item.name, version, bottle_sha256, keg_cache_dir) catch |err| {
        return .{ .failure = .{ .err_name = @errorName(err) } };
    };

    // Replace placeholders.
    bottle_inst.replacePlaceholders(keg_path) catch {};

    // Build runtime_dependencies and write install receipt.
    {
        const dep_names = ctx.index.getStringList(arena, entry.deps_offset) catch |err| {
            return .{ .failure = .{ .err_name = @errorName(err) } };
        };

        var runtime_deps = std.ArrayList(RuntimeDep).initCapacity(arena, dep_names.len) catch |err| {
            return .{ .failure = .{ .err_name = @errorName(err) } };
        };

        for (dep_names) |dep_name| {
            const dep_entry = ctx.index.lookup(dep_name) orelse continue;
            const dep_version = ctx.index.getString(dep_entry.version_offset);
            const dep_revision = dep_entry.revision;

            var pkg_ver_buf: [256]u8 = undefined;
            const pkg_version = if (dep_revision > 0)
                std.fmt.bufPrint(&pkg_ver_buf, "{s}_{d}", .{ dep_version, dep_revision }) catch continue
            else
                dep_version;

            const full_name = arena.dupe(u8, dep_name) catch continue;
            const version_str = arena.dupe(u8, dep_version) catch continue;
            const pkg_ver = arena.dupe(u8, pkg_version) catch continue;

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
        tab.writeToKeg(arena, keg_path) catch |err| {
            return .{ .failure = .{ .err_name = @errorName(err) } };
        };
    }

    const keg_only = (entry.flags & 1) != 0;

    return .{ .success = .{
        .keg_path = keg_path,
        .version = version,
        .keg_only = keg_only,
    } };
}

const PrepareWorkerContext = struct {
    items: []const OutdatedFormula,
    results: []PrepareResult,
    arenas: []std.heap.ArenaAllocator,
    next_index: *usize,
    prepare_ctx: PrepareContext,
};

/// Worker thread: claims items via atomic counter, prepares each in its own
/// arena. Arenas are stored in the shared array so they outlive the worker
/// (the caller deinits them after consuming results).
fn prepareWorker(ctx: PrepareWorkerContext) void {
    while (true) {
        const i = @atomicRmw(usize, ctx.next_index, .Add, 1, .seq_cst);
        if (i >= ctx.items.len) return;

        ctx.arenas[i] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        ctx.results[i] = prepareOne(ctx.arenas[i].allocator(), ctx.prepare_ctx, ctx.items[i]);
    }
}

const CleanupContext = struct {
    paths: []const []const u8,
    next_index: *usize,
};

fn cleanupWorker(ctx: CleanupContext) void {
    while (true) {
        const i = @atomicRmw(usize, ctx.next_index, .Add, 1, .seq_cst);
        if (i >= ctx.paths.len) return;
        std.fs.deleteTreeAbsolute(ctx.paths[i]) catch {};
    }
}

/// Upgrade outdated formulae: parallel prepare (download/extract/receipt
/// via worker threads), then sequential swap (unlink/link).
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

    // --- Dependency pre-scan: install missing deps before parallel prepare ---
    {
        var all_missing = std.StringHashMap(void).init(allocator);
        defer all_missing.deinit();

        for (to_upgrade.items) |item| {
            const entry = index.lookup(item.name) orelse continue;
            const dep_names = index.getStringList(allocator, entry.deps_offset) catch continue;
            defer allocator.free(dep_names);

            for (dep_names) |dep_name| {
                if (!cellar.isInstalled(dep_name) and !all_missing.contains(dep_name)) {
                    all_missing.put(dep_name, {}) catch continue;
                    out.print("Installing missing dependency: {s}...\n", .{dep_name});
                    const dep_args = &[_][]const u8{dep_name};
                    installCmd(allocator, dep_args, config) catch |install_err| {
                        err_out.err("Failed to install dependency \"{s}\": {s}", .{ dep_name, @errorName(install_err) });
                    };
                }
            }
        }
    }

    // --- Parallel prepare phase ---
    out.print("\nPreparing {d} package{s}...\n", .{
        to_upgrade.items.len,
        if (to_upgrade.items.len == 1) "" else "s",
    });

    const results = try allocator.alloc(PrepareResult, to_upgrade.items.len);
    defer allocator.free(results);

    // Per-item arenas kept alive until after swap phase so keg_path pointers
    // in PrepareResult.success remain valid.
    const arenas = try allocator.alloc(std.heap.ArenaAllocator, to_upgrade.items.len);
    for (arenas) |*a| a.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer {
        for (arenas) |*a| a.deinit();
        allocator.free(arenas);
    }

    // Initialize all results to failure.
    for (results) |*r| {
        r.* = .{ .failure = .{ .err_name = "NotStarted" } };
    }

    const prepare_ctx = PrepareContext{
        .index = &index,
        .config = config,
    };

    {
        const max_workers = 4;
        const worker_count = @min(max_workers, to_upgrade.items.len);
        var next_index: usize = 0;
        const worker_ctx = PrepareWorkerContext{
            .items = to_upgrade.items,
            .results = results,
            .arenas = arenas,
            .next_index = &next_index,
            .prepare_ctx = prepare_ctx,
        };

        var threads: [max_workers]std.Thread = undefined;
        var spawned: usize = 0;
        for (0..worker_count) |ti| {
            threads[ti] = std.Thread.spawn(.{}, prepareWorker, .{worker_ctx}) catch break;
            spawned += 1;
        }
        for (0..spawned) |ti| {
            threads[ti].join();
        }
    }

    // --- Sequential swap phase ---
    var linker = Linker.init(allocator, config.prefix);
    var old_kegs = std.ArrayList([]const u8){};
    defer {
        for (old_kegs.items) |p| allocator.free(p);
        old_kegs.deinit(allocator);
    }

    for (to_upgrade.items, results) |item, result| {
        switch (result) {
            .failure => |f| {
                err_out.err("Failed to prepare {s}: {s}", .{ item.name, f.err_name });
                continue;
            },
            .success => |s| {
                // Unlink old version.
                var old_keg_buf: [std.fs.max_path_bytes]u8 = undefined;
                const old_keg_path = std.fmt.bufPrint(&old_keg_buf, "{s}/{s}/{s}", .{
                    config.cellar, item.name, item.installed_version,
                }) catch continue;

                linker.unlink(old_keg_path) catch |err| {
                    out.warn("Failed to unlink old {s} {s}: {s}", .{
                        item.name, item.installed_version, @errorName(err),
                    });
                };

                // Link new version.
                if (s.keg_only) {
                    linker.optLink(item.name, s.keg_path) catch |err| {
                        err_out.err("Failed to link {s}: {s}", .{ item.name, @errorName(err) });
                    };
                } else {
                    linker.link(item.name, s.keg_path) catch |err| {
                        err_out.err("Failed to link {s}: {s}", .{ item.name, @errorName(err) });
                    };
                }

                out.print("{s} {s} upgraded.\n", .{ item.name, s.version });

                // Record state.
                {
                    var state = @import("../state.zig").State.load(allocator);
                    defer state.deinit();
                    state.recordAction("upgrade", item.name, s.version, item.installed_version) catch {};
                    state.save() catch {};
                }

                // Collect old keg path for cleanup.
                const old_keg_copy = allocator.dupe(u8, old_keg_path) catch continue;
                old_kegs.append(allocator, old_keg_copy) catch {
                    allocator.free(old_keg_copy);
                };
            },
        }
    }

    // --- Parallel cleanup phase ---
    if (old_kegs.items.len > 0) {
        const max_cleanup = 4;
        const cleanup_count = @min(max_cleanup, old_kegs.items.len);
        var cleanup_next: usize = 0;
        const cleanup_ctx = CleanupContext{
            .paths = old_kegs.items,
            .next_index = &cleanup_next,
        };

        var cleanup_threads: [max_cleanup]std.Thread = undefined;
        var cleanup_spawned: usize = 0;
        for (0..cleanup_count) |ti| {
            cleanup_threads[ti] = std.Thread.spawn(.{}, cleanupWorker, .{cleanup_ctx}) catch break;
            cleanup_spawned += 1;
        }
        for (0..cleanup_spawned) |ti| {
            cleanup_threads[ti].join();
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "upgradeCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = upgradeCmd;
    _ = handler;
}

test "prepareOne compiles and has correct signature" {
    const F = @TypeOf(prepareOne);
    const info = @typeInfo(F);
    try std.testing.expect(info == .@"fn");
}

test "prepareWorker compiles and has correct signature" {
    const F = @TypeOf(prepareWorker);
    const info = @typeInfo(F);
    try std.testing.expect(info == .@"fn");
}

test "cleanupWorker compiles and has correct signature" {
    const F = @TypeOf(cleanupWorker);
    const info = @typeInfo(F);
    try std.testing.expect(info == .@"fn");
}
