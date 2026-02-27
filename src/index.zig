const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const Allocator = mem.Allocator;
const formula_mod = @import("formula.zig");
const FormulaInfo = formula_mod.FormulaInfo;

// ---------------------------------------------------------------------------
// Binary index structures (C ABI layout, no padding)
// ---------------------------------------------------------------------------

pub const IndexHeader = extern struct {
    magic: [4]u8 = .{ 'B', 'R', 'U', 'I' },
    version: u32 = 1,
    source_hash: [32]u8 = .{0} ** 32,
    entry_count: u32 = 0,
    _pad: [4]u8 = .{0} ** 4,
    hash_table_offset: u64 = 0,
    entries_offset: u64 = 0,
    strings_offset: u64 = 0,
};

pub const IndexEntry = extern struct {
    name_offset: u32 = 0,
    full_name_offset: u32 = 0,
    desc_offset: u32 = 0,
    version_offset: u32 = 0,
    revision: u16 = 0,
    flags: u16 = 0,
    deps_offset: u32 = 0,
    build_deps_offset: u32 = 0,
    tap_offset: u32 = 0,
    homepage_offset: u32 = 0,
    license_offset: u32 = 0,
    bottle_root_url_offset: u32 = 0,
    bottle_sha256_offset: u32 = 0,
    bottle_cellar_offset: u32 = 0,
};

pub const HashBucket = extern struct {
    string_offset: u32 = 0,
    entry_index: u32 = std.math.maxInt(u32),
};

// ---------------------------------------------------------------------------
// FNV-1a hash
// ---------------------------------------------------------------------------

fn fnvHash(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |byte| {
        h ^= byte;
        h *%= 16777619;
    }
    return h;
}

// ---------------------------------------------------------------------------
// String table builder (helper used only during build)
// ---------------------------------------------------------------------------

