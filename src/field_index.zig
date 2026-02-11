const std = @import("std");
const varint = @import("varint.zig");
const trigram_mod = @import("trigram.zig");
const posting = @import("posting.zig");
const Trigram = trigram_mod.Trigram;

pub const MAGIC_HEADER = "hound fld 1\n";
pub const MAGIC_TRAILER = "\nhound ftl 1\n";

pub const Trailer = struct {
    name_list_offset: u64,
    name_count: u64,
    field_list_offset: u64,
    field_count: u64,
    posting_list_offset: u64,
    posting_index_offset: u64,

    pub const SIZE = 8 * 6 + MAGIC_TRAILER.len;

    pub fn encode(self: Trailer) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.name_list_offset, .big);
        std.mem.writeInt(u64, buf[8..16], self.name_count, .big);
        std.mem.writeInt(u64, buf[16..24], self.field_list_offset, .big);
        std.mem.writeInt(u64, buf[24..32], self.field_count, .big);
        std.mem.writeInt(u64, buf[32..40], self.posting_list_offset, .big);
        std.mem.writeInt(u64, buf[40..48], self.posting_index_offset, .big);
        @memcpy(buf[48..], MAGIC_TRAILER);
        return buf;
    }

    pub fn decode(buf: *const [SIZE]u8) !Trailer {
        if (!std.mem.eql(u8, buf[48..], MAGIC_TRAILER)) {
            return error.InvalidTrailer;
        }
        return .{
            .name_list_offset = std.mem.readInt(u64, buf[0..8], .big),
            .name_count = std.mem.readInt(u64, buf[8..16], .big),
            .field_list_offset = std.mem.readInt(u64, buf[16..24], .big),
            .field_count = std.mem.readInt(u64, buf[24..32], .big),
            .posting_list_offset = std.mem.readInt(u64, buf[32..40], .big),
            .posting_index_offset = std.mem.readInt(u64, buf[40..48], .big),
        };
    }
};

pub const FieldPostingIndexEntry = struct {
    tri: Trigram,
    field_id: u32,
    count: u32,
    offset: u64,

    pub fn encode(self: FieldPostingIndexEntry, buf: []u8) usize {
        const tri_bytes = trigram_mod.toBytes(self.tri);
        @memcpy(buf[0..3], &tri_bytes);
        var n: usize = 3;
        n += varint.encode(self.field_id, buf[n..]);
        n += varint.encode(self.count, buf[n..]);
        n += varint.encode(self.offset, buf[n..]);
        return n;
    }
};

/// Key packing for the writer's HashMap: field_id << 24 | tri
fn packWriterKey(field_id: u32, tri: Trigram) u64 {
    return @as(u64, field_id) << 24 | @as(u64, tri);
}

