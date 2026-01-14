const std = @import("std");
const varint = @import("varint.zig");
const trigram_mod = @import("trigram.zig");
const Trigram = trigram_mod.Trigram;

pub const PostEntry = packed struct {
    file_id: u40,
    tri: Trigram,

    pub fn init(tri: Trigram, file_id: u32) PostEntry {
        return .{ .tri = tri, .file_id = file_id };
    }

    pub fn trigram(self: PostEntry) Trigram {
        return self.tri;
    }

    pub fn fileId(self: PostEntry) u32 {
        return @truncate(self.file_id);
    }
};

pub const PostingList = struct {
    tri: Trigram,
    file_ids: std.ArrayList(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tri: Trigram) PostingList {
        return .{
            .tri = tri,
            .file_ids = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PostingList) void {
        self.file_ids.deinit();
    }

    pub fn add(self: *PostingList, file_id: u32) !void {
        try self.file_ids.append(file_id);
    }

    pub fn sort(self: *PostingList) void {
        std.mem.sort(u32, self.file_ids.items, {}, std.sort.asc(u32));
    }

    pub fn encodeDelta(self: *const PostingList, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        const tri_bytes = trigram_mod.toBytes(self.tri);
        try buf.appendSlice(&tri_bytes);

        var prev: u32 = 0;
        var tmp: [10]u8 = undefined;

        for (self.file_ids.items) |fid| {
            const delta = fid - prev;
            const n = varint.encode(delta + 1, &tmp);
            try buf.appendSlice(tmp[0..n]);
            prev = fid;
        }

        const n = varint.encode(0, &tmp);
        try buf.appendSlice(tmp[0..n]);

        return buf.toOwnedSlice();
    }
};

pub const PostingListReader = struct {
    data: []const u8,
    pos: usize,
    current_file_id: u32,

    pub fn init(data: []const u8) PostingListReader {
        return .{
            .data = data,
            .pos = 3,
            .current_file_id = 0,
        };
    }

    pub fn trigram(self: *const PostingListReader) Trigram {
        return trigram_mod.fromBytes(self.data[0], self.data[1], self.data[2]);
    }

    pub fn next(self: *PostingListReader) ?u32 {
        if (self.pos >= self.data.len) return null;

        const result = varint.decode(self.data[self.pos..]);
        self.pos += result.bytes_read;

        if (result.value == 0) return null;

        self.current_file_id += @as(u32, @truncate(result.value)) - 1;
        return self.current_file_id;
    }

    pub fn collect(self: *PostingListReader, allocator: std.mem.Allocator) ![]u32 {
        var list = std.ArrayList(u32).init(allocator);
        errdefer list.deinit();

        while (self.next()) |fid| {
            try list.append(fid);
        }

        return list.toOwnedSlice();
    }
};

test "posting list encode decode" {
    const allocator = std.testing.allocator;

    var pl = PostingList.init(allocator, trigram_mod.fromBytes('a', 'b', 'c'));
    defer pl.deinit();

    try pl.add(10);
    try pl.add(25);
    try pl.add(26);
    try pl.add(30);

    const encoded = try pl.encodeDelta(allocator);
    defer allocator.free(encoded);

    var reader = PostingListReader.init(encoded);
    try std.testing.expectEqual(trigram_mod.fromBytes('a', 'b', 'c'), reader.trigram());

    const file_ids = try reader.collect(allocator);
    defer allocator.free(file_ids);

    try std.testing.expectEqualSlices(u32, &[_]u32{ 10, 25, 26, 30 }, file_ids);
}

test "posting list sorted delta encoding" {
    const allocator = std.testing.allocator;

    var pl = PostingList.init(allocator, trigram_mod.fromBytes('x', 'y', 'z'));
    defer pl.deinit();

    try pl.add(100);
    try pl.add(50);
    try pl.add(200);
    try pl.add(75);

    pl.sort();

    const encoded = try pl.encodeDelta(allocator);
    defer allocator.free(encoded);

    var reader = PostingListReader.init(encoded);
    const file_ids = try reader.collect(allocator);
    defer allocator.free(file_ids);

    try std.testing.expectEqualSlices(u32, &[_]u32{ 50, 75, 100, 200 }, file_ids);
}
