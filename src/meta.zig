const std = @import("std");
const segment = @import("segment.zig");
const SegmentId = segment.SegmentId;
const SegmentMeta = segment.SegmentMeta;

pub const IndexMeta = struct {
    version: u32 = 1,
    opstamp: u64 = 0,
    segments: []SegmentMeta,

    pub fn init() IndexMeta {
        return .{
            .version = 1,
            .opstamp = 0,
            .segments = &[_]SegmentMeta{},
        };
    }

    pub fn deinit(self: *IndexMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.segments);
    }

    pub fn totalDocs(self: *const IndexMeta) u64 {
        var total: u64 = 0;
        for (self.segments) |seg| {
            total += seg.num_docs;
        }
        return total;
    }

    pub fn liveDocs(self: *const IndexMeta) u64 {
        var total: u64 = 0;
        for (self.segments) |seg| {
            total += seg.num_docs - seg.num_deleted_docs;
        }
        return total;
    }
};

pub fn loadMeta(allocator: std.mem.Allocator, dir: []const u8) !IndexMeta {
    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta.json", .{dir});
    defer allocator.free(meta_path);

    const file = std.fs.cwd().openFile(meta_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return IndexMeta.init();
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    return try parseMeta(allocator, content);
}

pub fn parseMeta(allocator: std.mem.Allocator, json: []const u8) !IndexMeta {
    const parsed = std.json.parseFromSlice(JsonMeta, allocator, json, .{}) catch {
        return error.InvalidMetaFormat;
    };
    defer parsed.deinit();

    const json_meta = parsed.value;
    const segments = try allocator.alloc(SegmentMeta, json_meta.segments.len);
    errdefer allocator.free(segments);

    for (json_meta.segments, 0..) |json_seg, i| {
        segments[i] = .{
            .id = try segment.parseSegmentId(json_seg.id),
            .num_docs = json_seg.num_docs,
            .num_deleted_docs = json_seg.num_deleted_docs,
            .has_deletions = json_seg.has_deletions,
            .del_gen = json_seg.del_gen,
        };
    }

    return .{
        .version = json_meta.version,
        .opstamp = json_meta.opstamp,
        .segments = segments,
    };
}

pub fn saveMeta(allocator: std.mem.Allocator, dir: []const u8, meta: *const IndexMeta) !void {
    try std.fs.cwd().makePath(dir);

    const segments_dir = try std.fmt.allocPrint(allocator, "{s}/segments", .{dir});
    defer allocator.free(segments_dir);
    try std.fs.cwd().makePath(segments_dir);

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/meta.json", .{dir});
    defer allocator.free(meta_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/meta.json.tmp", .{dir});
    defer allocator.free(tmp_path);

    const json = try serializeMeta(allocator, meta);
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(tmp_path, .{});
    errdefer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    try file.writeAll(json);
    try file.sync();
    file.close();

    try std.fs.cwd().rename(tmp_path, meta_path);

    if (std.fs.cwd().openDir(dir, .{})) |*d| {
        var dir_handle = d.*;
        dir_handle.close();
    } else |_| {}
}

fn serializeMeta(allocator: std.mem.Allocator, meta: *const IndexMeta) ![]u8 {
    var json_segments = try allocator.alloc(JsonSegmentMeta, meta.segments.len);
    defer allocator.free(json_segments);

    var id_strs = try allocator.alloc([32]u8, meta.segments.len);
    defer allocator.free(id_strs);

    for (meta.segments, 0..) |seg, i| {
        id_strs[i] = segment.formatSegmentId(seg.id);
        json_segments[i] = .{
            .id = &id_strs[i],
            .num_docs = seg.num_docs,
            .num_deleted_docs = seg.num_deleted_docs,
            .has_deletions = seg.has_deletions,
            .del_gen = seg.del_gen,
        };
    }

    const json_meta = JsonMeta{
        .version = meta.version,
        .opstamp = meta.opstamp,
        .segments = json_segments,
    };

    var list = std.ArrayList(u8){};
    errdefer list.deinit(allocator);

    try list.writer(allocator).print("{f}\n", .{std.json.fmt(json_meta, .{ .whitespace = .indent_2 })});

    return list.toOwnedSlice(allocator);
}

const JsonSegmentMeta = struct {
    id: []const u8,
    num_docs: u32,
    num_deleted_docs: u32,
    has_deletions: bool,
    del_gen: u32,
};

const JsonMeta = struct {
    version: u32,
    opstamp: u64,
    segments: []const JsonSegmentMeta,
};

pub const DocumentAddress = struct {
    segment_idx: usize,
    local_id: u32,
};

pub const PathIndex = struct {
    allocator: std.mem.Allocator,
    paths: std.StringHashMap(DocumentAddress),

    pub fn init(allocator: std.mem.Allocator) PathIndex {
        return .{
            .allocator = allocator,
            .paths = std.StringHashMap(DocumentAddress).init(allocator),
        };
    }

    pub fn deinit(self: *PathIndex) void {
        var it = self.paths.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.paths.deinit();
    }

    pub fn put(self: *PathIndex, path: []const u8, addr: DocumentAddress) !void {
        const existing = self.paths.get(path);
        if (existing != null) {
            try self.paths.put(path, addr);
            return;
        }
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try self.paths.put(path_copy, addr);
    }

    pub fn get(self: *const PathIndex, path: []const u8) ?DocumentAddress {
        return self.paths.get(path);
    }

    pub fn remove(self: *PathIndex, path: []const u8) bool {
        if (self.paths.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    pub fn count(self: *const PathIndex) usize {
        return self.paths.count();
    }
};

test "meta save and load roundtrip" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_meta_roundtrip_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const id1 = segment.generateSegmentId();
    const id2 = segment.generateSegmentId();

    var segments = [_]SegmentMeta{
        .{ .id = id1, .num_docs = 100, .num_deleted_docs = 5, .has_deletions = true, .del_gen = 1 },
        .{ .id = id2, .num_docs = 200, .num_deleted_docs = 0, .has_deletions = false, .del_gen = 0 },
    };

    const meta = IndexMeta{
        .version = 1,
        .opstamp = 42,
        .segments = &segments,
    };

    try saveMeta(allocator, test_dir, &meta);

    var loaded = try loadMeta(allocator, test_dir);
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), loaded.version);
    try std.testing.expectEqual(@as(u64, 42), loaded.opstamp);
    try std.testing.expectEqual(@as(usize, 2), loaded.segments.len);
    try std.testing.expectEqualSlices(u8, &id1, &loaded.segments[0].id);
    try std.testing.expectEqual(@as(u32, 100), loaded.segments[0].num_docs);
    try std.testing.expectEqual(@as(u32, 5), loaded.segments[0].num_deleted_docs);
    try std.testing.expect(loaded.segments[0].has_deletions);
    try std.testing.expectEqualSlices(u8, &id2, &loaded.segments[1].id);
}

test "meta totals" {
    var segments = [_]SegmentMeta{
        .{ .id = segment.generateSegmentId(), .num_docs = 100, .num_deleted_docs = 10, .has_deletions = true, .del_gen = 1 },
        .{ .id = segment.generateSegmentId(), .num_docs = 200, .num_deleted_docs = 20, .has_deletions = true, .del_gen = 1 },
    };

    const meta = IndexMeta{
        .version = 1,
        .opstamp = 1,
        .segments = &segments,
    };

    try std.testing.expectEqual(@as(u64, 300), meta.totalDocs());
    try std.testing.expectEqual(@as(u64, 270), meta.liveDocs());
}

test "path index basic" {
    const allocator = std.testing.allocator;

    var index = PathIndex.init(allocator);
    defer index.deinit();

    try index.put("file1.txt", .{ .segment_idx = 0, .local_id = 0 });
    try index.put("file2.txt", .{ .segment_idx = 0, .local_id = 1 });
    try index.put("file3.txt", .{ .segment_idx = 1, .local_id = 0 });

    const addr1 = index.get("file1.txt").?;
    try std.testing.expectEqual(@as(usize, 0), addr1.segment_idx);
    try std.testing.expectEqual(@as(u32, 0), addr1.local_id);

    const addr3 = index.get("file3.txt").?;
    try std.testing.expectEqual(@as(usize, 1), addr3.segment_idx);

    try std.testing.expect(index.get("nonexistent.txt") == null);
    try std.testing.expectEqual(@as(usize, 3), index.count());
}

test "load nonexistent meta returns empty" {
    const allocator = std.testing.allocator;

    const meta = try loadMeta(allocator, "/tmp/hound_meta_nonexistent_dir");

    try std.testing.expectEqual(@as(u32, 1), meta.version);
    try std.testing.expectEqual(@as(u64, 0), meta.opstamp);
    try std.testing.expectEqual(@as(usize, 0), meta.segments.len);
}
