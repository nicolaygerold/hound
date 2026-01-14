const std = @import("std");
const posix = std.posix;
const varint = @import("varint.zig");
const trigram_mod = @import("trigram.zig");
const posting = @import("posting.zig");
const index = @import("index.zig");
const Trigram = trigram_mod.Trigram;

pub const IndexReader = struct {
    data: []align(std.mem.page_size) const u8,
    fd: posix.fd_t,
    trailer: index.Trailer,
    posting_index: PostingIndex,
    allocator: std.mem.Allocator,

    pub const OpenError = error{
        InvalidMagic,
        InvalidTrailer,
        FileTooSmall,
    } || posix.MMapError || std.fs.File.OpenError || std.fs.File.StatError;

    pub fn open(allocator: std.mem.Allocator, path: []const u8) OpenError!IndexReader {
        const file = try std.fs.cwd().openFile(path, .{});
        const fd = file.handle;
        errdefer posix.close(fd);

        const stat = try file.stat();
        const size = stat.size;

        if (size < index.MAGIC_HEADER.len + index.Trailer.SIZE) {
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

        if (!std.mem.eql(u8, data[0..index.MAGIC_HEADER.len], index.MAGIC_HEADER)) {
            posix.munmap(data);
            return error.InvalidMagic;
        }

        const trailer_start = size - index.Trailer.SIZE;
        const trailer = index.Trailer.decode(data[trailer_start..][0..index.Trailer.SIZE]) catch {
            posix.munmap(data);
            return error.InvalidTrailer;
        };

        const posting_index = try PostingIndex.build(
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

    pub fn close(self: *IndexReader) void {
        self.posting_index.deinit();
        posix.munmap(self.data);
        posix.close(self.fd);
    }

    pub fn nameCount(self: *const IndexReader) u64 {
        return self.trailer.name_count;
    }

    pub fn getName(self: *const IndexReader, file_id: u32) ?[]const u8 {
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

    pub fn lookupTrigram(self: *const IndexReader, tri: Trigram) ?PostingListView {
        const entry = self.posting_index.lookup(tri) orelse return null;
        const start = self.trailer.posting_list_offset + entry.offset;
        return PostingListView.init(self.data[start..], entry.count);
    }

    pub fn trigramCount(self: *const IndexReader) usize {
        return self.posting_index.entries.items.len;
    }
};

const PostingIndex = struct {
    entries: std.ArrayList(Entry),

    const Entry = struct {
        tri: Trigram,
        count: u32,
        offset: u64,
    };

    fn build(allocator: std.mem.Allocator, data: []const u8, _: u64) !PostingIndex {
        var entries = std.ArrayList(Entry).init(allocator);
        errdefer entries.deinit();

        var pos: usize = 0;
        while (pos + 3 <= data.len) {
            const tri = trigram_mod.fromBytes(data[pos], data[pos + 1], data[pos + 2]);
            pos += 3;

            const count_result = varint.decode(data[pos..]);
            pos += count_result.bytes_read;

            const offset_result = varint.decode(data[pos..]);
            pos += offset_result.bytes_read;

            try entries.append(.{
                .tri = tri,
                .count = @truncate(count_result.value),
                .offset = offset_result.value,
            });
        }

        return .{ .entries = entries };
    }

    fn deinit(self: *PostingIndex) void {
        self.entries.deinit();
    }

    fn lookup(self: *const PostingIndex, tri: Trigram) ?Entry {
        const items = self.entries.items;
        var left: usize = 0;
        var right: usize = items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (items[mid].tri < tri) {
                left = mid + 1;
            } else if (items[mid].tri > tri) {
                right = mid;
            } else {
                return items[mid];
            }
        }
        return null;
    }
};

pub const PostingListView = struct {
    data: []const u8,
    pos: usize,
    current_file_id: u32,
    count: u32,
    items_read: u32,

    pub fn init(data: []const u8, count: u32) PostingListView {
        return .{
            .data = data,
            .pos = 3,
            .current_file_id = 0,
            .count = count,
            .items_read = 0,
        };
    }

    pub fn trigram(self: *const PostingListView) Trigram {
        return trigram_mod.fromBytes(self.data[0], self.data[1], self.data[2]);
    }

    pub fn next(self: *PostingListView) ?u32 {
        if (self.pos >= self.data.len) return null;

        const result = varint.decode(self.data[self.pos..]);
        self.pos += result.bytes_read;

        if (result.value == 0) return null;

        self.current_file_id += @as(u32, @truncate(result.value)) - 1;
        self.items_read += 1;
        return self.current_file_id;
    }

    pub fn collect(self: *PostingListView, allocator: std.mem.Allocator) ![]u32 {
        var list = std.ArrayList(u32).init(allocator);
        errdefer list.deinit();

        while (self.next()) |fid| {
            try list.append(fid);
        }

        return list.toOwnedSlice();
    }
};

test "index reader basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_reader_test.idx";

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("test.txt", "hello world");
        try writer.addFile("foo.txt", "hello there");
        try writer.addFile("bar.txt", "world hello");
        try writer.finish();
    }

    var reader = try IndexReader.open(allocator, test_path);
    defer reader.close();

    try std.testing.expectEqual(@as(u64, 3), reader.nameCount());
    try std.testing.expectEqualSlices(u8, "test.txt", reader.getName(0).?);
    try std.testing.expectEqualSlices(u8, "foo.txt", reader.getName(1).?);
    try std.testing.expectEqualSlices(u8, "bar.txt", reader.getName(2).?);
    try std.testing.expect(reader.getName(3) == null);
}

test "index reader trigram lookup" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_reader_trigram_test.idx";

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("hello.txt", "hello");
        try writer.addFile("world.txt", "world");
        try writer.addFile("helloworld.txt", "helloworld");
        try writer.finish();
    }

    var reader = try IndexReader.open(allocator, test_path);
    defer reader.close();

    const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');
    var view = reader.lookupTrigram(tri_hel).?;
    const file_ids = try view.collect(allocator);
    defer allocator.free(file_ids);

    try std.testing.expect(file_ids.len >= 2);
    try std.testing.expect(std.mem.indexOfScalar(u32, file_ids, 0) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, file_ids, 2) != null);

    const tri_wor = trigram_mod.fromBytes('w', 'o', 'r');
    var view2 = reader.lookupTrigram(tri_wor).?;
    const file_ids2 = try view2.collect(allocator);
    defer allocator.free(file_ids2);

    try std.testing.expect(file_ids2.len >= 1);

    const tri_xyz = trigram_mod.fromBytes('x', 'y', 'z');
    try std.testing.expect(reader.lookupTrigram(tri_xyz) == null);
}

test "index reader empty index" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_reader_empty_test.idx";

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.finish();
    }

    var reader = try IndexReader.open(allocator, test_path);
    defer reader.close();

    try std.testing.expectEqual(@as(u64, 0), reader.nameCount());
    try std.testing.expectEqual(@as(usize, 0), reader.trigramCount());
}
