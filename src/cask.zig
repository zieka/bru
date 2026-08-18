const std = @import("std");
const builtin = @import("builtin");
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
/// Uses the current machine's macOS for variation resolution.
pub fn parseCaskJson(allocator: Allocator, json_bytes: []const u8) ![]CaskInfo {
    var tag_buf: [64]u8 = undefined;
    const tag = currentMacOSVariationTag(&tag_buf);
    return parseCaskJsonWithTag(allocator, json_bytes, tag);
}

/// Same as parseCaskJson but with the variation tag passed explicitly.
/// Useful for tests and for callers that want to resolve for a non-current OS.
pub fn parseCaskJsonWithTag(allocator: Allocator, json_bytes: []const u8, variation_tag: []const u8) ![]CaskInfo {
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

        const info = parseOneCask(allocator, obj, variation_tag) catch continue;
        result.appendAssumeCapacity(info);
    }

    return try result.toOwnedSlice(allocator);
}

/// Parse a single cask JSON object's bytes into a CaskInfo, applying the given
/// variation tag. Public so tests can drive parseOneCask directly.
pub fn parseSingleCaskJson(allocator: Allocator, json_bytes: []const u8, variation_tag: []const u8) !CaskInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };
    return parseOneCask(allocator, obj, variation_tag);
}

/// Parse a single cask JSON object into a CaskInfo. Applies the platform
/// variation override iff `variation_tag` is present in `variations`.
fn parseOneCask(allocator: Allocator, obj: std.json.ObjectMap, variation_tag: []const u8) !CaskInfo {
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

    // Start from top-level, then override with the current-OS variation iff present.
    var version_src: []const u8 = jsonStr(obj, "version") orelse "";
    var url_src: []const u8 = jsonStr(obj, "url") orelse "";
    var sha256_src: []const u8 = jsonStr(obj, "sha256") orelse "";
    if (variationOverrideObject(obj, variation_tag)) |tag_obj| {
        if (jsonStr(tag_obj, "version")) |v| version_src = v;
        if (jsonStr(tag_obj, "url")) |u| url_src = u;
        if (jsonStr(tag_obj, "sha256")) |s| sha256_src = s;
    }

    const version = try allocator.dupe(u8, version_src);
    errdefer allocator.free(version);

    const url = try allocator.dupe(u8, url_src);
    errdefer allocator.free(url);

    const sha256 = try allocator.dupe(u8, sha256_src);
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

/// An app-bundle artifact (`Some.app`) extracted from a cask's artifacts.
/// brew moves `source` from the staged Caskroom version dir into `/Applications`
/// (renamed to `target`), then leaves a back-symlink in the Caskroom.
pub const AppArtifact = struct {
    source: []const u8, // bundle name inside the archive, e.g., "Rectangle.app"
    target: []const u8, // destination basename in /Applications, e.g., "Rectangle.app"
};

/// A macOS installer package. Nothing to extract — it is handed to
/// `/usr/sbin/installer -target /`, which writes to absolute paths it declares.
pub const PkgArtifact = struct {
    source: []const u8, // path to the .pkg relative to the staged version dir
    allow_untrusted: bool, // `pkg "x.pkg", allow_untrusted: true`
};

/// A cask's `uninstall` stanza, split into directives bru can carry out and
/// those it cannot. A pkg cask writes outside the Caskroom, so this is the
/// only record of what to remove; `unsupported` drives the install-time gate.
pub const UninstallPlan = struct {
    pkgutil: [][]const u8, // receipts to forget, and whose payload to delete
    delete: [][]const u8, // paths to remove outright
    rmdir: [][]const u8, // dirs to remove only if they end up empty
    trash: [][]const u8, // paths to move to the user's Trash
    /// Directives bru does not implement (launchctl, quit, script, ...), deduped.
    unsupported: [][]const u8,

    pub fn isEmpty(self: UninstallPlan) bool {
        return self.pkgutil.len == 0 and self.delete.len == 0 and
            self.rmdir.len == 0 and self.trash.len == 0;
    }
};

/// Resolved metadata for installing a single cask, fetched from per-cask API.
pub const ResolvedCask = struct {
    token: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    name: []const u8,
    binaries: []BinaryArtifact,
    apps: []AppArtifact,
    pkgs: []PkgArtifact,
    uninstall: UninstallPlan,
};

/// Map a Darwin kernel major version and CPU arch to the Homebrew cask
/// variation tag for the user's actual macOS. Returns "" when the kernel
/// release is unknown — callers treat empty as "no variation, use top-level".
///
/// Darwin → macOS mapping:
///   25 → Tahoe (macOS 26)        22 → Ventura (13)
///   24 → Sequoia (15)            21 → Monterey (12)
///   23 → Sonoma (14)             20 → Big Sur (11)
fn darwinReleaseToVariationTag(major: u32, arch: std.Target.Cpu.Arch, buf: []u8) []const u8 {
    const name: []const u8 = switch (major) {
        25 => "tahoe",
        24 => "sequoia",
        23 => "sonoma",
        22 => "ventura",
        21 => "monterey",
        20 => "big_sur",
        else => return "",
    };
    const prefix: []const u8 = if (arch == .aarch64) "arm64_" else "";
    return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, name }) catch "";
}

