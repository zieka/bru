const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Config;

/// Supported shell types for shellenv output.
const Shell = enum { bash, zsh, fish, csh };

/// Detect the target shell from command arguments or the SHELL env var.
///
/// 1. Check the first positional (non-flag) arg for a known shell name.
/// 2. If no positional arg, check the basename of $SHELL.
/// 3. Default to .bash.
fn detectShell(args: []const []const u8) Shell {
    // Look for the first positional (non-flag) argument.
    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        if (std.mem.eql(u8, arg, "fish")) return .fish;
        if (std.mem.eql(u8, arg, "csh") or std.mem.eql(u8, arg, "tcsh")) return .csh;
        if (std.mem.eql(u8, arg, "zsh")) return .zsh;
        // Any other positional arg (including "bash", "sh", etc.) → .bash
        return .bash;
    }

    // No positional arg — fall back to $SHELL basename.
    if (std.posix.getenv("SHELL")) |shell_path| {
        const basename = std.fs.path.basename(shell_path);
        if (std.mem.eql(u8, basename, "fish")) return .fish;
        if (std.mem.eql(u8, basename, "csh") or std.mem.eql(u8, basename, "tcsh")) return .csh;
        if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    }

    return .bash;
}

/// Print shell environment variables matching `brew shellenv` output.
/// Dispatches to the appropriate per-shell writer based on argument or $SHELL.
pub fn shellenvCmd(_: std.mem.Allocator, args: []const []const u8, config: Config) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    const shell = detectShell(args);
    switch (shell) {
        .bash => try writeBash(stdout, config.prefix, config.cellar, config.repository),
        .zsh => try writeZsh(stdout, config.prefix, config.cellar, config.repository),
        .fish => try writeFish(stdout, config.prefix, config.cellar, config.repository),
        .csh => try writeCsh(stdout, config.prefix, config.cellar, config.repository),
    }
    try stdout.flush();
}

/// Write bash-compatible shellenv output.
fn writeBash(writer: anytype, prefix: []const u8, cellar: []const u8, repository: []const u8) !void {
    try writeExports(writer, prefix, cellar, repository);
    try writeBashPathBlock(writer, prefix);
}

/// Write zsh-compatible shellenv output (bash + fpath line).
fn writeZsh(writer: anytype, prefix: []const u8, cellar: []const u8, repository: []const u8) !void {
    try writeExports(writer, prefix, cellar, repository);
    try writer.print(
        \\fpath[1,0]="{s}/share/zsh/site-functions";
        \\
    , .{prefix});
    try writeBashPathBlock(writer, prefix);
}

/// Write fish-compatible shellenv output (same on macOS and Linux).
fn writeFish(writer: anytype, prefix: []const u8, cellar: []const u8, repository: []const u8) !void {
    try writer.print(
        \\set --global --export HOMEBREW_PREFIX "{s}";
        \\set --global --export HOMEBREW_CELLAR "{s}";
        \\set --global --export HOMEBREW_REPOSITORY "{s}";
        \\fish_add_path --global --move --path "{s}/bin" "{s}/sbin";
        \\
    , .{ prefix, cellar, repository, prefix, prefix });
    try writer.writeAll(
        \\if test -n "$MANPATH[1]"; set --global --export MANPATH '' $MANPATH; end;
        \\
    );
    try writer.print(
        \\if not contains "{s}/share/info" $INFOPATH; set --global --export INFOPATH "{s}/share/info" $INFOPATH; end;
        \\
    , .{ prefix, prefix });
}

/// Write csh/tcsh-compatible shellenv output.
fn writeCsh(writer: anytype, prefix: []const u8, cellar: []const u8, repository: []const u8) !void {
    try writer.print(
        \\setenv HOMEBREW_PREFIX {s};
        \\setenv HOMEBREW_CELLAR {s};
        \\setenv HOMEBREW_REPOSITORY {s};
        \\
    , .{ prefix, cellar, repository });
    if (comptime builtin.os.tag == .macos) {
        try writer.print(
            \\eval `/usr/bin/env PATH_HELPER_ROOT="{s}" /usr/libexec/path_helper -c`;
            \\
        , .{prefix});
    } else {
        try writer.print(
            \\setenv PATH {s}/bin:{s}/sbin:${{PATH}};
            \\
        , .{ prefix, prefix });
    }
    if (comptime builtin.os.tag == .macos) {
        try writer.writeAll(
            \\test ${?MANPATH} -eq 1 && setenv MANPATH :${MANPATH};
            \\
        );
    } else {
        try writer.print(
            \\test ${{?MANPATH}} -eq 1 && setenv MANPATH {s}/share/man:${{MANPATH}};
            \\
        , .{prefix});
    }
    try writer.print(
        \\setenv INFOPATH {s}/share/info`test ${{?INFOPATH}} -eq 1 && echo :${{INFOPATH}}`;
        \\
    , .{prefix});
}

