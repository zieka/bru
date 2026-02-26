const std = @import("std");

/// Output provides brew-compatible formatted output with optional ANSI colors.
///
/// Each method creates its own buffered writer from the stored file handle,
/// matching the pattern used throughout the codebase (see fallback.zig).
pub const Output = struct {
    file: std.fs.File,
    use_color: bool,

    /// Initialize an Output targeting stdout.
    /// Color is enabled when no_color is false AND stdout is a tty.
    pub fn init(no_color: bool) Output {
        const file = std.fs.File.stdout();
        return .{
            .file = file,
            .use_color = !no_color and std.posix.isatty(file.handle),
        };
    }

    /// Initialize an Output targeting stderr.
    /// Color is enabled when no_color is false AND stderr is a tty.
    pub fn initErr(no_color: bool) Output {
        const file = std.fs.File.stderr();
        return .{
            .file = file,
            .use_color = !no_color and std.posix.isatty(file.handle),
        };
    }

    /// Write formatted text to the output.
    pub fn print(self: Output, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        const writer = &w.interface;
        writer.print(fmt, args) catch {};
        writer.flush() catch {};
    }

    /// Print a brew-style section header: "==> Title\n"
    /// With color: blue "==>" + reset + space + bold title + reset + newline.
    /// Without color: plain "==> Title\n".
    pub fn section(self: Output, title: []const u8) void {
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        const writer = &w.interface;

        if (self.use_color) {
            writer.print("\x1b[34m==>\x1b[0m \x1b[1m{s}\x1b[0m\n", .{title}) catch {};
        } else {
            writer.print("==> {s}\n", .{title}) catch {};
        }
        writer.flush() catch {};
    }

    /// Print a warning message: "Warning: msg\n"
    /// With color: yellow "Warning:" prefix.
    pub fn warn(self: Output, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        const writer = &w.interface;

        if (self.use_color) {
            writer.writeAll("\x1b[33mWarning\x1b[0m: ") catch {};
        } else {
            writer.writeAll("Warning: ") catch {};
        }
        writer.print(fmt, args) catch {};
        writer.writeAll("\n") catch {};
        writer.flush() catch {};
    }

    /// Print an error message: "Error: msg\n"
    /// With color: red "Error:" prefix.
    /// Note: This writes to whatever file handle the Output was initialized with.
    /// Use Output.initErr() to target stderr.
    pub fn err(self: Output, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        var w = self.file.writer(&buf);
        const writer = &w.interface;

        if (self.use_color) {
            writer.writeAll("\x1b[31mError\x1b[0m: ") catch {};
        } else {
            writer.writeAll("Error: ") catch {};
        }
        writer.print(fmt, args) catch {};
        writer.writeAll("\n") catch {};
        writer.flush() catch {};
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Output init respects no_color" {
    const out = Output.init(true);
    try std.testing.expect(!out.use_color);
}

test "Output initErr respects no_color" {
    const out = Output.initErr(true);
    try std.testing.expect(!out.use_color);
}
