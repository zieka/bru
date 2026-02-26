const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    prefix: []const u8,
    cellar: []const u8,
    caskroom: []const u8,
    cache: []const u8,
    brew_file: ?[]const u8,
    no_color: bool,
    no_emoji: bool,
    verbose: bool,
    debug: bool,
    quiet: bool,

    allocator: Allocator,

    /// Platform-appropriate default prefix, determined at comptime.
    pub const default_prefix: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => if (builtin.os.tag == .macos) "/opt/homebrew" else "/usr/local",
        else => "/usr/local",
    };

    /// Platform-appropriate default cache suffix appended to HOME.
    const default_cache_suffix: []const u8 = switch (builtin.os.tag) {
        .macos => "/Library/Caches/Homebrew",
        .linux => "/.cache/Homebrew",
        else => "/.cache/Homebrew",
    };

    /// Return true if the named env var is set and has a non-empty value.
    fn envBool(name: []const u8) bool {
        const val = std.posix.getenv(name) orelse return false;
        return val.len > 0;
    }

    /// Read an env var, returning its value or null.
    fn getEnv(name: []const u8) ?[]const u8 {
        return std.posix.getenv(name);
    }

    /// Load configuration from environment variables with platform defaults.
    pub fn load(allocator: Allocator) !Config {
        const prefix = getEnv("HOMEBREW_PREFIX") orelse default_prefix;

        const cellar = getEnv("HOMEBREW_CELLAR") orelse
            try std.fmt.allocPrint(allocator, "{s}/Cellar", .{prefix});

        const caskroom = getEnv("HOMEBREW_CASKROOM") orelse
            try std.fmt.allocPrint(allocator, "{s}/Caskroom", .{prefix});

        const cache = blk: {
            if (getEnv("HOMEBREW_CACHE")) |c| break :blk c;
            const home = getEnv("HOME") orelse "/tmp";
            break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, default_cache_suffix });
        };

        return Config{
            .prefix = prefix,
            .cellar = cellar,
            .caskroom = caskroom,
            .cache = cache,
            .brew_file = getEnv("HOMEBREW_BREW_FILE"),
            .no_color = envBool("HOMEBREW_NO_COLOR") or envBool("NO_COLOR"),
            .no_emoji = envBool("HOMEBREW_NO_EMOJI"),
            .verbose = false,
            .debug = false,
            .quiet = false,
            .allocator = allocator,
        };
    }

    /// Free any allocator-owned strings. Env-sourced strings are static
    /// and must not be freed; only strings built via allocPrint need freeing.
    pub fn deinit(self: *Config) void {
        // Free cellar if it was allocated (not from env)
        if (std.posix.getenv("HOMEBREW_CELLAR") == null) {
            self.allocator.free(self.cellar);
        }
        // Free caskroom if it was allocated (not from env)
        if (std.posix.getenv("HOMEBREW_CASKROOM") == null) {
            self.allocator.free(self.caskroom);
        }
        // Free cache if it was allocated (not from env)
        if (std.posix.getenv("HOMEBREW_CACHE") == null) {
            self.allocator.free(self.cache);
        }
    }

    /// Attempt to load a keg path. Returns null if the path does not exist.
    pub fn loadFromKeg(self: Config, name: []const u8) ?[]const u8 {
        _ = self;
        _ = name;
        // Stub: would check {cellar}/{name} exists on disk
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "config defaults on arm64 macOS" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    var cfg = try Config.load(allocator);
    defer cfg.deinit();

    // Verify the comptime default prefix for this architecture
    try std.testing.expectEqualStrings(Config.default_prefix, cfg.prefix);

    // Cellar should be {prefix}/Cellar when HOMEBREW_CELLAR is not set
    if (std.posix.getenv("HOMEBREW_CELLAR") == null) {
        const expected_cellar = try std.fmt.allocPrint(allocator, "{s}/Cellar", .{cfg.prefix});
        defer allocator.free(expected_cellar);
        try std.testing.expectEqualStrings(expected_cellar, cfg.cellar);
    }

    // no_color should be false unless env vars are set
    if (std.posix.getenv("HOMEBREW_NO_COLOR") == null and std.posix.getenv("NO_COLOR") == null) {
        try std.testing.expect(!cfg.no_color);
    }
}

test "config loadFromKeg returns null for nonexistent" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    var cfg = try Config.load(allocator);
    defer cfg.deinit();

    const result = cfg.loadFromKeg("nonexistent-package-xyz");
    try std.testing.expect(result == null);
}
