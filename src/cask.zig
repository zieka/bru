const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const HttpClient = @import("http.zig").HttpClient;

/// Parsed representation of a single Homebrew cask from the API JSON.
pub const CaskInfo = struct {
    token: []const u8, // e.g., "firefox"
    full_token: []const u8, // e.g., "firefox" or "homebrew/cask/firefox"
    name: []const u8, // display name, e.g., "Mozilla Firefox" -- first element of the "name" array
    desc: []const u8,
    homepage: []const u8,
    version: []const u8,
    url: []const u8, // download URL
    sha256: []const u8,
    deprecated: bool,
    disabled: bool,
};

/// Parse a JSON array of cask objects into a slice of CaskInfo.
/// The caller owns the returned slice and must free each entry with freeCask.
pub fn parseCaskJson(allocator: Allocator, json_bytes: []const u8) ![]CaskInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.InvalidJson,
    };

    var result = try std.ArrayList(CaskInfo).initCapacity(allocator, arr.items.len);
    errdefer {
        for (result.items) |c| {
            freeCask(allocator, c);
        }
        result.deinit(allocator);
    }

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const info = parseOneCask(allocator, obj) catch continue;
        result.appendAssumeCapacity(info);
    }

    return try result.toOwnedSlice(allocator);
}

/// Parse a single cask JSON object into a CaskInfo.
fn parseOneCask(allocator: Allocator, obj: std.json.ObjectMap) !CaskInfo {
    const token = try allocator.dupe(u8, jsonStr(obj, "token") orelse return error.MissingField);
    errdefer allocator.free(token);

    const full_token = try allocator.dupe(u8, jsonStr(obj, "full_token") orelse "");
    errdefer allocator.free(full_token);

    // name is a JSON array -- take the first element
    const name = blk: {
        const name_val = obj.get("name") orelse break :blk try allocator.dupe(u8, "");
        const name_arr = switch (name_val) {
            .array => |a| a,
            else => break :blk try allocator.dupe(u8, ""),
        };
        if (name_arr.items.len == 0) break :blk try allocator.dupe(u8, "");
        const first = switch (name_arr.items[0]) {
            .string => |s| s,
            else => break :blk try allocator.dupe(u8, ""),
        };
        break :blk try allocator.dupe(u8, first);
    };
    errdefer allocator.free(name);

    const desc = try allocator.dupe(u8, jsonStr(obj, "desc") orelse "");
    errdefer allocator.free(desc);

    const homepage = try allocator.dupe(u8, jsonStr(obj, "homepage") orelse "");
    errdefer allocator.free(homepage);

    const version = try allocator.dupe(u8, jsonStr(obj, "version") orelse "");
    errdefer allocator.free(version);

    const url = try allocator.dupe(u8, jsonStr(obj, "url") orelse "");
    errdefer allocator.free(url);

    const sha256 = try allocator.dupe(u8, jsonStr(obj, "sha256") orelse "");
    // No errdefer needed for the last allocation before the return.

    const deprecated = jsonBool(obj, "deprecated") orelse false;
    const disabled = jsonBool(obj, "disabled") orelse false;

    return CaskInfo{
        .token = token,
        .full_token = full_token,
        .name = name,
        .desc = desc,
        .homepage = homepage,
        .version = version,
        .url = url,
        .sha256 = sha256,
        .deprecated = deprecated,
        .disabled = disabled,
    };
}

/// Free all owned memory in a CaskInfo.
pub fn freeCask(allocator: Allocator, c: CaskInfo) void {
    allocator.free(c.token);
    allocator.free(c.full_token);
    allocator.free(c.name);
    allocator.free(c.desc);
    allocator.free(c.homepage);
    allocator.free(c.version);
    allocator.free(c.url);
    allocator.free(c.sha256);
}

// ---------------------------------------------------------------------------
// JSON helpers (same pattern as formula.zig)
// ---------------------------------------------------------------------------

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Per-cask API types and parsing (for cask install)
// ---------------------------------------------------------------------------

/// A binary artifact extracted from a cask's artifacts array.
pub const BinaryArtifact = struct {
    source: []const u8, // path inside the archive, e.g., "firefox.wrapper.sh"
    target: []const u8, // symlink name for bin/, e.g., "firefox"
};

/// Resolved metadata for installing a single cask, fetched from per-cask API.
pub const ResolvedCask = struct {
    token: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    name: []const u8,
    binaries: []BinaryArtifact,
};

