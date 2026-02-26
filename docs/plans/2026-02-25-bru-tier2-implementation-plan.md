# bru Tier 2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add write operations to bru: update, fetch, install, uninstall, upgrade, link/unlink, cleanup/autoremove.

**Architecture:** HTTP client for bottle downloads from ghcr.io (OCI blobs). Gzip+tar extraction into Cellar. Symlink management mirroring brew's keg linking strategy. Tab writing for brew compatibility. All operations fall back to brew on failure.

**Tech Stack:** Zig 0.15.2. `std.http.Client` for HTTP. `std.compress.gzip` and `std.tar` for extraction. `std.crypto.hash.sha2.Sha256` for checksums.

**Reference:** `docs/plans/2026-02-25-bru-architecture-design.md`, Tier 1 code in `src/`

**Zig 0.15.2 API patterns (from Tier 1):**
- stdout: `std.fs.File.stdout().writer(&buf)` → `.interface` → `.print(...)` → `.flush()`
- stderr: `std.fs.File.stderr()` same pattern
- ArrayList: unmanaged — pass allocator to every method (`append(allocator, item)`, `deinit(allocator)`, `toOwnedSlice(allocator)`)
- JSON: `std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always })`
- CommandFn: `*const fn (std.mem.Allocator, []const []const u8, Config) anyerror!void`
- Register commands in `src/dispatch.zig` `native_commands` array as `CommandEntry{ .name = "...", .handler = ... }`
- Add `_ = @import("...");` to `src/main.zig` test block

---

## Phase 1: Networking & Downloads (Tasks 1–3)

### Task 1: HTTP Client Module

**Files:**
- Create: `src/http.zig`
- Modify: `src/main.zig` (test block)

**Context:** All bottle downloads go to ghcr.io. Anonymous auth uses `Authorization: Bearer QQ==` (base64 of "A"). Downloads are simple GET requests to blob URLs. We need resume support and checksum verification.

**Step 1: Write failing test**

Create `src/http.zig` with a test that fetches a known small URL:

```zig
const std = @import("std");

pub const HttpClient = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{ .allocator = allocator };
    }

    pub fn fetch(self: HttpClient, url: []const u8, dest_path: []const u8) !void {
        _ = self;
        _ = url;
        _ = dest_path;
        unreachable;
    }

    pub fn fetchGhcr(self: HttpClient, url: []const u8, dest_path: []const u8) !void {
        _ = self;
        _ = url;
        _ = dest_path;
        unreachable;
    }
};

test "HttpClient fetch downloads a file" {
    var client = HttpClient.init(std.testing.allocator);
    // Fetch a tiny known URL (Homebrew's formula_names.txt is small)
    try client.fetch(
        "https://formulae.brew.sh/api/formula_names.txt",
        "/tmp/bru_test_fetch.txt",
    );
    const file = try std.fs.openFileAbsolute("/tmp/bru_test_fetch.txt", .{});
    defer file.close();
    const stat = try file.stat();
    try std.testing.expect(stat.size > 100);
    std.fs.deleteFileAbsolute("/tmp/bru_test_fetch.txt") catch {};
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL (unreachable)

**Step 3: Implement HttpClient**

```zig
pub fn fetch(self: HttpClient, url: []const u8, dest_path: []const u8) !void {
    return self.fetchWithHeaders(url, dest_path, &.{});
}

pub fn fetchGhcr(self: HttpClient, url: []const u8, dest_path: []const u8) !void {
    return self.fetchWithHeaders(url, dest_path, &.{
        .{ .name = "Authorization", .value = "Bearer QQ==" },
    });
}

fn fetchWithHeaders(
    self: HttpClient,
    url: []const u8,
    dest_path: []const u8,
    extra_headers: []const std.http.Header,
) !void {
    var client = std.http.Client{ .allocator = self.allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var header_buf: [8192]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = extra_headers,
    });
    defer req.deinit();
    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpError;
    }

    // Write response body to dest file
    const dest_file = try std.fs.createFileAbsolute(dest_path, .{});
    defer dest_file.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try req.reader().read(&buf);
        if (n == 0) break;
        try dest_file.writeAll(buf[0..n]);
    }
}
```

Note: The Zig 0.15 HTTP client API may differ. Check `std.http.Client` for exact method names. Key methods to look for: `open`, `send`, `wait`, `reader`. If the API is different (e.g., `request` instead of `open`), adapt accordingly.

**Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS

**Step 5: Add test for GHCR auth**

```zig
test "HttpClient fetchGhcr with auth header" {
    var client = HttpClient.init(std.testing.allocator);
    // Fetch a bottle manifest (small JSON) to verify auth works
    // Using a known stable formula
    try client.fetchGhcr(
        "https://ghcr.io/v2/homebrew/core/jq/manifests/1.7.1",
        "/tmp/bru_test_ghcr.json",
    );
    const file = try std.fs.openFileAbsolute("/tmp/bru_test_ghcr.json", .{});
    defer file.close();
    const stat = try file.stat();
    try std.testing.expect(stat.size > 50);
    std.fs.deleteFileAbsolute("/tmp/bru_test_ghcr.json") catch {};
}
```

Note: The manifest endpoint may require an Accept header. If this test fails with 401 or 404, add `Accept: application/vnd.oci.image.index.v1+json` to the GHCR headers. If it fails with a redirect, the HTTP client may need to follow redirects (check if Zig's client does this automatically).

**Step 6: Run tests**

Run: `zig build test`
Expected: PASS

**Step 7: Commit**

```bash
git add src/http.zig src/main.zig
git commit -m "feat: HTTP client with GHCR auth for bottle downloads"
```

---

### Task 2: Download Cache & Checksum Verification

**Files:**
- Create: `src/download.zig`
- Modify: `src/main.zig` (test block)

**Context:** Brew caches downloads at `$HOMEBREW_CACHE/downloads/{SHA256(url)}--{safe_filename}`. Before downloading, check if the cached file exists and its SHA-256 matches the expected checksum. If so, skip the download.

**Step 1: Write failing test**

```zig
const std = @import("std");

