const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const Allocator = mem.Allocator;
const cask_mod = @import("cask.zig");
const CaskInfo = cask_mod.CaskInfo;

// ---------------------------------------------------------------------------
// Binary index structures (C ABI layout, no padding)
// ---------------------------------------------------------------------------

pub const CaskIndexHeader = extern struct {
    magic: [4]u8 = .{ 'B', 'R', 'U', 'C' },
    version: u32 = 1,
    source_hash: [32]u8 = .{0} ** 32,
    entry_count: u32 = 0,
    _pad: [4]u8 = .{0} ** 4,
    hash_table_offset: u64 = 0,
    entries_offset: u64 = 0,
    strings_offset: u64 = 0,
};

pub const CaskIndexEntry = extern struct {
    token_offset: u32 = 0,
    full_token_offset: u32 = 0,
    name_offset: u32 = 0,
    desc_offset: u32 = 0,
    homepage_offset: u32 = 0,
    version_offset: u32 = 0,
    url_offset: u32 = 0,
    sha256_offset: u32 = 0,
    flags: u16 = 0, // bit 0: deprecated, bit 1: disabled
    _pad: u16 = 0,
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
};

// ---------------------------------------------------------------------------
// CaskIndex -- the main public type
// ---------------------------------------------------------------------------

pub const CaskIndex = struct {
    data: []const u8,
    allocator: Allocator,

    /// Build a binary index from a slice of CaskInfo.
    pub fn build(allocator: Allocator, casks: []const CaskInfo) !CaskIndex {
        // ------------------------------------------------------------------
        // 1. Build string table and collect per-cask string offsets.
        // ------------------------------------------------------------------
        var stb = StringTableBuilder{};
        defer stb.deinit(allocator);

        const entries = try allocator.alloc(CaskIndexEntry, casks.len);
        defer allocator.free(entries);

        for (casks, 0..) |c, i| {
            var flags: u16 = 0;
            if (c.deprecated) flags |= 1;
            if (c.disabled) flags |= 2;

            entries[i] = CaskIndexEntry{
                .token_offset = try stb.addString(allocator, c.token),
                .full_token_offset = try stb.addString(allocator, c.full_token),
                .name_offset = try stb.addString(allocator, c.name),
                .desc_offset = try stb.addString(allocator, c.desc),
                .homepage_offset = try stb.addString(allocator, c.homepage),
                .version_offset = try stb.addString(allocator, c.version),
                .url_offset = try stb.addString(allocator, c.url),
                .sha256_offset = try stb.addString(allocator, c.sha256),
                .flags = flags,
            };
        }

        // ------------------------------------------------------------------
        // 2. Build the hash table (open addressing, 2x capacity, linear probing).
        // ------------------------------------------------------------------
        const bucket_count: u32 = if (casks.len == 0) 2 else @intCast(casks.len * 2);
        const hash_table = try allocator.alloc(HashBucket, bucket_count);
        defer allocator.free(hash_table);

        // Initialise all buckets as empty.
        for (hash_table) |*b| {
            b.* = HashBucket{};
        }

        // Insert each cask token.
        for (casks, 0..) |c, i| {
            const h = fnvHash(c.token);
            var slot = h % bucket_count;
            while (hash_table[slot].entry_index != std.math.maxInt(u32)) {
                slot = (slot + 1) % bucket_count;
            }
            hash_table[slot] = HashBucket{
                .string_offset = entries[i].token_offset,
                .entry_index = @intCast(i),
            };
        }

        // ------------------------------------------------------------------
        // 3. Calculate layout sizes.
        // ------------------------------------------------------------------
        const header_size: u64 = @sizeOf(CaskIndexHeader);
        const hash_table_size: u64 = @as(u64, bucket_count) * @sizeOf(HashBucket);
        const entries_size: u64 = @as(u64, @intCast(casks.len)) * @sizeOf(CaskIndexEntry);
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
        var header = CaskIndexHeader{
            .entry_count = @intCast(casks.len),
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

        return CaskIndex{
            .data = buf,
            .allocator = allocator,
        };
    }

    /// Free the index buffer.
    pub fn deinit(self: *CaskIndex) void {
        self.allocator.free(self.data);
        self.data = &.{};
    }

    // ------------------------------------------------------------------
    // Accessors
    // ------------------------------------------------------------------

    fn getHeader(self: *const CaskIndex) CaskIndexHeader {
        return mem.bytesToValue(CaskIndexHeader, self.data[0..@sizeOf(CaskIndexHeader)]);
    }

    /// Number of cask entries in the index.
    pub fn entryCount(self: *const CaskIndex) u32 {
        return self.getHeader().entry_count;
    }

    /// Get an entry by its zero-based index in the entries array.
    pub fn getEntryByIndex(self: *const CaskIndex, idx: u32) CaskIndexEntry {
        const header = self.getHeader();
        const off: usize = @intCast(header.entries_offset + @as(u64, idx) * @sizeOf(CaskIndexEntry));
        return mem.bytesToValue(CaskIndexEntry, self.data[off..][0..@sizeOf(CaskIndexEntry)]);
    }

    /// Retrieve a null-terminated string from the string table.
    /// `offset` is relative to the start of the string table.
    pub fn getString(self: *const CaskIndex, offset: u32) []const u8 {
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

    /// Look up a cask by token. Returns the CaskIndexEntry if found, null otherwise.
    pub fn lookup(self: *const CaskIndex, token: []const u8) ?CaskIndexEntry {
        const header = self.getHeader();
        if (header.entry_count == 0) return null;
        const bucket_count: u32 = header.entry_count * 2;
        const h = fnvHash(token);
        var slot = h % bucket_count;

        while (true) {
            const bucket_off: usize = @intCast(header.hash_table_offset + @as(u64, slot) * @sizeOf(HashBucket));
            const bucket = mem.bytesToValue(HashBucket, self.data[bucket_off..][0..@sizeOf(HashBucket)]);
            if (bucket.entry_index == std.math.maxInt(u32)) {
                return null; // empty bucket -- not found
            }
            // Compare the token string at that offset.
            const candidate = self.getString(bucket.string_offset);
            if (mem.eql(u8, candidate, token)) {
                return self.getEntryByIndex(bucket.entry_index);
            }
            slot = (slot + 1) % bucket_count;
        }
    }

    // ------------------------------------------------------------------
    // Persistence
    // ------------------------------------------------------------------

    /// Write the index data to a file, creating or overwriting.
    pub fn writeToDisk(self: *const CaskIndex, path: []const u8) !void {
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(self.data);
    }

    /// Open a previously-written index from disk via mmap.
    /// Returns null if the file does not exist or is too small to contain a header.
    /// The returned CaskIndex has mmap'd data; the process exits after use so OS
    /// reclamation is sufficient.
    pub fn openFromDisk(path: []const u8) !?CaskIndex {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;
        if (size < @sizeOf(CaskIndexHeader)) return null;

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
        if (!mem.eql(u8, data[0..4], "BRUC")) {
            posix.munmap(mapped);
            return null;
        }

        return CaskIndex{
            .data = data,
            .allocator = undefined, // mmap'd; caller should not use allocator
        };
    }

    /// Release an mmap'd cask index. Does not use the allocator.
    fn munmapCaskIndex(idx: CaskIndex) void {
        const aligned: []align(std.heap.page_size_min) const u8 = @alignCast(idx.data);
        posix.munmap(aligned);
    }

    /// Load an existing index from disk, or build one from the JWS cache.
    /// Rebuilds if the JWS source file is newer than the cached index.
    pub fn loadOrBuild(allocator: Allocator, cache_dir: []const u8) !CaskIndex {
        // 1. Try loading existing index from disk.
        var idx_path_buf: [1024]u8 = undefined;
        const idx_path = std.fmt.bufPrint(&idx_path_buf, "{s}/api/cask.bru.idx", .{cache_dir}) catch
            return error.PathTooLong;

        var jws_path_buf: [1024]u8 = undefined;
        const jws_path = std.fmt.bufPrint(&jws_path_buf, "{s}/api/cask.jws.json", .{cache_dir}) catch
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
            munmapCaskIndex(idx);
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

        // 4. Parse the payload into CaskInfo array.
        const casks = try cask_mod.parseCaskJson(allocator, payload_str);
        defer {
            for (casks) |c| cask_mod.freeCask(allocator, c);
            allocator.free(casks);
        }

        // 5. Build the index.
        var idx = try CaskIndex.build(allocator, casks);

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

    const cask = CaskInfo{
        .token = "firefox",
        .full_token = "firefox",
        .name = "Mozilla Firefox",
        .desc = "Web browser",
        .homepage = "https://www.mozilla.org/firefox/",
        .version = "136.0.4",
        .url = "https://download-installer.cdn.mozilla.net/pub/firefox/releases/136.0.4/mac/en-US/Firefox%20136.0.4.dmg",
        .sha256 = "abc123def456",
        .deprecated = false,
        .disabled = false,
    };

    const casks = [_]CaskInfo{cask};

    var idx = try CaskIndex.build(allocator, &casks);
    defer idx.deinit();

    // Verify entry count.
    try std.testing.expectEqual(@as(u32, 1), idx.entryCount());

    // Lookup by token.
    const entry = idx.lookup("firefox") orelse return error.TestUnexpectedResult;

    // Verify string fields.
    try std.testing.expectEqualStrings("firefox", idx.getString(entry.token_offset));
    try std.testing.expectEqualStrings("firefox", idx.getString(entry.full_token_offset));
    try std.testing.expectEqualStrings("Mozilla Firefox", idx.getString(entry.name_offset));
    try std.testing.expectEqualStrings("Web browser", idx.getString(entry.desc_offset));
    try std.testing.expectEqualStrings("https://www.mozilla.org/firefox/", idx.getString(entry.homepage_offset));
    try std.testing.expectEqualStrings("136.0.4", idx.getString(entry.version_offset));
    try std.testing.expectEqualStrings("https://download-installer.cdn.mozilla.net/pub/firefox/releases/136.0.4/mac/en-US/Firefox%20136.0.4.dmg", idx.getString(entry.url_offset));
    try std.testing.expectEqualStrings("abc123def456", idx.getString(entry.sha256_offset));

    // Verify flags: deprecated=false, disabled=false -> flags=0.
    try std.testing.expectEqual(@as(u16, 0), entry.flags);

    // getEntryByIndex should return the same entry.
    const entry_by_idx = idx.getEntryByIndex(0);
    try std.testing.expectEqual(entry.token_offset, entry_by_idx.token_offset);
}

test "lookup missing returns null" {
    const allocator = std.testing.allocator;

    const cask = CaskInfo{
        .token = "firefox",
        .full_token = "firefox",
        .name = "Mozilla Firefox",
        .desc = "Web browser",
        .homepage = "",
        .version = "1.0",
        .url = "",
        .sha256 = "",
        .deprecated = false,
        .disabled = false,
    };

    const casks = [_]CaskInfo{cask};

    var idx = try CaskIndex.build(allocator, &casks);
    defer idx.deinit();

    // Lookup a token that does not exist.
    try std.testing.expect(idx.lookup("nonexistent") == null);
    try std.testing.expect(idx.lookup("") == null);
    try std.testing.expect(idx.lookup("firefoxes") == null);
}

test "loadOrBuild from real cache" {
    const allocator = std.testing.allocator;

    const home = std.posix.getenv("HOME") orelse return;
    var buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&buf, "{s}/Library/Caches/Homebrew", .{home}) catch return;

    // Delete any existing .idx file so we exercise the full build path.
    var idx_buf: [1024]u8 = undefined;
    const idx_path = std.fmt.bufPrint(&idx_buf, "{s}/api/cask.bru.idx", .{cache_dir}) catch return;
    std.fs.deleteFileAbsolute(idx_path) catch {};

    var idx = CaskIndex.loadOrBuild(allocator, cache_dir) catch return;
    defer idx.deinit();

    // Should have >1000 cask entries.
    try std.testing.expect(idx.entryCount() > 1000);

    // Lookup "firefox".
    const entry = idx.lookup("firefox") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("firefox", idx.getString(entry.token_offset));
}

test "deprecated and disabled flags" {
    const allocator = std.testing.allocator;

    const cask = CaskInfo{
        .token = "old-app",
        .full_token = "old-app",
        .name = "Old App",
        .desc = "An old app",
        .homepage = "",
        .version = "1.0",
        .url = "",
        .sha256 = "",
        .deprecated = true,
        .disabled = true,
    };

    const casks = [_]CaskInfo{cask};

    var idx = try CaskIndex.build(allocator, &casks);
    defer idx.deinit();

    const entry = idx.lookup("old-app") orelse return error.TestUnexpectedResult;
    // bit 0: deprecated, bit 1: disabled -> flags = 3
    try std.testing.expectEqual(@as(u16, 3), entry.flags);
}