/// Platform tags to try when resolving cask variations, in priority order.
/// Tries the most specific first (arch + OS version), then falls back to
/// less specific tags. The first match wins.
fn platformVariationTags() []const []const u8 {
    const arch = @import("builtin").target.cpu.arch;

    if (arch == .aarch64) {
        return &.{
            "arm64_tahoe",
            "arm64_sequoia",
            "arm64_sonoma",
            "arm64_ventura",
            "arm64_monterey",
            "arm64_big_sur",
        };
    }
    return &.{
        "tahoe",
        "sequoia",
        "sonoma",
        "ventura",
        "monterey",
        "big_sur",
    };
}

/// Fetch and resolve a cask from the per-cask API.
/// Returns a ResolvedCask with platform-resolved URL/SHA256 and binary artifacts.
/// All strings in the result are owned by the provided allocator.
pub fn fetchAndResolveCask(allocator: Allocator, http_client: *HttpClient, token: []const u8) !ResolvedCask {
    // Build API URL: https://formulae.brew.sh/api/cask/{token}.json
    const api_url = try std.fmt.allocPrint(allocator, "https://formulae.brew.sh/api/cask/{s}.json", .{token});
    defer allocator.free(api_url);

    // Fetch JSON into memory.
    const json_bytes = try http_client.fetchToMemory(allocator, api_url);
    defer allocator.free(json_bytes);

    return try parseResolvedCask(allocator, json_bytes);
}

/// Parse a per-cask API JSON response into a ResolvedCask.
pub fn parseResolvedCask(allocator: Allocator, json_bytes: []const u8) !ResolvedCask {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };

    const result_token = try allocator.dupe(u8, jsonStr(obj, "token") orelse return error.MissingField);
    errdefer allocator.free(result_token);

    // Start with top-level url/sha256/version, then override from variations.
    var url = try allocator.dupe(u8, jsonStr(obj, "url") orelse "");
    errdefer allocator.free(url);

    var sha256 = try allocator.dupe(u8, jsonStr(obj, "sha256") orelse "");
    errdefer allocator.free(sha256);

    var version = try allocator.dupe(u8, jsonStr(obj, "version") orelse "");
    errdefer allocator.free(version);

    // Check variations for platform-specific overrides.
    // Allocate new values before freeing old ones to avoid double-free on OOM.
    if (obj.get("variations")) |var_val| {
        if (asObject(var_val)) |variations| {
            const tags = platformVariationTags();
            for (tags) |tag| {
                if (variations.get(tag)) |tag_val| {
                    if (asObject(tag_val)) |tag_obj| {
                        if (jsonStr(tag_obj, "url")) |v_url| {
                            const new_url = try allocator.dupe(u8, v_url);
                            allocator.free(url);
                            url = new_url;
                        }
                        if (jsonStr(tag_obj, "sha256")) |v_sha| {
                            const new_sha = try allocator.dupe(u8, v_sha);
                            allocator.free(sha256);
                            sha256 = new_sha;
                        }
                        if (jsonStr(tag_obj, "version")) |v_ver| {
                            const new_ver = try allocator.dupe(u8, v_ver);
                            allocator.free(version);
                            version = new_ver;
                        }
                        break;
                    }
                }
            }
        }
    }

    // Parse name (first element of name array).
    const result_name = blk: {
        const name_val = obj.get("name") orelse break :blk try allocator.dupe(u8, "");
        const name_arr = switch (name_val) {
            .array => |a| a,
            else => break :blk try allocator.dupe(u8, ""),
        };
        if (name_arr.items.len == 0) break :blk try allocator.dupe(u8, "");
        const first = switch (name_arr.items[0]) {
            .string => |s| s,
            else => break :blk try allocator.dupe(u8, ""),
        };
        break :blk try allocator.dupe(u8, first);
    };
    errdefer allocator.free(result_name);

    // Parse binary artifacts from the artifacts array.
    const binaries = try parseBinaryArtifacts(allocator, obj);

    return ResolvedCask{
        .token = result_token,
        .version = version,
        .url = url,
        .sha256 = sha256,
        .name = result_name,
        .binaries = binaries,
    };
}

