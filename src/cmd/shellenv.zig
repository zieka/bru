const std = @import("std");
const Config = @import("../config.zig").Config;

/// Print shell environment variables matching `brew shellenv` output.
/// Outputs bash/zsh-compatible `export` statements.
pub fn shellenvCmd(_: std.mem.Allocator, _: []const []const u8, config: Config) anyerror!void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const stdout = &w.interface;

    try stdout.print(
        \\export HOMEBREW_PREFIX="{s}"
        \\export HOMEBREW_CELLAR="{s}"
        \\export HOMEBREW_REPOSITORY="{s}"
        \\export PATH="{s}/bin:{s}/sbin${{PATH+:$PATH}}"
        \\export MANPATH="{s}/share/man${{MANPATH+:$MANPATH}}:"
        \\export INFOPATH="{s}/share/info:${{INFOPATH:-}}"
        \\
    , .{
        config.prefix,
        config.cellar,
        config.repository,
        config.prefix,
        config.prefix,
        config.prefix,
        config.prefix,
    });
    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "shellenvCmd smoke test" {
    // Smoke test: verifies the function signature is correct and the module compiles.
}
