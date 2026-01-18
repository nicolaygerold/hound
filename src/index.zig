const std = @import("std");
const varint = @import("varint.zig");
const trigram_mod = @import("trigram.zig");
const posting = @import("posting.zig");
const Trigram = trigram_mod.Trigram;

pub const MAGIC_HEADER = "hound idx 1\n";
pub const MAGIC_TRAILER = "\nhound trl 1\n";

pub const Trailer = struct {
    name_list_offset: u64,
    name_count: u64,
    posting_list_offset: u64,
    posting_index_offset: u64,

    pub const SIZE = 8 * 4 + MAGIC_TRAILER.len;

    pub fn encode(self: Trailer) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.name_list_offset, .big);
        std.mem.writeInt(u64, buf[8..16], self.name_count, .big);
        std.mem.writeInt(u64, buf[16..24], self.posting_list_offset, .big);
        std.mem.writeInt(u64, buf[24..32], self.posting_index_offset, .big);
        @memcpy(buf[32..], MAGIC_TRAILER);
        return buf;
    }

    pub fn decode(buf: *const [SIZE]u8) !Trailer {
        if (!std.mem.eql(u8, buf[32..], MAGIC_TRAILER)) {
            return error.InvalidTrailer;
        }
        return .{
            .name_list_offset = std.mem.readInt(u64, buf[0..8], .big),
            .name_count = std.mem.readInt(u64, buf[8..16], .big),
            .posting_list_offset = std.mem.readInt(u64, buf[16..24], .big),
            .posting_index_offset = std.mem.readInt(u64, buf[24..32], .big),
        };
    }
};

pub const PostingIndexEntry = struct {
    tri: Trigram,
    count: u32,
    offset: u64,

    pub fn encode(self: PostingIndexEntry, buf: []u8) usize {
        const tri_bytes = trigram_mod.toBytes(self.tri);
        @memcpy(buf[0..3], &tri_bytes);
        var n: usize = 3;
        n += varint.encode(self.count, buf[n..]);
        n += varint.encode(self.offset, buf[n..]);
        return n;
    }
};

pub const IndexWriter = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    names: std.ArrayList([]const u8),
    postings: std.AutoHashMap(Trigram, *posting.PostingList),
    extractor: trigram_mod.Extractor,
    current_offset: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !IndexWriter {
        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();

        try file.writeAll(MAGIC_HEADER);

        return .{
            .allocator = allocator,
            .file = file,
            .names = .{},
            .postings = std.AutoHashMap(Trigram, *posting.PostingList).init(allocator),
            .extractor = try trigram_mod.Extractor.init(allocator),
            .current_offset = MAGIC_HEADER.len,
        };
    }

    pub fn deinit(self: *IndexWriter) void {
        self.file.close();
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.names.deinit(self.allocator);

        var it = self.postings.valueIterator();
        while (it.next()) |pl_ptr| {
            pl_ptr.*.deinit();
            self.allocator.destroy(pl_ptr.*);
        }
        self.postings.deinit();
        self.extractor.deinit();
    }

    pub fn addFile(self: *IndexWriter, name: []const u8, content: []const u8) !void {
        const combined = try std.mem.concat(self.allocator, u8, &.{ name, "\n", content });
        defer self.allocator.free(combined);

        const trigrams = self.extractor.extract(combined) catch |err| switch (err) {
            error.ContainsNul, error.InvalidUtf8, error.FileTooLong, error.LineTooLong, error.TooManyTrigrams => return,
            error.OutOfMemory => return err,
        };

        const file_id: u32 = @intCast(self.names.items.len);
        const name_copy = try self.allocator.dupe(u8, name);
        try self.names.append(self.allocator, name_copy);

        for (trigrams) |tri| {
            const entry = try self.postings.getOrPut(tri);
            if (!entry.found_existing) {
                const pl = try self.allocator.create(posting.PostingList);
                pl.* = posting.PostingList.init(self.allocator, tri);
                entry.value_ptr.* = pl;
            }
            try entry.value_ptr.*.add(file_id);
        }
    }

    pub fn finish(self: *IndexWriter) !void {
        const name_list_offset = try self.writeNameList();
        const posting_list_offset = try self.writePostingLists();
        const posting_index_offset = try self.writePostingIndex();

        const trailer = Trailer{
            .name_list_offset = name_list_offset,
            .name_count = self.names.items.len,
            .posting_list_offset = posting_list_offset,
            .posting_index_offset = posting_index_offset,
        };
        const trailer_bytes = trailer.encode();
        try self.file.writeAll(&trailer_bytes);
    }

    fn writeNameList(self: *IndexWriter) !u64 {
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

    fn writePostingLists(self: *IndexWriter) !u64 {
        const offset = self.current_offset;

        var trigrams: std.ArrayList(Trigram) = .{};
        defer trigrams.deinit(self.allocator);

        var it = self.postings.keyIterator();
        while (it.next()) |tri| {
            try trigrams.append(self.allocator, tri.*);
        }
        std.mem.sort(Trigram, trigrams.items, {}, std.sort.asc(Trigram));

        for (trigrams.items) |tri| {
            const pl = self.postings.get(tri).?;
            pl.sort();
            const encoded = try pl.encodeDelta(self.allocator);
            defer self.allocator.free(encoded);
            try self.file.writeAll(encoded);
            self.current_offset += encoded.len;
        }

        return offset;
    }

    fn writePostingIndex(self: *IndexWriter) !u64 {
        const offset = self.current_offset;

        var trigrams: std.ArrayList(Trigram) = .{};
        defer trigrams.deinit(self.allocator);

        var it = self.postings.keyIterator();
        while (it.next()) |tri| {
            try trigrams.append(self.allocator, tri.*);
        }
        std.mem.sort(Trigram, trigrams.items, {}, std.sort.asc(Trigram));

        var posting_offset: u64 = 0;
        var buf: [32]u8 = undefined;

        for (trigrams.items) |tri| {
            const pl = self.postings.get(tri).?;
            const encoded = try pl.encodeDelta(self.allocator);
            defer self.allocator.free(encoded);

            const entry = PostingIndexEntry{
                .tri = tri,
                .count = @intCast(pl.file_ids.items.len),
                .offset = posting_offset,
            };
            const n = entry.encode(&buf);
            try self.file.writeAll(buf[0..n]);
            self.current_offset += n;

            posting_offset += encoded.len;
        }

        return offset;
    }
};

test "index writer basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_index_writer_basic_test.idx";

    std.fs.cwd().deleteFile(test_path) catch {};

    {
        var writer = try IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("test.txt", "hello world");
        try writer.addFile("foo.txt", "hello there");
        try writer.finish();
    }

    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();

    var header_buf: [MAGIC_HEADER.len]u8 = undefined;
    _ = try file.readAll(&header_buf);
    try std.testing.expectEqualSlices(u8, MAGIC_HEADER, &header_buf);

    const stat = try file.stat();
    try file.seekTo(stat.size - Trailer.SIZE);

    var trailer_buf: [Trailer.SIZE]u8 = undefined;
    _ = try file.readAll(&trailer_buf);
    const trailer = try Trailer.decode(&trailer_buf);

    try std.testing.expect(trailer.name_count == 2);
    try std.testing.expect(trailer.name_list_offset > 0);
    try std.testing.expect(trailer.posting_list_offset > trailer.name_list_offset);
}
