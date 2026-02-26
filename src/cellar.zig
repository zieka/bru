const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// A formula installed in the Homebrew Cellar with its version history.
pub const InstalledFormula = struct {
    name: []const u8,
    versions: []const []const u8,

    /// Return the latest (last) version string from the sorted versions array.
    pub fn latestVersion(self: InstalledFormula) []const u8 {
        return self.versions[self.versions.len - 1];
    }
};

/// Reads installed formula state from a Homebrew Cellar directory.
pub const Cellar = struct {
    path: []const u8,

    /// Create a Cellar pointing at the given filesystem path.
    pub fn init(path: []const u8) Cellar {
        return .{ .path = path };
    }

    /// Check whether a formula is installed by probing for its directory.
    pub fn isInstalled(self: Cellar, name: []const u8) bool {
        var buf: [1024]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.path, name }) catch return false;

        // Try to open the directory; if it succeeds, the formula is installed.
        var dir = std.fs.openDirAbsolute(full_path, .{}) catch return false;
        dir.close();
        return true;
    }

    /// Return a sorted list of installed version strings for a formula,
    /// or null if the formula is not installed / has no versions.
    /// Caller owns the returned slice and all strings within it.
    pub fn installedVersions(self: Cellar, allocator: Allocator, name: []const u8) ?[]const []const u8 {
        var buf: [1024]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.path, name }) catch return null;

        var dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch return null;
        defer dir.close();

        var versions: std.ArrayList([]const u8) = .{};

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            // Skip hidden / dot entries.
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            const duped = allocator.dupe(u8, entry.name) catch return null;
            versions.append(allocator, duped) catch {
                allocator.free(duped);
                return null;
            };
        }

        if (versions.items.len == 0) {
            versions.deinit(allocator);
            return null;
        }

        mem.sort([]const u8, versions.items, {}, stringLessThan);
        return versions.toOwnedSlice(allocator) catch null;
    }

    /// Scan the entire cellar and return a sorted list of installed formulae.
    /// Caller owns the returned slice and all data within it.
    pub fn installedFormulae(self: Cellar, allocator: Allocator) []InstalledFormula {
        var dir = std.fs.openDirAbsolute(self.path, .{ .iterate = true }) catch return &.{};
        defer dir.close();

        var formulae: std.ArrayList(InstalledFormula) = .{};

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 0 and entry.name[0] == '.') continue;

            const name = allocator.dupe(u8, entry.name) catch continue;
            const versions = self.installedVersions(allocator, name) orelse {
                allocator.free(name);
                continue;
            };

            formulae.append(allocator, .{
                .name = name,
                .versions = versions,
            }) catch {
                // Clean up on failure.
                for (versions) |v| allocator.free(v);
                allocator.free(versions);
                allocator.free(name);
                continue;
            };
        }

        mem.sort(InstalledFormula, formulae.items, {}, formulaLessThan);
        return formulae.toOwnedSlice(allocator) catch &.{};
    }
};

/// Lexicographic string comparison for sorting.
fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return mem.order(u8, a, b) == .lt;
}

/// Sort InstalledFormula by name.
fn formulaLessThan(_: void, a: InstalledFormula, b: InstalledFormula) bool {
    return mem.order(u8, a.name, b.name) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Cellar isInstalled on real cellar" {
    const cellar = Cellar.init("/opt/homebrew/Cellar");

    // A nonexistent formula should return false.
    try std.testing.expect(!cellar.isInstalled("__nonexistent_formula_xyz_42__"));
}

test "Cellar installedFormulae returns non-empty list" {
    const allocator = std.testing.allocator;
    const cellar = Cellar.init("/opt/homebrew/Cellar");

    const formulae = cellar.installedFormulae(allocator);
    defer {
        for (formulae) |f| {
            for (f.versions) |v| allocator.free(v);
            allocator.free(f.versions);
            allocator.free(f.name);
        }
        allocator.free(formulae);
    }

    // The real cellar should have at least one formula installed.
    try std.testing.expect(formulae.len > 0);

    // Verify sorted order.
    for (0..formulae.len - 1) |i| {
        const cmp = mem.order(u8, formulae[i].name, formulae[i + 1].name);
        try std.testing.expect(cmp == .lt or cmp == .eq);
    }

    // Every formula should have at least one version, and latestVersion should work.
    for (formulae) |f| {
        try std.testing.expect(f.versions.len > 0);
        try std.testing.expect(f.latestVersion().len > 0);
    }
}
