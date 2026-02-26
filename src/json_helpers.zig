const std = @import("std");

/// Write a JSON-escaped string with surrounding quotes to the writer.
///
/// Escapes the critical characters: double-quote, backslash, newline, carriage
/// return, and tab.  All other bytes are passed through verbatim.
pub fn writeJsonStr(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeJsonStr escapes special characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeJsonStr(writer, "hello");
    try std.testing.expectEqualStrings("\"hello\"", fbs.getWritten());

    fbs.reset();
    try writeJsonStr(writer, "say \"hi\"");
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", fbs.getWritten());

    fbs.reset();
    try writeJsonStr(writer, "a\\b");
    try std.testing.expectEqualStrings("\"a\\\\b\"", fbs.getWritten());

    fbs.reset();
    try writeJsonStr(writer, "line1\nline2");
    try std.testing.expectEqualStrings("\"line1\\nline2\"", fbs.getWritten());

    fbs.reset();
    try writeJsonStr(writer, "col1\tcol2");
    try std.testing.expectEqualStrings("\"col1\\tcol2\"", fbs.getWritten());

    fbs.reset();
    try writeJsonStr(writer, "cr\rhere");
    try std.testing.expectEqualStrings("\"cr\\rhere\"", fbs.getWritten());
}

test "writeJsonStr escapes control characters below 0x20" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // NUL byte
    try writeJsonStr(writer, "\x00");
    try std.testing.expectEqualStrings("\"\\u0000\"", fbs.getWritten());

    fbs.reset();
    // BEL (0x07)
    try writeJsonStr(writer, "\x07");
    try std.testing.expectEqualStrings("\"\\u0007\"", fbs.getWritten());

    fbs.reset();
    // Mixed: control char + normal text
    try writeJsonStr(writer, "a\x01b");
    try std.testing.expectEqualStrings("\"a\\u0001b\"", fbs.getWritten());
}

test "writeJsonStr handles empty string" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeJsonStr(writer, "");
    try std.testing.expectEqualStrings("\"\"", fbs.getWritten());
}