pub const Download = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8) Download {
        return .{ .allocator = allocator, .cache_dir = cache_dir };
    }

    /// Return the cache path for a URL. Format: {cache_dir}/downloads/{sha256_of_url}--{safe_name}
    pub fn cachePath(self: Download, url: []const u8, name: []const u8) ![]const u8 {
        _ = self;
        _ = url;
        _ = name;
        unreachable;
    }

    /// Verify a file's SHA-256 matches expected hash
    pub fn verifySha256(path: []const u8, expected_hex: []const u8) !bool {
        _ = path;
        _ = expected_hex;
        unreachable;
    }

    /// Download a bottle, using cache if available and checksum matches
    pub fn fetchBottle(
        self: Download,
        url: []const u8,
        name: []const u8,
        expected_sha256: []const u8,
    ) ![]const u8 {
        _ = self;
        _ = url;
        _ = name;
        _ = expected_sha256;
        unreachable;
    }
};

test "cachePath produces deterministic path" {
    const dl = Download.init(std.testing.allocator, "/tmp/test_cache");
    const p1 = try dl.cachePath("https://example.com/file.tar.gz", "test-pkg");
    defer std.testing.allocator.free(p1);
    const p2 = try dl.cachePath("https://example.com/file.tar.gz", "test-pkg");
    defer std.testing.allocator.free(p2);
    try std.testing.expectEqualStrings(p1, p2);
    try std.testing.expect(std.mem.indexOf(u8, p1, "downloads/") != null);
    try std.testing.expect(std.mem.endsWith(u8, p1, "--test-pkg"));
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement Download**

```zig
pub fn cachePath(self: Download, url: []const u8, name: []const u8) ![]const u8 {
    // Hash the URL to get a deterministic cache key
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(url);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // Convert to hex
    const hex = std.fmt.bytesToHex(digest, .lower);

    return std.fmt.allocPrint(self.allocator, "{s}/downloads/{s}--{s}", .{
        self.cache_dir, hex, name,
    });
}

pub fn verifySha256(allocator: std.mem.Allocator, path: []const u8, expected_hex: []const u8) !bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return false;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const actual_hex = std.fmt.bytesToHex(digest, .lower);

    return std.mem.eql(u8, &actual_hex, expected_hex);
}

pub fn fetchBottle(
    self: Download,
    url: []const u8,
    name: []const u8,
    expected_sha256: []const u8,
) ![]const u8 {
    const path = try self.cachePath(url, name);

    // Check cache
    if (expected_sha256.len > 0) {
        if (try verifySha256(self.allocator, path, expected_sha256)) {
            return path; // Cache hit
        }
    }

    // Ensure downloads directory exists
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/downloads", .{self.cache_dir});
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Download
    const http = @import("http.zig");
    var client = http.HttpClient.init(self.allocator);
    try client.fetchGhcr(url, path);

    // Verify checksum
    if (expected_sha256.len > 0) {
        if (!try verifySha256(self.allocator, path, expected_sha256)) {
            std.fs.deleteFileAbsolute(path) catch {};
            return error.ChecksumMismatch;
        }
    }

    return path;
}
```

Note: `std.crypto.hash.sha2.Sha256` — verify this exists in Zig 0.15. It might be at a different path. Also check `std.fmt.bytesToHex`.

**Step 4: Run tests**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/download.zig src/main.zig
git commit -m "feat: download cache with SHA-256 verification"
```

---

### Task 3: `fetch` Command

**Files:**
- Create: `src/cmd/fetch_cmd.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew fetch <formula>` downloads the bottle without installing. It uses the index to look up the bottle URL and SHA-256, then downloads to cache.

The bottle blob URL pattern from the formula API JSON is:
```
{bottle.stable.files.{tag}.url}
```
Which is the direct GHCR blob URL like:
`https://ghcr.io/v2/homebrew/core/bat/blobs/sha256:abc123...`

If the formula API JSON provides the `url` field directly, use it. Otherwise construct from `root_url`:
```
{root_url}/{name}/blobs/sha256:{sha256}
```

But in the index we stored `bottle_root_url` and `bottle_sha256`. We need to construct:
```
{bottle_root_url}/{name}/blobs/sha256:{bottle_sha256}
```

Name needs `@` → `/` and `+` → `x` substitution for GHCR image naming.

**Step 1: Create src/cmd/fetch_cmd.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Download = @import("../download.zig").Download;
const Output = @import("../output.zig").Output;

pub fn fetchCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    if (args.len == 0) {
        const out = Output.initErr(config.no_color);
        try out.err("Usage: bru fetch <formula>", .{});
        std.process.exit(1);
    }

    const name = args[0];
    const index = try Index.loadOrBuild(allocator, config.cache);
    const entry = index.lookup(name) orelse {
        const out = Output.initErr(config.no_color);
        try out.err("No available formula with the name \"{s}\".", .{name});
        std.process.exit(1);
    };

    const root_url = index.getString(entry.bottle_root_url_offset);
    const sha256 = index.getString(entry.bottle_sha256_offset);

    if (root_url.len == 0 or sha256.len == 0) {
        const out = Output.initErr(config.no_color);
        try out.err("No bottle available for {s}.", .{name});
        std.process.exit(1);
    }

    // Construct GHCR blob URL
    // Name: @ → /, + → x for GHCR image naming
    const image_name = try ghcrImageName(allocator, name);
    defer allocator.free(image_name);
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}/blobs/sha256:{s}", .{
        root_url, image_name, sha256,
    });
    defer allocator.free(url);

    const out = Output.init(config.no_color);
    try out.section(try std.fmt.allocPrint(allocator, "Fetching {s}", .{name}));

    const dl = Download.init(allocator, config.cache);
    const cached_path = try dl.fetchBottle(url, name, sha256);

    try out.print("Downloaded to: {s}\n", .{cached_path});
}

