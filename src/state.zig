const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const writeJsonStr = @import("json_helpers.zig").writeJsonStr;

/// A single entry recording an action performed on a formula.
pub const HistoryEntry = struct {
    action: []const u8,
    formula: []const u8,
    version: []const u8,
    previous_version: ?[]const u8,
    timestamp: i64,
};

/// Persistent state stored in ~/.bru/state.json.
pub const State = struct {
    version: u32 = 1,
    history: std.ArrayList(HistoryEntry),
    bru_version: []const u8 = "0.1.0",
    bru_version_allocated: bool = false,
    bru_updated_at: ?i64 = null,
    allocator: Allocator,

    /// Create an empty state.
    pub fn init(allocator: Allocator) State {
        return .{
            .history = .{},
            .allocator = allocator,
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *State) void {
        for (self.history.items) |entry| {
            self.allocator.free(entry.action);
            self.allocator.free(entry.formula);
            self.allocator.free(entry.version);
            if (entry.previous_version) |pv| {
                self.allocator.free(pv);
            }
        }
        self.history.deinit(self.allocator);
        if (self.bru_version_allocated) {
            self.allocator.free(self.bru_version);
        }
    }

    /// Record an action in the history. All strings are duped.
    pub fn recordAction(
        self: *State,
        action: []const u8,
        formula: []const u8,
        version: []const u8,
        previous_version: ?[]const u8,
    ) !void {
        const duped_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(duped_action);

        const duped_formula = try self.allocator.dupe(u8, formula);
        errdefer self.allocator.free(duped_formula);

        const duped_version = try self.allocator.dupe(u8, version);
        errdefer self.allocator.free(duped_version);

        const duped_prev = if (previous_version) |pv|
            try self.allocator.dupe(u8, pv)
        else
            null;
        errdefer if (duped_prev) |pv| self.allocator.free(pv);

        try self.history.append(self.allocator, .{
            .action = duped_action,
            .formula = duped_formula,
            .version = duped_version,
            .previous_version = duped_prev,
            .timestamp = std.time.timestamp(),
        });
    }

    /// Walk history backwards to find the most recent entry for the given
    /// formula that has a non-null previous_version (i.e. a rollback target).
    /// The returned entry borrows pointers from state and must not outlive it.
    pub fn findRollbackTarget(self: *const State, formula: []const u8) ?HistoryEntry {
        var i: usize = self.history.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.history.items[i];
            if (mem.eql(u8, entry.formula, formula) and entry.previous_version != null) {
                return entry;
            }
        }
        return null;
    }

    /// Load state from ~/.bru/state.json.
    /// Returns an empty state if the file does not exist or cannot be parsed.
    pub fn load(allocator: Allocator) State {
        const home = std.posix.getenv("HOME") orelse return State.init(allocator);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.bru/state.json", .{home}) catch
            return State.init(allocator);

        const file = std.fs.openFileAbsolute(path, .{}) catch return State.init(allocator);
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return State.init(allocator);
        defer allocator.free(content);

        return parseState(allocator, content) catch State.init(allocator);
    }

    /// Write state as JSON to ~/.bru/state.json, creating ~/.bru/ if needed.
    pub fn save(self: *const State) !void {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.bru", .{home});

        // Create the directory if it doesn't exist.
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/.bru/state.json", .{home});

        // TODO: write to temp file and rename for atomic save
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        var json_buf: std.ArrayList(u8) = .{};
        defer json_buf.deinit(self.allocator);
        const writer = json_buf.writer(self.allocator);

        try writer.writeAll("{\"version\":");
        try writer.print("{d}", .{self.version});
        try writer.writeAll(",\"history\":[");

        for (self.history.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"action\":");
            try writeJsonStr(writer, entry.action);
            try writer.writeAll(",\"formula\":");
            try writeJsonStr(writer, entry.formula);
            try writer.writeAll(",\"version\":");
            try writeJsonStr(writer, entry.version);
            try writer.writeAll(",\"previous_version\":");
            if (entry.previous_version) |pv| {
                try writeJsonStr(writer, pv);
            } else {
                try writer.writeAll("null");
            }
            try writer.print(",\"timestamp\":{d}", .{entry.timestamp});
            try writer.writeAll("}");
        }

        try writer.writeAll("],\"bru_version\":");
        try writeJsonStr(writer, self.bru_version);
        try writer.writeAll(",\"bru_updated_at\":");
        if (self.bru_updated_at) |ts| {
            try writer.print("{d}", .{ts});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}");

        try file.writeAll(json_buf.items);
    }
};

