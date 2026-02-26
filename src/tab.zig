const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// A single runtime dependency entry from a Homebrew INSTALL_RECEIPT.json.
pub const RuntimeDep = struct {
    full_name: []const u8,
    version: []const u8,
    revision: u32,
    pkg_version: []const u8,
    declared_directly: bool,
};

/// Parsed representation of a Homebrew keg's INSTALL_RECEIPT.json file.
pub const Tab = struct {
    installed_on_request: bool,
    poured_from_bottle: bool,
    loaded_from_api: bool,
    time: ?i64,
    runtime_dependencies: []const RuntimeDep,
    compiler: []const u8,
    homebrew_version: []const u8,

    /// Attempt to load and parse a Tab from a keg directory.
    /// Expects {keg_path}/INSTALL_RECEIPT.json to exist.
    /// Returns null if the file doesn't exist or can't be parsed.
    pub fn loadFromKeg(allocator: Allocator, keg_path: []const u8) ?Tab {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const receipt_path = std.fmt.bufPrint(&path_buf, "{s}/INSTALL_RECEIPT.json", .{keg_path}) catch return null;

        const file = std.fs.openFileAbsolute(receipt_path, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return null,
        };

        // Extract scalar fields.
        const installed_on_request = jsonBool(root, "installed_on_request") orelse false;
        const poured_from_bottle = jsonBool(root, "poured_from_bottle") orelse false;
        const loaded_from_api = jsonBool(root, "loaded_from_api") orelse false;
        const time = jsonInt(root, "time");
        const compiler = allocator.dupe(u8, jsonStr(root, "compiler") orelse "unknown") catch return null;
        const homebrew_version = allocator.dupe(u8, jsonStr(root, "homebrew_version") orelse "unknown") catch {
            allocator.free(compiler);
            return null;
        };

        // Parse runtime_dependencies array.
        const deps = parseRuntimeDeps(allocator, root) catch {
            allocator.free(compiler);
            allocator.free(homebrew_version);
            return null;
        };

        return Tab{
            .installed_on_request = installed_on_request,
            .poured_from_bottle = poured_from_bottle,
            .loaded_from_api = loaded_from_api,
            .time = time,
            .runtime_dependencies = deps,
            .compiler = compiler,
            .homebrew_version = homebrew_version,
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: Tab, allocator: Allocator) void {
        for (self.runtime_dependencies) |dep| {
            allocator.free(dep.full_name);
            allocator.free(dep.version);
            allocator.free(dep.pkg_version);
        }
        allocator.free(self.runtime_dependencies);
        allocator.free(self.compiler);
        allocator.free(self.homebrew_version);
    }

    /// Write an INSTALL_RECEIPT.json file into the keg directory.
    pub fn writeToKeg(self: Tab, allocator: std.mem.Allocator, keg_path: []const u8) !void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const receipt_path = try std.fmt.bufPrint(&path_buf, "{s}/INSTALL_RECEIPT.json", .{keg_path});

        var json_buf: std.ArrayList(u8) = .{};
        defer json_buf.deinit(allocator);
        const writer = json_buf.writer(allocator);

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

        if (self.runtime_dependencies.len > 0) {
            try writer.writeAll("\n  ");
        }
        try writer.writeAll("],\n");

        try writer.writeAll("  \"source\": {\"spec\": \"stable\"}\n");
        try writer.writeAll("}\n");

        const file = try std.fs.createFileAbsolute(receipt_path, .{});
        defer file.close();
        try file.writeAll(json_buf.items);
    }
};

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Get a string value from a JSON object by key.
fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Get a bool value from a JSON object by key.
fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// Get an integer value from a JSON object by key.
fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// Parse the runtime_dependencies array from the root JSON object.
fn parseRuntimeDeps(allocator: Allocator, root: std.json.ObjectMap) ![]const RuntimeDep {
    const arr_val = root.get("runtime_dependencies") orelse return &.{};
    const arr = switch (arr_val) {
        .array => |a| a,
        else => return &.{},
    };

    var deps = try std.ArrayList(RuntimeDep).initCapacity(allocator, arr.items.len);
    errdefer {
        for (deps.items) |dep| {
            allocator.free(dep.full_name);
            allocator.free(dep.version);
            allocator.free(dep.pkg_version);
        }
        deps.deinit(allocator);
    }

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const full_name = try allocator.dupe(u8, jsonStr(obj, "full_name") orelse continue);
        errdefer allocator.free(full_name);

        const version = try allocator.dupe(u8, jsonStr(obj, "version") orelse {
            allocator.free(full_name);
            continue;
        });
        errdefer allocator.free(version);

        const pkg_version = try allocator.dupe(u8, jsonStr(obj, "pkg_version") orelse {
            allocator.free(full_name);
            allocator.free(version);
            continue;
        });

        const revision: u32 = blk: {
            const rev_int = jsonInt(obj, "revision") orelse break :blk 0;
            break :blk if (rev_int >= 0) @intCast(rev_int) else 0;
        };

        deps.appendAssumeCapacity(.{
            .full_name = full_name,
            .version = version,
            .revision = revision,
            .pkg_version = pkg_version,
            .declared_directly = jsonBool(obj, "declared_directly") orelse false,
        });
    }

    return try deps.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Tab loadFromKeg reads real tab" {
    const allocator = std.testing.allocator;

    const tab = Tab.loadFromKeg(allocator, "/opt/homebrew/Cellar/bat/0.26.1") orelse {
        // If bat is not installed, skip gracefully.
        return;
    };
    defer tab.deinit(allocator);

    try std.testing.expect(tab.poured_from_bottle);
    try std.testing.expect(tab.homebrew_version.len > 0);
    try std.testing.expect(tab.installed_on_request);
    try std.testing.expect(tab.loaded_from_api);
    try std.testing.expect(tab.time != null);
    try std.testing.expect(tab.runtime_dependencies.len > 0);
    try std.testing.expectEqualStrings("clang", tab.compiler);
}

test "Tab loadFromKeg returns null for nonexistent" {
    const allocator = std.testing.allocator;
    const result = Tab.loadFromKeg(allocator, "/nonexistent/path");
    try std.testing.expect(result == null);
}

test "Tab writeToKeg round-trips" {
    const allocator = std.testing.allocator;

    // Create a temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the real path of the temp dir
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &real_path_buf);

    var tab = Tab{
        .installed_on_request = true,
        .poured_from_bottle = true,
        .loaded_from_api = true,
        .time = 1700000000,
        .runtime_dependencies = &.{},
        .compiler = "clang",
        .homebrew_version = "bru 0.1.0",
    };
    try tab.writeToKeg(allocator, tmp_path);

    // Read it back
    const tab2 = Tab.loadFromKeg(allocator, tmp_path) orelse return error.TestUnexpectedResult;
    defer tab2.deinit(allocator);
    try std.testing.expect(tab2.poured_from_bottle);
    try std.testing.expect(tab2.installed_on_request);
    try std.testing.expectEqualStrings("clang", tab2.compiler);
}
