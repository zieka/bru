const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Parsed representation of a single Homebrew formula from the API JSON.
pub const FormulaInfo = struct {
    name: []const u8,
    full_name: []const u8,
    desc: []const u8,
    homepage: []const u8,
    license: []const u8,
    version: []const u8, // from versions.stable
    revision: u32,
    tap: []const u8,
    keg_only: bool,
    deprecated: bool,
    disabled: bool,
    dependencies: []const []const u8,
    build_dependencies: []const []const u8,
    oldnames: []const []const u8,
    deprecation_replacement: []const u8,
    has_head: bool,
    caveats: []const u8,
    bottle_root_url: []const u8,
    bottle_sha256: []const u8,
    bottle_cellar: []const u8,
};

/// Returns the Homebrew bottle platform tag for the current compilation target.
pub fn currentPlatformTag() []const u8 {
    const arch = @import("builtin").target.cpu.arch;
    const os = @import("builtin").target.os.tag;

    if (os == .macos) {
        if (arch == .aarch64) return "arm64_sequoia";
        if (arch == .x86_64) return "sequoia";
    }
    if (os == .linux) {
        if (arch == .aarch64) return "arm64_linux";
        if (arch == .x86_64) return "x86_64_linux";
    }
    return "unknown";
}

/// Parse a JSON array of formula objects into a slice of FormulaInfo.
/// The caller owns the returned slice and must free each entry with freeFormula.
pub fn parseFormulaJson(allocator: Allocator, json_bytes: []const u8) ![]FormulaInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.InvalidJson,
    };

    var result = try std.ArrayList(FormulaInfo).initCapacity(allocator, arr.items.len);
    errdefer {
        for (result.items) |f| {
            freeFormula(allocator, f);
        }
        result.deinit(allocator);
    }

    const platform = currentPlatformTag();

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const info = parseOneFormula(allocator, obj, platform) catch continue;
        result.appendAssumeCapacity(info);
    }

    return try result.toOwnedSlice(allocator);
}