const StringTableBuilder = struct {
    data: std.ArrayList(u8) = .{},

    fn deinit(self: *StringTableBuilder, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    /// Ensure offset 0 is the empty string (single null byte).
    fn ensureReserved(self: *StringTableBuilder, allocator: Allocator) !void {
        if (self.data.items.len == 0) {
            try self.data.append(allocator, 0);
        }
    }

    /// Add a null-terminated string. Returns the offset relative to string table start.
    fn addString(self: *StringTableBuilder, allocator: Allocator, s: []const u8) !u32 {
        try self.ensureReserved(allocator);
        if (s.len == 0) return 0; // offset 0 is the empty string
        const offset: u32 = @intCast(self.data.items.len);
        try self.data.appendSlice(allocator, s);
        try self.data.append(allocator, 0); // null terminator
        return offset;
    }

    /// Add a length-prefixed string list. Returns the offset relative to string table start.
    /// Format: u32 count, then for each: u32 length, bytes (no null terminator per item).
    fn addStringList(self: *StringTableBuilder, allocator: Allocator, list: []const []const u8) !u32 {
        try self.ensureReserved(allocator);
        if (list.len == 0) return 0; // offset 0 means empty
        const offset: u32 = @intCast(self.data.items.len);
        // Write count as little-endian u32
        const count: u32 = @intCast(list.len);
        try self.data.appendSlice(allocator, &mem.toBytes(mem.nativeToLittle(u32, count)));
        for (list) |item| {
            const len: u32 = @intCast(item.len);
            try self.data.appendSlice(allocator, &mem.toBytes(mem.nativeToLittle(u32, len)));
            try self.data.appendSlice(allocator, item);
        }
        return offset;
    }
};

// ---------------------------------------------------------------------------
// Index -- the main public type
// ---------------------------------------------------------------------------

pub const Index = struct {
    data: []const u8,
    allocator: Allocator,

    /// Build a binary index from a slice of FormulaInfo.
    pub fn build(allocator: Allocator, formulae: []const FormulaInfo) !Index {
        // ------------------------------------------------------------------
        // 1. Build string table and collect per-formula string offsets.
        // ------------------------------------------------------------------
        var stb = StringTableBuilder{};
        defer stb.deinit(allocator);

        const entries = try allocator.alloc(IndexEntry, formulae.len);
        defer allocator.free(entries);

        for (formulae, 0..) |f, i| {
            var flags: u16 = 0;
            if (f.keg_only) flags |= 1;
            if (f.deprecated) flags |= 2;
            if (f.disabled) flags |= 4;
            if (f.bottle_root_url.len > 0) flags |= 8;

            entries[i] = IndexEntry{
                .name_offset = try stb.addString(allocator, f.name),
                .full_name_offset = try stb.addString(allocator, f.full_name),
                .desc_offset = try stb.addString(allocator, f.desc),
                .version_offset = try stb.addString(allocator, f.version),
                .revision = @intCast(f.revision),
                .flags = flags,
                .deps_offset = try stb.addStringList(allocator, f.dependencies),
                .build_deps_offset = try stb.addStringList(allocator, f.build_dependencies),
                .tap_offset = try stb.addString(allocator, f.tap),
                .homepage_offset = try stb.addString(allocator, f.homepage),
                .license_offset = try stb.addString(allocator, f.license),
                .bottle_root_url_offset = try stb.addString(allocator, f.bottle_root_url),
                .bottle_sha256_offset = try stb.addString(allocator, f.bottle_sha256),
                .bottle_cellar_offset = try stb.addString(allocator, f.bottle_cellar),
            };
        }

        // ------------------------------------------------------------------
        // 2. Build the hash table (open addressing, 2x capacity, linear probing).
        // ------------------------------------------------------------------
        const bucket_count: u32 = if (formulae.len == 0) 2 else @intCast(formulae.len * 2);
        const hash_table = try allocator.alloc(HashBucket, bucket_count);
        defer allocator.free(hash_table);

        // Initialise all buckets as empty.
        for (hash_table) |*b| {
            b.* = HashBucket{};
        }

        // Insert each formula name.
        for (formulae, 0..) |f, i| {
            const h = fnvHash(f.name);
            var slot = h % bucket_count;
            while (hash_table[slot].entry_index != std.math.maxInt(u32)) {
                slot = (slot + 1) % bucket_count;
            }
            hash_table[slot] = HashBucket{
                .string_offset = entries[i].name_offset,
                .entry_index = @intCast(i),
            };
        }

        // ------------------------------------------------------------------
        // 3. Calculate layout sizes.
        // ------------------------------------------------------------------
        const header_size: u64 = @sizeOf(IndexHeader);
        const hash_table_size: u64 = @as(u64, bucket_count) * @sizeOf(HashBucket);
        const entries_size: u64 = @as(u64, @intCast(formulae.len)) * @sizeOf(IndexEntry);
        const strings_size: u64 = stb.data.items.len;

        const hash_table_offset = header_size;
        const entries_offset = hash_table_offset + hash_table_size;
        const strings_offset = entries_offset + entries_size;
        const total_size: usize = @intCast(strings_offset + strings_size);

        // ------------------------------------------------------------------
        // 4. Allocate buffer and copy everything in.
        // ------------------------------------------------------------------
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);

        // Header
        var header = IndexHeader{
            .entry_count = @intCast(formulae.len),
            .hash_table_offset = hash_table_offset,
            .entries_offset = entries_offset,
            .strings_offset = strings_offset,
        };
        const header_bytes = mem.asBytes(&header);
        @memcpy(buf[0..header_bytes.len], header_bytes);

        // Hash table
        const ht_bytes = mem.sliceAsBytes(hash_table);
        @memcpy(buf[@intCast(hash_table_offset)..][0..ht_bytes.len], ht_bytes);

        // Entries
        const entry_bytes = mem.sliceAsBytes(entries);
        @memcpy(buf[@intCast(entries_offset)..][0..entry_bytes.len], entry_bytes);

        // String table
        @memcpy(buf[@intCast(strings_offset)..][0..stb.data.items.len], stb.data.items);

        return Index{
            .data = buf,
            .allocator = allocator,
        };
    }

    /// Free the index buffer.
    pub fn deinit(self: *Index) void {
        self.allocator.free(self.data);
        self.data = &.{};
    }

    // ------------------------------------------------------------------
    // Accessors
    // ------------------------------------------------------------------

    fn getHeader(self: *const Index) IndexHeader {
        return mem.bytesToValue(IndexHeader, self.data[0..@sizeOf(IndexHeader)]);
    }

    /// Number of formula entries in the index.
    pub fn entryCount(self: *const Index) u32 {
        return self.getHeader().entry_count;
    }

    /// Get an entry by its zero-based index in the entries array.
    pub fn getEntryByIndex(self: *const Index, idx: u32) IndexEntry {
        const header = self.getHeader();
        const off: usize = @intCast(header.entries_offset + @as(u64, idx) * @sizeOf(IndexEntry));
        return mem.bytesToValue(IndexEntry, self.data[off..][0..@sizeOf(IndexEntry)]);
    }

    /// Retrieve a null-terminated string from the string table.
    /// `offset` is relative to the start of the string table.
    pub fn getString(self: *const Index, offset: u32) []const u8 {
        if (offset == 0) {
            // Offset 0 is the reserved empty string.
            return "";
        }
        const header = self.getHeader();
        const abs: usize = @intCast(header.strings_offset + offset);
        const remaining = self.data[abs..];
        // Find the null terminator.
        const end = mem.indexOfScalar(u8, remaining, 0) orelse remaining.len;
        return remaining[0..end];
    }

    /// Retrieve a length-prefixed string list from the string table.
    /// Caller owns the returned slice (but NOT the inner []const u8; those point into index data).
    pub fn getStringList(self: *const Index, allocator: Allocator, offset: u32) ![]const []const u8 {
        if (offset == 0) return try allocator.alloc([]const u8, 0);
        const header = self.getHeader();
        var pos: usize = @intCast(header.strings_offset + offset);
        const count = mem.readInt(u32, self.data[pos..][0..4], .little);
        pos += 4;
        const result = try allocator.alloc([]const u8, count);
        for (0..count) |i| {
            const len = mem.readInt(u32, self.data[pos..][0..4], .little);
            pos += 4;
            result[i] = self.data[pos..][0..len];
            pos += len;
        }
        return result;
    }

    /// Look up a formula by name. Returns the IndexEntry if found, null otherwise.
    pub fn lookup(self: *const Index, name: []const u8) ?IndexEntry {
        const header = self.getHeader();
        if (header.entry_count == 0) return null;
        const bucket_count: u32 = header.entry_count * 2;
        const h = fnvHash(name);
        var slot = h % bucket_count;

        while (true) {
            const bucket_off: usize = @intCast(header.hash_table_offset + @as(u64, slot) * @sizeOf(HashBucket));
            const bucket = mem.bytesToValue(HashBucket, self.data[bucket_off..][0..@sizeOf(HashBucket)]);
            if (bucket.entry_index == std.math.maxInt(u32)) {
                return null; // empty bucket -- not found
            }
            // Compare the name string at that offset.
            const candidate = self.getString(bucket.string_offset);
            if (mem.eql(u8, candidate, name)) {
                return self.getEntryByIndex(bucket.entry_index);
            }
            slot = (slot + 1) % bucket_count;
        }
    }

    // ------------------------------------------------------------------
    // Persistence
    // ------------------------------------------------------------------

    /// Release an mmap'd index (from openFromDisk). Does not use the allocator.
    fn munmapIndex(idx: Index) void {
        const aligned: []align(std.heap.page_size_min) const u8 = @alignCast(idx.data);
        posix.munmap(aligned);
    }

    /// Write the index data to a file, creating or overwriting.
    pub fn writeToDisk(self: *const Index, path: []const u8) !void {
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(self.data);
    }

    /// Open a previously-written index from disk via mmap.
    /// Returns null if the file does not exist or is too small to contain a header.
    /// The returned Index has mmap'd data; call munmapAndDeinit() to release it.
    pub fn openFromDisk(path: []const u8) !?Index {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;
        if (size < @sizeOf(IndexHeader)) return null;

        const mapped = try posix.mmap(
            null,
            size,
            posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        // mapped is []align(page_size) u8. Coerce to []const u8 for storage.
        const data: []const u8 = mapped;

        // Verify magic bytes.
        if (!mem.eql(u8, data[0..4], "BRUI")) {
            posix.munmap(mapped);
            return null;
        }

        return Index{
            .data = data,
            .allocator = undefined, // mmap'd; caller should not use allocator
        };
    }

    /// Load an existing index from disk, or build one from the JWS cache.
    /// Rebuilds if the JWS source file is newer than the cached index.
    pub fn loadOrBuild(allocator: Allocator, cache_dir: []const u8) !Index {
        // 1. Try loading existing index from disk.
        var idx_path_buf: [1024]u8 = undefined;
        const idx_path = std.fmt.bufPrint(&idx_path_buf, "{s}/api/formula.bru.idx", .{cache_dir}) catch
            return error.PathTooLong;

        var jws_path_buf: [1024]u8 = undefined;
        const jws_path = std.fmt.bufPrint(&jws_path_buf, "{s}/api/formula.jws.json", .{cache_dir}) catch
            return error.PathTooLong;

        if (try openFromDisk(idx_path)) |idx| {
            // Check if the JWS source is newer than the cached index.
            const stale = blk: {
                const idx_file = std.fs.openFileAbsolute(idx_path, .{}) catch break :blk true;
                defer idx_file.close();
                const jws_file = std.fs.openFileAbsolute(jws_path, .{}) catch break :blk false;
                defer jws_file.close();
                const idx_stat = idx_file.stat() catch break :blk true;
                const jws_stat = jws_file.stat() catch break :blk false;
                break :blk jws_stat.mtime > idx_stat.mtime;
            };
            if (!stale) return idx;
            // Stale: unmap and rebuild below.
            munmapIndex(idx);
        }

        // 2. Read the JWS file.
        const jws_file = try std.fs.openFileAbsolute(jws_path, .{});
        defer jws_file.close();

        const jws_bytes = try jws_file.readToEndAlloc(allocator, 64 * 1024 * 1024);
        defer allocator.free(jws_bytes);

        // 3. Parse JWS envelope to get the payload string.
        const JwsEnvelope = struct { payload: []const u8 };
        const jws_parsed = try std.json.parseFromSlice(JwsEnvelope, allocator, jws_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer jws_parsed.deinit();

        const payload_str = jws_parsed.value.payload;

        // 4. Parse the payload into FormulaInfo array.
        const formulae = try formula_mod.parseFormulaJson(allocator, payload_str);
        defer {
            for (formulae) |f| formula_mod.freeFormula(allocator, f);
            allocator.free(formulae);
        }

        // 5. Build the index.
        var idx = try Index.build(allocator, formulae);

        // 6. Write to disk (best-effort).
        idx.writeToDisk(idx_path) catch {};

        return idx;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "build and lookup" {
    const allocator = std.testing.allocator;

    const deps = [_][]const u8{ "libgit2", "oniguruma" };
    const build_deps = [_][]const u8{ "pkgconf", "rust" };

    const formula = FormulaInfo{
        .name = "bat",
        .full_name = "bat",
        .desc = "Clone of cat(1) with syntax highlighting",
        .homepage = "https://github.com/sharkdp/bat",
        .license = "Apache-2.0",
        .version = "0.26.1",
        .revision = 3,
        .tap = "homebrew/core",
        .keg_only = false,
        .deprecated = false,
        .disabled = false,
        .dependencies = &deps,
        .build_dependencies = &build_deps,
        .bottle_root_url = "https://ghcr.io/v2/homebrew/core",
        .bottle_sha256 = "abc123",
        .bottle_cellar = ":any",
    };

    const formulae = [_]FormulaInfo{formula};

    var idx = try Index.build(allocator, &formulae);
    defer idx.deinit();

    // Verify entry count.
    try std.testing.expectEqual(@as(u32, 1), idx.entryCount());

    // Lookup by name.
    const entry = idx.lookup("bat") orelse return error.TestUnexpectedResult;

    // Verify string fields.
    try std.testing.expectEqualStrings("bat", idx.getString(entry.name_offset));
    try std.testing.expectEqualStrings("bat", idx.getString(entry.full_name_offset));
    try std.testing.expectEqualStrings("Clone of cat(1) with syntax highlighting", idx.getString(entry.desc_offset));
    try std.testing.expectEqualStrings("0.26.1", idx.getString(entry.version_offset));
    try std.testing.expectEqualStrings("homebrew/core", idx.getString(entry.tap_offset));
    try std.testing.expectEqualStrings("https://github.com/sharkdp/bat", idx.getString(entry.homepage_offset));
    try std.testing.expectEqualStrings("Apache-2.0", idx.getString(entry.license_offset));
    try std.testing.expectEqualStrings("https://ghcr.io/v2/homebrew/core", idx.getString(entry.bottle_root_url_offset));
    try std.testing.expectEqualStrings("abc123", idx.getString(entry.bottle_sha256_offset));
    try std.testing.expectEqualStrings(":any", idx.getString(entry.bottle_cellar_offset));

    // Verify revision and flags.
    try std.testing.expectEqual(@as(u16, 3), entry.revision);
    // bottle_available flag (bit 3) should be set since bottle_root_url is non-empty.
    try std.testing.expect(entry.flags & 8 != 0);
    // keg_only, deprecated, disabled should be unset.
    try std.testing.expectEqual(@as(u16, 0), entry.flags & 7);

    // Verify dependencies string list.
    const dep_list = try idx.getStringList(allocator, entry.deps_offset);
    defer allocator.free(dep_list);
    try std.testing.expectEqual(@as(usize, 2), dep_list.len);
    try std.testing.expectEqualStrings("libgit2", dep_list[0]);
    try std.testing.expectEqualStrings("oniguruma", dep_list[1]);

    // Verify build dependencies string list.
    const bdep_list = try idx.getStringList(allocator, entry.build_deps_offset);
    defer allocator.free(bdep_list);
    try std.testing.expectEqual(@as(usize, 2), bdep_list.len);
    try std.testing.expectEqualStrings("pkgconf", bdep_list[0]);
    try std.testing.expectEqualStrings("rust", bdep_list[1]);

    // getEntryByIndex should return the same entry.
    const entry_by_idx = idx.getEntryByIndex(0);
    try std.testing.expectEqual(entry.name_offset, entry_by_idx.name_offset);
}

test "lookup missing returns null" {
    const allocator = std.testing.allocator;

    const formula = FormulaInfo{
        .name = "bat",
        .full_name = "bat",
        .desc = "A cat clone",
        .homepage = "",
        .license = "",
        .version = "1.0",
        .revision = 0,
        .tap = "",
        .keg_only = false,
        .deprecated = false,
        .disabled = false,
        .dependencies = &.{},
        .build_dependencies = &.{},
        .bottle_root_url = "",
        .bottle_sha256 = "",
        .bottle_cellar = "",
    };

    const formulae = [_]FormulaInfo{formula};

    var idx = try Index.build(allocator, &formulae);
    defer idx.deinit();

    // Lookup a name that does not exist.
    try std.testing.expect(idx.lookup("nonexistent") == null);
    try std.testing.expect(idx.lookup("") == null);
    try std.testing.expect(idx.lookup("bats") == null);
}

test "loadOrBuild rebuilds stale index when JWS is newer" {
    const allocator = std.testing.allocator;

    const home = std.posix.getenv("HOME") orelse return;
    var cache_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/Library/Caches/Homebrew", .{home}) catch return;

    var idx_buf: [1024]u8 = undefined;
    const idx_path = std.fmt.bufPrint(&idx_buf, "{s}/api/formula.bru.idx", .{cache_dir}) catch return;

    // Write a minimal valid .idx file with 0 entries and backdate it.
    {
        const fake_header = IndexHeader{
            .entry_count = 0,
            .hash_table_offset = @sizeOf(IndexHeader),
            .entries_offset = @sizeOf(IndexHeader),
            .strings_offset = @sizeOf(IndexHeader),
        };
        const f = std.fs.createFileAbsolute(idx_path, .{}) catch return;
        f.writeAll(mem.asBytes(&fake_header)) catch {
            f.close();
            return;
        };
        // Backdate the file so the JWS is newer.
        const epoch_past: posix.timespec = .{ .sec = 1000000000, .nsec = 0 };
        posix.futimens(f.handle, &.{ epoch_past, epoch_past }) catch {
            f.close();
            return;
        };
        f.close();
    }

    // loadOrBuild should detect the stale index and rebuild from JWS.
    var idx = Index.loadOrBuild(allocator, cache_dir) catch return;
    defer idx.deinit();

    // A rebuilt index from the real JWS should have thousands of entries.
    // A stale load of our fake file would have 0 entries.
    try std.testing.expect(idx.entryCount() > 5000);

    // Verify the index is functional.
    const entry = idx.lookup("bat") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bat", idx.getString(entry.name_offset));
}

test "loadOrBuild from real cache" {
    const allocator = std.testing.allocator;

    const home = std.posix.getenv("HOME") orelse return;
    var buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&buf, "{s}/Library/Caches/Homebrew", .{home}) catch return;

    // Delete any existing .idx file so we exercise the full build path.
    var idx_buf: [1024]u8 = undefined;
    const idx_path = std.fmt.bufPrint(&idx_buf, "{s}/api/formula.bru.idx", .{cache_dir}) catch return;
    std.fs.deleteFileAbsolute(idx_path) catch {};

    var idx = Index.loadOrBuild(allocator, cache_dir) catch return;
    defer idx.deinit();

    // Should have >5000 entries.
    try std.testing.expect(idx.entryCount() > 5000);

    // Lookup "bat".
    const entry = idx.lookup("bat") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("bat", idx.getString(entry.name_offset));
}
