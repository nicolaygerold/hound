const std = @import("std");
const posix = std.posix;
const varint = @import("varint.zig");
const trigram_mod = @import("trigram.zig");
const position = @import("position.zig");
const positional_index = @import("positional_index.zig");
const Trigram = trigram_mod.Trigram;

pub const PositionalIndexReader = struct {
    data: []align(std.mem.page_size) const u8,
    fd: posix.fd_t,
    trailer: positional_index.Trailer,
    posting_index: PostingIndex,
    rune_map_offsets: []u64,
    allocator: std.mem.Allocator,

    pub const OpenError = error{
        InvalidMagic,
        InvalidTrailer,
        FileTooSmall,
    } || posix.MMapError || std.fs.File.OpenError || std.fs.File.StatError || std.mem.Allocator.Error;

    pub fn open(allocator: std.mem.Allocator, path: []const u8) OpenError!PositionalIndexReader {
        const file = try std.fs.cwd().openFile(path, .{});
        const fd = file.handle;
        errdefer posix.close(fd);

        const stat = try file.stat();
        const size = stat.size;

        if (size < positional_index.MAGIC_HEADER.len + positional_index.Trailer.SIZE) {
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

        if (!std.mem.eql(u8, data[0..positional_index.MAGIC_HEADER.len], positional_index.MAGIC_HEADER)) {
            posix.munmap(data);
            return error.InvalidMagic;
        }

        const trailer_start = size - positional_index.Trailer.SIZE;
        const trailer = positional_index.Trailer.decode(data[trailer_start..][0..positional_index.Trailer.SIZE]) catch {
            posix.munmap(data);
            return error.InvalidTrailer;
        };

        const posting_index = try PostingIndex.build(
            allocator,
            data[trailer.posting_index_offset..trailer.rune_map_offset],
        );

        const rune_map_offsets = try buildRuneMapOffsets(
            allocator,
            data[trailer.rune_map_offset..trailer_start],
            trailer.rune_map_count,
        );

        return .{
            .data = data,
            .fd = fd,
            .trailer = trailer,
            .posting_index = posting_index,
            .rune_map_offsets = rune_map_offsets,
            .allocator = allocator,
        };
    }

    pub fn close(self: *PositionalIndexReader) void {
        self.posting_index.deinit();
        self.allocator.free(self.rune_map_offsets);
        posix.munmap(self.data);
        posix.close(self.fd);
    }

    pub fn nameCount(self: *const PositionalIndexReader) u64 {
        return self.trailer.name_count;
    }

    pub fn getName(self: *const PositionalIndexReader, file_id: u32) ?[]const u8 {
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

    pub fn lookupTrigram(self: *const PositionalIndexReader, tri: Trigram) ?PositionalPostingListView {
        const entry = self.posting_index.lookup(tri) orelse return null;
        const start = self.trailer.posting_list_offset + entry.offset;
        return PositionalPostingListView.init(self.data[start..], entry.file_count, entry.position_count);
    }

    pub fn trigramCount(self: *const PositionalIndexReader) usize {
        return self.posting_index.entries.items.len;
    }

    pub fn getRuneMapData(self: *const PositionalIndexReader, file_id: u32) ?[]const u8 {
        if (file_id >= self.rune_map_offsets.len) return null;

        const start = self.trailer.rune_map_offset + self.rune_map_offsets[file_id];
        const len_result = varint.decode(self.data[start..]);
        const data_start = start + len_result.bytes_read;
        const data_end = data_start + len_result.value;

        return self.data[data_start..data_end];
    }

    pub fn getRuneMap(self: *const PositionalIndexReader, file_id: u32) !?position.RuneOffsetMap {
        const rune_data = self.getRuneMapData(file_id) orelse return null;
        return try position.RuneOffsetMap.decode(self.allocator, rune_data);
    }
};

fn buildRuneMapOffsets(
    allocator: std.mem.Allocator,
    data: []const u8,
    count: u64,
) ![]u64 {
    var offsets = try allocator.alloc(u64, @intCast(count));
    errdefer allocator.free(offsets);

    var pos: u64 = 0;
    for (0..@as(usize, @intCast(count))) |i| {
        offsets[i] = pos;
        const len_result = varint.decode(data[@intCast(pos)..]);
        pos += len_result.bytes_read + len_result.value;
    }

    return offsets;
}

const PostingIndex = struct {
    entries: std.ArrayList(Entry),

    const Entry = struct {
        tri: Trigram,
        file_count: u32,
        position_count: u32,
        offset: u64,
    };

    fn build(allocator: std.mem.Allocator, data: []const u8) !PostingIndex {
        var entries = std.ArrayList(Entry).init(allocator);
        errdefer entries.deinit();

        var pos: usize = 0;
        while (pos + 3 <= data.len) {
            const tri = trigram_mod.fromBytes(data[pos], data[pos + 1], data[pos + 2]);
            pos += 3;

            const file_count_result = varint.decode(data[pos..]);
            pos += file_count_result.bytes_read;

            const position_count_result = varint.decode(data[pos..]);
            pos += position_count_result.bytes_read;

            const offset_result = varint.decode(data[pos..]);
            pos += offset_result.bytes_read;

            try entries.append(.{
                .tri = tri,
                .file_count = @truncate(file_count_result.value),
                .position_count = @truncate(position_count_result.value),
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

pub const PositionalPostingListView = struct {
    data: []const u8,
    pos: usize,
    current_file_id: u32,
    file_count: u32,
    position_count: u32,
    files_read: u32,

    pub fn init(data: []const u8, file_count: u32, position_count: u32) PositionalPostingListView {
        return .{
            .data = data,
            .pos = 3,
            .current_file_id = 0,
            .file_count = file_count,
            .position_count = position_count,
            .files_read = 0,
        };
    }

    pub fn trigram(self: *const PositionalPostingListView) Trigram {
        return trigram_mod.fromBytes(self.data[0], self.data[1], self.data[2]);
    }

    pub const FileEntry = struct {
        file_id: u32,
        positions: []position.TrigramPosition,
    };

    pub fn next(self: *PositionalPostingListView, allocator: std.mem.Allocator) !?FileEntry {
        if (self.pos >= self.data.len) return null;

        const file_delta_result = varint.decode(self.data[self.pos..]);
        self.pos += file_delta_result.bytes_read;

        if (file_delta_result.value == 0) return null;

        self.current_file_id += @as(u32, @truncate(file_delta_result.value)) - 1;

        const pos_count_result = varint.decode(self.data[self.pos..]);
        self.pos += pos_count_result.bytes_read;
        const pos_count: usize = @intCast(pos_count_result.value);

        var positions = try allocator.alloc(position.TrigramPosition, pos_count);
        errdefer allocator.free(positions);

        var prev_byte_offset: u32 = 0;
        var prev_rune_offset: u32 = 0;

        for (0..pos_count) |i| {
            const byte_delta_result = varint.decode(self.data[self.pos..]);
            self.pos += byte_delta_result.bytes_read;

            const rune_delta_result = varint.decode(self.data[self.pos..]);
            self.pos += rune_delta_result.bytes_read;

            prev_byte_offset += @truncate(byte_delta_result.value);
            prev_rune_offset += @truncate(rune_delta_result.value);

            positions[i] = .{
                .byte_offset = prev_byte_offset,
                .rune_offset = prev_rune_offset,
            };
        }

        self.files_read += 1;
        return .{
            .file_id = self.current_file_id,
            .positions = positions,
        };
    }

    pub fn collectFileIds(self: *PositionalPostingListView, allocator: std.mem.Allocator) ![]u32 {
        var list = std.ArrayList(u32).init(allocator);
        errdefer list.deinit();

        while (try self.next(allocator)) |entry| {
            allocator.free(entry.positions);
            try list.append(entry.file_id);
        }

        return list.toOwnedSlice();
    }
};

pub fn proximitySearch(
    allocator: std.mem.Allocator,
    reader: *const PositionalIndexReader,
    trigram_a: Trigram,
    trigram_b: Trigram,
    max_distance: u32,
) ![]u32 {
    const view_a = reader.lookupTrigram(trigram_a) orelse return &[_]u32{};
    const view_b = reader.lookupTrigram(trigram_b) orelse return &[_]u32{};

    var v_a = view_a;
    var v_b = view_b;

    var file_positions_a = std.AutoHashMap(u32, []position.TrigramPosition).init(allocator);
    defer {
        var it = file_positions_a.valueIterator();
        while (it.next()) |positions| {
            allocator.free(positions.*);
        }
        file_positions_a.deinit();
    }

    var file_positions_b = std.AutoHashMap(u32, []position.TrigramPosition).init(allocator);
    defer {
        var it = file_positions_b.valueIterator();
        while (it.next()) |positions| {
            allocator.free(positions.*);
        }
        file_positions_b.deinit();
    }

    while (try v_a.next(allocator)) |entry| {
        try file_positions_a.put(entry.file_id, entry.positions);
    }

    while (try v_b.next(allocator)) |entry| {
        try file_positions_b.put(entry.file_id, entry.positions);
    }

    var results = std.ArrayList(u32).init(allocator);
    errdefer results.deinit();

    var it = file_positions_a.iterator();
    while (it.next()) |kv| {
        const file_id = kv.key_ptr.*;
        const pos_a = kv.value_ptr.*;
        if (file_positions_b.get(file_id)) |pos_b| {
            if (position.proximityMatch(pos_a, pos_b, max_distance)) {
                try results.append(file_id);
            }
        }
    }

    std.mem.sort(u32, results.items, {}, std.sort.asc(u32));
    return results.toOwnedSlice();
}

test "positional index reader basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_positional_reader_test.idx";

    {
        var writer = try positional_index.PositionalIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("test.txt", "hello world");
        try writer.addFile("foo.txt", "hello there");
        try writer.addFile("bar.txt", "world hello");
        try writer.finish();
    }

    var reader = try PositionalIndexReader.open(allocator, test_path);
    defer reader.close();

    try std.testing.expectEqual(@as(u64, 3), reader.nameCount());
    try std.testing.expectEqualSlices(u8, "test.txt", reader.getName(0).?);
    try std.testing.expectEqualSlices(u8, "foo.txt", reader.getName(1).?);
    try std.testing.expectEqualSlices(u8, "bar.txt", reader.getName(2).?);
    try std.testing.expect(reader.getName(3) == null);
}

test "positional index reader trigram lookup with positions" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_positional_reader_positions.idx";

    {
        var writer = try positional_index.PositionalIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("test.txt", "abc abc def");
        try writer.finish();
    }

    var reader = try PositionalIndexReader.open(allocator, test_path);
    defer reader.close();

    const tri_abc = trigram_mod.fromBytes('a', 'b', 'c');
    var view = reader.lookupTrigram(tri_abc).?;

    const entry = (try view.next(allocator)).?;
    defer allocator.free(entry.positions);

    try std.testing.expectEqual(@as(u32, 0), entry.file_id);
    try std.testing.expectEqual(@as(usize, 2), entry.positions.len);
    try std.testing.expectEqual(@as(u32, 0), entry.positions[0].byte_offset);
    try std.testing.expectEqual(@as(u32, 4), entry.positions[1].byte_offset);
}

test "proximity search" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_proximity_search.idx";

    {
        var writer = try positional_index.PositionalIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("close.txt", "abc def ghi");
        try writer.addFile("far.txt", "abc xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx def");
        try writer.addFile("no_match.txt", "xyz only");
        try writer.finish();
    }

    var reader = try PositionalIndexReader.open(allocator, test_path);
    defer reader.close();

    const tri_abc = trigram_mod.fromBytes('a', 'b', 'c');
    const tri_def = trigram_mod.fromBytes('d', 'e', 'f');

    const close_results = try proximitySearch(allocator, &reader, tri_abc, tri_def, 10);
    defer allocator.free(close_results);
    try std.testing.expectEqual(@as(usize, 1), close_results.len);
    try std.testing.expectEqual(@as(u32, 0), close_results[0]);

    const wide_results = try proximitySearch(allocator, &reader, tri_abc, tri_def, 50);
    defer allocator.free(wide_results);
    try std.testing.expectEqual(@as(usize, 2), wide_results.len);
}

test "positional index rune map" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_positional_rune_map.idx";

    {
        var writer = try positional_index.PositionalIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("test.txt", "hello world");
        try writer.finish();
    }

    var reader = try PositionalIndexReader.open(allocator, test_path);
    defer reader.close();

    const rune_data = reader.getRuneMapData(0);
    try std.testing.expect(rune_data != null);
}