pub const FieldIndexWriter = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    names: std.ArrayList([]const u8),
    field_names: std.ArrayList([]const u8),
    /// Key: field_id << 24 | tri -> PostingList
    postings: std.AutoHashMap(u64, *posting.PostingList),
    extractor: trigram_mod.Extractor,
    current_offset: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FieldIndexWriter {
        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();

        try file.writeAll(MAGIC_HEADER);

        return .{
            .allocator = allocator,
            .file = file,
            .names = .{},
            .field_names = .{},
            .postings = std.AutoHashMap(u64, *posting.PostingList).init(allocator),
            .extractor = try trigram_mod.Extractor.init(allocator),
            .current_offset = MAGIC_HEADER.len,
        };
    }

    pub fn deinit(self: *FieldIndexWriter) void {
        self.file.close();
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.names.deinit(self.allocator);

        for (self.field_names.items) |name| {
            self.allocator.free(name);
        }
        self.field_names.deinit(self.allocator);

        var it = self.postings.valueIterator();
        while (it.next()) |pl_ptr| {
            pl_ptr.*.deinit();
            self.allocator.destroy(pl_ptr.*);
        }
        self.postings.deinit();
        self.extractor.deinit();
    }

    /// Register a field name and return its id. If the name already exists, return existing id.
    pub fn addField(self: *FieldIndexWriter, name: []const u8) !u32 {
        for (self.field_names.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, name)) {
                return @intCast(i);
            }
        }
        const name_copy = try self.allocator.dupe(u8, name);
        try self.field_names.append(self.allocator, name_copy);
        return @intCast(self.field_names.items.len - 1);
    }

    /// Add a file with field-specific content.
    pub fn addFileField(self: *FieldIndexWriter, name: []const u8, field_id: u32, content: []const u8) !void {
        // Ensure this file name is registered (use file_id = names.len)
        var file_id: u32 = undefined;
        var found = false;
        for (self.names.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, name)) {
                file_id = @intCast(i);
                found = true;
                break;
            }
        }
        if (!found) {
            file_id = @intCast(self.names.items.len);
            const name_copy = try self.allocator.dupe(u8, name);
            try self.names.append(self.allocator, name_copy);
        }

        const trigrams = self.extractor.extract(content) catch |err| switch (err) {
            error.ContainsNul, error.InvalidUtf8, error.FileTooLong, error.LineTooLong, error.TooManyTrigrams => return,
            error.OutOfMemory => return err,
        };

        for (trigrams) |tri| {
            const key = packWriterKey(field_id, tri);
            const entry = try self.postings.getOrPut(key);
            if (!entry.found_existing) {
                const pl = try self.allocator.create(posting.PostingList);
                pl.* = posting.PostingList.init(self.allocator, tri);
                entry.value_ptr.* = pl;
            }
            try entry.value_ptr.*.add(file_id);
        }
    }

    pub fn finish(self: *FieldIndexWriter) !void {
        const name_list_offset = try self.writeNameList();
        const field_list_offset = try self.writeFieldList();
        const posting_list_offset = try self.writePostingLists();
        const posting_index_offset = try self.writePostingIndex();

        const trailer = Trailer{
            .name_list_offset = name_list_offset,
            .name_count = self.names.items.len,
            .field_list_offset = field_list_offset,
            .field_count = self.field_names.items.len,
            .posting_list_offset = posting_list_offset,
            .posting_index_offset = posting_index_offset,
        };
        const trailer_bytes = trailer.encode();
        try self.file.writeAll(&trailer_bytes);
    }

    fn writeNameList(self: *FieldIndexWriter) !u64 {
        const offset = self.current_offset;
        var buf: [10]u8 = undefined;

        for (self.names.items) |name| {
            const len_bytes = varint.encode(name.len, &buf);
            try self.file.writeAll(buf[0..len_bytes]);
            try self.file.writeAll(name);
            self.current_offset += len_bytes + name.len;
        }

        return offset;
    }

    fn writeFieldList(self: *FieldIndexWriter) !u64 {
        const offset = self.current_offset;
        var buf: [10]u8 = undefined;

        for (self.field_names.items) |name| {
            const len_bytes = varint.encode(name.len, &buf);
            try self.file.writeAll(buf[0..len_bytes]);
            try self.file.writeAll(name);
            self.current_offset += len_bytes + name.len;
        }

        return offset;
    }

    /// Sorted keys for deterministic output. Sort by (tri, field_id) for reader's binary search.
    fn getSortedKeys(self: *FieldIndexWriter) !std.ArrayList(u64) {
        var keys = std.ArrayList(u64){};
        errdefer keys.deinit(self.allocator);

        var it = self.postings.keyIterator();
        while (it.next()) |k| {
            try keys.append(self.allocator, k.*);
        }

        // Sort by (tri, field_id) for the reader
        const SortCtx = struct {
            fn lessThan(_: void, a: u64, b: u64) bool {
                // writer key: field_id << 24 | tri
                const a_tri: u24 = @truncate(a);
                const a_field: u32 = @truncate(a >> 24);
                const b_tri: u24 = @truncate(b);
                const b_field: u32 = @truncate(b >> 24);

                if (a_tri != b_tri) return a_tri < b_tri;
                return a_field < b_field;
            }
        };
        std.mem.sort(u64, keys.items, {}, SortCtx.lessThan);

        return keys;
    }

    fn writePostingLists(self: *FieldIndexWriter) !u64 {
        const offset = self.current_offset;

        var keys = try self.getSortedKeys();
        defer keys.deinit(self.allocator);

        for (keys.items) |key| {
            const pl = self.postings.get(key).?;
            pl.sort();

            // On-disk format: tri(3 bytes) + field_id(varint) + delta-encoded file_ids + 0 terminator
            const field_id: u32 = @truncate(key >> 24);
            const tri: Trigram = @truncate(key);

            const tri_bytes = trigram_mod.toBytes(tri);
            try self.file.writeAll(&tri_bytes);
            self.current_offset += 3;

            var vbuf: [10]u8 = undefined;
            const field_len = varint.encode(field_id, &vbuf);
            try self.file.writeAll(vbuf[0..field_len]);
            self.current_offset += field_len;

            // Delta-encode file IDs
            var prev: u32 = 0;
            for (pl.file_ids.items) |fid| {
                const delta = fid - prev;
                const n = varint.encode(delta + 1, &vbuf);
                try self.file.writeAll(vbuf[0..n]);
                self.current_offset += n;
                prev = fid;
            }

            // 0 terminator
            const term_len = varint.encode(0, &vbuf);
            try self.file.writeAll(vbuf[0..term_len]);
            self.current_offset += term_len;
        }

        return offset;
    }

    fn writePostingIndex(self: *FieldIndexWriter) !u64 {
        const offset = self.current_offset;

        var keys = try self.getSortedKeys();
        defer keys.deinit(self.allocator);

        var posting_offset: u64 = 0;
        var buf: [48]u8 = undefined;

        for (keys.items) |key| {
            const pl = self.postings.get(key).?;
            pl.sort();

            const field_id: u32 = @truncate(key >> 24);
            const tri: Trigram = @truncate(key);

            // Calculate posting list size on disk for this entry
            const pl_size = try self.calcPostingListSize(tri, field_id, pl);

            const entry = FieldPostingIndexEntry{
                .tri = tri,
                .field_id = field_id,
                .count = @intCast(pl.file_ids.items.len),
                .offset = posting_offset,
            };
            const n = entry.encode(&buf);
            try self.file.writeAll(buf[0..n]);
            self.current_offset += n;

            posting_offset += pl_size;
        }

        return offset;
    }

    fn calcPostingListSize(_: *FieldIndexWriter, _: Trigram, field_id: u32, pl: *posting.PostingList) !u64 {
        var size: u64 = 3; // tri bytes
        size += varint.encodedLen(field_id);

        var prev: u32 = 0;
        for (pl.file_ids.items) |fid| {
            const delta = fid - prev;
            size += varint.encodedLen(delta + 1);
            prev = fid;
        }
        size += varint.encodedLen(0); // terminator

        return size;
    }
};

