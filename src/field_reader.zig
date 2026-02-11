const std = @import("std");
const posix = std.posix;
const varint = @import("varint.zig");
const trigram_mod = @import("trigram.zig");
const field_index = @import("field_index.zig");
const Trigram = trigram_mod.Trigram;

pub const FieldIndexReader = struct {
    data: []align(std.heap.page_size_min) const u8,
    fd: posix.fd_t,
    trailer: field_index.Trailer,
    posting_index: FieldPostingIndex,
    allocator: std.mem.Allocator,

    pub const OpenError = error{
        InvalidMagic,
        InvalidTrailer,
        FileTooSmall,
    } || posix.MMapError || std.fs.File.OpenError || std.fs.File.StatError || std.mem.Allocator.Error;

    pub fn open(allocator: std.mem.Allocator, path: []const u8) OpenError!FieldIndexReader {
        const file = try std.fs.cwd().openFile(path, .{});
        const fd = file.handle;
        errdefer posix.close(fd);

        const stat = try file.stat();
        const size = stat.size;

        if (size < field_index.MAGIC_HEADER.len + field_index.Trailer.SIZE) {
            return error.FileTooSmall;
        }

        const data = try posix.mmap(
            null,
            size,
            posix.PROT.READ,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        if (!std.mem.eql(u8, data[0..field_index.MAGIC_HEADER.len], field_index.MAGIC_HEADER)) {
            posix.munmap(data);
            return error.InvalidMagic;
        }

        const trailer_start = size - field_index.Trailer.SIZE;
        const trailer = field_index.Trailer.decode(data[trailer_start..][0..field_index.Trailer.SIZE]) catch {
            posix.munmap(data);
            return error.InvalidTrailer;
        };

        const posting_index = try FieldPostingIndex.build(
            allocator,
            data[trailer.posting_index_offset..trailer_start],
            trailer.posting_list_offset,
        );

        return .{
            .data = data,
            .fd = fd,
            .trailer = trailer,
            .posting_index = posting_index,
            .allocator = allocator,
        };
    }

    pub fn close(self: *FieldIndexReader) void {
        self.posting_index.deinit();
        posix.munmap(self.data);
        posix.close(self.fd);
    }

    pub fn nameCount(self: *const FieldIndexReader) u64 {
        return self.trailer.name_count;
    }

    pub fn getName(self: *const FieldIndexReader, file_id: u32) ?[]const u8 {
        if (file_id >= self.trailer.name_count) return null;

        var pos = self.trailer.name_list_offset;
        var current_id: u32 = 0;

        while (current_id < file_id) : (current_id += 1) {
            const result = varint.decode(self.data[pos..]);
            pos += result.bytes_read + result.value;
        }

        const len_result = varint.decode(self.data[pos..]);
        const name_start = pos + len_result.bytes_read;
        const name_end = name_start + len_result.value;

        return self.data[name_start..name_end];
    }

    pub fn fieldCount(self: *const FieldIndexReader) u64 {
        return self.trailer.field_count;
    }

    pub fn getFieldName(self: *const FieldIndexReader, field_id: u32) ?[]const u8 {
        if (field_id >= self.trailer.field_count) return null;

        var pos = self.trailer.field_list_offset;
        var current_id: u32 = 0;

        while (current_id < field_id) : (current_id += 1) {
            const result = varint.decode(self.data[pos..]);
            pos += result.bytes_read + result.value;
        }

        const len_result = varint.decode(self.data[pos..]);
        const name_start = pos + len_result.bytes_read;
        const name_end = name_start + len_result.value;

        return self.data[name_start..name_end];
    }

    /// Lookup posting list for a specific (trigram, field) pair.
    pub fn lookupFieldTrigram(self: *const FieldIndexReader, tri: Trigram, field_id: u32) ?FieldPostingListView {
        const entry = self.posting_index.lookup(tri, field_id) orelse return null;
        const start = self.trailer.posting_list_offset + entry.offset;
        return FieldPostingListView.init(self.data[start..], entry.count, field_id);
    }

    /// Lookup posting lists for a trigram across ALL fields.
    /// Returns slice of entries matching this trigram (different field_ids).
    pub fn lookupTrigramAllFields(self: *const FieldIndexReader, tri: Trigram) []const FieldPostingIndex.Entry {
        return self.posting_index.lookupAll(tri);
    }

    pub fn trigramFieldCount(self: *const FieldIndexReader) usize {
        return self.posting_index.entries.items.len;
    }
};

/// Posting index sorted by packed key (tri, field_id) for binary search.
const FieldPostingIndex = struct {
    entries: std.ArrayList(Entry),
    allocator: std.mem.Allocator,

    const Entry = struct {
        tri: Trigram,
        field_id: u32,
        count: u32,
        offset: u64,

        /// Pack for comparison: sort by tri first, then field_id.
        fn packKey(self: Entry) u64 {
            return @as(u64, self.tri) << 32 | @as(u64, self.field_id);
        }
    };

    fn build(allocator: std.mem.Allocator, posting_index_data: []const u8, _: u64) !FieldPostingIndex {
        var entries = std.ArrayList(Entry){};
        errdefer entries.deinit(allocator);

        var pos: usize = 0;
        while (pos + 3 <= posting_index_data.len) {
            const tri = trigram_mod.fromBytes(
                posting_index_data[pos],
                posting_index_data[pos + 1],
                posting_index_data[pos + 2],
            );
            pos += 3;

            const field_id_result = varint.decode(posting_index_data[pos..]);
            pos += field_id_result.bytes_read;

            const count_result = varint.decode(posting_index_data[pos..]);
            pos += count_result.bytes_read;

            const offset_result = varint.decode(posting_index_data[pos..]);
            pos += offset_result.bytes_read;

            try entries.append(allocator, .{
                .tri = tri,
                .field_id = @truncate(field_id_result.value),
                .count = @truncate(count_result.value),
                .offset = offset_result.value,
            });
        }

        return .{ .entries = entries, .allocator = allocator };
    }

    fn deinit(self: *FieldPostingIndex) void {
        self.entries.deinit(self.allocator);
    }

    /// Binary search for exact (tri, field_id) match.
    fn lookup(self: *const FieldPostingIndex, tri: Trigram, field_id: u32) ?Entry {
        const items = self.entries.items;
        const target: u64 = @as(u64, tri) << 32 | @as(u64, field_id);

        var left: usize = 0;
        var right: usize = items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_key = items[mid].packKey();
            if (mid_key < target) {
                left = mid + 1;
            } else if (mid_key > target) {
                right = mid;
            } else {
                return items[mid];
            }
        }
        return null;
    }

    /// Find range of entries matching tri (any field_id).
    /// Returns a slice into the sorted entries array.
    fn lookupAll(self: *const FieldPostingIndex, tri: Trigram) []const Entry {
        const items = self.entries.items;
        if (items.len == 0) return items[0..0];

        // Binary search for the first entry with this trigram.
        // Use tri << 32 | 0 as the lower bound target.
        const target_lo: u64 = @as(u64, tri) << 32;

        var left: usize = 0;
        var right: usize = items.len;

        // Find leftmost entry where tri matches (or first entry >= target_lo).
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (items[mid].packKey() < target_lo) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        const start = left;

        // If start is past the end or doesn't match the trigram, return empty.
        if (start >= items.len or items[start].tri != tri) {
            return items[0..0];
        }

        // Scan forward while tri matches.
        var end = start;
        while (end < items.len and items[end].tri == tri) {
            end += 1;
        }

        return items[start..end];
    }
};

