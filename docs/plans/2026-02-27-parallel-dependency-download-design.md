# Parallel Dependency Download Design

GitHub Issue: #22

## Problem

Download is 95-96% of cold install wall time. For packages with many deps (e.g. ffmpeg with 10 deps), each dep is downloaded sequentially despite being independent GHCR fetches.

## Approach: Parallel Pre-fetch (Approach A)

Before the sequential install loop, pre-download all missing bottles in parallel. The install loop runs unchanged — each `fetchBottle` call hits the download cache.

## Design

### Download Task

```zig
const DownloadTask = struct {
    url: []const u8,
    name: []const u8,
    sha256: []const u8,
};
```

### Pre-fetch Flow

1. Use `collectTransitiveDeps` from `deps.zig` to get full transitive closure
2. Filter to deps not already installed
3. Include the target formula in the task list
4. Look up `bottle_root_url` and `bottle_sha256` for each from the index
5. Spawn `@min(4, tasks.len)` worker threads
6. Each worker uses a shared atomic counter to grab the next task, calls `fetchBottle`, stores result
7. Main thread joins all workers

### Worker Pattern

Shared `std.atomic.Value(usize)` starts at 0. Each worker:
1. Atomically fetch-and-increment counter
2. If index >= tasks.len, exit
3. Call `Download.fetchBottle(task.url, task.name, task.sha256)`
4. Store error (if any) in per-task result slot
5. Goto 1

Each worker gets its own `ArenaAllocator` backed by page allocator.

### Error Handling

Pre-fetch is opportunistic. Failed downloads are logged as warnings. The sequential install loop retries the download and surfaces the real error if it fails again.

### Changes

- **`src/cmd/install.zig`**: Add `prefetchBottles` function, call it before the install loop, add `"prefetch"` timer span. Import `collectTransitiveDeps` and threading primitives.
- **`src/download.zig`**: No changes. Already stateless and thread-safe.
- **Other files**: No changes.

### Timing Output

```
==> Timing: ffmpeg
  index            42ms
  deps             1534ms
    prefetch       1200ms
  download         2ms       (cache hit)
  extract          890ms
  ...
```