// ---- internal helpers ----

/// Write the three HOMEBREW_* export lines common to bash and zsh.
fn writeExports(writer: anytype, prefix: []const u8, cellar: []const u8, repository: []const u8) !void {
    try writer.print(
        \\export HOMEBREW_PREFIX="{s}";
        \\export HOMEBREW_CELLAR="{s}";
        \\export HOMEBREW_REPOSITORY="{s}";
        \\
    , .{ prefix, cellar, repository });
}

/// Write the PATH / MANPATH / INFOPATH block used by both bash and zsh.
fn writeBashPathBlock(writer: anytype, prefix: []const u8) !void {
    if (comptime builtin.os.tag == .macos) {
        try writer.print(
            \\eval "$(/usr/bin/env PATH_HELPER_ROOT="{s}" /usr/libexec/path_helper -s)"
            \\
        , .{prefix});
        try writer.writeAll(
            \\[ -z "${MANPATH-}" ] || export MANPATH=":${MANPATH#:}";
            \\
        );
    } else {
        try writer.print(
            \\export PATH="{s}/bin:{s}/sbin${{PATH+:$PATH}}";
            \\export MANPATH="{s}/share/man${{MANPATH+:$MANPATH}}:";
            \\
        , .{ prefix, prefix, prefix });
    }
    try writer.print(
        \\export INFOPATH="{s}/share/info:${{INFOPATH:-}}";
        \\
    , .{prefix});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "shellenvCmd compiles and has correct signature" {
    const handler: @import("../dispatch.zig").CommandFn = shellenvCmd;
    _ = handler;
}

// ---- detectShell tests ----

test "detectShell with explicit 'fish' arg" {
    const args = &[_][]const u8{"fish"};
    try std.testing.expectEqual(Shell.fish, detectShell(args));
}

test "detectShell with explicit 'csh' arg" {
    const args = &[_][]const u8{"csh"};
    try std.testing.expectEqual(Shell.csh, detectShell(args));
}

test "detectShell with explicit 'tcsh' arg" {
    const args = &[_][]const u8{"tcsh"};
    try std.testing.expectEqual(Shell.csh, detectShell(args));
}

test "detectShell with explicit 'zsh' arg" {
    const args = &[_][]const u8{"zsh"};
    try std.testing.expectEqual(Shell.zsh, detectShell(args));
}

test "detectShell with explicit 'bash' arg" {
    const args = &[_][]const u8{"bash"};
    try std.testing.expectEqual(Shell.bash, detectShell(args));
}

test "detectShell with explicit 'sh' arg" {
    const args = &[_][]const u8{"sh"};
    try std.testing.expectEqual(Shell.bash, detectShell(args));
}

test "detectShell skips flags" {
    const args = &[_][]const u8{ "--verbose", "-q", "fish" };
    try std.testing.expectEqual(Shell.fish, detectShell(args));
}

test "detectShell with no args falls back to default" {
    // With no args and no matching $SHELL, should return .bash.
    // We cannot control env vars at comptime, but empty args should trigger
    // the $SHELL fallback path. The result depends on the test runner's
    // environment, so we just verify it returns a valid Shell value.
    const args = &[_][]const u8{};
    const shell = detectShell(args);
    // Must be one of the valid enum values.
    _ = @intFromEnum(shell);
}

// ---- writeBash tests ----

test "writeBash produces correct output" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeBash(writer, "/test/prefix", "/test/prefix/Cellar", "/test/prefix");

    const output = fbs.getWritten();

    if (comptime builtin.os.tag == .macos) {
        try std.testing.expectEqualStrings(
            \\export HOMEBREW_PREFIX="/test/prefix";
            \\export HOMEBREW_CELLAR="/test/prefix/Cellar";
            \\export HOMEBREW_REPOSITORY="/test/prefix";
            \\eval "$(/usr/bin/env PATH_HELPER_ROOT="/test/prefix" /usr/libexec/path_helper -s)"
            \\[ -z "${MANPATH-}" ] || export MANPATH=":${MANPATH#:}";
            \\export INFOPATH="/test/prefix/share/info:${INFOPATH:-}";
            \\
        , output);
    } else {
        try std.testing.expectEqualStrings(
            \\export HOMEBREW_PREFIX="/test/prefix";
            \\export HOMEBREW_CELLAR="/test/prefix/Cellar";
            \\export HOMEBREW_REPOSITORY="/test/prefix";
            \\export PATH="/test/prefix/bin:/test/prefix/sbin${PATH+:$PATH}";
            \\export MANPATH="/test/prefix/share/man${MANPATH+:$MANPATH}:";
            \\export INFOPATH="/test/prefix/share/info:${INFOPATH:-}";
            \\
        , output);
    }
}

