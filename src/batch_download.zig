const std = @import("std");
const Allocator = std.mem.Allocator;
const Index = @import("index.zig").Index;
const Cellar = @import("cellar.zig").Cellar;
const download = @import("download.zig");
const Download = download.Download;
const HttpClient = @import("http.zig").HttpClient;
const collectTransitiveDeps = @import("cmd/deps.zig").collectTransitiveDeps;

pub const DownloadTask = struct {
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

/// Build a download task for a single formula and append it to the task list.
pub fn addDownloadTask(
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
pub fn prefetchDeps(
    allocator: Allocator,
    idx: *const Index,
    cellar: Cellar,
    name: []const u8,
    cache_dir: []const u8,
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
    fetchAll(tasks.items, cache_dir, http_client);
}

/// Spawn up to 4 worker threads to download all tasks using atomic
/// work-stealing. Blocks until all workers have finished.
pub fn fetchAll(
    tasks: []const DownloadTask,
    cache_dir: []const u8,
    http_client: *HttpClient,
) void {
    const max_workers = 4;
    const worker_count = @min(max_workers, tasks.len);
    var next_index: usize = 0;
    const ctx = WorkerContext{
        .tasks = tasks,
        .next_index = &next_index,
        .cache_dir = cache_dir,
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
}