/// Return the cask-variation tag for THIS machine (e.g. "arm64_tahoe"),
/// or "" if it cannot be determined. Uses uname() — no subprocess.
///
/// Match policy: a variation must match this exact tag to override the
/// top-level fields. Previously the resolver walked all known tags new-to-old
/// and applied the first match, which downgraded current-macOS users when a
/// cask had variations only for older OSes (e.g. raycast: top-level 1.104.18,
/// arm64_monterey override 1.94.4 — a Tahoe user was incorrectly handed 1.94.4).
pub fn currentMacOSVariationTag(buf: []u8) []const u8 {
    const uname = std.posix.uname();
    const release = std.mem.sliceTo(&uname.release, 0);
    var it = std.mem.splitScalar(u8, release, '.');
    const major_str = it.next() orelse return "";
    const major = std.fmt.parseInt(u32, major_str, 10) catch return "";
    return darwinReleaseToVariationTag(major, builtin.target.cpu.arch, buf);
}

/// If `obj.variations[variation_tag]` exists and is an object, return it.
/// Otherwise null — caller falls back to top-level fields.
fn variationOverrideObject(obj: std.json.ObjectMap, variation_tag: []const u8) ?std.json.ObjectMap {
    if (variation_tag.len == 0) return null;
    const var_val = obj.get("variations") orelse return null;
    const variations = asObject(var_val) orelse return null;
    const tag_val = variations.get(variation_tag) orelse return null;
    return asObject(tag_val);
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

/// Parse a per-cask API JSON response, applying the current machine's macOS
/// variation. See parseResolvedCaskWithTag for tag semantics.
pub fn parseResolvedCask(allocator: Allocator, json_bytes: []const u8) !ResolvedCask {
    var tag_buf: [64]u8 = undefined;
    const tag = currentMacOSVariationTag(&tag_buf);
    return parseResolvedCaskWithTag(allocator, json_bytes, tag);
}

/// Parse a per-cask API JSON response into a ResolvedCask, applying the
/// variation block for `variation_tag` iff it exists. Pass "" to skip
/// variations entirely.
pub fn parseResolvedCaskWithTag(allocator: Allocator, json_bytes: []const u8, variation_tag: []const u8) !ResolvedCask {
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

    // Resolve url/sha256/version against the variation for this macOS, if any.
    var url_src: []const u8 = jsonStr(obj, "url") orelse "";
    var sha256_src: []const u8 = jsonStr(obj, "sha256") orelse "";
    var version_src: []const u8 = jsonStr(obj, "version") orelse "";
    if (variationOverrideObject(obj, variation_tag)) |tag_obj| {
        if (jsonStr(tag_obj, "url")) |v| url_src = v;
        if (jsonStr(tag_obj, "sha256")) |v| sha256_src = v;
        if (jsonStr(tag_obj, "version")) |v| version_src = v;
    }

    const url = try allocator.dupe(u8, url_src);
    errdefer allocator.free(url);

    const sha256 = try allocator.dupe(u8, sha256_src);
    errdefer allocator.free(sha256);

    const version = try allocator.dupe(u8, version_src);
    errdefer allocator.free(version);

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
    errdefer {
        for (binaries) |b| {
            allocator.free(b.source);
            allocator.free(b.target);
        }
        allocator.free(binaries);
    }

    // Parse app-bundle artifacts (e.g. `app "Rectangle.app"`).
    const apps = try parseAppArtifacts(allocator, obj);
    errdefer {
        for (apps) |a| {
            allocator.free(a.source);
            allocator.free(a.target);
        }
        allocator.free(apps);
    }

    // Parse pkg artifacts (e.g. `pkg "session-manager-plugin.pkg"`).
    const pkgs = try parsePkgArtifacts(allocator, obj);
    errdefer {
        for (pkgs) |p| allocator.free(p.source);
        allocator.free(pkgs);
    }

    // Parse the `uninstall` stanza so an install can be undone later, and so
    // the caller can tell whether bru is able to undo it at all.
    const uninstall = try parseUninstallPlan(allocator, obj);

    return ResolvedCask{
        .token = result_token,
        .version = version,
        .url = url,
        .sha256 = sha256,
        .name = result_name,
        .binaries = binaries,
        .apps = apps,
        .pkgs = pkgs,
        .uninstall = uninstall,
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

/// Parse app-bundle artifacts from a cask's artifacts array.
/// App artifacts look like:
///   - {"app": ["Rectangle.app"]}                       -> source/target = "Rectangle.app"
///   - {"app": ["Source.app", {"target": "Dest.app"}]}  -> source/target may differ
fn parseAppArtifacts(allocator: Allocator, obj: std.json.ObjectMap) ![]AppArtifact {
    const artifacts_val = obj.get("artifacts") orelse return try allocator.alloc(AppArtifact, 0);
    const artifacts_arr = switch (artifacts_val) {
        .array => |a| a,
        else => return try allocator.alloc(AppArtifact, 0),
    };

    var result = std.ArrayList(AppArtifact){};
    errdefer {
        for (result.items) |a| {
            allocator.free(a.source);
            allocator.free(a.target);
        }
        result.deinit(allocator);
    }

    for (artifacts_arr.items) |artifact_val| {
        const artifact_obj = switch (artifact_val) {
            .object => |o| o,
            else => continue,
        };

        const app_val = artifact_obj.get("app") orelse continue;
        const app_arr = switch (app_val) {
            .array => |a| a,
            else => continue,
        };
        if (app_arr.items.len == 0) continue;

        const source_raw = switch (app_arr.items[0]) {
            .string => |s| s,
            else => continue,
        };
        const source_clean = cleanArtifactPath(source_raw);

        const source = try allocator.dupe(u8, source_clean);
        errdefer allocator.free(source);

        const target = blk: {
            if (app_arr.items.len > 1) {
                if (asObject(app_arr.items[1])) |target_obj| {
                    if (jsonStr(target_obj, "target")) |t| {
                        break :blk try allocator.dupe(u8, t);
                    }
                }
            }
            // Default target = basename of source (most casks use this).
            break :blk try allocator.dupe(u8, std.fs.path.basename(source_clean));
        };

        try result.append(allocator, .{ .source = source, .target = target });
    }

    return try result.toOwnedSlice(allocator);
}

/// A cask's `artifacts` entries, empty when the key is absent or malformed.
fn artifactsArray(obj: std.json.ObjectMap) []const std.json.Value {
    const val = obj.get("artifacts") orelse return &.{};
    return switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
}

/// Parse pkg artifacts: {"pkg": ["Foo.pkg"]} or ["Foo.pkg", {"allow_untrusted": true}].
// TODO: `choices` (installer choice overrides) is ignored; those casks install
// with the package's defaults.
fn parsePkgArtifacts(allocator: Allocator, obj: std.json.ObjectMap) ![]PkgArtifact {
    var result = std.ArrayList(PkgArtifact){};
    errdefer {
        for (result.items) |p| allocator.free(p.source);
        result.deinit(allocator);
    }

    for (artifactsArray(obj)) |artifact_val| {
        const artifact_obj = switch (artifact_val) {
            .object => |o| o,
            else => continue,
        };

        const pkg_val = artifact_obj.get("pkg") orelse continue;
        const pkg_arr = switch (pkg_val) {
            .array => |a| a,
            else => continue,
        };
        if (pkg_arr.items.len == 0) continue;

        const source_raw = switch (pkg_arr.items[0]) {
            .string => |s| s,
            else => continue,
        };

        var allow_untrusted = false;
        if (pkg_arr.items.len > 1) {
            if (asObject(pkg_arr.items[1])) |opts| {
                allow_untrusted = jsonBool(opts, "allow_untrusted") orelse false;
            }
        }

        const source = try allocator.dupe(u8, cleanArtifactPath(source_raw));
        errdefer allocator.free(source);

        try result.append(allocator, .{ .source = source, .allow_untrusted = allow_untrusted });
    }

    return try result.toOwnedSlice(allocator);
}

/// Parse a cask's `uninstall` stanza; each directive value is a string or an
/// array of them. Unimplemented directives are named in `unsupported` rather
/// than dropped, so the caller can say why it is deferring to brew.
fn parseUninstallPlan(allocator: Allocator, obj: std.json.ObjectMap) !UninstallPlan {
    var pkgutil = std.ArrayList([]const u8){};
    var delete = std.ArrayList([]const u8){};
    var rmdir = std.ArrayList([]const u8){};
    var trash = std.ArrayList([]const u8){};
    var unsupported = std.ArrayList([]const u8){};

    errdefer {
        for ([_]*std.ArrayList([]const u8){ &pkgutil, &delete, &rmdir, &trash, &unsupported }) |list| {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
    }

    for (artifactsArray(obj)) |artifact_val| {
        const artifact_obj = switch (artifact_val) {
            .object => |o| o,
            else => continue,
        };

        const uninstall_val = artifact_obj.get("uninstall") orelse continue;
        const uninstall_arr = switch (uninstall_val) {
            .array => |a| a,
            else => continue,
        };

        for (uninstall_arr.items) |directive_val| {
            const directive = asObject(directive_val) orelse continue;
            var it = directive.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                const target: ?*std.ArrayList([]const u8) =
                    if (mem.eql(u8, key, "pkgutil")) &pkgutil
                    else if (mem.eql(u8, key, "delete")) &delete
                    else if (mem.eql(u8, key, "rmdir")) &rmdir
                    else if (mem.eql(u8, key, "trash")) &trash
                    else null;

                const list = target orelse {
                    try appendUnique(allocator, &unsupported, key);
                    continue;
                };

                // A pkgutil value may be a Ruby Regexp; guessing which
                // receipts it covers could forget another package's.
                const literal_only = mem.eql(u8, key, "pkgutil");
                if (!try appendStringValues(allocator, list, kv.value_ptr.*, literal_only)) {
                    try appendUnique(allocator, &unsupported, key);
                }
            }
        }
    }

    return UninstallPlan{
        .pkgutil = try pkgutil.toOwnedSlice(allocator),
        .delete = try delete.toOwnedSlice(allocator),
        .rmdir = try rmdir.toOwnedSlice(allocator),
        .trash = try trash.toOwnedSlice(allocator),
        .unsupported = try unsupported.toOwnedSlice(allocator),
    };
}

/// Append a directive's string or string-array value to `list`. False when a
/// value was skipped, telling the caller to mark the directive unsupported.
fn appendStringValues(
    allocator: Allocator,
    list: *std.ArrayList([]const u8),
    value: std.json.Value,
    literal_only: bool,
) !bool {
    switch (value) {
        .string => |s| {
            if (literal_only and !pkgutilIdIsLiteral(s)) return false;
            try list.append(allocator, try allocator.dupe(u8, s));
            return true;
        },
        .array => |items| {
            var complete = true;
            for (items.items) |item| {
                const s = switch (item) {
                    .string => |v| v,
                    else => {
                        complete = false;
                        continue;
                    },
                };
                if (literal_only and !pkgutilIdIsLiteral(s)) {
                    complete = false;
                    continue;
                }
                try list.append(allocator, try allocator.dupe(u8, s));
            }
            return complete;
        },
        else => return false,
    }
}

/// Append `value` to `list` unless it is already present.
fn appendUnique(allocator: Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (mem.eql(u8, existing, value)) return;
    }
    try list.append(allocator, try allocator.dupe(u8, value));
}

/// True when a pkgutil ID is a plain package identifier (reverse-DNS-ish)
/// rather than a regex. A mis-expanded pattern would forget other packages.
fn pkgutilIdIsLiteral(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '_' or c == '+';
        if (!ok) return false;
    }
    return true;
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

/// Whether bru can install a cask, and if not, why.
pub const Installability = enum {
    ok,
    /// No artifact kind bru handles (font, installer, manpage, ...).
    no_artifacts,
    /// Installs as root but declares uninstall steps bru cannot perform, so
    /// bru could not take it back out again.
    unremovable,
};

/// Single source of truth for "should bru handle this cask itself?" — install
/// and upgrade must agree, or upgrade becomes a way around the install gate.
pub fn installability(c: ResolvedCask) Installability {
    if (c.binaries.len == 0 and c.apps.len == 0 and c.pkgs.len == 0) return .no_artifacts;
    if (c.pkgs.len > 0 and c.uninstall.unsupported.len > 0) return .unremovable;
    return .ok;
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
    for (c.apps) |a| {
        allocator.free(a.source);
        allocator.free(a.target);
    }
    allocator.free(c.apps);
    for (c.pkgs) |p| allocator.free(p.source);
    allocator.free(c.pkgs);
    freeUninstallPlan(allocator, c.uninstall);
}

/// Free an UninstallPlan and all its owned strings.
pub fn freeUninstallPlan(allocator: Allocator, plan: UninstallPlan) void {
    for ([_][][]const u8{ plan.pkgutil, plan.delete, plan.rmdir, plan.trash, plan.unsupported }) |list| {
        for (list) |s| allocator.free(s);
        allocator.free(list);
    }
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
    try std.testing.expectEqual(@as(usize, 1), resolved.apps.len);
    try std.testing.expectEqualStrings("Google Chrome.app", resolved.apps[0].source);
    try std.testing.expectEqualStrings("Google Chrome.app", resolved.apps[0].target);
}

test "parseResolvedCask app artifact with target rename" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\{
        \\  "token": "renamed",
        \\  "name": ["Renamed"],
        \\  "url": "https://example.com/renamed.dmg",
        \\  "version": "1.0",
        \\  "sha256": "no_check",
        \\  "variations": {},
        \\  "artifacts": [
        \\    {"app": ["Source.app", {"target": "Dest.app"}]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCask(allocator, json_bytes);
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 1), resolved.apps.len);
    try std.testing.expectEqualStrings("Source.app", resolved.apps[0].source);
    try std.testing.expectEqualStrings("Dest.app", resolved.apps[0].target);
}

// ---------------------------------------------------------------------------
// pkg artifacts — shapes below are real payloads from the cask API.
// ---------------------------------------------------------------------------

test "parseResolvedCask parses pkg artifact and pkgutil uninstall id" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\{
        \\  "token": "session-manager-plugin",
        \\  "version": "1.2.835.0",
        \\  "url": "https://example.com/session-manager-plugin.pkg",
        \\  "sha256": "abc123",
        \\  "name": ["Session Manager Plugin for the AWS CLI"],
        \\  "artifacts": [
        \\    {"uninstall": [{"pkgutil": "session-manager-plugin"}]},
        \\    {"pkg": ["session-manager-plugin.pkg"]},
        \\    {"binary": ["/usr/local/sessionmanagerplugin/bin/session-manager-plugin"], "target": "$HOMEBREW_PREFIX/bin/session-manager-plugin"},
        \\    {"zap": [{"trash": "/Library/LaunchDaemons/SessionManagerPlugin.plist"}]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCaskWithTag(allocator, json_bytes, "");
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 1), resolved.pkgs.len);
    try std.testing.expectEqualStrings("session-manager-plugin.pkg", resolved.pkgs[0].source);
    try std.testing.expectEqual(false, resolved.pkgs[0].allow_untrusted);

    try std.testing.expectEqual(@as(usize, 1), resolved.uninstall.pkgutil.len);
    try std.testing.expectEqualStrings("session-manager-plugin", resolved.uninstall.pkgutil[0]);

    // pkgutil-only: bru can fully undo this install, so no gate.
    try std.testing.expectEqual(@as(usize, 0), resolved.uninstall.unsupported.len);

    // Absolute: it lives where the pkg put it, not in the Caskroom.
    try std.testing.expectEqual(@as(usize, 1), resolved.binaries.len);
    try std.testing.expectEqualStrings(
        "/usr/local/sessionmanagerplugin/bin/session-manager-plugin",
        resolved.binaries[0].source,
    );
    try std.testing.expectEqualStrings("session-manager-plugin", resolved.binaries[0].target);

    // No app bundle, and the zap stanza must not be mistaken for one.
    try std.testing.expectEqual(@as(usize, 0), resolved.apps.len);
}

test "parseResolvedCask parses pkg allow_untrusted and array pkgutil ids" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\{
        \\  "token": "example",
        \\  "version": "1.0",
        \\  "url": "https://example.com/x.dmg",
        \\  "sha256": "abc",
        \\  "name": ["Example"],
        \\  "artifacts": [
        \\    {"pkg": ["Installer.pkg", {"allow_untrusted": true}]},
        \\    {"uninstall": [{"pkgutil": ["com.example.one", "com.example.two"]}]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCaskWithTag(allocator, json_bytes, "");
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 1), resolved.pkgs.len);
    try std.testing.expectEqualStrings("Installer.pkg", resolved.pkgs[0].source);
    try std.testing.expectEqual(true, resolved.pkgs[0].allow_untrusted);

    try std.testing.expectEqual(@as(usize, 2), resolved.uninstall.pkgutil.len);
    try std.testing.expectEqualStrings("com.example.one", resolved.uninstall.pkgutil[0]);
    try std.testing.expectEqualStrings("com.example.two", resolved.uninstall.pkgutil[1]);
}

test "parseUninstallPlan rejects regex pkgutil patterns as unsupported" {
    const allocator = std.testing.allocator;

    // brew allows a Regexp for pkgutil:. Forgetting receipts by a pattern bru
    // cannot evaluate risks clobbering unrelated packages, so these are dropped.
    const json_bytes =
        \\{
        \\  "token": "example",
        \\  "version": "1.0",
        \\  "url": "https://example.com/x.pkg",
        \\  "sha256": "abc",
        \\  "name": ["Example"],
        \\  "artifacts": [
        \\    {"uninstall": [{"pkgutil": ["com.example.plain", "com\\.example\\..*", "com.example.*"]}]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCaskWithTag(allocator, json_bytes, "");
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 1), resolved.uninstall.pkgutil.len);
    try std.testing.expectEqualStrings("com.example.plain", resolved.uninstall.pkgutil[0]);

    // Dropping a pattern makes the uninstall incomplete, so the gate must fire.
    try std.testing.expectEqual(@as(usize, 1), resolved.uninstall.unsupported.len);
    try std.testing.expectEqualStrings("pkgutil", resolved.uninstall.unsupported[0]);
}

test "parseResolvedCask leaves pkg fields empty for a plain app cask" {
    const allocator = std.testing.allocator;

    const json_bytes =
        \\{
        \\  "token": "chrome",
        \\  "version": "1.0",
        \\  "url": "https://example.com/x.dmg",
        \\  "sha256": "abc",
        \\  "name": ["Chrome"],
        \\  "artifacts": [{"app": ["Google Chrome.app"]}]
        \\}
    ;

    const resolved = try parseResolvedCaskWithTag(allocator, json_bytes, "");
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 0), resolved.pkgs.len);
    try std.testing.expect(resolved.uninstall.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), resolved.uninstall.unsupported.len);
}