fn ghcrImageName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = switch (c) {
            '@' => '/',
            '+' => 'x',
            else => c,
        };
    }
    return result;
}
```

**Step 2: Register in dispatch.zig**

Add to native_commands:
```zig
const fetch_cmd = @import("cmd/fetch_cmd.zig");
.{ .name = "fetch", .handler = fetch_cmd.fetchCmd },
```

**Step 3: Build and test**

Run: `zig build run -- fetch jq`
Expected: Downloads jq bottle to cache, prints path

Note: This is a real network download. If it fails, check:
- HTTP client redirect handling (GHCR may 307 redirect)
- Auth header format
- URL construction

If the HTTP client can't follow redirects automatically, you'll need to handle 301/302/307 responses manually.

**Step 4: Commit**

```bash
git add src/cmd/fetch_cmd.zig src/dispatch.zig src/main.zig
git commit -m "feat: fetch command downloads bottles from GHCR"
```

---

## Phase 2: Extraction & Linking (Tasks 4–6)

### Task 4: Bottle Extraction

**Files:**
- Create: `src/bottle.zig`
- Modify: `src/main.zig` (test block)

**Context:** Bottles are .tar.gz files. The tar contains a directory structure starting with `{formula_name}/{version}/`. This extracts into `HOMEBREW_CELLAR/{formula_name}/{version}/`. After extraction, path placeholders in text files need replacement.

Six placeholders:
- `@@HOMEBREW_PREFIX@@` → actual prefix (e.g., `/opt/homebrew`)
- `@@HOMEBREW_CELLAR@@` → actual cellar (e.g., `/opt/homebrew/Cellar`)
- `@@HOMEBREW_REPOSITORY@@` → actual prefix (same as prefix on standard installs)
- `@@HOMEBREW_LIBRARY@@` → `{prefix}/Library`
- `@@HOMEBREW_PERL@@` → perl path (skip for now)
- `@@HOMEBREW_JAVA@@` → java path (skip for now)

**Step 1: Write failing test**

```zig
const std = @import("std");
const Config = @import("config.zig").Config;

pub const Bottle = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) Bottle {
        return .{ .allocator = allocator, .config = config };
    }

    /// Extract a .tar.gz bottle into the cellar.
    /// Returns the keg path (e.g., /opt/homebrew/Cellar/bat/0.26.1)
    pub fn pour(self: Bottle, archive_path: []const u8) ![]const u8 {
        _ = self;
        _ = archive_path;
        unreachable;
    }

    /// Replace @@HOMEBREW_*@@ placeholders in text files within a keg
    pub fn replacePlaceholders(self: Bottle, keg_path: []const u8) !void {
        _ = self;
        _ = keg_path;
        unreachable;
    }
};
```

Testing tar extraction is tricky without a real bottle. For unit tests, create a small .tar.gz in memory or use a real cached bottle. The real integration test will come when `install` is wired up.

**Step 2: Implement pour()**

```zig
pub fn pour(self: Bottle, archive_path: []const u8) ![]const u8 {
    // Open the archive file
    const file = try std.fs.openFileAbsolute(archive_path, .{});
    defer file.close();

    // Decompress gzip
    var gzip = std.compress.gzip.decompressor(file.reader());

    // Extract tar into cellar directory
    var cellar_dir = try std.fs.openDirAbsolute(self.config.cellar, .{});
    defer cellar_dir.close();

    try std.tar.pipeToFileSystem(cellar_dir, gzip.reader(), .{
        .strip_components = 0,
    });

    // The first directory in the tar is the formula name/version
    // We need to find what was extracted
    // For now, return the path based on the archive filename
    // TODO: Parse tar headers to determine the actual keg path
    return ""; // Placeholder - will be determined from context
}
```

Note: The Zig 0.15 API for `std.compress.gzip` and `std.tar` may differ significantly. Look for:
- `std.compress.gzip.Decompressor` or `std.compress.gzip.decompressor`
- `std.tar.pipeToFileSystem` or equivalent
- These may not exist at all in 0.15 — if so, use `std.process.Child.run` to call system `tar xzf` as a fallback

**Step 3: Implement replacePlaceholders()**

Walk the keg directory recursively, read each regular file, check if it's a text file (no null bytes in first 512 bytes), replace placeholder strings, write back.

```zig
pub fn replacePlaceholders(self: Bottle, keg_path: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(keg_path, .{ .iterate = true });
    defer dir.close();
    try self.replaceInDir(dir, keg_path);
}

fn replaceInDir(self: Bottle, dir: std.fs.Dir, dir_path: []const u8) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });

        if (entry.kind == .directory) {
            var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer sub_dir.close();
            try self.replaceInDir(sub_dir, full_path);
        } else if (entry.kind == .file or entry.kind == .sym_link) {
            self.replaceInFile(full_path) catch continue;
        }
    }
}

fn replaceInFile(self: Bottle, path: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer file.close();

    const contents = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
    defer self.allocator.free(contents);

    // Check if text file (no null bytes in first 512 bytes)
    const check_len = @min(contents.len, 512);
    for (contents[0..check_len]) |byte| {
        if (byte == 0) return; // Binary file, skip
    }

    // Replace placeholders
    var modified = false;
    var result = contents;
    const replacements = [_][2][]const u8{
        .{ "@@HOMEBREW_PREFIX@@", self.config.prefix },
        .{ "@@HOMEBREW_CELLAR@@", self.config.cellar },
        .{ "@@HOMEBREW_REPOSITORY@@", self.config.prefix },
    };
    for (replacements) |pair| {
        if (std.mem.indexOf(u8, result, pair[0]) != null) {
            modified = true;
            // Perform replacement — allocate new buffer
            // (simple approach: use std.mem.replaceOwned or manual)
        }
    }

    if (modified) {
        // Write back
        try file.seekTo(0);
        try file.writeAll(result);
        try file.setEndPos(result.len);
    }
}
```

This needs a proper string replace implementation. Use a helper that replaces all occurrences.

**Step 4: Run tests**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/bottle.zig src/main.zig
git commit -m "feat: bottle extraction with tar.gz decompression and placeholder replacement"
```

---

### Task 5: Keg Linker

**Files:**
- Create: `src/linker.zig`
- Modify: `src/main.zig` (test block)

**Context:** After a bottle is poured, its contents need to be symlinked into `$HOMEBREW_PREFIX/{bin,lib,include,share,...}`. The opt link `$HOMEBREW_PREFIX/opt/{name} → keg` must also be created. This mirrors brew's keg linking strategy:

- `bin/`, `sbin/`: flat — symlink files only, skip subdirectories
- `lib/`: link dirs by default, but create real dirs for `pkgconfig/`, `cmake/`, language-specific dirs
- `include/`: link dirs by default
- `share/`: link dirs by default, but create real dirs for `man/`, `locale/`, `info/`, `icons/`, `zsh/`, `fish/`
- `etc/`: always create real directories, symlink files only
- `var/`: link normally

**Step 1: Write failing test**

