const std = @import("std");

pub const Trigram = u24;
pub const InvalidTrigram: Trigram = 0xFFFFFF;

pub fn fromBytes(b0: u8, b1: u8, b2: u8) Trigram {
    return @as(Trigram, b0) << 16 | @as(Trigram, b1) << 8 | @as(Trigram, b2);
}

pub fn toBytes(t: Trigram) [3]u8 {
    return .{
        @truncate(t >> 16),
        @truncate(t >> 8),
        @truncate(t),
    };
}

pub fn format(t: Trigram) [3]u8 {
    return toBytes(t);
}

pub const TrigramSet = struct {
    dense: std.ArrayList(Trigram),
    sparse: []u32,
    allocator: std.mem.Allocator,

    const SPARSE_SIZE = 1 << 24;

    pub fn init(allocator: std.mem.Allocator) !TrigramSet {
        const sparse = try allocator.alloc(u32, SPARSE_SIZE);
        @memset(sparse, 0xFFFFFFFF);
        return .{
            .dense = std.ArrayList(Trigram){},
            .sparse = sparse,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TrigramSet) void {
        self.dense.deinit(self.allocator);
        self.allocator.free(self.sparse);
    }

    pub fn add(self: *TrigramSet, t: Trigram) !void {
        if (self.sparse[t] == 0xFFFFFFFF) {
            self.sparse[t] = @intCast(self.dense.items.len);
            try self.dense.append(self.allocator, t);
        }
    }

    pub fn contains(self: *const TrigramSet, t: Trigram) bool {
        return self.sparse[t] != 0xFFFFFFFF;
    }

    pub fn len(self: *const TrigramSet) usize {
        return self.dense.items.len;
    }

    pub fn reset(self: *TrigramSet) void {
        for (self.dense.items) |t| {
            self.sparse[t] = 0xFFFFFFFF;
        }
        self.dense.clearRetainingCapacity();
    }

    pub fn items(self: *const TrigramSet) []const Trigram {
        return self.dense.items;
    }
};

pub const Extractor = struct {
    trigrams: TrigramSet,
    tv: u32 = 0,
    count: u64 = 0,

    const max_file_len: u64 = 1 << 30;
    const max_line_len: usize = 2000;
    const max_trigrams: usize = 20000;

    pub fn init(allocator: std.mem.Allocator) !Extractor {
        return .{
            .trigrams = try TrigramSet.init(allocator),
        };
    }

    pub fn deinit(self: *Extractor) void {
        self.trigrams.deinit();
    }

    pub fn reset(self: *Extractor) void {
        self.trigrams.reset();
        self.tv = 0;
        self.count = 0;
    }

    pub const ExtractError = error{
        ContainsNul,
        InvalidUtf8,
        FileTooLong,
        LineTooLong,
        TooManyTrigrams,
        OutOfMemory,
    };

    pub fn extract(self: *Extractor, data: []const u8) ExtractError![]const Trigram {
        self.reset();
        var line_len: usize = 0;

        for (data) |c| {
            self.tv = (self.tv << 8) & 0xFFFFFF;
            self.tv |= @as(u32, c);
            self.count += 1;

            if (c == 0) return error.ContainsNul;

            if (self.count >= 3) {
                const b1: u8 = @truncate(self.tv >> 8);
                const b2: u8 = @truncate(self.tv);
                if (!validUtf8Pair(b1, b2)) return error.InvalidUtf8;

                try self.trigrams.add(@truncate(self.tv));
            }

            if (self.count > max_file_len) return error.FileTooLong;

            line_len += 1;
            if (line_len > max_line_len) return error.LineTooLong;
            if (c == '\n') line_len = 0;
        }

        if (self.trigrams.len() > max_trigrams) return error.TooManyTrigrams;

        return self.trigrams.items();
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

test "trigram from bytes" {
    const t = fromBytes('a', 'b', 'c');
    const bytes = toBytes(t);
    try std.testing.expectEqualSlices(u8, "abc", &bytes);
}

test "trigram set" {
    var set = try TrigramSet.init(std.testing.allocator);
    defer set.deinit();

    const t1 = fromBytes('a', 'b', 'c');
    const t2 = fromBytes('b', 'c', 'd');

    try set.add(t1);
    try set.add(t1);
    try set.add(t2);

    try std.testing.expectEqual(@as(usize, 2), set.len());
    try std.testing.expect(set.contains(t1));
    try std.testing.expect(set.contains(t2));
}

test "extractor basic" {
    var ext = try Extractor.init(std.testing.allocator);
    defer ext.deinit();

    const trigrams = try ext.extract("hello world");
    try std.testing.expect(trigrams.len > 0);
}

test "extractor sliding window" {
    var ext = try Extractor.init(std.testing.allocator);
    defer ext.deinit();

    const trigrams = try ext.extract("abcd");
    try std.testing.expectEqual(@as(usize, 2), trigrams.len);

    const t_abc = fromBytes('a', 'b', 'c');
    const t_bcd = fromBytes('b', 'c', 'd');
    try std.testing.expect(ext.trigrams.contains(t_abc));
    try std.testing.expect(ext.trigrams.contains(t_bcd));
}
