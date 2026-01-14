const std = @import("std");
const varint = @import("varint.zig");
const trigram_mod = @import("trigram.zig");
const position = @import("position.zig");
const Trigram = trigram_mod.Trigram;

pub const MAGIC_HEADER = "hound idx 2\n";
pub const MAGIC_TRAILER = "\nhound trl 2\n";

pub const Trailer = struct {
    name_list_offset: u64,
    name_count: u64,
    posting_list_offset: u64,
    posting_index_offset: u64,
    rune_map_offset: u64,
    rune_map_count: u64,

    pub const SIZE = 8 * 6 + MAGIC_TRAILER.len;

    pub fn encode(self: Trailer) [SIZE]u8 {
        var buf: [SIZE]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.name_list_offset, .big);
        std.mem.writeInt(u64, buf[8..16], self.name_count, .big);
        std.mem.writeInt(u64, buf[16..24], self.posting_list_offset, .big);
        std.mem.writeInt(u64, buf[24..32], self.posting_index_offset, .big);
        std.mem.writeInt(u64, buf[32..40], self.rune_map_offset, .big);
        std.mem.writeInt(u64, buf[40..48], self.rune_map_count, .big);
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
            .posting_list_offset = std.mem.readInt(u64, buf[16..24], .big),
            .posting_index_offset = std.mem.readInt(u64, buf[24..32], .big),
            .rune_map_offset = std.mem.readInt(u64, buf[32..40], .big),
            .rune_map_count = std.mem.readInt(u64, buf[40..48], .big),
        };
    }
};

pub const PostingIndexEntry = struct {
    tri: Trigram,
    file_count: u32,
    position_count: u32,
    offset: u64,

    pub fn encode(self: PostingIndexEntry, buf: []u8) usize {
        const tri_bytes = trigram_mod.toBytes(self.tri);
        @memcpy(buf[0..3], &tri_bytes);
        var n: usize = 3;
        n += varint.encode(self.file_count, buf[n..]);
        n += varint.encode(self.position_count, buf[n..]);
        n += varint.encode(self.offset, buf[n..]);
        return n;
    }
};