/// View over a field-aware posting list in mmap'd data.
///
/// On-disk format per entry: tri(3 bytes) + field_id(varint) + delta-encoded file_ids + 0 terminator
pub const FieldPostingListView = struct {
    data: []const u8,
    pos: usize,
    current_file_id: u32,
    count: u32,
    items_read: u32,
    field_id: u32,

    pub fn init(data: []const u8, count: u32, field_id: u32) FieldPostingListView {
        // Skip past: tri(3 bytes) + field_id(varint)
        var pos: usize = 3;
        const field_result = varint.decode(data[pos..]);
        pos += field_result.bytes_read;

        return .{
            .data = data,
            .pos = pos,
            .current_file_id = 0,
            .count = count,
            .items_read = 0,
            .field_id = field_id,
        };
    }

    pub fn trigram(self: *const FieldPostingListView) Trigram {
        return trigram_mod.fromBytes(self.data[0], self.data[1], self.data[2]);
    }

    pub fn next(self: *FieldPostingListView) ?u32 {
        if (self.pos >= self.data.len) return null;

        const result = varint.decode(self.data[self.pos..]);
        self.pos += result.bytes_read;

        if (result.value == 0) return null;

        self.current_file_id += @as(u32, @truncate(result.value)) - 1;
        self.items_read += 1;
        return self.current_file_id;
    }

    pub fn collect(self: *FieldPostingListView, allocator: std.mem.Allocator) ![]u32 {
        var list = std.ArrayList(u32){};
        errdefer list.deinit(allocator);

        while (self.next()) |fid| {
            try list.append(allocator, fid);
        }

        return list.toOwnedSlice(allocator);
    }
};

test "field index reader basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_field_reader_basic_test.idx";

    std.fs.cwd().deleteFile(test_path) catch {};

    {
        var writer = try field_index.FieldIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        const title_id = try writer.addField("title");
        const body_id = try writer.addField("body");

        try writer.addFileField("doc1.txt", title_id, "hello world");
        try writer.addFileField("doc1.txt", body_id, "some body text");
        try writer.addFileField("doc2.txt", title_id, "another title");
        try writer.finish();
    }

    var reader = try FieldIndexReader.open(allocator, test_path);
    defer reader.close();

    try std.testing.expectEqual(@as(u64, 2), reader.nameCount());
    try std.testing.expectEqualSlices(u8, "doc1.txt", reader.getName(0).?);
    try std.testing.expectEqualSlices(u8, "doc2.txt", reader.getName(1).?);
    try std.testing.expect(reader.getName(2) == null);

    try std.testing.expectEqual(@as(u64, 2), reader.fieldCount());
    try std.testing.expectEqualSlices(u8, "title", reader.getFieldName(0).?);
    try std.testing.expectEqualSlices(u8, "body", reader.getFieldName(1).?);
    try std.testing.expect(reader.getFieldName(2) == null);
}

