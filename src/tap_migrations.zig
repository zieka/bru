const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Parsed tap migration target.
pub const MigrationTarget = struct {
    /// Full target string, e.g. "homebrew/cask" or "homebrew/cask/luanti".
    raw: []const u8,

    /// Returns true if the target is a cask (starts with "homebrew/cask").
    pub fn isCask(self: MigrationTarget) bool {
        return mem.startsWith(u8, self.raw, "homebrew/cask");
    }

    /// Extract the new name from the target.
    /// - "homebrew/cask/luanti" -> "luanti"
    /// - "homebrew/cask" -> null (same name, just moved to cask)
    /// - "some-tap/some-name" -> "some-name"
    pub fn newName(self: MigrationTarget) ?[]const u8 {
        // Count slashes: "homebrew/cask" has 1, "homebrew/cask/luanti" has 2
        var slash_count: usize = 0;
        var last_slash: usize = 0;
        for (self.raw, 0..) |c, i| {
            if (c == '/') {
                slash_count += 1;
                last_slash = i;
            }
        }
        // "homebrew/cask" (1 slash) -> no rename, just moved
        if (slash_count <= 1) return null;
        // "homebrew/cask/luanti" (2 slashes) -> "luanti"
        if (last_slash + 1 < self.raw.len) return self.raw[last_slash + 1 ..];
        return null;
    }
};

/// Loads and queries formula tap migrations from the Homebrew API cache.
pub const TapMigrations = struct {
    parsed: std.json.Parsed(std.json.Value),

    /// Load tap migrations from {cache}/api/formula_tap_migrations.jws.json.
    /// Returns null if the file doesn't exist or can't be parsed.
    pub fn load(allocator: Allocator, cache_dir: []const u8) ?TapMigrations {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/api/formula_tap_migrations.jws.json", .{cache_dir}) catch return null;

        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const bytes = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return null;
        defer allocator.free(bytes);

        // Parse outer JWS envelope.
        const jws = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .allocate = .alloc_always,
        }) catch return null;

        const payload_str = switch (jws.value) {
            .object => |obj| switch (obj.get("payload") orelse {
                jws.deinit();
                return null;
            }) {
                .string => |s| s,
                else => {
                    jws.deinit();
                    return null;
                },
            },
            else => {
                jws.deinit();
                return null;
            },
        };

        // Parse the payload string as a JSON object.
        const migrations = std.json.parseFromSlice(std.json.Value, allocator, payload_str, .{
            .allocate = .alloc_always,
        }) catch {
            jws.deinit();
            return null;
        };

        // We keep the migrations parsed value; free the JWS envelope.
        jws.deinit();

        return TapMigrations{
            .parsed = migrations,
        };
    }

    /// Look up a formula name in the tap migrations.
    pub fn lookup(self: *const TapMigrations, name: []const u8) ?MigrationTarget {
        const obj = switch (self.parsed.value) {
            .object => |o| o,
            else => return null,
        };
        const val = obj.get(name) orelse return null;
        return switch (val) {
            .string => |s| MigrationTarget{ .raw = s },
            else => null,
        };
    }

    pub fn deinit(self: *TapMigrations) void {
        self.parsed.deinit();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MigrationTarget.isCask" {
    const cask = MigrationTarget{ .raw = "homebrew/cask" };
    try std.testing.expect(cask.isCask());

    const cask_named = MigrationTarget{ .raw = "homebrew/cask/luanti" };
    try std.testing.expect(cask_named.isCask());

    const formula = MigrationTarget{ .raw = "homebrew/core" };
    try std.testing.expect(!formula.isCask());
}

test "MigrationTarget.newName" {
    const same_name = MigrationTarget{ .raw = "homebrew/cask" };
    try std.testing.expect(same_name.newName() == null);

    const renamed = MigrationTarget{ .raw = "homebrew/cask/luanti" };
    try std.testing.expectEqualStrings("luanti", renamed.newName().?);

    const tap_move = MigrationTarget{ .raw = "some-tap/some-formula" };
    try std.testing.expect(tap_move.newName() == null);
}

test "TapMigrations load from real cache" {
    const allocator = std.testing.allocator;

    const home = std.posix.getenv("HOME") orelse return;
    var buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&buf, "{s}/Library/Caches/Homebrew", .{home}) catch return;

    var migrations = TapMigrations.load(allocator, cache_dir) orelse return;
    defer migrations.deinit();

    // The tap migrations file should exist and have entries.
    // Check for a known migration (these are stable).
    if (migrations.lookup("android-ndk")) |target| {
        try std.testing.expect(target.isCask());
    }
}
