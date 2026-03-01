const std = @import("std");
const Index = @import("index.zig").Index;

/// Candidate with edit distance for sorting.
const Candidate = struct {
    name: []const u8,
    dist: usize,
};

/// Find up to `max_results` formula names closest to `query` by edit distance.
/// Returns names with distance <= max_distance and distance > 0 (excludes exact matches).
/// Caller owns the returned slice (inner strings point into index data).
pub fn findSimilar(
    idx: *const Index,
    allocator: std.mem.Allocator,
    query: []const u8,
    max_results: usize,
    max_distance: usize,
) ![]const []const u8 {
    var candidates = std.ArrayList(Candidate){};
    defer candidates.deinit(allocator);

    const count = idx.entryCount();
    for (0..count) |i| {
        const entry = idx.getEntryByIndex(@intCast(i));
        const name = idx.getString(entry.name_offset);
        const dist = editDistance(query, name);
        if (dist > 0 and dist <= max_distance) {
            try candidates.append(allocator, .{ .name = name, .dist = dist });
        }
    }

    // Sort by distance, then alphabetically for ties
    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);

    const result_len = @min(candidates.items.len, max_results);
    const result = try allocator.alloc([]const u8, result_len);
    for (0..result_len) |i| {
        result[i] = candidates.items[i].name;
    }
    return result;
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    if (a.dist != b.dist) return a.dist < b.dist;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Return true when every character in `query` appears in `name` in order
/// (but not necessarily consecutively). For example, "bat" is a subsequence
/// of "mongodb-atlas-cli" because the characters b-a-t appear in that order.
pub fn isSubsequence(query: []const u8, name: []const u8) bool {
    var qi: usize = 0;
    for (name) |c| {
        if (qi < query.len and c == query[qi]) {
            qi += 1;
        }
    }
    return qi == query.len;
}

/// Levenshtein edit distance. Returns 999 for very long strings to avoid allocations.
pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return 999;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    // Use two rows of a DP table on the stack.
    var prev_row: [65]usize = undefined;
    var curr_row: [65]usize = undefined;

    for (0..b.len + 1) |j| {
        prev_row[j] = j;
    }

    for (0..a.len) |i| {
        curr_row[0] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            curr_row[j + 1] = @min(
                @min(curr_row[j] + 1, prev_row[j + 1] + 1),
                prev_row[j] + cost,
            );
        }
        @memcpy(prev_row[0 .. b.len + 1], curr_row[0 .. b.len + 1]);
    }

    return prev_row[b.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isSubsequence basic cases" {
    try std.testing.expect(isSubsequence("bat", "mongodb-atlas-cli"));
    try std.testing.expect(isSubsequence("bat", "bat"));
    try std.testing.expect(isSubsequence("bat", "bat-extras"));
    try std.testing.expect(isSubsequence("bat", "combinator"));
    try std.testing.expect(!isSubsequence("bat", "tab"));
    try std.testing.expect(!isSubsequence("bat", "beta"));
    try std.testing.expect(isSubsequence("", "anything"));
    try std.testing.expect(!isSubsequence("abc", ""));
    try std.testing.expect(isSubsequence("", ""));
}

test "editDistance basic cases" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("bat", "bat"));
    try std.testing.expectEqual(@as(usize, 2), editDistance("bat", "bta"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("bat", "ba"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("bat", "bats"));
    try std.testing.expectEqual(@as(usize, 3), editDistance("abc", "xyz"));
    try std.testing.expectEqual(@as(usize, 0), editDistance("", ""));
    try std.testing.expectEqual(@as(usize, 3), editDistance("", "abc"));
}

test "findSimilar returns close matches" {
    const allocator = std.testing.allocator;
    const formula_mod = @import("formula.zig");

    const formulae = [_]formula_mod.FormulaInfo{
        .{
            .name = "bat",
            .full_name = "bat",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "0.26.1",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .has_head = false,
            .caveats = "",
            .dependencies = &.{},
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
        .{
            .name = "cat",
            .full_name = "cat",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "1.0",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .has_head = false,
            .caveats = "",
            .dependencies = &.{},
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
        .{
            .name = "zzz",
            .full_name = "zzz",
            .desc = "",
            .homepage = "",
            .license = "",
            .version = "1.0",
            .revision = 0,
            .tap = "",
            .keg_only = false,
            .deprecated = false,
            .disabled = false,
            .has_head = false,
            .caveats = "",
            .dependencies = &.{},
            .build_dependencies = &.{},
            .bottle_root_url = "",
            .bottle_sha256 = "",
            .bottle_cellar = "",
        },
    };

    var idx = try Index.build(allocator, &formulae);
    defer idx.deinit();

    const similar = try findSimilar(&idx, allocator, "bta", 3, 2);
    defer allocator.free(similar);

    // "bat" has distance 2 from "bta" (transposition), "cat" has distance 2
    try std.testing.expect(similar.len >= 1);
    try std.testing.expectEqualStrings("bat", similar[0]);
}