test "field index reader trigram lookup" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_field_reader_trigram_lookup_test.idx";

    std.fs.cwd().deleteFile(test_path) catch {};

    {
        var writer = try field_index.FieldIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        const title_id = try writer.addField("title");
        const body_id = try writer.addField("body");

        // doc1: title="hello", body="world"
        try writer.addFileField("doc1.txt", title_id, "hello");
        try writer.addFileField("doc1.txt", body_id, "world");
        // doc2: title="world", body="hello"
        try writer.addFileField("doc2.txt", title_id, "world");
        try writer.addFileField("doc2.txt", body_id, "hello");
        try writer.finish();
    }

    var reader = try FieldIndexReader.open(allocator, test_path);
    defer reader.close();

    const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');

    // lookupFieldTrigram("hel", field_id=0/title) should return doc1
    {
        var view = reader.lookupFieldTrigram(tri_hel, 0).?;
        const file_ids = try view.collect(allocator);
        defer allocator.free(file_ids);

        try std.testing.expectEqual(@as(usize, 1), file_ids.len);
        try std.testing.expectEqual(@as(u32, 0), file_ids[0]); // doc1
    }

    // lookupFieldTrigram("hel", field_id=1/body) should return doc2
    {
        var view = reader.lookupFieldTrigram(tri_hel, 1).?;
        const file_ids = try view.collect(allocator);
        defer allocator.free(file_ids);

        try std.testing.expectEqual(@as(usize, 1), file_ids.len);
        try std.testing.expectEqual(@as(u32, 1), file_ids[0]); // doc2
    }

    const tri_wor = trigram_mod.fromBytes('w', 'o', 'r');

    // lookupFieldTrigram("wor", field_id=0/title) should return doc2
    {
        var view = reader.lookupFieldTrigram(tri_wor, 0).?;
        const file_ids = try view.collect(allocator);
        defer allocator.free(file_ids);

        try std.testing.expectEqual(@as(usize, 1), file_ids.len);
        try std.testing.expectEqual(@as(u32, 1), file_ids[0]); // doc2
    }

    // lookupFieldTrigram("wor", field_id=1/body) should return doc1
    {
        var view = reader.lookupFieldTrigram(tri_wor, 1).?;
        const file_ids = try view.collect(allocator);
        defer allocator.free(file_ids);

        try std.testing.expectEqual(@as(usize, 1), file_ids.len);
        try std.testing.expectEqual(@as(u32, 0), file_ids[0]); // doc1
    }

    // Non-existent trigram returns null
    const tri_xyz = trigram_mod.fromBytes('x', 'y', 'z');
    try std.testing.expect(reader.lookupFieldTrigram(tri_xyz, 0) == null);
}

test "field index reader lookup all fields" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_field_reader_lookup_all_test.idx";

    std.fs.cwd().deleteFile(test_path) catch {};

    {
        var writer = try field_index.FieldIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        const title_id = try writer.addField("title");
        const body_id = try writer.addField("body");

        // doc1: title="hello", body="world"
        try writer.addFileField("doc1.txt", title_id, "hello");
        try writer.addFileField("doc1.txt", body_id, "world");
        // doc2: title="world", body="hello"
        try writer.addFileField("doc2.txt", title_id, "world");
        try writer.addFileField("doc2.txt", body_id, "hello");
        try writer.finish();
    }

    var reader = try FieldIndexReader.open(allocator, test_path);
    defer reader.close();

    const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');

    // lookupTrigramAllFields("hel") should return entries for both field 0 and field 1
    const entries = reader.lookupTrigramAllFields(tri_hel);
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    // Entries are sorted by (tri, field_id), so field 0 comes first
    try std.testing.expectEqual(@as(u32, 0), entries[0].field_id);
    try std.testing.expectEqual(@as(u32, 1), entries[1].field_id);

    // Non-existent trigram returns empty slice
    const tri_xyz = trigram_mod.fromBytes('x', 'y', 'z');
    const empty = reader.lookupTrigramAllFields(tri_xyz);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "field index reader empty index" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_field_reader_empty_test.idx";

    std.fs.cwd().deleteFile(test_path) catch {};

    {
        var writer = try field_index.FieldIndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.finish();
    }

    var reader = try FieldIndexReader.open(allocator, test_path);
    defer reader.close();

    try std.testing.expectEqual(@as(u64, 0), reader.nameCount());
    try std.testing.expectEqual(@as(u64, 0), reader.fieldCount());
    try std.testing.expectEqual(@as(usize, 0), reader.trigramFieldCount());
}