/// Parse binary artifacts from a cask's artifacts array.
/// Binary artifacts come in two forms:
///   - ["path/to/binary"]              -> source=path, target=basename
///   - ["path/to/binary", {target: "name"}] -> source=path, target=name
fn parseBinaryArtifacts(allocator: Allocator, obj: std.json.ObjectMap) ![]BinaryArtifact {
    const artifacts_val = obj.get("artifacts") orelse return try allocator.alloc(BinaryArtifact, 0);
    const artifacts_arr = switch (artifacts_val) {
        .array => |a| a,
        else => return try allocator.alloc(BinaryArtifact, 0),
    };

    var result = std.ArrayList(BinaryArtifact){};
    errdefer {
        for (result.items) |b| {
            allocator.free(b.source);
            allocator.free(b.target);
        }
        result.deinit(allocator);
    }

    for (artifacts_arr.items) |artifact_val| {
        const artifact_obj = switch (artifact_val) {
            .object => |o| o,
            else => continue,
        };

        // Look for "binary" key.
        const binary_val = artifact_obj.get("binary") orelse continue;
        const binary_arr = switch (binary_val) {
            .array => |a| a,
            else => continue,
        };

        if (binary_arr.items.len == 0) continue;

        // First element is the source path (string).
        const source_raw = switch (binary_arr.items[0]) {
            .string => |s| s,
            else => continue,
        };

        // Strip $HOMEBREW_PREFIX/Caskroom/... prefix and $APPDIR/ prefix from source.
        const source_clean = cleanArtifactPath(source_raw);

        const source = try allocator.dupe(u8, source_clean);
        errdefer allocator.free(source);

        // Second element (if present and an object) has {target: "name"}.
        const target = blk: {
            if (binary_arr.items.len > 1) {
                if (asObject(binary_arr.items[1])) |target_obj| {
                    if (jsonStr(target_obj, "target")) |t| {
                        break :blk try allocator.dupe(u8, t);
                    }
                }
            }
            // Default target: basename of source.
            break :blk try allocator.dupe(u8, std.fs.path.basename(source_clean));
        };

        try result.append(allocator, .{ .source = source, .target = target });
    }

    return try result.toOwnedSlice(allocator);
}

/// Strip known prefixes from cask binary artifact paths.
/// Removes "$HOMEBREW_PREFIX/Caskroom/{token}/{version}/" and "$APPDIR/" prefixes.
fn cleanArtifactPath(path: []const u8) []const u8 {
    // Strip $APPDIR/ prefix.
    if (mem.startsWith(u8, path, "$APPDIR/")) {
        return path["$APPDIR/".len..];
    }
    // Strip $HOMEBREW_PREFIX/Caskroom/... prefix.
    if (mem.startsWith(u8, path, "$HOMEBREW_PREFIX/Caskroom/")) {
        // Find the third / after "Caskroom/" to skip {token}/{version}/
        const after_caskroom = path["$HOMEBREW_PREFIX/Caskroom/".len..];
        if (mem.indexOfScalar(u8, after_caskroom, '/')) |slash1| {
            const after_token = after_caskroom[slash1 + 1 ..];
            if (mem.indexOfScalar(u8, after_token, '/')) |slash2| {
                return after_token[slash2 + 1 ..];
            }
        }
    }
    return path;
}

fn asObject(val: std.json.Value) ?std.json.ObjectMap {
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

/// Free a ResolvedCask and all its owned memory.
pub fn freeResolvedCask(allocator: Allocator, c: ResolvedCask) void {
    allocator.free(c.token);
    allocator.free(c.version);
    allocator.free(c.url);
    allocator.free(c.sha256);
    allocator.free(c.name);
    for (c.binaries) |b| {
        allocator.free(b.source);
        allocator.free(b.target);
    }
    allocator.free(c.binaries);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseCaskJson parses small payload" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\[{
        \\  "token": "firefox",
        \\  "full_token": "firefox",
        \\  "old_tokens": [],
        \\  "tap": "homebrew/cask",
        \\  "name": ["Mozilla Firefox"],
        \\  "desc": "Web browser",
        \\  "homepage": "https://www.mozilla.org/firefox/",
        \\  "url": "https://download-installer.cdn.mozilla.net/pub/firefox/releases/136.0.4/mac/en-US/Firefox%20136.0.4.dmg",
        \\  "url_specs": {},
        \\  "version": "136.0.4",
        \\  "sha256": "abc123def456",
        \\  "deprecated": false,
        \\  "disabled": false
        \\}]
    ;

    const casks = try parseCaskJson(allocator, json_bytes);
    defer {
        for (casks) |c| freeCask(allocator, c);
        allocator.free(casks);
    }

    try std.testing.expectEqual(@as(usize, 1), casks.len);

    const firefox = casks[0];
    try std.testing.expectEqualStrings("firefox", firefox.token);
    try std.testing.expectEqualStrings("firefox", firefox.full_token);
    try std.testing.expectEqualStrings("Mozilla Firefox", firefox.name);
    try std.testing.expectEqualStrings("Web browser", firefox.desc);
    try std.testing.expectEqualStrings("https://www.mozilla.org/firefox/", firefox.homepage);
    try std.testing.expectEqualStrings("136.0.4", firefox.version);
    try std.testing.expectEqualStrings("https://download-installer.cdn.mozilla.net/pub/firefox/releases/136.0.4/mac/en-US/Firefox%20136.0.4.dmg", firefox.url);
    try std.testing.expectEqualStrings("abc123def456", firefox.sha256);
    try std.testing.expect(!firefox.deprecated);
    try std.testing.expect(!firefox.disabled);
}

