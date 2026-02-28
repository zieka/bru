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
const timer_mod = @import("../timer.zig");
const Timer = timer_mod.Timer;
const Trace = timer_mod.Trace;
const HttpClient = @import("../http.zig").HttpClient;
const collectTransitiveDeps = @import("deps.zig").collectTransitiveDeps;

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

    // Initialize trace for timing/profiling.
    var trace = Trace.init(allocator, config.timing);
    defer trace.deinit();
    trace.formula_name = name;

    var http_client = HttpClient.init(allocator);
    defer http_client.deinit();

    // Start total timer.
    var total_timer = Timer.start(&trace, "total");

    // 2. Look up in index.
    var index_timer = Timer.start(&trace, "index");
    var idx = try Index.loadOrBuild(allocator, config.cache);
    index_timer.stop();
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
    var deps_timer = Timer.start(&trace, "deps");
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
            prefetchBottles(allocator, &idx, cellar, name, config, &trace, &http_client);
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
    deps_timer.stop();

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

    var dl = Download.init(allocator, config.cache, &http_client);

    var download_timer = Timer.start(&trace, "download");
    const archive_path = try dl.fetchBottle(url, name, bottle_sha256);
    download_timer.stop();
    defer allocator.free(archive_path);

    // 8. Extract bottle.
    out.print("Pouring {s} {s}...\n", .{ name, version });

    var bottle = Bottle.init(allocator, config);

    var extract_timer = Timer.start(&trace, "extract");
    const keg_path = try bottle.pour(archive_path, name, version);
    extract_timer.stop();
    defer allocator.free(keg_path);

    // 9. Replace placeholders.
    var placeholders_timer = Timer.start(&trace, "placeholders");
    try bottle.replacePlaceholders(keg_path);
    placeholders_timer.stop();

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
    var receipt_timer = Timer.start(&trace, "receipt");
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
    try tab.writeToKeg(allocator, keg_path);
    receipt_timer.stop();

    // 12. Link into prefix.
    var link_timer = Timer.start(&trace, "link");
    const keg_only = (entry.flags & 1) != 0;
    var linker = Linker.init(allocator, config.prefix);

    if (keg_only) {
        try linker.optLink(name, keg_path);
    } else {
        try linker.link(name, keg_path);
    }
    link_timer.stop();

    // Stop total timer.
    total_timer.stop();

    // Print timing breakdown if --timing was set.
    trace.printTimings();

    // Write trace file if -Dtrace was set at build time.
    trace.writeTraceFile("bru-trace.json");

    // 13. Print completion.
    const done_title = try std.fmt.allocPrint(allocator, "{s} {s} is installed", .{ name, version });
    defer allocator.free(done_title);
    out.section(done_title);
}

// ---------------------------------------------------------------------------
// Parallel bottle pre-fetch
// ---------------------------------------------------------------------------

const DownloadTask = struct {
    url: []const u8,
    name: []const u8,
    sha256: []const u8,
};

const WorkerContext = struct {
    tasks: []const DownloadTask,
    next_index: *usize,
    cache_dir: []const u8,
    http_client: *HttpClient,
};

/// Worker thread: claims tasks via atomic counter and downloads bottles.
/// Must not access shared mutable state (e.g. Trace) -- only the atomic
/// next_index and immutable task data.
fn downloadWorker(ctx: WorkerContext) void {
    while (true) {
        const i = @atomicRmw(usize, ctx.next_index, .Add, 1, .seq_cst);
        if (i >= ctx.tasks.len) return;

        const task = ctx.tasks[i];
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var dl = Download.init(arena.allocator(), ctx.cache_dir, ctx.http_client);
        _ = dl.fetchBottle(task.url, task.name, task.sha256) catch continue;
    }
}

fn addDownloadTask(
    allocator: Allocator,
    idx: *const Index,
    tasks: *std.ArrayList(DownloadTask),
    dep_name: []const u8,
) !void {
    const dep_entry = idx.lookup(dep_name) orelse return;
    const bottle_root_url = idx.getString(dep_entry.bottle_root_url_offset);
    const bottle_sha256 = idx.getString(dep_entry.bottle_sha256_offset);
    if (bottle_root_url.len == 0 or bottle_sha256.len == 0) return;

    const image_name = try download.ghcrImageName(allocator, dep_name);
    defer allocator.free(image_name);

    const url = try std.fmt.allocPrint(allocator, "{s}/{s}/blobs/sha256:{s}", .{
        bottle_root_url, image_name, bottle_sha256,
    });

    try tasks.append(allocator, .{ .url = url, .name = dep_name, .sha256 = bottle_sha256 });
}

/// Pre-fetch bottles for all transitive missing dependencies (and the target
/// formula) in parallel. This is best-effort: any failures are silently
/// ignored because the sequential install loop will retry each download.
fn prefetchBottles(
    allocator: Allocator,
    idx: *const Index,
    cellar: Cellar,
    name: []const u8,
    config: Config,
    trace: *Trace,
    http_client: *HttpClient,
) void {
    // 1. Collect full transitive dependency closure.
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    var all_deps = std.ArrayList([]const u8){};
    defer all_deps.deinit(allocator);
    collectTransitiveDeps(idx, allocator, name, &visited, &all_deps, false) catch return;

    // 2. Build download tasks for missing deps + target formula.
    var tasks = std.ArrayList(DownloadTask){};
    defer {
        for (tasks.items) |task| allocator.free(task.url);
        tasks.deinit(allocator);
    }

    for (all_deps.items) |dep_name| {
        if (cellar.isInstalled(dep_name)) continue;
        addDownloadTask(allocator, idx, &tasks, dep_name) catch continue;
    }
    addDownloadTask(allocator, idx, &tasks, name) catch {};

    if (tasks.items.len == 0) return;

    // 3. Spawn worker threads with shared atomic work index.
    var prefetch_timer = Timer.start(trace, "prefetch");

    const max_workers = 4;
    const worker_count = @min(max_workers, tasks.items.len);
    // next_index and tasks.items are safe to share because we join all
    // threads before this function returns (so they outlive the workers).
    var next_index: usize = 0;
    const ctx = WorkerContext{
        .tasks = tasks.items,
        .next_index = &next_index,
        .cache_dir = config.cache,
        .http_client = http_client,
    };

    var threads: [max_workers]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..worker_count) |i| {
        threads[i] = std.Thread.spawn(.{}, downloadWorker, .{ctx}) catch break;
        spawned += 1;
    }
    for (0..spawned) |i| {
        threads[i].join();
    }

    prefetch_timer.stop();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "installCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = installCmd;
    _ = handler;
}