pub const PositionalIndexWriter = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    names: std.ArrayList([]const u8),
    contents: std.ArrayList([]const u8),
    postings: std.AutoHashMap(Trigram, *position.PositionalPostingList),
    rune_samplers: std.ArrayList(*position.RuneOffsetSampler),
    current_offset: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !PositionalIndexWriter {
        const f = try std.fs.cwd().createFile(path, .{});
        errdefer f.close();

        try f.writeAll(MAGIC_HEADER);

        return .{
            .allocator = allocator,
            .file = f,
            .names = std.ArrayList([]const u8).init(allocator),
            .contents = std.ArrayList([]const u8).init(allocator),
            .postings = std.AutoHashMap(Trigram, *position.PositionalPostingList).init(allocator),
            .rune_samplers = std.ArrayList(*position.RuneOffsetSampler).init(allocator),
            .current_offset = MAGIC_HEADER.len,
        };
    }

    pub fn deinit(self: *PositionalIndexWriter) void {
        self.file.close();
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.names.deinit();

        for (self.contents.items) |content| {
            self.allocator.free(content);
        }
        self.contents.deinit();

        var it = self.postings.valueIterator();
        while (it.next()) |pl_ptr| {
            pl_ptr.*.deinit();
            self.allocator.destroy(pl_ptr.*);
        }
        self.postings.deinit();

        for (self.rune_samplers.items) |sampler| {
            sampler.deinit();
            self.allocator.destroy(sampler);
        }
        self.rune_samplers.deinit();
    }

    pub fn addFile(self: *PositionalIndexWriter, name: []const u8, content: []const u8) !void {
        const file_id: u32 = @intCast(self.names.items.len);
        const name_copy = try self.allocator.dupe(u8, name);
        try self.names.append(name_copy);

        const combined = try std.mem.concat(self.allocator, u8, &.{ name, "\n", content });
        try self.contents.append(combined);

        const sampler = try self.allocator.create(position.RuneOffsetSampler);
        sampler.* = position.RuneOffsetSampler.init(self.allocator);
        try self.rune_samplers.append(sampler);

        self.extractPositionalTrigrams(file_id, combined, sampler) catch |err| switch (err) {
            error.ContainsNul, error.InvalidUtf8, error.FileTooLong, error.LineTooLong => return,
            error.OutOfMemory => return err,
        };
    }

    fn extractPositionalTrigrams(
        self: *PositionalIndexWriter,
        file_id: u32,
        data: []const u8,
        sampler: *position.RuneOffsetSampler,
    ) !void {
        const max_file_len: u64 = 1 << 30;
        const max_line_len: usize = 2000;

        if (data.len > max_file_len) return error.FileTooLong;

        var byte_offset: u32 = 0;
        var rune_offset: u32 = 0;
        var line_len: usize = 0;

        var window: [3]u8 = undefined;
        var window_pos: usize = 0;
        var window_byte_offsets: [3]u32 = undefined;
        var window_rune_offsets: [3]u32 = undefined;

        while (byte_offset < data.len) {
            const c = data[byte_offset];
            if (c == 0) return error.ContainsNul;

            const byte_len = utf8ByteLen(c);
            if (byte_offset + byte_len > data.len) return error.InvalidUtf8;

            if (byte_len > 1) {
                for (1..byte_len) |j| {
                    if (byte_offset + j >= data.len) return error.InvalidUtf8;
                    const cont = data[byte_offset + j];
                    if (cont < 0x80 or cont >= 0xC0) return error.InvalidUtf8;
                }
            }

            try sampler.sample(rune_offset, byte_offset);

            window[window_pos % 3] = c;
            window_byte_offsets[window_pos % 3] = byte_offset;
            window_rune_offsets[window_pos % 3] = rune_offset;
            window_pos += 1;

            if (window_pos >= 3) {
                const oldest_idx = (window_pos - 3) % 3;
                const mid_idx = (window_pos - 2) % 3;
                const newest_idx = (window_pos - 1) % 3;

                const b0 = window[oldest_idx];
                const b1 = window[mid_idx];
                const b2 = window[newest_idx];

                if (!validUtf8Pair(b0, b1) or !validUtf8Pair(b1, b2)) {
                    return error.InvalidUtf8;
                }

                const tri = trigram_mod.fromBytes(b0, b1, b2);
                const tri_byte_offset = window_byte_offsets[oldest_idx];
                const tri_rune_offset = window_rune_offsets[oldest_idx];

                const entry = try self.postings.getOrPut(tri);
                if (!entry.found_existing) {
                    const pl = try self.allocator.create(position.PositionalPostingList);
                    pl.* = position.PositionalPostingList.init(self.allocator, tri);
                    entry.value_ptr.* = pl;
                }
                try entry.value_ptr.*.add(file_id, tri_byte_offset, tri_rune_offset);
            }

            byte_offset += @as(u32, @intCast(byte_len));
            rune_offset += 1;

            line_len += 1;
            if (line_len > max_line_len) return error.LineTooLong;
            if (c == '\n') line_len = 0;
        }
    }

    pub fn finish(self: *PositionalIndexWriter) !void {
        const name_list_offset = try self.writeNameList();
        const posting_list_offset = try self.writePostingLists();
        const posting_index_offset = try self.writePostingIndex();
        const rune_map_offset = try self.writeRuneMaps();

        const trailer = Trailer{
            .name_list_offset = name_list_offset,
            .name_count = self.names.items.len,
            .posting_list_offset = posting_list_offset,
            .posting_index_offset = posting_index_offset,
            .rune_map_offset = rune_map_offset,
            .rune_map_count = self.rune_samplers.items.len,
        };
        const trailer_bytes = trailer.encode();
        try self.file.writeAll(&trailer_bytes);
    }

    fn writeNameList(self: *PositionalIndexWriter) !u64 {
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

    fn writePostingLists(self: *PositionalIndexWriter) !u64 {
        const offset = self.current_offset;

        var trigrams = std.ArrayList(Trigram).init(self.allocator);
        defer trigrams.deinit();

        var it = self.postings.keyIterator();
        while (it.next()) |tri| {
            try trigrams.append(tri.*);
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

    fn writePostingIndex(self: *PositionalIndexWriter) !u64 {
        const offset = self.current_offset;

        var trigrams = std.ArrayList(Trigram).init(self.allocator);
        defer trigrams.deinit();

        var it = self.postings.keyIterator();
        while (it.next()) |tri| {
            try trigrams.append(tri.*);
        }
        std.mem.sort(Trigram, trigrams.items, {}, std.sort.asc(Trigram));

        var posting_offset: u64 = 0;
        var buf: [48]u8 = undefined;

        for (trigrams.items) |tri| {
            const pl = self.postings.get(tri).?;
            pl.sort();
            const encoded = try pl.encodeDelta(self.allocator);
            defer self.allocator.free(encoded);

            var total_positions: u32 = 0;
            for (pl.file_positions.items) |fp| {
                total_positions += @intCast(fp.positions.items.len);
            }

            const entry = PostingIndexEntry{
                .tri = tri,
                .file_count = @intCast(pl.fileCount()),
                .position_count = total_positions,
                .offset = posting_offset,
            };
            const n = entry.encode(&buf);
            try self.file.writeAll(buf[0..n]);
            self.current_offset += n;

            posting_offset += encoded.len;
        }

        return offset;
    }

    fn writeRuneMaps(self: *PositionalIndexWriter) !u64 {
        const offset = self.current_offset;
        var buf: [10]u8 = undefined;

        for (self.rune_samplers.items) |sampler| {
            const encoded = try sampler.encode(self.allocator);
            defer self.allocator.free(encoded);

            const len_bytes = varint.encode(encoded.len, &buf);
            try self.file.writeAll(buf[0..len_bytes]);
            try self.file.writeAll(encoded);
            self.current_offset += len_bytes + encoded.len;
        }

        return offset;
    }
};

fn utf8ByteLen(first_byte: u8) u32 {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

fn validUtf8Pair(c1: u8, c2: u8) bool {
    if (c1 < 0x80) {
        return c2 < 0x80 or (c2 >= 0xC0 and c2 < 0xF8);
    } else if (c1 < 0xC0) {
        return c2 < 0xF8;
    } else if (c1 < 0xF8) {
        return c2 >= 0x80 and c2 < 0xC0;
    }
    return false;
}

test "positional index writer basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_positional_test.idx";

    {
        var writer = try PositionalIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("test.txt", "hello world");
        try writer.addFile("foo.txt", "hello there");
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
    try std.testing.expect(trailer.name_list_offset > 0);
    try std.testing.expect(trailer.posting_list_offset > trailer.name_list_offset);
    try std.testing.expect(trailer.rune_map_count == 2);
}

test "positional index positions recorded" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_positional_positions.idx";

    {
        var writer = try PositionalIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("test.txt", "abc abc");
        try writer.finish();
    }

    const f = try std.fs.cwd().openFile(test_path, .{});
    defer f.close();

    const stat = try f.stat();
    try f.seekTo(stat.size - Trailer.SIZE);

    var trailer_buf: [Trailer.SIZE]u8 = undefined;
    _ = try f.readAll(&trailer_buf);
    const trailer = try Trailer.decode(&trailer_buf);

    try std.testing.expect(trailer.name_count == 1);
    try std.testing.expect(trailer.posting_index_offset > trailer.posting_list_offset);
}

test "positional index utf8" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_positional_utf8.idx";

    {
        var writer = try PositionalIndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile("test.txt", "hello 世界");
        try writer.finish();
    }

    const f = try std.fs.cwd().openFile(test_path, .{});
    defer f.close();

    const stat = try f.stat();
    try f.seekTo(stat.size - Trailer.SIZE);

    var trailer_buf: [Trailer.SIZE]u8 = undefined;
    _ = try f.readAll(&trailer_buf);
    const trailer = try Trailer.decode(&trailer_buf);

    try std.testing.expect(trailer.name_count == 1);
    try std.testing.expect(trailer.rune_map_count == 1);
}