```zig
const std = @import("std");

pub const Linker = struct {
    prefix: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8) Linker {
        return .{ .prefix = prefix, .allocator = allocator };
    }

    /// Create opt link: $PREFIX/opt/{name} → keg_path
    pub fn optLink(self: Linker, name: []const u8, keg_path: []const u8) !void {
        _ = self; _ = name; _ = keg_path;
        unreachable;
    }

    /// Link all keg contents into prefix
    pub fn link(self: Linker, name: []const u8, keg_path: []const u8) !void {
        _ = self; _ = name; _ = keg_path;
        unreachable;
    }

    /// Remove all symlinks from prefix that point into the given keg
    pub fn unlink(self: Linker, keg_path: []const u8) !void {
        _ = self; _ = keg_path;
        unreachable;
    }
};

test "Linker optLink creates symlink" {
    // This test needs a temp directory setup
    // Use /tmp/bru_test_linker as a fake prefix
    const test_prefix = "/tmp/bru_test_linker";
    std.fs.makeDirAbsolute(test_prefix) catch {};
    defer std.fs.deleteTreeAbsolute(test_prefix) catch {};

    std.fs.makeDirAbsolute(test_prefix ++ "/opt") catch {};

    var linker = Linker.init(std.testing.allocator, test_prefix);
    try linker.optLink("test-pkg", "/opt/homebrew/Cellar/test-pkg/1.0");

    // Verify symlink exists
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fs.readLinkAbsolute(test_prefix ++ "/opt/test-pkg", &buf);
    try std.testing.expectEqualStrings("/opt/homebrew/Cellar/test-pkg/1.0", target);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL

**Step 3: Implement Linker**

```zig
pub fn optLink(self: Linker, name: []const u8, keg_path: []const u8) !void {
    var opt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opt_path = try std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ self.prefix, name });

    // Remove existing symlink/file
    std.fs.deleteFileAbsolute(opt_path) catch {};

    // Create symlink
    try std.fs.symLinkAbsolute(keg_path, opt_path, .{});
}

pub fn link(self: Linker, name: []const u8, keg_path: []const u8) !void {
    // Create opt link
    try self.optLink(name, keg_path);

    // Link each standard directory
    const dirs = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc", "var" };
    for (dirs) |dir| {
        var keg_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const keg_dir = try std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ keg_path, dir });

        var prefix_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const prefix_dir = try std.fmt.bufPrint(&prefix_dir_buf, "{s}/{s}", .{ self.prefix, dir });

        // Check if keg has this directory
        var kd = std.fs.openDirAbsolute(keg_dir, .{ .iterate = true }) catch continue;
        defer kd.close();

        // Ensure prefix dir exists
        std.fs.makeDirAbsolute(prefix_dir) catch {};

        // Strategy depends on directory type
        const flat = std.mem.eql(u8, dir, "bin") or std.mem.eql(u8, dir, "sbin");

        try self.linkDir(keg_dir, prefix_dir, flat);
    }
}

fn linkDir(self: Linker, src: []const u8, dst: []const u8, flat: bool) !void {
    var dir = try std.fs.openDirAbsolute(src, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_path = try std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src, entry.name });

        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst_path = try std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dst, entry.name });

        if (entry.kind == .directory) {
            if (flat) continue; // Skip dirs for bin/sbin
            // Create real dir and recurse
            std.fs.makeDirAbsolute(dst_path) catch {};
            try self.linkDir(src_path, dst_path, false);
        } else {
            // Remove existing and create symlink
            std.fs.deleteFileAbsolute(dst_path) catch {};
            std.fs.symLinkAbsolute(src_path, dst_path, .{}) catch |err| {
                _ = err;
                continue; // Skip on error
            };
        }
    }
    _ = self;
}

pub fn unlink(self: Linker, keg_path: []const u8) !void {
    // Walk prefix dirs and remove symlinks pointing into keg_path
    const dirs = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc", "var" };
    for (dirs) |dir| {
        var prefix_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const prefix_dir = try std.fmt.bufPrint(&prefix_dir_buf, "{s}/{s}", .{ self.prefix, dir });
        self.unlinkDir(prefix_dir, keg_path) catch continue;
    }

    // Remove opt link
    // Extract name from keg_path: /opt/homebrew/Cellar/{name}/{version}
    // We need to find the name component
    var opt_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Find name by parsing keg_path
    if (std.mem.lastIndexOfScalar(u8, keg_path, '/')) |last_slash| {
        const parent = keg_path[0..last_slash];
        if (std.mem.lastIndexOfScalar(u8, parent, '/')) |name_slash| {
            const name = parent[name_slash + 1 ..];
            const opt_path = try std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ self.prefix, name });
            std.fs.deleteFileAbsolute(opt_path) catch {};
        }
    }
}