test "parseCaskJson handles name array with multiple elements" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\[{
        \\  "token": "visual-studio-code",
        \\  "full_token": "visual-studio-code",
        \\  "name": ["Microsoft Visual Studio Code", "VS Code"],
        \\  "desc": "Open-source code editor",
        \\  "homepage": "https://code.visualstudio.com/",
        \\  "url": "https://example.com/vscode.zip",
        \\  "version": "1.85.0",
        \\  "sha256": "deadbeef",
        \\  "deprecated": false,
        \\  "disabled": false
        \\}]
    ;

    const casks = try parseCaskJson(allocator, json_bytes);
    defer {
        for (casks) |c| freeCask(allocator, c);
        allocator.free(casks);
    }

    try std.testing.expectEqual(@as(usize, 1), casks.len);
    // Should take the first element of the name array
    try std.testing.expectEqualStrings("Microsoft Visual Studio Code", casks[0].name);
}

test "parseResolvedCask parses per-cask API response" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\{
        \\  "token": "firefox",
        \\  "full_token": "firefox",
        \\  "name": ["Mozilla Firefox"],
        \\  "desc": "Web browser",
        \\  "homepage": "https://www.mozilla.org/firefox/",
        \\  "url": "https://example.com/firefox.dmg",
        \\  "version": "136.0.4",
        \\  "sha256": "abc123def456abc123def456abc123def456abc123def456abc123def456abcd",
        \\  "variations": {},
        \\  "artifacts": [
        \\    {"app": ["Firefox.app"]},
        \\    {"binary": ["$HOMEBREW_PREFIX/Caskroom/firefox/136.0.4/firefox.wrapper.sh", {"target": "firefox"}]},
        \\    {"zap": [{"trash": ["~/Library/Firefox"]}]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCask(allocator, json_bytes);
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqualStrings("firefox", resolved.token);
    try std.testing.expectEqualStrings("136.0.4", resolved.version);
    try std.testing.expectEqualStrings("https://example.com/firefox.dmg", resolved.url);
    try std.testing.expectEqualStrings("abc123def456abc123def456abc123def456abc123def456abc123def456abcd", resolved.sha256);
    try std.testing.expectEqualStrings("Mozilla Firefox", resolved.name);

    try std.testing.expectEqual(@as(usize, 1), resolved.binaries.len);
    try std.testing.expectEqualStrings("firefox.wrapper.sh", resolved.binaries[0].source);
    try std.testing.expectEqualStrings("firefox", resolved.binaries[0].target);
}

test "parseResolvedCask with APPDIR binary path" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\{
        \\  "token": "visual-studio-code",
        \\  "name": ["VS Code"],
        \\  "url": "https://example.com/vscode.zip",
        \\  "version": "1.85.0",
        \\  "sha256": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        \\  "variations": {},
        \\  "artifacts": [
        \\    {"app": ["Visual Studio Code.app"]},
        \\    {"binary": ["$APPDIR/Visual Studio Code.app/Contents/Resources/app/bin/code"]},
        \\    {"binary": ["$APPDIR/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCask(allocator, json_bytes);
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 2), resolved.binaries.len);
    try std.testing.expectEqualStrings("Visual Studio Code.app/Contents/Resources/app/bin/code", resolved.binaries[0].source);
    try std.testing.expectEqualStrings("code", resolved.binaries[0].target);
    try std.testing.expectEqualStrings("Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel", resolved.binaries[1].source);
    try std.testing.expectEqualStrings("code-tunnel", resolved.binaries[1].target);
}

test "parseResolvedCask with no binary artifacts" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\{
        \\  "token": "google-chrome",
        \\  "name": ["Google Chrome"],
        \\  "url": "https://example.com/chrome.dmg",
        \\  "version": "120.0",
        \\  "sha256": "no_check",
        \\  "variations": {},
        \\  "artifacts": [
        \\    {"app": ["Google Chrome.app"]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCask(allocator, json_bytes);
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 0), resolved.binaries.len);
}

test "cleanArtifactPath strips APPDIR prefix" {
    try std.testing.expectEqualStrings(
        "Visual Studio Code.app/Contents/Resources/app/bin/code",
        cleanArtifactPath("$APPDIR/Visual Studio Code.app/Contents/Resources/app/bin/code"),
    );
}

test "cleanArtifactPath strips HOMEBREW_PREFIX/Caskroom prefix" {
    try std.testing.expectEqualStrings(
        "firefox.wrapper.sh",
        cleanArtifactPath("$HOMEBREW_PREFIX/Caskroom/firefox/136.0.4/firefox.wrapper.sh"),
    );
}

test "cleanArtifactPath preserves plain paths" {
    try std.testing.expectEqualStrings("studio", cleanArtifactPath("studio"));
}