/// Parse a single formula JSON object into a FormulaInfo.
fn parseOneFormula(allocator: Allocator, obj: std.json.ObjectMap, platform: []const u8) !FormulaInfo {
    const name = try allocator.dupe(u8, jsonStr(obj, "name") orelse return error.MissingField);
    errdefer allocator.free(name);

    const full_name = try allocator.dupe(u8, jsonStr(obj, "full_name") orelse "");
    errdefer allocator.free(full_name);

    const desc = try allocator.dupe(u8, jsonStr(obj, "desc") orelse "");
    errdefer allocator.free(desc);

    const homepage = try allocator.dupe(u8, jsonStr(obj, "homepage") orelse "");
    errdefer allocator.free(homepage);

    const license = try allocator.dupe(u8, jsonStr(obj, "license") orelse "");
    errdefer allocator.free(license);

    // versions.stable and versions.head
    var has_head = false;
    const version = blk: {
        const versions_val = obj.get("versions") orelse break :blk try allocator.dupe(u8, "");
        const versions_obj = switch (versions_val) {
            .object => |o| o,
            else => break :blk try allocator.dupe(u8, ""),
        };
        // HEAD is available if versions.head is a non-null string
        if (versions_obj.get("head")) |head_val| {
            has_head = switch (head_val) {
                .string => true,
                else => false,
            };
        }
        break :blk try allocator.dupe(u8, jsonStr(versions_obj, "stable") orelse "");
    };
    errdefer allocator.free(version);

    const revision: u32 = blk: {
        const rev_int = jsonInt(obj, "revision") orelse break :blk 0;
        break :blk if (rev_int >= 0) @intCast(rev_int) else 0;
    };

    const tap = try allocator.dupe(u8, jsonStr(obj, "tap") orelse "");
    errdefer allocator.free(tap);

    const keg_only = jsonBool(obj, "keg_only") orelse false;
    const deprecated = jsonBool(obj, "deprecated") orelse false;
    const disabled = jsonBool(obj, "disabled") orelse false;

    const caveats = try allocator.dupe(u8, jsonStr(obj, "caveats") orelse "");
    errdefer allocator.free(caveats);

    const dependencies = try parseStringArray(allocator, obj, "dependencies");
    errdefer freeStringSlice(allocator, dependencies);

    const build_dependencies = try parseStringArray(allocator, obj, "build_dependencies");
    errdefer freeStringSlice(allocator, build_dependencies);

    const oldnames = try parseStringArray(allocator, obj, "oldnames");
    errdefer freeStringSlice(allocator, oldnames);

    const deprecation_replacement = try allocator.dupe(u8, jsonStr(obj, "deprecation_replacement_formula") orelse "");
    errdefer allocator.free(deprecation_replacement);

    // Bottle info: bottle.stable.root_url, bottle.stable.files.{platform}.sha256, .cellar
    var bottle_root_url: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(bottle_root_url);
    var bottle_sha256: []const u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(bottle_sha256);
    var bottle_cellar: []const u8 = try allocator.dupe(u8, "");
    // No errdefer needed for the last allocation before the return.

    if (obj.get("bottle")) |bottle_val| {
        if (asObject(bottle_val)) |bottle_obj| {
            if (bottle_obj.get("stable")) |stable_val| {
                if (asObject(stable_val)) |stable_obj| {
                    // root_url
                    if (jsonStr(stable_obj, "root_url")) |url| {
                        allocator.free(bottle_root_url);
                        bottle_root_url = try allocator.dupe(u8, url);
                    }

                    // files.{platform}
                    if (stable_obj.get("files")) |files_val| {
                        if (asObject(files_val)) |files_obj| {
                            if (files_obj.get(platform)) |plat_val| {
                                if (asObject(plat_val)) |plat_obj| {
                                    if (jsonStr(plat_obj, "sha256")) |sha| {
                                        allocator.free(bottle_sha256);
                                        bottle_sha256 = try allocator.dupe(u8, sha);
                                    }
                                    if (jsonStr(plat_obj, "cellar")) |cel| {
                                        allocator.free(bottle_cellar);
                                        bottle_cellar = try allocator.dupe(u8, cel);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return FormulaInfo{
        .name = name,
        .full_name = full_name,
        .desc = desc,
        .homepage = homepage,
        .license = license,
        .version = version,
        .revision = revision,
        .tap = tap,
        .keg_only = keg_only,
        .deprecated = deprecated,
        .disabled = disabled,
        .has_head = has_head,
        .caveats = caveats,
        .dependencies = dependencies,
        .build_dependencies = build_dependencies,
        .oldnames = oldnames,
        .deprecation_replacement = deprecation_replacement,
        .bottle_root_url = bottle_root_url,
        .bottle_sha256 = bottle_sha256,
        .bottle_cellar = bottle_cellar,
    };
}

/// Free all owned memory in a FormulaInfo.
pub fn freeFormula(allocator: Allocator, f: FormulaInfo) void {
    allocator.free(f.name);
    allocator.free(f.full_name);
    allocator.free(f.desc);
    allocator.free(f.homepage);
    allocator.free(f.license);
    allocator.free(f.version);
    allocator.free(f.tap);
    allocator.free(f.caveats);
    freeStringSlice(allocator, f.dependencies);
    freeStringSlice(allocator, f.build_dependencies);
    freeStringSlice(allocator, f.oldnames);
    allocator.free(f.deprecation_replacement);
    allocator.free(f.bottle_root_url);
    allocator.free(f.bottle_sha256);
    allocator.free(f.bottle_cellar);
}

// ---------------------------------------------------------------------------
// JSON helpers (same pattern as tab.zig)
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

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

fn asObject(val: std.json.Value) ?std.json.ObjectMap {
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

/// Parse a JSON array of strings into an owned slice.
fn parseStringArray(allocator: Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const arr_val = obj.get(key) orelse return try allocator.alloc([]const u8, 0);
    const arr = switch (arr_val) {
        .array => |a| a,
        else => return try allocator.alloc([]const u8, 0),
    };

    var result = try std.ArrayList([]const u8).initCapacity(allocator, arr.items.len);
    errdefer {
        for (result.items) |s| allocator.free(s);
        result.deinit(allocator);
    }

    for (arr.items) |item| {
        const s = switch (item) {
            .string => |s| s,
            else => continue,
        };
        result.appendAssumeCapacity(try allocator.dupe(u8, s));
    }

    return try result.toOwnedSlice(allocator);
}

/// Free a slice of owned strings.
fn freeStringSlice(allocator: Allocator, slice: []const []const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseFormulaJson parses small payload" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\[{
        \\  "name": "bat",
        \\  "full_name": "bat",
        \\  "tap": "homebrew/core",
        \\  "desc": "Clone of cat(1) with syntax highlighting and Git integration",
        \\  "homepage": "https://github.com/sharkdp/bat",
        \\  "license": "Apache-2.0 OR MIT",
        \\  "versions": {"stable": "0.26.1", "head": "HEAD", "bottle": true},
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "deprecated": false,
        \\  "disabled": false,
        \\  "caveats": null,
        \\  "dependencies": ["libgit2", "oniguruma"],
        \\  "build_dependencies": ["pkgconf", "rust"],
        \\  "oldnames": [],
        \\  "deprecation_replacement_formula": null,
        \\  "bottle": {
        \\    "stable": {
        \\      "root_url": "https://ghcr.io/v2/homebrew/core",
        \\      "files": {
        \\        "arm64_sequoia": {
        \\          "cellar": ":any",
        \\          "sha256": "072537d409b056879cb735bcbc0454562b8bae732fbbfac9242afea736410f88"
        \\        }
        \\      }
        \\    }
        \\  }
        \\}]
    ;

    const formulae = try parseFormulaJson(allocator, json_bytes);
    defer {
        for (formulae) |f| freeFormula(allocator, f);
        allocator.free(formulae);
    }

    try std.testing.expectEqual(@as(usize, 1), formulae.len);

    const bat = formulae[0];
    try std.testing.expectEqualStrings("bat", bat.name);
    try std.testing.expectEqualStrings("bat", bat.full_name);
    try std.testing.expectEqualStrings("homebrew/core", bat.tap);
    try std.testing.expectEqualStrings("Clone of cat(1) with syntax highlighting and Git integration", bat.desc);
    try std.testing.expectEqualStrings("https://github.com/sharkdp/bat", bat.homepage);
    try std.testing.expectEqualStrings("Apache-2.0 OR MIT", bat.license);
    try std.testing.expectEqualStrings("0.26.1", bat.version);
    try std.testing.expectEqual(@as(u32, 0), bat.revision);
    try std.testing.expect(!bat.keg_only);
    try std.testing.expect(!bat.deprecated);
    try std.testing.expect(!bat.disabled);
    try std.testing.expect(bat.has_head);
    try std.testing.expectEqualStrings("", bat.caveats);

    // Dependencies
    try std.testing.expectEqual(@as(usize, 2), bat.dependencies.len);
    try std.testing.expectEqualStrings("libgit2", bat.dependencies[0]);
    try std.testing.expectEqualStrings("oniguruma", bat.dependencies[1]);

    // Build dependencies
    try std.testing.expectEqual(@as(usize, 2), bat.build_dependencies.len);
    try std.testing.expectEqualStrings("pkgconf", bat.build_dependencies[0]);
    try std.testing.expectEqualStrings("rust", bat.build_dependencies[1]);

    // Oldnames and deprecation replacement
    try std.testing.expectEqual(@as(usize, 0), bat.oldnames.len);
    try std.testing.expectEqualStrings("", bat.deprecation_replacement);

    // Bottle info
    try std.testing.expectEqualStrings("https://ghcr.io/v2/homebrew/core", bat.bottle_root_url);
    try std.testing.expectEqualStrings("072537d409b056879cb735bcbc0454562b8bae732fbbfac9242afea736410f88", bat.bottle_sha256);
    try std.testing.expectEqualStrings(":any", bat.bottle_cellar);
}

test "parseFormulaJson loads real JWS payload" {
    const allocator = std.testing.allocator;

    // Read the JWS file from the Homebrew cache.
    const jws_path = blk: {
        const home = std.posix.getenv("HOME") orelse return;
        var buf: [512]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, "{s}/Library/Caches/Homebrew/api/formula.jws.json", .{home}) catch return;
    };

    const file = std.fs.openFileAbsolute(jws_path, .{}) catch return; // skip if not present
    defer file.close();

    const jws_bytes = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch return;
    defer allocator.free(jws_bytes);

    // Step 1: Parse the outer JWS envelope to get the payload string.
    const jws_parsed = std.json.parseFromSlice(std.json.Value, allocator, jws_bytes, .{
        .allocate = .alloc_always,
    }) catch return;
    defer jws_parsed.deinit();

    const jws_root = switch (jws_parsed.value) {
        .object => |o| o,
        else => return,
    };

    const payload_str = jsonStr(jws_root, "payload") orelse return;

    // Step 2: Parse the payload string as a JSON array of formulae.
    const formulae = try parseFormulaJson(allocator, payload_str);
    defer {
        for (formulae) |f| freeFormula(allocator, f);
        allocator.free(formulae);
    }

    // Should have >5000 formulae.
    try std.testing.expect(formulae.len > 5000);

    // Find "bat" and verify its fields.
    var bat_found = false;
    for (formulae) |f| {
        if (mem.eql(u8, f.name, "bat")) {
            bat_found = true;
            try std.testing.expectEqualStrings("bat", f.full_name);
            try std.testing.expectEqualStrings("homebrew/core", f.tap);
            try std.testing.expect(f.version.len > 0);
            try std.testing.expect(f.desc.len > 0);
            try std.testing.expect(f.homepage.len > 0);
            try std.testing.expect(f.bottle_root_url.len > 0);
            try std.testing.expect(f.bottle_sha256.len > 0);
            try std.testing.expect(f.dependencies.len > 0);
            break;
        }
    }
    try std.testing.expect(bat_found);
}

test "parseFormulaJson parses oldnames and replacement" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\[{
        \\  "name": "adwaita-icon-theme",
        \\  "full_name": "adwaita-icon-theme",
        \\  "tap": "homebrew/core",
        \\  "desc": "Icons for GNOME",
        \\  "homepage": "https://gnome.org",
        \\  "license": "LGPL-3.0",
        \\  "versions": {"stable": "46.0", "head": null},
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "deprecated": false,
        \\  "disabled": false,
        \\  "caveats": null,
        \\  "dependencies": [],
        \\  "build_dependencies": [],
        \\  "oldnames": ["gnome-icon-theme"],
        \\  "deprecation_replacement_formula": null,
        \\  "bottle": {}
        \\}]
    ;

    const formulae = try parseFormulaJson(allocator, json_bytes);
    defer {
        for (formulae) |f| freeFormula(allocator, f);
        allocator.free(formulae);
    }

    try std.testing.expectEqual(@as(usize, 1), formulae.len);
    try std.testing.expectEqual(@as(usize, 1), formulae[0].oldnames.len);
    try std.testing.expectEqualStrings("gnome-icon-theme", formulae[0].oldnames[0]);
    try std.testing.expectEqualStrings("", formulae[0].deprecation_replacement);
}