fn unlinkDir(self: Linker, dir_path: []const u8, keg_path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        var full_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ dir_path, entry.name });

        if (entry.kind == .sym_link) {
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = std.fs.readLinkAbsolute(full_path, &target_buf) catch continue;
            if (std.mem.startsWith(u8, target, keg_path)) {
                std.fs.deleteFileAbsolute(full_path) catch {};
            }
        } else if (entry.kind == .directory) {
            try self.unlinkDir(full_path, keg_path);
        }
    }
}
```

**Step 4: Run tests**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```bash
git add src/linker.zig src/main.zig
git commit -m "feat: keg linker with opt links and directory symlinking"
```

---

### Task 6: Tab Writer

**Files:**
- Modify: `src/tab.zig`

**Context:** After pouring a bottle, we need to write an INSTALL_RECEIPT.json that brew can read. The Tab struct from Task 10 reads tabs — now we add writing.

**Step 1: Add writeToKeg method to Tab**

```zig
pub fn writeToKeg(self: Tab, allocator: std.mem.Allocator, keg_path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const receipt_path = try std.fmt.bufPrint(&buf, "{s}/INSTALL_RECEIPT.json", .{keg_path});

    // Build JSON string
    var json_buf = std.ArrayList(u8).init(allocator);
    defer json_buf.deinit(allocator);

    const writer = json_buf.writer(allocator);

    // Write JSON manually for control over format
    try writer.writeAll("{\n");
    try writer.print("  \"homebrew_version\": \"{s}\",\n", .{self.homebrew_version});
    try writer.writeAll("  \"used_options\": [],\n");
    try writer.writeAll("  \"unused_options\": [],\n");
    try writer.writeAll("  \"built_as_bottle\": true,\n");
    try writer.print("  \"poured_from_bottle\": {s},\n", .{if (self.poured_from_bottle) "true" else "false"});
    try writer.print("  \"loaded_from_api\": {s},\n", .{if (self.loaded_from_api) "true" else "false"});
    try writer.writeAll("  \"installed_as_dependency\": false,\n");
    try writer.print("  \"installed_on_request\": {s},\n", .{if (self.installed_on_request) "true" else "false"});
    try writer.writeAll("  \"changed_files\": [],\n");
    if (self.time) |t| {
        try writer.print("  \"time\": {d},\n", .{t});
    } else {
        try writer.writeAll("  \"time\": null,\n");
    }
    try writer.print("  \"compiler\": \"{s}\",\n", .{self.compiler});
    try writer.writeAll("  \"aliases\": [],\n");
    try writer.writeAll("  \"runtime_dependencies\": [");

    for (self.runtime_dependencies, 0..) |dep, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {");
        try writer.print("\"full_name\": \"{s}\", ", .{dep.full_name});
        try writer.print("\"version\": \"{s}\", ", .{dep.version});
        try writer.print("\"revision\": {d}, ", .{dep.revision});
        try writer.print("\"pkg_version\": \"{s}\", ", .{dep.pkg_version});
        try writer.print("\"declared_directly\": {s}", .{if (dep.declared_directly) "true" else "false"});
        try writer.writeAll("}");
    }
    if (self.runtime_dependencies.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll("],\n");
    try writer.writeAll("  \"source\": {\"spec\": \"stable\"}\n");
    try writer.writeAll("}\n");

    // Write to file
    const file = try std.fs.createFileAbsolute(receipt_path, .{});
    defer file.close();
    try file.writeAll(json_buf.items);
}
```

**Step 2: Add test**

```zig
test "Tab writeToKeg round-trips" {
    const tmp_dir = "/tmp/bru_test_tab_write";
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    var tab = Tab{
        .installed_on_request = true,
        .poured_from_bottle = true,
        .loaded_from_api = true,
        .time = 1700000000,
        .runtime_dependencies = &.{},
        .compiler = "clang",
        .homebrew_version = "bru 0.1.0",
    };
    try tab.writeToKeg(std.testing.allocator, tmp_dir);

    // Read it back
    var tab2 = (try Tab.loadFromKeg(std.testing.allocator, tmp_dir)).?;
    defer tab2.deinit(std.testing.allocator);
    try std.testing.expect(tab2.poured_from_bottle);
    try std.testing.expect(tab2.installed_on_request);
    try std.testing.expectEqualStrings("clang", tab2.compiler);
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: PASS

**Step 4: Commit**

```bash
git add src/tab.zig
git commit -m "feat: tab writer creates brew-compatible INSTALL_RECEIPT.json"
```

---

## Phase 3: Install & Uninstall (Tasks 7–9)

### Task 7: `install` Command

**Files:**
- Create: `src/cmd/install.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew install <formula>` is the highest-value Tier 2 command. The pipeline:
1. Look up formula in index
2. Check if already installed (skip if so)
3. Resolve dependencies (for now: skip — install only the requested formula)
4. Download bottle via fetch
5. Extract into cellar via bottle.pour()
6. Replace placeholders
7. Write INSTALL_RECEIPT.json
8. Link keg into prefix
9. If formula has post_install, exec `brew postinstall <name>`

For the first pass, skip dependency resolution. If installing a formula that needs deps, the user can install them manually or fall back to `brew install`.

**Step 1: Create src/cmd/install.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const Download = @import("../download.zig").Download;
const Bottle = @import("../bottle.zig").Bottle;
const Linker = @import("../linker.zig").Linker;
const Tab = @import("../tab.zig").Tab;
const Output = @import("../output.zig").Output;
const fallback = @import("../fallback.zig");

pub fn installCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    if (args.len == 0) {
        const out = Output.initErr(config.no_color);
        try out.err("Usage: bru install <formula>", .{});
        std.process.exit(1);
    }

    const name = args[0];
    const out = Output.init(config.no_color);

    // Look up in index
    const index = try Index.loadOrBuild(allocator, config.cache);
    const entry = index.lookup(name) orelse {
        // Fall back to brew for unknown formulae
        try out.warn("Formula not found in index, falling back to brew.", .{});
        try fallback.execBrew(allocator, std.process.argsAlloc(allocator) catch unreachable);
    };

    // Check if already installed
    const cellar = Cellar.init(config.cellar);
    if (cellar.isInstalled(name)) {
        try out.warn("{s} is already installed.", .{name});
        return;
    }

    // Check for bottle availability
    const root_url = index.getString(entry.bottle_root_url_offset);
    const sha256 = index.getString(entry.bottle_sha256_offset);
    if (root_url.len == 0 or sha256.len == 0) {
        try out.warn("No bottle available, falling back to brew.", .{});
        // Reconstruct full argv and exec brew
        const argv = try std.process.argsAlloc(allocator);
        try fallback.execBrew(allocator, argv);
    }

    const version = index.getString(entry.version_offset);
    try out.section(try std.fmt.allocPrint(allocator, "Installing {s} {s}", .{ name, version }));

    // 1. Download bottle
    try out.print("Downloading...\n", .{});
    const image_name = try ghcrImageName(allocator, name);
    defer allocator.free(image_name);
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}/blobs/sha256:{s}", .{
        root_url, image_name, sha256,
    });
    defer allocator.free(url);

    const dl = Download.init(allocator, config.cache);
    const archive_path = try dl.fetchBottle(url, name, sha256);

    // 2. Extract
    try out.print("Pouring {s}...\n", .{name});
    var bottle = Bottle.init(allocator, config);
    const keg_path = try bottle.pour(archive_path);

    // 3. Replace placeholders
    try bottle.replacePlaceholders(keg_path);

    // 4. Write INSTALL_RECEIPT.json
    const now = std.time.timestamp();
    var tab = Tab{
        .installed_on_request = true,
        .poured_from_bottle = true,
        .loaded_from_api = true,
        .time = now,
        .runtime_dependencies = &.{}, // TODO: populate from index
        .compiler = "clang",
        .homebrew_version = "bru 0.1.0",
    };
    try tab.writeToKeg(allocator, keg_path);

    // 5. Link
    try out.print("Linking...\n", .{});
    var linker = Linker.init(allocator, config.prefix);
    const is_keg_only = (entry.flags & 1) != 0;
    if (is_keg_only) {
        try linker.optLink(name, keg_path);
        try out.print("{s} is keg-only. Not linking into {s}.\n", .{ name, config.prefix });
    } else {
        try linker.link(name, keg_path);
    }

    try out.section(try std.fmt.allocPrint(allocator, "{s} {s} installed", .{ name, version }));
}