test "parseUninstallPlan collects delete, rmdir, and trash paths" {
    const allocator = std.testing.allocator;

    // adguard's shape: delete as an array, rmdir as a bare string.
    const json_bytes =
        \\{
        \\  "token": "example",
        \\  "version": "1.0",
        \\  "url": "https://example.com/x.pkg",
        \\  "sha256": "abc",
        \\  "name": ["Example"],
        \\  "artifacts": [
        \\    {"pkg": ["Example.pkg"]},
        \\    {"uninstall": [{
        \\      "pkgutil": "com.example.app",
        \\      "delete": ["/Library/Application Support/Example", "~/Library/Logs/Example"],
        \\      "rmdir": "/Library/Application Support/Example Software",
        \\      "trash": "/Library/Audio/Plug-Ins/HAL/Example.driver"
        \\    }]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCaskWithTag(allocator, json_bytes, "");
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 2), resolved.uninstall.delete.len);
    try std.testing.expectEqualStrings("/Library/Application Support/Example", resolved.uninstall.delete[0]);
    // Tilde paths survive parsing verbatim; expansion happens at uninstall.
    try std.testing.expectEqualStrings("~/Library/Logs/Example", resolved.uninstall.delete[1]);

    try std.testing.expectEqual(@as(usize, 1), resolved.uninstall.rmdir.len);
    try std.testing.expectEqualStrings("/Library/Application Support/Example Software", resolved.uninstall.rmdir[0]);

    try std.testing.expectEqual(@as(usize, 1), resolved.uninstall.trash.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.uninstall.unsupported.len);
}

test "parseUninstallPlan reports directives bru cannot carry out" {
    const allocator = std.testing.allocator;

    // 60% of pkg casks look like this.
    const json_bytes =
        \\{
        \\  "token": "example",
        \\  "version": "1.0",
        \\  "url": "https://example.com/x.pkg",
        \\  "sha256": "abc",
        \\  "name": ["Example"],
        \\  "artifacts": [
        \\    {"pkg": ["Example.pkg"]},
        \\    {"uninstall": [
        \\      {"launchctl": "com.example.daemon", "quit": "com.example.app"},
        \\      {"pkgutil": "com.example.app"},
        \\      {"launchctl": "com.example.other"}
        \\    ]}
        \\  ]
        \\}
    ;

    const resolved = try parseResolvedCaskWithTag(allocator, json_bytes, "");
    defer freeResolvedCask(allocator, resolved);

    try std.testing.expectEqual(@as(usize, 1), resolved.uninstall.pkgutil.len);

    // Unsupported ones are named once each for the gate message.
    try std.testing.expectEqual(@as(usize, 2), resolved.uninstall.unsupported.len);
    var saw_launchctl = false;
    var saw_quit = false;
    for (resolved.uninstall.unsupported) |d| {
        if (mem.eql(u8, d, "launchctl")) saw_launchctl = true;
        if (mem.eql(u8, d, "quit")) saw_quit = true;
    }
    try std.testing.expect(saw_launchctl);
    try std.testing.expect(saw_quit);
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

// ---------------------------------------------------------------------------
// Bug 2: variation-tag selection must match the user's actual macOS.
// Previously the code iterated platformVariationTags() new-to-old and applied
// the first match, which downgraded users on a recent macOS when a cask had
// variations only for older OSes (e.g. raycast 1.99.3 -> 1.94.4).
// ---------------------------------------------------------------------------

test "parseSingleCaskJson without variations keeps top-level fields" {
    const allocator = std.testing.allocator;
    const json_bytes =
        \\{
        \\  "token": "raycast",
        \\  "name": ["Raycast"],
        \\  "url": "https://example.com/raycast-1.104.18.dmg",
        \\  "version": "1.104.18",
        \\  "sha256": "newhash"
        \\}
    ;
    const info = try parseSingleCaskJson(allocator, json_bytes, "arm64_tahoe");
    defer freeCask(allocator, info);
    try std.testing.expectEqualStrings("1.104.18", info.version);
    try std.testing.expectEqualStrings("https://example.com/raycast-1.104.18.dmg", info.url);
    try std.testing.expectEqualStrings("newhash", info.sha256);
}

test "parseSingleCaskJson applies variation only when tag matches user OS" {
    const allocator = std.testing.allocator;
    // Top-level is the current Raycast; variations cap older macOS at 1.94.4.
    // A Tahoe user must NOT pick up monterey's downgrade.
    const json_bytes =
        \\{
        \\  "token": "raycast",
        \\  "name": ["Raycast"],
        \\  "url": "https://example.com/raycast-1.104.18.dmg",
        \\  "version": "1.104.18",
        \\  "sha256": "newhash",
        \\  "variations": {
        \\    "arm64_monterey": {
        \\      "url": "https://example.com/raycast-1.94.4.dmg",
        \\      "version": "1.94.4",
        \\      "sha256": "oldhash"
        \\    }
        \\  }
        \\}
    ;
    const tahoe = try parseSingleCaskJson(allocator, json_bytes, "arm64_tahoe");
    defer freeCask(allocator, tahoe);
    try std.testing.expectEqualStrings("1.104.18", tahoe.version);
    try std.testing.expectEqualStrings("newhash", tahoe.sha256);
}

test "parseSingleCaskJson uses variation when tag matches" {
    const allocator = std.testing.allocator;
    const json_bytes =
        \\{
        \\  "token": "raycast",
        \\  "name": ["Raycast"],
        \\  "url": "https://example.com/raycast-1.104.18.dmg",
        \\  "version": "1.104.18",
        \\  "sha256": "newhash",
        \\  "variations": {
        \\    "arm64_monterey": {
        \\      "url": "https://example.com/raycast-1.94.4.dmg",
        \\      "version": "1.94.4",
        \\      "sha256": "oldhash"
        \\    }
        \\  }
        \\}
    ;
    const monterey = try parseSingleCaskJson(allocator, json_bytes, "arm64_monterey");
    defer freeCask(allocator, monterey);
    try std.testing.expectEqualStrings("1.94.4", monterey.version);
    try std.testing.expectEqualStrings("oldhash", monterey.sha256);
}

test "parseResolvedCaskWithTag ignores non-matching variation" {
    const allocator = std.testing.allocator;
    const json_bytes =
        \\{
        \\  "token": "raycast",
        \\  "name": ["Raycast"],
        \\  "url": "https://example.com/raycast-1.104.18.dmg",
        \\  "version": "1.104.18",
        \\  "sha256": "newhash",
        \\  "variations": {
        \\    "arm64_monterey": {
        \\      "url": "https://example.com/raycast-1.94.4.dmg",
        \\      "version": "1.94.4",
        \\      "sha256": "oldhash"
        \\    }
        \\  },
        \\  "artifacts": [{"app": ["Raycast.app"]}]
        \\}
    ;
    const resolved = try parseResolvedCaskWithTag(allocator, json_bytes, "arm64_tahoe");
    defer freeResolvedCask(allocator, resolved);
    try std.testing.expectEqualStrings("1.104.18", resolved.version);
}

test "parseResolvedCaskWithTag picks matching variation" {
    const allocator = std.testing.allocator;
    const json_bytes =
        \\{
        \\  "token": "raycast",
        \\  "name": ["Raycast"],
        \\  "url": "https://example.com/raycast-1.104.18.dmg",
        \\  "version": "1.104.18",
        \\  "sha256": "newhash",
        \\  "variations": {
        \\    "arm64_monterey": {
        \\      "url": "https://example.com/raycast-1.94.4.dmg",
        \\      "version": "1.94.4",
        \\      "sha256": "oldhash"
        \\    }
        \\  },
        \\  "artifacts": [{"app": ["Raycast.app"]}]
        \\}
    ;
    const resolved = try parseResolvedCaskWithTag(allocator, json_bytes, "arm64_monterey");
    defer freeResolvedCask(allocator, resolved);
    try std.testing.expectEqualStrings("1.94.4", resolved.version);
}

test "currentMacOSVariationTag identifies Tahoe from Darwin 25" {
    var buf: [64]u8 = undefined;
    const tag = darwinReleaseToVariationTag(25, .aarch64, &buf);
    try std.testing.expectEqualStrings("arm64_tahoe", tag);
}

test "currentMacOSVariationTag identifies Sequoia from Darwin 24" {
    var buf: [64]u8 = undefined;
    const tag = darwinReleaseToVariationTag(24, .aarch64, &buf);
    try std.testing.expectEqualStrings("arm64_sequoia", tag);
}

test "currentMacOSVariationTag handles intel arch" {
    var buf: [64]u8 = undefined;
    const tag = darwinReleaseToVariationTag(23, .x86_64, &buf);
    try std.testing.expectEqualStrings("sonoma", tag);
}

test "currentMacOSVariationTag returns empty for unknown release" {
    var buf: [64]u8 = undefined;
    const tag = darwinReleaseToVariationTag(99, .aarch64, &buf);
    try std.testing.expectEqualStrings("", tag);
}

test "installability gates pkg casks bru could not uninstall" {
    const empty_plan = UninstallPlan{ .pkgutil = &.{}, .delete = &.{}, .rmdir = &.{}, .trash = &.{}, .unsupported = &.{} };
    var base = ResolvedCask{
        .token = "x",
        .version = "1",
        .url = "",
        .sha256 = "",
        .name = "X",
        .binaries = &.{},
        .apps = &.{},
        .pkgs = &.{},
        .uninstall = empty_plan,
    };
    try std.testing.expectEqual(Installability.no_artifacts, installability(base));

    var pkgs = [_]PkgArtifact{.{ .source = "a.pkg", .allow_untrusted = false }};
    base.pkgs = &pkgs;
    try std.testing.expectEqual(Installability.ok, installability(base));

    // A pkg cask needing launchctl must be refused by BOTH install and
    // upgrade — upgrade is otherwise a way around the gate, since brew fills
    // the same Caskroom that `bru upgrade` scans.
    var unsupported = [_][]const u8{"launchctl"};
    base.uninstall.unsupported = &unsupported;
    try std.testing.expectEqual(Installability.unremovable, installability(base));

    // The same stanza on an app cask is not gated: bru never installs it as
    // root, so there is nothing unremovable to guard against.
    base.pkgs = &.{};
    var apps = [_]AppArtifact{.{ .source = "A.app", .target = "A.app" }};
    base.apps = &apps;
    try std.testing.expectEqual(Installability.ok, installability(base));
}