/// Parse JSON content into a State struct.
fn parseState(allocator: Allocator, content: []const u8) !State {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidFormat,
    };

    var state = State.init(allocator);
    errdefer state.deinit();

    // Parse version.
    if (jsonInt(root, "version")) |v| {
        state.version = if (v >= 0) @intCast(v) else 1;
    }

    // Parse bru_version.
    if (jsonStr(root, "bru_version")) |bv| {
        state.bru_version = try allocator.dupe(u8, bv);
        state.bru_version_allocated = true;
    }

    // Parse bru_updated_at.
    state.bru_updated_at = jsonInt(root, "bru_updated_at");

    // Parse history array.
    const arr_val = root.get("history") orelse return state;
    const arr = switch (arr_val) {
        .array => |a| a,
        else => return state,
    };

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const action = try allocator.dupe(u8, jsonStr(obj, "action") orelse continue);
        errdefer allocator.free(action);

        const formula = try allocator.dupe(u8, jsonStr(obj, "formula") orelse {
            allocator.free(action);
            continue;
        });
        errdefer allocator.free(formula);

        const version = try allocator.dupe(u8, jsonStr(obj, "version") orelse {
            allocator.free(action);
            allocator.free(formula);
            continue;
        });
        errdefer allocator.free(version);

        const prev_str = jsonStr(obj, "previous_version");
        const previous_version = if (prev_str) |pv|
            try allocator.dupe(u8, pv)
        else
            null;
        errdefer if (previous_version) |pv| allocator.free(pv);

        const timestamp = jsonInt(obj, "timestamp") orelse 0;

        try state.history.append(allocator, .{
            .action = action,
            .formula = formula,
            .version = version,
            .previous_version = previous_version,
            .timestamp = timestamp,
        });
    }

    return state;
}

// ---------------------------------------------------------------------------
// JSON reading helpers
// ---------------------------------------------------------------------------

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "State init creates empty state" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(u32, 1), state.version);
    try std.testing.expectEqual(@as(usize, 0), state.history.items.len);
    try std.testing.expectEqualStrings("0.1.0", state.bru_version);
    try std.testing.expect(state.bru_updated_at == null);
}

test "State recordAction appends entry" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    try state.recordAction("install", "ripgrep", "14.1.0", null);

    try std.testing.expectEqual(@as(usize, 1), state.history.items.len);
    try std.testing.expectEqualStrings("install", state.history.items[0].action);
    try std.testing.expectEqualStrings("ripgrep", state.history.items[0].formula);
    try std.testing.expectEqualStrings("14.1.0", state.history.items[0].version);
    try std.testing.expect(state.history.items[0].previous_version == null);
    try std.testing.expect(state.history.items[0].timestamp > 0);
}

test "State recordAction with previous_version" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    try state.recordAction("upgrade", "bat", "0.25.0", "0.24.0");

    try std.testing.expectEqual(@as(usize, 1), state.history.items.len);
    try std.testing.expectEqualStrings("upgrade", state.history.items[0].action);
    try std.testing.expectEqualStrings("bat", state.history.items[0].formula);
    try std.testing.expectEqualStrings("0.25.0", state.history.items[0].version);
    try std.testing.expectEqualStrings("0.24.0", state.history.items[0].previous_version.?);
}

test "findRollbackTarget returns most recent entry with previous_version" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    // First upgrade
    try state.recordAction("upgrade", "bat", "0.24.0", "0.23.0");
    // Second upgrade
    try state.recordAction("upgrade", "bat", "0.25.0", "0.24.0");
    // An install of a different formula (no previous_version)
    try state.recordAction("install", "ripgrep", "14.1.0", null);

    const target = state.findRollbackTarget("bat");
    try std.testing.expect(target != null);
    try std.testing.expectEqualStrings("0.25.0", target.?.version);
    try std.testing.expectEqualStrings("0.24.0", target.?.previous_version.?);
}

test "findRollbackTarget returns null when no previous_version" {
    const allocator = std.testing.allocator;
    var state = State.init(allocator);
    defer state.deinit();

    try state.recordAction("install", "bat", "0.25.0", null);

    const target = state.findRollbackTarget("bat");
    try std.testing.expect(target == null);
}

test "parseState round-trips through JSON" {
    const allocator = std.testing.allocator;

    const json =
        \\{"version":1,"history":[{"action":"install","formula":"ripgrep","version":"14.1.0","previous_version":null,"timestamp":1700000000},{"action":"upgrade","formula":"bat","version":"0.25.0","previous_version":"0.24.0","timestamp":1700000001}],"bru_version":"0.1.0","bru_updated_at":null}
    ;

    var state = try parseState(allocator, json);
    defer state.deinit();

    try std.testing.expectEqual(@as(u32, 1), state.version);
    try std.testing.expectEqual(@as(usize, 2), state.history.items.len);

    // First entry
    try std.testing.expectEqualStrings("install", state.history.items[0].action);
    try std.testing.expectEqualStrings("ripgrep", state.history.items[0].formula);
    try std.testing.expectEqualStrings("14.1.0", state.history.items[0].version);
    try std.testing.expect(state.history.items[0].previous_version == null);
    try std.testing.expectEqual(@as(i64, 1700000000), state.history.items[0].timestamp);

    // Second entry
    try std.testing.expectEqualStrings("upgrade", state.history.items[1].action);
    try std.testing.expectEqualStrings("bat", state.history.items[1].formula);
    try std.testing.expectEqualStrings("0.25.0", state.history.items[1].version);
    try std.testing.expectEqualStrings("0.24.0", state.history.items[1].previous_version.?);
    try std.testing.expectEqual(@as(i64, 1700000001), state.history.items[1].timestamp);

    // Verify bru_updated_at
    try std.testing.expect(state.bru_updated_at == null);
}