fn ghcrImageName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = switch (c) {
            '@' => '/',
            '+' => 'x',
            else => c,
        };
    }
    return result;
}
```

**Step 2: Register in dispatch.zig**

```zig
const install = @import("cmd/install.zig");
.{ .name = "install", .handler = install.installCmd },
```

**Step 3: Test manually**

Run: `zig build run -- install jq` (if jq is not installed)
Expected: Downloads, extracts, links jq. Then `jq --version` should work.

If jq is already installed, try a small formula that isn't: `zig build run -- install figlet` or similar.

**Step 4: Commit**

```bash
git add src/cmd/install.zig src/dispatch.zig src/main.zig
git commit -m "feat: install command with bottle download, extraction, and linking"
```

---

### Task 8: `uninstall` Command

**Files:**
- Create: `src/cmd/uninstall.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew uninstall <formula>` unlinks the keg from the prefix, then deletes the keg directory. For safety, check if other installed formulae depend on it (warn but don't block with `--force`).

**Step 1: Create src/cmd/uninstall.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;

pub fn uninstallCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    if (args.len == 0) {
        const out = Output.initErr(config.no_color);
        try out.err("Usage: bru uninstall <formula>", .{});
        std.process.exit(1);
    }

    var force = false;
    var formula_name: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            formula_name = arg;
        }
    }

    const name = formula_name orelse {
        const out = Output.initErr(config.no_color);
        try out.err("Usage: bru uninstall <formula>", .{});
        std.process.exit(1);
    };

    const out = Output.init(config.no_color);
    const cellar = Cellar.init(config.cellar);

    const versions = try cellar.installedVersions(allocator, name) orelse {
        try out.err("{s} is not installed.", .{name});
        std.process.exit(1);
    };

    // TODO: Check if other formulae depend on this one (warn if so)
    _ = force;

    // Unlink and remove each version
    var linker = Linker.init(allocator, config.prefix);
    for (versions) |ver| {
        var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const keg_path = try std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, name, ver });

        try out.print("Uninstalling {s} {s}...\n", .{ name, ver });

        // Unlink from prefix
        linker.unlink(keg_path) catch |err| {
            try out.warn("Failed to unlink: {any}", .{err});
        };

        // Delete keg directory
        std.fs.deleteTreeAbsolute(keg_path) catch |err| {
            try out.err("Failed to delete {s}: {any}", .{ keg_path, err });
        };
    }

    // Remove formula directory if empty
    var formula_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const formula_dir = try std.fmt.bufPrint(&formula_dir_buf, "{s}/{s}", .{ config.cellar, name });
    std.fs.deleteDirAbsolute(formula_dir) catch {}; // Only succeeds if empty

    // Remove opt link
    var opt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const opt_path = try std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ config.prefix, name });
    std.fs.deleteFileAbsolute(opt_path) catch {};

    try out.section(try std.fmt.allocPrint(allocator, "{s} uninstalled", .{name}));
}
```

**Step 2: Register in dispatch.zig**

```zig
const uninstall = @import("cmd/uninstall.zig");
.{ .name = "uninstall", .handler = uninstall.uninstallCmd },
```

Note: The alias `rm` → `uninstall` is already defined in dispatch.zig from Tier 1.

**Step 3: Test manually**

Run: `zig build run -- install figlet && zig build run -- uninstall figlet`
Expected: Installs then cleanly uninstalls figlet

**Step 4: Commit**

```bash
git add src/cmd/uninstall.zig src/dispatch.zig src/main.zig
git commit -m "feat: uninstall command with unlinking and keg removal"
```

---

### Task 9: `link` and `unlink` Commands

**Files:**
- Create: `src/cmd/link.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew link <formula>` creates symlinks from keg into prefix. `brew unlink <formula>` removes them. Uses the Linker module from Task 5.

**Step 1: Create src/cmd/link.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;

pub fn linkCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    if (args.len == 0) {
        const out = Output.initErr(config.no_color);
        try out.err("Usage: bru link <formula>", .{});
        std.process.exit(1);
    }

    const name = args[0];
    const out = Output.init(config.no_color);
    const cellar = Cellar.init(config.cellar);

    const versions = try cellar.installedVersions(allocator, name) orelse {
        try out.err("{s} is not installed.", .{name});
        std.process.exit(1);
    };
    const latest = versions[versions.len - 1];

    var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const keg_path = try std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, name, latest });

    var linker = Linker.init(allocator, config.prefix);
    try linker.link(name, keg_path);
    try out.print("Linking {s} {s}...\n", .{ name, latest });
}

