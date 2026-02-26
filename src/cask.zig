const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

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
