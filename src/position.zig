const std = @import("std");
const varint = @import("varint.zig");
const trigram_mod = @import("trigram.zig");
const Trigram = trigram_mod.Trigram;

pub const RUNE_SAMPLE_FREQUENCY: u32 = 100;

pub const TrigramPosition = struct {
    byte_offset: u32,
    rune_offset: u32,
};

pub const FilePositions = struct {
    file_id: u32,
    positions: std.ArrayList(TrigramPosition),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, file_id: u32) FilePositions {
        return .{
            .file_id = file_id,
            .positions = std.ArrayList(TrigramPosition){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FilePositions) void {
        self.positions.deinit(self.allocator);
    }

    pub fn addPosition(self: *FilePositions, byte_offset: u32, rune_offset: u32) !void {
        try self.positions.append(self.allocator, .{
            .byte_offset = byte_offset,
            .rune_offset = rune_offset,
        });
    }
};

pub const PositionalPostingList = struct {
    tri: Trigram,
    file_positions: std.ArrayList(*FilePositions),
    file_map: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tri: Trigram) PositionalPostingList {
        return .{
            .tri = tri,
            .file_positions = std.ArrayList(*FilePositions){},
            .file_map = std.AutoHashMap(u32, usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PositionalPostingList) void {
        for (self.file_positions.items) |fp| {
            fp.deinit();
            self.allocator.destroy(fp);
        }
        self.file_positions.deinit(self.allocator);
        self.file_map.deinit();
    }

    pub fn add(self: *PositionalPostingList, file_id: u32, byte_offset: u32, rune_offset: u32) !void {
        const entry = try self.file_map.getOrPut(file_id);
        if (!entry.found_existing) {
            const fp = try self.allocator.create(FilePositions);
            fp.* = FilePositions.init(self.allocator, file_id);
            entry.value_ptr.* = self.file_positions.items.len;
            try self.file_positions.append(self.allocator, fp);
        }
        try self.file_positions.items[entry.value_ptr.*].addPosition(byte_offset, rune_offset);
    }

    pub fn sort(self: *PositionalPostingList) void {
        std.mem.sort(*FilePositions, self.file_positions.items, {}, struct {
            fn lessThan(_: void, a: *FilePositions, b: *FilePositions) bool {
                return a.file_id < b.file_id;
            }
        }.lessThan);

        for (self.file_positions.items, 0..) |fp, i| {
            self.file_map.put(fp.file_id, i) catch {};
        }
    }

    pub fn fileCount(self: *const PositionalPostingList) usize {
        return self.file_positions.items.len;
    }

    pub fn encodeDelta(self: *const PositionalPostingList, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(allocator);

        const tri_bytes = trigram_mod.toBytes(self.tri);
        try buf.appendSlice(allocator, &tri_bytes);

        var tmp: [10]u8 = undefined;
        var prev_file_id: u32 = 0;

        for (self.file_positions.items) |fp| {
            const file_delta = fp.file_id - prev_file_id;
            var n = varint.encode(file_delta + 1, &tmp);
            try buf.appendSlice(allocator, tmp[0..n]);

            n = varint.encode(fp.positions.items.len, &tmp);
            try buf.appendSlice(allocator, tmp[0..n]);

            var prev_byte_offset: u32 = 0;
            var prev_rune_offset: u32 = 0;

            for (fp.positions.items) |pos| {
                const byte_delta = pos.byte_offset - prev_byte_offset;
                const rune_delta = pos.rune_offset - prev_rune_offset;

                n = varint.encode(byte_delta, &tmp);
                try buf.appendSlice(allocator, tmp[0..n]);

                n = varint.encode(rune_delta, &tmp);
                try buf.appendSlice(allocator, tmp[0..n]);

                prev_byte_offset = pos.byte_offset;
                prev_rune_offset = pos.rune_offset;
            }

            prev_file_id = fp.file_id;
        }

        const n = varint.encode(0, &tmp);
        try buf.appendSlice(allocator, tmp[0..n]);

        return buf.toOwnedSlice(allocator);
    }
};

pub const PositionalPostingReader = struct {
    data: []const u8,
    pos: usize,
    current_file_id: u32,

    pub fn init(data: []const u8) PositionalPostingReader {
        return .{
            .data = data,
            .pos = 3,
            .current_file_id = 0,
        };
    }

    pub fn trigram(self: *const PositionalPostingReader) Trigram {
        return trigram_mod.fromBytes(self.data[0], self.data[1], self.data[2]);
    }

    pub const FileEntry = struct {
        file_id: u32,
        positions: []TrigramPosition,
    };

    pub fn next(self: *PositionalPostingReader, allocator: std.mem.Allocator) !?FileEntry {
        if (self.pos >= self.data.len) return null;

        const file_delta_result = varint.decode(self.data[self.pos..]);
        self.pos += file_delta_result.bytes_read;

        if (file_delta_result.value == 0) return null;

        self.current_file_id += @as(u32, @truncate(file_delta_result.value)) - 1;

        const pos_count_result = varint.decode(self.data[self.pos..]);
        self.pos += pos_count_result.bytes_read;
        const pos_count: usize = @intCast(pos_count_result.value);

        var positions = try allocator.alloc(TrigramPosition, pos_count);
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

        return .{
            .file_id = self.current_file_id,
            .positions = positions,
        };
    }
};

pub const RuneOffsetSampler = struct {
    samples: std.ArrayList(RuneSample),
    allocator: std.mem.Allocator,

    pub const RuneSample = struct {
        rune_offset: u32,
        byte_offset: u32,
    };

    pub fn init(allocator: std.mem.Allocator) RuneOffsetSampler {
        return .{
            .samples = std.ArrayList(RuneSample){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RuneOffsetSampler) void {
        self.samples.deinit(self.allocator);
    }

    pub fn reset(self: *RuneOffsetSampler) void {
        self.samples.clearRetainingCapacity();
    }

    pub fn sample(self: *RuneOffsetSampler, rune_offset: u32, byte_offset: u32) !void {
        if (rune_offset % RUNE_SAMPLE_FREQUENCY == 0) {
            try self.samples.append(self.allocator, .{
                .rune_offset = rune_offset,
                .byte_offset = byte_offset,
            });
        }
    }

    pub fn runeToByteOffset(self: *const RuneOffsetSampler, rune_offset: u32, content: []const u8) u32 {
        if (self.samples.items.len == 0) {
            return linearRuneToByteOffset(0, rune_offset, content);
        }

        const sample_idx = rune_offset / RUNE_SAMPLE_FREQUENCY;
        if (sample_idx >= self.samples.items.len) {
            const last = self.samples.items[self.samples.items.len - 1];
            const remaining = rune_offset - last.rune_offset;
            return last.byte_offset + linearRuneToByteOffset(last.byte_offset, remaining, content);
        }

        const s = self.samples.items[sample_idx];
        const remaining = rune_offset - s.rune_offset;
        if (remaining == 0) {
            return s.byte_offset;
        }
        return s.byte_offset + linearRuneToByteOffset(s.byte_offset, remaining, content);
    }

    pub fn encode(self: *const RuneOffsetSampler, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(allocator);

        var tmp: [10]u8 = undefined;
        var n = varint.encode(self.samples.items.len, &tmp);
        try buf.appendSlice(allocator, tmp[0..n]);

        var prev_byte_offset: u32 = 0;
        for (self.samples.items) |s| {
            const delta = s.byte_offset - prev_byte_offset;
            n = varint.encode(delta, &tmp);
            try buf.appendSlice(allocator, tmp[0..n]);
            prev_byte_offset = s.byte_offset;
        }

        return buf.toOwnedSlice(allocator);
    }
};

pub const RuneOffsetMap = struct {
    samples: []u32,
    allocator: std.mem.Allocator,

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !RuneOffsetMap {
        var pos: usize = 0;
        const count_result = varint.decode(data[pos..]);
        pos += count_result.bytes_read;
        const count: usize = @intCast(count_result.value);

        var samples = try allocator.alloc(u32, count);
        errdefer allocator.free(samples);

        var prev_byte_offset: u32 = 0;
        for (0..count) |i| {
            const delta_result = varint.decode(data[pos..]);
            pos += delta_result.bytes_read;
            prev_byte_offset += @truncate(delta_result.value);
            samples[i] = prev_byte_offset;
        }

        return .{
            .samples = samples,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RuneOffsetMap) void {
        self.allocator.free(self.samples);
    }

    pub fn runeToByteOffset(self: *const RuneOffsetMap, rune_offset: u32, content: []const u8) u32 {
        if (self.samples.len == 0) {
            return linearRuneToByteOffset(0, rune_offset, content);
        }

        const sample_idx = rune_offset / RUNE_SAMPLE_FREQUENCY;
        if (sample_idx >= self.samples.len) {
            const last_byte_offset = self.samples[self.samples.len - 1];
            const last_rune_offset = @as(u32, @intCast(self.samples.len - 1)) * RUNE_SAMPLE_FREQUENCY;
            const remaining = rune_offset - last_rune_offset;
            return last_byte_offset + linearRuneToByteOffsetFromStart(last_byte_offset, remaining, content);
        }

        const base_byte_offset = self.samples[sample_idx];
        const base_rune_offset = sample_idx * RUNE_SAMPLE_FREQUENCY;
        const remaining = rune_offset - base_rune_offset;
        if (remaining == 0) {
            return base_byte_offset;
        }
        return base_byte_offset + linearRuneToByteOffsetFromStart(base_byte_offset, remaining, content);
    }
};

fn linearRuneToByteOffset(start_byte: u32, rune_count: u32, content: []const u8) u32 {
    _ = start_byte;
    var byte_offset: u32 = 0;
    var runes_remaining = rune_count;
    var i: usize = 0;

    while (runes_remaining > 0 and i < content.len) {
        const byte_len = utf8ByteLen(content[i]);
        byte_offset += byte_len;
        i += byte_len;
        runes_remaining -= 1;
    }

    return byte_offset;
}

fn linearRuneToByteOffsetFromStart(start_byte: u32, rune_count: u32, content: []const u8) u32 {
    if (start_byte >= content.len) return 0;
    var byte_offset: u32 = 0;
    var runes_remaining = rune_count;
    var i: usize = start_byte;

    while (runes_remaining > 0 and i < content.len) {
        const byte_len = utf8ByteLen(content[i]);
        byte_offset += byte_len;
        i += byte_len;
        runes_remaining -= 1;
    }

    return byte_offset;
}

fn utf8ByteLen(first_byte: u8) u32 {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

pub const PositionalExtractor = struct {
    allocator: std.mem.Allocator,
    postings: std.AutoHashMap(Trigram, *PositionalPostingList),
    sampler: RuneOffsetSampler,

    const max_file_len: u64 = 1 << 30;
    const max_line_len: usize = 2000;
    const max_trigrams: usize = 20000;

    pub fn init(allocator: std.mem.Allocator) PositionalExtractor {
        return .{
            .allocator = allocator,
            .postings = std.AutoHashMap(Trigram, *PositionalPostingList).init(allocator),
            .sampler = RuneOffsetSampler.init(allocator),
        };
    }

    pub fn deinit(self: *PositionalExtractor) void {
        var it = self.postings.valueIterator();
        while (it.next()) |pl_ptr| {
            pl_ptr.*.deinit();
            self.allocator.destroy(pl_ptr.*);
        }
        self.postings.deinit();
        self.sampler.deinit();
    }

    pub fn reset(self: *PositionalExtractor) void {
        var it = self.postings.valueIterator();
        while (it.next()) |pl_ptr| {
            pl_ptr.*.deinit();
            self.allocator.destroy(pl_ptr.*);
        }
        self.postings.clearRetainingCapacity();
        self.sampler.reset();
    }

    pub const ExtractError = error{
        ContainsNul,
        InvalidUtf8,
        FileTooLong,
        LineTooLong,
        TooManyTrigrams,
        OutOfMemory,
    };

    pub fn extract(self: *PositionalExtractor, file_id: u32, data: []const u8) ExtractError!void {
        self.sampler.reset();

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

            try self.sampler.sample(rune_offset, byte_offset);

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
                    const pl = try self.allocator.create(PositionalPostingList);
                    pl.* = PositionalPostingList.init(self.allocator, tri);
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

        if (self.postings.count() > max_trigrams) return error.TooManyTrigrams;
    }

    pub fn getRuneSampler(self: *const PositionalExtractor) *const RuneOffsetSampler {
        return &self.sampler;
    }
};

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

pub fn proximityMatch(
    positions_a: []const TrigramPosition,
    positions_b: []const TrigramPosition,
    max_distance: u32,
) bool {
    for (positions_a) |pa| {
        for (positions_b) |pb| {
            const dist = if (pa.rune_offset > pb.rune_offset)
                pa.rune_offset - pb.rune_offset
            else
                pb.rune_offset - pa.rune_offset;

            if (dist <= max_distance) {
                return true;
            }
        }
    }
    return false;
}

pub fn findProximityMatches(
    allocator: std.mem.Allocator,
    positions_a: []const TrigramPosition,
    positions_b: []const TrigramPosition,
    max_distance: u32,
) ![]struct { a: TrigramPosition, b: TrigramPosition } {
    var matches = std.ArrayList(struct { a: TrigramPosition, b: TrigramPosition }){};
    errdefer matches.deinit(allocator);

    for (positions_a) |pa| {
        for (positions_b) |pb| {
            const dist = if (pa.rune_offset > pb.rune_offset)
                pa.rune_offset - pb.rune_offset
            else
                pb.rune_offset - pa.rune_offset;

            if (dist <= max_distance) {
                try matches.append(allocator, .{ .a = pa, .b = pb });
            }
        }
    }

    return matches.toOwnedSlice(allocator);
}

test "positional posting list encode decode" {
    const allocator = std.testing.allocator;

    var pl = PositionalPostingList.init(allocator, trigram_mod.fromBytes('a', 'b', 'c'));
    defer pl.deinit();

    try pl.add(0, 0, 0);
    try pl.add(0, 10, 10);
    try pl.add(0, 25, 25);
    try pl.add(1, 5, 5);
    try pl.add(1, 15, 15);

    pl.sort();

    const encoded = try pl.encodeDelta(allocator);
    defer allocator.free(encoded);

    var reader = PositionalPostingReader.init(encoded);
    try std.testing.expectEqual(trigram_mod.fromBytes('a', 'b', 'c'), reader.trigram());

    const entry0 = (try reader.next(allocator)).?;
    defer allocator.free(entry0.positions);
    try std.testing.expectEqual(@as(u32, 0), entry0.file_id);
    try std.testing.expectEqual(@as(usize, 3), entry0.positions.len);
    try std.testing.expectEqual(@as(u32, 0), entry0.positions[0].byte_offset);
    try std.testing.expectEqual(@as(u32, 10), entry0.positions[1].byte_offset);
    try std.testing.expectEqual(@as(u32, 25), entry0.positions[2].byte_offset);

    const entry1 = (try reader.next(allocator)).?;
    defer allocator.free(entry1.positions);
    try std.testing.expectEqual(@as(u32, 1), entry1.file_id);
    try std.testing.expectEqual(@as(usize, 2), entry1.positions.len);

    try std.testing.expect((try reader.next(allocator)) == null);
}

test "rune offset sampling" {
    const allocator = std.testing.allocator;

    var sampler = RuneOffsetSampler.init(allocator);
    defer sampler.deinit();

    var byte_offset: u32 = 0;
    for (0..250) |rune_offset| {
        try sampler.sample(@intCast(rune_offset), byte_offset);
        byte_offset += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), sampler.samples.items.len);
    try std.testing.expectEqual(@as(u32, 0), sampler.samples.items[0].byte_offset);
    try std.testing.expectEqual(@as(u32, 100), sampler.samples.items[1].byte_offset);
    try std.testing.expectEqual(@as(u32, 200), sampler.samples.items[2].byte_offset);
}

test "rune offset sampling with multibyte utf8" {
    const allocator = std.testing.allocator;

    var sampler = RuneOffsetSampler.init(allocator);
    defer sampler.deinit();

    var byte_offset: u32 = 0;
    for (0..110) |rune_offset| {
        try sampler.sample(@intCast(rune_offset), byte_offset);
        byte_offset += if (rune_offset % 10 == 0) 3 else 1;
    }

    try std.testing.expectEqual(@as(usize, 2), sampler.samples.items.len);
    try std.testing.expectEqual(@as(u32, 0), sampler.samples.items[0].byte_offset);
    try std.testing.expect(sampler.samples.items[1].byte_offset > 100);
}

test "positional extractor basic" {
    const allocator = std.testing.allocator;

    var extractor = PositionalExtractor.init(allocator);
    defer extractor.deinit();

    try extractor.extract(0, "hello world");

    const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');
    const pl = extractor.postings.get(tri_hel).?;

    try std.testing.expectEqual(@as(usize, 1), pl.fileCount());
    try std.testing.expectEqual(@as(usize, 1), pl.file_positions.items[0].positions.items.len);
    try std.testing.expectEqual(@as(u32, 0), pl.file_positions.items[0].positions.items[0].byte_offset);
}

test "positional extractor multiple files" {
    const allocator = std.testing.allocator;

    var extractor = PositionalExtractor.init(allocator);
    defer extractor.deinit();

    try extractor.extract(0, "hello");
    try extractor.extract(1, "hello there");
    try extractor.extract(2, "world hello");

    const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');
    const pl = extractor.postings.get(tri_hel).?;

    try std.testing.expectEqual(@as(usize, 3), pl.fileCount());
}

test "proximity match" {
    const positions_a = [_]TrigramPosition{
        .{ .byte_offset = 0, .rune_offset = 0 },
        .{ .byte_offset = 10, .rune_offset = 10 },
    };
    const positions_b = [_]TrigramPosition{
        .{ .byte_offset = 5, .rune_offset = 5 },
        .{ .byte_offset = 100, .rune_offset = 100 },
    };

    try std.testing.expect(proximityMatch(&positions_a, &positions_b, 10));
    try std.testing.expect(!proximityMatch(&positions_a, &positions_b, 4));
}

test "encode decode rune offset sampler" {
    const allocator = std.testing.allocator;

    var sampler = RuneOffsetSampler.init(allocator);
    defer sampler.deinit();

    try sampler.sample(0, 0);
    try sampler.sample(100, 105);
    try sampler.sample(200, 215);

    const encoded = try sampler.encode(allocator);
    defer allocator.free(encoded);

    var map = try RuneOffsetMap.decode(allocator, encoded);
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 3), map.samples.len);
    try std.testing.expectEqual(@as(u32, 0), map.samples[0]);
    try std.testing.expectEqual(@as(u32, 105), map.samples[1]);
    try std.testing.expectEqual(@as(u32, 215), map.samples[2]);
}