pub fn unlinkCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    if (args.len == 0) {
        const out = Output.initErr(config.no_color);
        try out.err("Usage: bru unlink <formula>", .{});
        std.process.exit(1);
    }

    const name = args[0];
    const out = Output.init(config.no_color);
    const cellar = Cellar.init(config.cellar);

    const versions = try cellar.installedVersions(allocator, name) orelse {
        try out.err("{s} is not installed.", .{name});
        std.process.exit(1);
    };
    const latest = versions[versions.len - 1];

    var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const keg_path = try std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ config.cellar, name, latest });

    var linker = Linker.init(allocator, config.prefix);
    try linker.unlink(keg_path);
    try out.print("Unlinking {s} {s}...\n", .{ name, latest });
}
```

**Step 2: Register in dispatch.zig**

```zig
const link_cmd = @import("cmd/link.zig");
.{ .name = "link", .handler = link_cmd.linkCmd },
.{ .name = "unlink", .handler = link_cmd.unlinkCmd },
```

**Step 3: Test manually**

Run: `zig build run -- unlink bat && zig build run -- link bat`
Expected: Unlinks then relinks bat's symlinks

**Step 4: Commit**

```bash
git add src/cmd/link.zig src/dispatch.zig src/main.zig
git commit -m "feat: link and unlink commands for keg symlink management"
```

---

## Phase 4: Upgrade, Cleanup, Update (Tasks 10–13)

### Task 10: `upgrade` Command

**Files:**
- Create: `src/cmd/upgrade.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew upgrade [formula]` upgrades outdated formulae. If no formula specified, upgrades all outdated. The flow: detect outdated → install new version → unlink old → link new → remove old keg.

For the first pass, keep it simple: upgrade one formula at a time, no dependency ordering.

**Step 1: Create src/cmd/upgrade.zig**

The command should:
1. If specific formula given, check if it's outdated. If not, say "already up to date".
2. If no formula, get all outdated formulae.
3. For each outdated formula: install new version (reuse install logic), then remove old version.
4. If install fails, fall back to brew.

Since we can't easily call installCmd internally (it calls process.exit), factor out the core install logic into a shared function, or just exec `bru install` as a subprocess. The simpler approach: duplicate the install pipeline inline.

Actually the cleanest approach: make a helper function in install.zig that returns errors instead of calling process.exit, and call it from both installCmd and upgradeCmd.

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const Linker = @import("../linker.zig").Linker;
const PkgVersion = @import("../version.zig").PkgVersion;
const Output = @import("../output.zig").Output;
const fallback = @import("../fallback.zig");

pub fn upgradeCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const out = Output.init(config.no_color);
    const index = try Index.loadOrBuild(allocator, config.cache);
    const cellar = Cellar.init(config.cellar);

    // Determine which formulae to upgrade
    var targets: []const []const u8 = undefined;
    var free_targets = false;

    if (args.len > 0 and !std.mem.startsWith(u8, args[0], "-")) {
        targets = args[0..1];
    } else {
        // Find all outdated
        // Reuse outdated detection logic
        const installed = try cellar.installedFormulae(allocator);
        var outdated_list = std.ArrayList([]const u8).init(allocator);
        for (installed) |f| {
            const entry = index.lookup(f.name) orelse continue;
            const latest_version = index.getString(entry.version_offset);
            const latest = PkgVersion{ .version = latest_version, .revision = @as(u32, entry.revision) };
            const current = PkgVersion.parse(f.latestVersion());
            if (current.order(latest) == .lt) {
                try outdated_list.append(allocator, f.name);
            }
        }
        targets = try outdated_list.toOwnedSlice(allocator);
        free_targets = true;
    }

    if (targets.len == 0) {
        try out.print("Already up-to-date.\n", .{});
        return;
    }

    for (targets) |name| {
        try out.section(try std.fmt.allocPrint(allocator, "Upgrading {s}", .{name}));

        // Fall back to brew for the actual upgrade (safest approach for now)
        // This ensures deps are handled correctly
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "brew", "upgrade", name },
        }) catch {
            try out.err("Failed to upgrade {s}", .{name});
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            try out.print("{s} upgraded successfully.\n", .{name});
        } else {
            try out.err("brew upgrade {s} failed", .{name});
        }
    }

    if (free_targets) allocator.free(targets);
}
```

Note: For the first pass, we delegate the actual upgrade to `brew upgrade` to ensure dependency safety. As bru matures, we can replace this with native install+unlink+link logic.

**Step 2: Register and test**

Register `"upgrade"` in dispatch.zig. Test with a formula that has an available upgrade (if any).

**Step 3: Commit**

```bash
git add src/cmd/upgrade.zig src/dispatch.zig src/main.zig
git commit -m "feat: upgrade command detects outdated and delegates to brew"
```

---

### Task 11: `cleanup` Command

**Files:**
- Create: `src/cmd/cleanup.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew cleanup` removes old versions from the cellar and stale downloads from the cache. Default retention: 120 days for cached downloads. For kegs, only keep the latest version.

**Step 1: Create src/cmd/cleanup.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Cellar = @import("../cellar.zig").Cellar;
const Output = @import("../output.zig").Output;

pub fn cleanupCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const out = Output.init(config.no_color);
    var dry_run = false;
    var prune_days: u32 = 120;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) dry_run = true;
        if (std.mem.startsWith(u8, arg, "--prune=")) {
            const val = arg["--prune=".len..];
            prune_days = std.fmt.parseInt(u32, val, 10) catch 120;
        }
    }

    // 1. Clean old versions from cellar
    try out.section("Cleaning old versions");
    const cellar = Cellar.init(config.cellar);
    const formulae = try cellar.installedFormulae(allocator);
    for (formulae) |f| {
        if (f.versions.len <= 1) continue;
        // Keep only the latest version, remove older ones
        for (f.versions[0 .. f.versions.len - 1]) |old_ver| {
            var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
            const keg_path = try std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{
                config.cellar, f.name, old_ver,
            });
            if (dry_run) {
                try out.print("Would remove: {s}\n", .{keg_path});
            } else {
                try out.print("Removing: {s}/{s}/{s}...\n", .{ config.cellar, f.name, old_ver });
                std.fs.deleteTreeAbsolute(keg_path) catch |err| {
                    try out.warn("Failed to remove {s}: {any}", .{ keg_path, err });
                };
            }
        }
    }

    // 2. Clean old downloads from cache
    try out.section("Cleaning cache");
    var downloads_buf: [std.fs.max_path_bytes]u8 = undefined;
    const downloads_dir = try std.fmt.bufPrint(&downloads_buf, "{s}/downloads", .{config.cache});

    var dir = std.fs.openDirAbsolute(downloads_dir, .{ .iterate = true }) catch {
        try out.print("No downloads directory.\n", .{});
        return;
    };
    defer dir.close();

    const now = std.time.timestamp();
    const max_age_secs: i128 = @as(i128, prune_days) * 86400;
    var cleaned: u32 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        // Check file age
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ downloads_dir, entry.name });
        const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;
        const age = @as(i128, now) - @as(i128, @divFloor(stat.mtime, std.time.ns_per_s));
        if (age > max_age_secs) {
            if (dry_run) {
                try out.print("Would remove: {s}\n", .{entry.name});
            } else {
                std.fs.deleteFileAbsolute(full_path) catch continue;
                cleaned += 1;
            }
        }
    }

    try out.print("Cleaned {d} old downloads.\n", .{cleaned});
}
```

**Step 2: Register and test**

Register `"cleanup"` in dispatch.zig. Test: `zig build run -- cleanup --dry-run`

**Step 3: Commit**

```bash
git add src/cmd/cleanup.zig src/dispatch.zig src/main.zig
git commit -m "feat: cleanup command removes old versions and stale cache"
```

---

### Task 12: `autoremove` Command

**Files:**
- Create: `src/cmd/autoremove.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew autoremove` uninstalls formulae that were installed as dependencies but are no longer needed. Algorithm: find formulae where installed_on_request=false AND not a dep of any installed formula.

**Step 1: Create src/cmd/autoremove.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const Index = @import("../index.zig").Index;
const Cellar = @import("../cellar.zig").Cellar;
const Tab = @import("../tab.zig").Tab;
const Linker = @import("../linker.zig").Linker;
const Output = @import("../output.zig").Output;

pub fn autoremoveCmd(allocator: std.mem.Allocator, args: []const []const u8, config: Config) !void {
    const out = Output.init(config.no_color);
    var dry_run = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) dry_run = true;
    }

    const index = try Index.loadOrBuild(allocator, config.cache);
    const cellar = Cellar.init(config.cellar);
    const installed = try cellar.installedFormulae(allocator);

    // Build set of all deps of installed formulae
    var dep_set = std.StringHashMap(void).init(allocator);
    defer dep_set.deinit();
    for (installed) |f| {
        const entry = index.lookup(f.name) orelse continue;
        const deps = index.getStringList(allocator, entry.deps_offset) catch continue;
        defer allocator.free(deps);
        for (deps) |d| {
            try dep_set.put(d, {});
        }
    }

    // Find orphans: installed_on_request=false AND not in dep_set
    var removed: u32 = 0;
    for (installed) |f| {
        if (dep_set.contains(f.name)) continue;

        var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const keg_path = try std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{
            config.cellar, f.name, f.latestVersion(),
        });
        var tab = (Tab.loadFromKeg(allocator, keg_path) catch continue) orelse continue;
        defer tab.deinit(allocator);

        if (tab.installed_on_request) continue; // User wanted this

        if (dry_run) {
            try out.print("Would remove: {s}\n", .{f.name});
        } else {
            try out.print("Removing {s}...\n", .{f.name});
            var linker = Linker.init(allocator, config.prefix);
            linker.unlink(keg_path) catch {};
            std.fs.deleteTreeAbsolute(keg_path) catch {};

            // Remove formula dir if empty
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ config.cellar, f.name });
            std.fs.deleteDirAbsolute(dir_path) catch {};
        }
        removed += 1;
    }

    if (removed == 0) {
        try out.print("No orphaned dependencies to remove.\n", .{});
    } else {
        try out.print("Removed {d} orphaned dependencies.\n", .{removed});
    }
}
```