test "field index writer basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_field_index_writer_basic_test.idx";

    std.fs.cwd().deleteFile(test_path) catch {};

    {
        var writer = try FieldIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        const title_id = try writer.addField("title");
        const body_id = try writer.addField("body");

        try writer.addFileField("doc1.txt", title_id, "hello world");
        try writer.addFileField("doc1.txt", body_id, "some body text");
        try writer.addFileField("doc2.txt", title_id, "another title");
        try writer.finish();
    }

    const f = try std.fs.cwd().openFile(test_path, .{});
    defer f.close();

    var header_buf: [MAGIC_HEADER.len]u8 = undefined;
    _ = try f.readAll(&header_buf);
    try std.testing.expectEqualSlices(u8, MAGIC_HEADER, &header_buf);

    const stat = try f.stat();
    try f.seekTo(stat.size - Trailer.SIZE);

    var trailer_buf: [Trailer.SIZE]u8 = undefined;
    _ = try f.readAll(&trailer_buf);
    const trailer = try Trailer.decode(&trailer_buf);

    try std.testing.expect(trailer.name_count == 2);
    try std.testing.expect(trailer.field_count == 2);
    try std.testing.expect(trailer.name_list_offset > 0);
    try std.testing.expect(trailer.field_list_offset > trailer.name_list_offset);
    try std.testing.expect(trailer.posting_list_offset > trailer.field_list_offset);
    try std.testing.expect(trailer.posting_index_offset > trailer.posting_list_offset);
}