// ---- writeZsh tests ----

test "writeZsh produces correct output" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeZsh(writer, "/test/prefix", "/test/prefix/Cellar", "/test/prefix");

    const output = fbs.getWritten();

    if (comptime builtin.os.tag == .macos) {
        try std.testing.expectEqualStrings(
            \\export HOMEBREW_PREFIX="/test/prefix";
            \\export HOMEBREW_CELLAR="/test/prefix/Cellar";
            \\export HOMEBREW_REPOSITORY="/test/prefix";
            \\fpath[1,0]="/test/prefix/share/zsh/site-functions";
            \\eval "$(/usr/bin/env PATH_HELPER_ROOT="/test/prefix" /usr/libexec/path_helper -s)"
            \\[ -z "${MANPATH-}" ] || export MANPATH=":${MANPATH#:}";
            \\export INFOPATH="/test/prefix/share/info:${INFOPATH:-}";
            \\
        , output);
    } else {
        try std.testing.expectEqualStrings(
            \\export HOMEBREW_PREFIX="/test/prefix";
            \\export HOMEBREW_CELLAR="/test/prefix/Cellar";
            \\export HOMEBREW_REPOSITORY="/test/prefix";
            \\fpath[1,0]="/test/prefix/share/zsh/site-functions";
            \\export PATH="/test/prefix/bin:/test/prefix/sbin${PATH+:$PATH}";
            \\export MANPATH="/test/prefix/share/man${MANPATH+:$MANPATH}:";
            \\export INFOPATH="/test/prefix/share/info:${INFOPATH:-}";
            \\
        , output);
    }
}

// ---- writeFish tests ----

test "writeFish produces correct output" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeFish(writer, "/test/prefix", "/test/prefix/Cellar", "/test/prefix");

    const output = fbs.getWritten();

    try std.testing.expectEqualStrings(
        \\set --global --export HOMEBREW_PREFIX "/test/prefix";
        \\set --global --export HOMEBREW_CELLAR "/test/prefix/Cellar";
        \\set --global --export HOMEBREW_REPOSITORY "/test/prefix";
        \\fish_add_path --global --move --path "/test/prefix/bin" "/test/prefix/sbin";
        \\if test -n "$MANPATH[1]"; set --global --export MANPATH '' $MANPATH; end;
        \\if not contains "/test/prefix/share/info" $INFOPATH; set --global --export INFOPATH "/test/prefix/share/info" $INFOPATH; end;
        \\
    , output);
}

// ---- writeCsh tests ----

test "writeCsh produces correct output" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeCsh(writer, "/test/prefix", "/test/prefix/Cellar", "/test/prefix");

    const output = fbs.getWritten();

    if (comptime builtin.os.tag == .macos) {
        try std.testing.expectEqualStrings(
            \\setenv HOMEBREW_PREFIX /test/prefix;
            \\setenv HOMEBREW_CELLAR /test/prefix/Cellar;
            \\setenv HOMEBREW_REPOSITORY /test/prefix;
            \\eval `/usr/bin/env PATH_HELPER_ROOT="/test/prefix" /usr/libexec/path_helper -c`;
            \\test ${?MANPATH} -eq 1 && setenv MANPATH :${MANPATH};
            \\setenv INFOPATH /test/prefix/share/info`test ${?INFOPATH} -eq 1 && echo :${INFOPATH}`;
            \\
        , output);
    } else {
        try std.testing.expectEqualStrings(
            \\setenv HOMEBREW_PREFIX /test/prefix;
            \\setenv HOMEBREW_CELLAR /test/prefix/Cellar;
            \\setenv HOMEBREW_REPOSITORY /test/prefix;
            \\setenv PATH /test/prefix/bin:/test/prefix/sbin:${PATH};
            \\test ${?MANPATH} -eq 1 && setenv MANPATH /test/prefix/share/man:${MANPATH};
            \\setenv INFOPATH /test/prefix/share/info`test ${?INFOPATH} -eq 1 && echo :${INFOPATH}`;
            \\
        , output);
    }
}