**Step 2: Register and test**

Register `"autoremove"` in dispatch.zig. Test: `zig build run -- autoremove --dry-run`

**Step 3: Commit**

```bash
git add src/cmd/autoremove.zig src/dispatch.zig src/main.zig
git commit -m "feat: autoremove command uninstalls orphaned dependencies"
```

---

### Task 13: `update` Command

**Files:**
- Create: `src/cmd/update.zig`
- Modify: `src/dispatch.zig`

**Context:** `brew update` fetches fresh formula.jws.json from the API and rebuilds the index. URL: `https://formulae.brew.sh/api/formula.jws.json`

**Step 1: Create src/cmd/update.zig**

```zig
const std = @import("std");
const Config = @import("../config.zig").Config;
const HttpClient = @import("../http.zig").HttpClient;
const Index = @import("../index.zig").Index;
const Output = @import("../output.zig").Output;

pub fn updateCmd(allocator: std.mem.Allocator, _: []const []const u8, config: Config) !void {
    const out = Output.init(config.no_color);

    // 1. Download fresh formula.jws.json
    try out.section("Updating formulae");
    var json_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const json_path = try std.fmt.bufPrint(&json_path_buf, "{s}/api/formula.jws.json", .{config.cache});

    var client = HttpClient.init(allocator);
    try out.print("Fetching formula index...\n", .{});
    client.fetch("https://formulae.brew.sh/api/formula.jws.json", json_path) catch |err| {
        try out.err("Failed to download formula index: {any}", .{err});
        std.process.exit(1);
    };

    // 2. Delete old binary index to force rebuild
    var idx_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/api/formula.bru.idx", .{config.cache});
    std.fs.deleteFileAbsolute(idx_path) catch {};

    // 3. Rebuild index
    try out.print("Rebuilding index...\n", .{});
    _ = try Index.loadOrBuild(allocator, config.cache);

    try out.section("Updated successfully");
}
```

**Step 2: Register and test**

Register `"update"` in dispatch.zig. Test: `zig build run -- update`

**Step 3: Commit**

```bash
git add src/cmd/update.zig src/dispatch.zig src/main.zig
git commit -m "feat: update command fetches fresh API data and rebuilds index"
```

---

## Phase 5: Validation (Task 14)

### Task 14: Update Compat Test Script

**Files:**
- Modify: `test/compat/compare.sh`

**Context:** Add Tier 2 command comparisons to the existing compat script. For write commands, test in a safer way (e.g., fetch only, cleanup --dry-run).

**Step 1: Add new comparisons**

Add to compare.sh:
```bash
# Tier 2 - safe comparisons
compare_exact "fetch --help" fetch --help  # Just check it doesn't crash
# cleanup --dry-run comparison
# update is tested by running it

echo ""
echo "=== Tier 2 smoke tests ==="
echo ""

# Verify install/uninstall round-trip
echo -n "install/uninstall round-trip: "
if $BRU install figlet >/dev/null 2>&1 && figlet -v >/dev/null 2>&1 && $BRU uninstall figlet >/dev/null 2>&1; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    FAIL=$((FAIL + 1))
fi

echo -n "link/unlink round-trip: "
if $BRU unlink bat >/dev/null 2>&1 && $BRU link bat >/dev/null 2>&1 && bat --version >/dev/null 2>&1; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    FAIL=$((FAIL + 1))
fi
```

**Step 2: Run and verify**

Run: `bash test/compat/compare.sh`
Expected: New tests pass

**Step 3: Commit**

```bash
git add test/compat/compare.sh
git commit -m "feat: add Tier 2 smoke tests to compat script"
```

---

## Summary

| Phase | Tasks | What it delivers |
|-------|-------|-----------------|
| 1: Networking | 1–3 | HTTP client, download cache with SHA-256, fetch command |
| 2: Extraction & Linking | 4–6 | Bottle extraction (tar.gz), keg linker, tab writer |
| 3: Install & Uninstall | 7–9 | install, uninstall, link/unlink commands |
| 4: Lifecycle | 10–13 | upgrade, cleanup, autoremove, update commands |
| 5: Validation | 14 | Updated compat test script with Tier 2 smoke tests |

After this plan: bru handles install/uninstall/upgrade/link/unlink/cleanup/autoremove/update/fetch natively for bottle-based formulae, with exec fallback to brew for edge cases (source builds, complex deps).
