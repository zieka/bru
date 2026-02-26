const std = @import("std");
const mem = std.mem;

pub const PkgVersion = struct {
    version: []const u8,
    revision: u32,

    /// Parse a version string like "1.2.3" or "3.6.1_1".
    /// Finds the last underscore; if the remainder is a valid integer,
    /// splits into version + revision. Otherwise the whole string is the
    /// version with revision 0.
    pub fn parse(s: []const u8) PkgVersion {
        if (mem.lastIndexOfScalar(u8, s, '_')) |pos| {
            const tail = s[pos + 1 ..];
            if (std.fmt.parseInt(u32, tail, 10)) |rev| {
                return .{ .version = s[0..pos], .revision = rev };
            } else |_| {}
        }
        return .{ .version = s, .revision = 0 };
    }

    /// Compare two PkgVersions segment-by-segment.
    /// Each dot-delimited segment is compared numerically if both sides
    /// parse as integers, otherwise lexically.  If the version parts are
    /// equal the revision numbers break the tie.
    pub fn order(self: PkgVersion, other: PkgVersion) std.math.Order {
        var self_iter = mem.splitScalar(u8, self.version, '.');
        var other_iter = mem.splitScalar(u8, other.version, '.');

        while (true) {
            const a_seg = self_iter.next();
            const b_seg = other_iter.next();

            // Both exhausted — versions are equal so far.
            if (a_seg == null and b_seg == null) break;

            // Treat a missing segment as "0".
            const a = a_seg orelse "0";
            const b = b_seg orelse "0";

            const cmp = segmentOrder(a, b);
            if (cmp != .eq) return cmp;
        }

        return std.math.order(self.revision, other.revision);
    }

    /// Format into a caller-provided buffer.
    /// Returns "version" when revision is 0, "version_revision" otherwise.
    pub fn format(self: PkgVersion, buf: []u8) []const u8 {
        if (self.revision == 0) {
            if (buf.len < self.version.len) return self.version;
            @memcpy(buf[0..self.version.len], self.version);
            return buf[0..self.version.len];
        }

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        writer.print("{s}_{d}", .{ self.version, self.revision }) catch
            return self.version;
        return stream.getWritten();
    }
};

/// Compare two version segments.  Try numeric comparison first;
/// if either side is not a valid integer, fall back to lexical ordering.
fn segmentOrder(a: []const u8, b: []const u8) std.math.Order {
    const a_num = std.fmt.parseInt(u64, a, 10) catch null;
    const b_num = std.fmt.parseInt(u64, b, 10) catch null;

    if (a_num != null and b_num != null) {
        return std.math.order(a_num.?, b_num.?);
    }

    return mem.order(u8, a, b);
}

// ---------- tests ----------

test "parse plain version" {
    const v = PkgVersion.parse("1.2.3");
    try std.testing.expectEqualStrings("1.2.3", v.version);
    try std.testing.expectEqual(@as(u32, 0), v.revision);
}

test "parse version with revision" {
    const v = PkgVersion.parse("3.6.1_1");
    try std.testing.expectEqualStrings("3.6.1", v.version);
    try std.testing.expectEqual(@as(u32, 1), v.revision);
}

test "compare 1.2.3 < 1.2.4" {
    const a = PkgVersion.parse("1.2.3");
    const b = PkgVersion.parse("1.2.4");
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "compare 1.2.3 < 1.2.3_1" {
    const a = PkgVersion.parse("1.2.3");
    const b = PkgVersion.parse("1.2.3_1");
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "compare 2.0.0 == 2.0.0" {
    const a = PkgVersion.parse("2.0.0");
    const b = PkgVersion.parse("2.0.0");
    try std.testing.expectEqual(std.math.Order.eq, a.order(b));
}

test "compare 2.0.0 < 10.0.0 numeric" {
    const a = PkgVersion.parse("2.0.0");
    const b = PkgVersion.parse("10.0.0");
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "format version with revision" {
    const v = PkgVersion{ .version = "3.6.1", .revision = 1 };
    var buf: [64]u8 = undefined;
    const result = v.format(&buf);
    try std.testing.expectEqualStrings("3.6.1_1", result);
}

test "format version without revision" {
    const v = PkgVersion{ .version = "1.0.0", .revision = 0 };
    var buf: [64]u8 = undefined;
    const result = v.format(&buf);
    try std.testing.expectEqualStrings("1.0.0", result);
}
