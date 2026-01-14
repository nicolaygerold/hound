const std = @import("std");
const posix = std.posix;
const index_mod = @import("index.zig");
const reader_mod = @import("reader.zig");
const trigram_mod = @import("trigram.zig");
const varint = @import("varint.zig");
const Trigram = trigram_mod.Trigram;

pub const SegmentId = [16]u8;

pub fn generateSegmentId() SegmentId {
    var id: SegmentId = undefined;
    std.crypto.random.bytes(&id);
    return id;
}

pub fn formatSegmentId(id: SegmentId) [32]u8 {
    const hex = "0123456789abcdef";
    var result: [32]u8 = undefined;
    for (id, 0..) |byte, i| {
        result[i * 2] = hex[byte >> 4];
        result[i * 2 + 1] = hex[byte & 0x0F];
    }
    return result;
}

pub fn parseSegmentId(hex: []const u8) !SegmentId {
    if (hex.len != 32) return error.InvalidSegmentId;
    var id: SegmentId = undefined;
    for (0..16) |i| {
        id[i] = (try hexDigit(hex[i * 2])) << 4 | try hexDigit(hex[i * 2 + 1]);
    }
    return id;
}

fn hexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return error.InvalidHexDigit,
    };
}

pub const SegmentMeta = struct {
    id: SegmentId,
    num_docs: u32,
    num_deleted_docs: u32,
    has_deletions: bool,
    del_gen: u32,

    pub fn segmentFileName(self: *const SegmentMeta, allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
        const id_str = formatSegmentId(self.id);
        return std.fmt.allocPrint(allocator, "{s}/{s}.seg", .{ dir, &id_str });
    }

    pub fn deletionsFileName(self: *const SegmentMeta, allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
        const id_str = formatSegmentId(self.id);
        return std.fmt.allocPrint(allocator, "{s}/{s}.del", .{ dir, &id_str });
    }
};

pub const SegmentWriter = struct {
    allocator: std.mem.Allocator,
    inner: index_mod.IndexWriter,
    id: SegmentId,
    doc_count: u32,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, id: SegmentId) !SegmentWriter {
        return .{
            .allocator = allocator,
            .inner = try index_mod.IndexWriter.init(allocator, path),
            .id = id,
            .doc_count = 0,
        };
    }

    pub fn deinit(self: *SegmentWriter) void {
        self.inner.deinit();
    }

    pub fn addFile(self: *SegmentWriter, name: []const u8, content: []const u8) !void {
        try self.inner.addFile(name, content);
        self.doc_count += 1;
    }

    pub fn finish(self: *SegmentWriter) !SegmentMeta {
        try self.inner.finish();
        return .{
            .id = self.id,
            .num_docs = self.doc_count,
            .num_deleted_docs = 0,
            .has_deletions = false,
            .del_gen = 0,
        };
    }
};

pub const SegmentReader = struct {
    allocator: std.mem.Allocator,
    inner: reader_mod.IndexReader,
    id: SegmentId,
    del_bitmap: ?DeletionBitmap,
    base_doc_id: u32,

    pub const OpenError = reader_mod.IndexReader.OpenError || error{InvalidDeletionFile};

    pub fn open(
        allocator: std.mem.Allocator,
        segment_path: []const u8,
        deletion_path: ?[]const u8,
        id: SegmentId,
        base_doc_id: u32,
    ) OpenError!SegmentReader {
        const inner = try reader_mod.IndexReader.open(allocator, segment_path);
        errdefer {
            var inner_copy = inner;
            inner_copy.close();
        }

        var del_bitmap: ?DeletionBitmap = null;
        if (deletion_path) |del_path| {
            del_bitmap = DeletionBitmap.open(del_path) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return error.InvalidDeletionFile,
            };
        }

        return .{
            .allocator = allocator,
            .inner = inner,
            .id = id,
            .del_bitmap = del_bitmap,
            .base_doc_id = base_doc_id,
        };
    }

    pub fn close(self: *SegmentReader) void {
        if (self.del_bitmap) |*bitmap| {
            bitmap.close();
        }
        self.inner.close();
    }

    pub fn nameCount(self: *const SegmentReader) u64 {
        return self.inner.nameCount();
    }

    pub fn getName(self: *const SegmentReader, local_id: u32) ?[]const u8 {
        return self.inner.getName(local_id);
    }

    pub fn isDeleted(self: *const SegmentReader, local_id: u32) bool {
        if (self.del_bitmap) |bitmap| {
            return bitmap.isDeleted(local_id);
        }
        return false;
    }

    pub fn liveDocCount(self: *const SegmentReader) u64 {
        const total = self.inner.nameCount();
        if (self.del_bitmap) |bitmap| {
            return total - bitmap.deletedCount();
        }
        return total;
    }

    pub fn lookupTrigram(self: *const SegmentReader, tri: Trigram) ?reader_mod.PostingListView {
        return self.inner.lookupTrigram(tri);
    }

    pub fn trigramCount(self: *const SegmentReader) usize {
        return self.inner.trigramCount();
    }
};

pub const DeletionBitmap = struct {
    data: []align(std.mem.page_size) const u8,
    fd: posix.fd_t,
    num_docs: u32,
    num_deleted: u32,

    const MAGIC = "hound del\n";
    const HEADER_SIZE = MAGIC.len + 4 + 4;

    pub fn open(path: []const u8) !DeletionBitmap {
        const file = try std.fs.cwd().openFile(path, .{});
        const fd = file.handle;
        errdefer posix.close(fd);

        const stat = try file.stat();
        if (stat.size < HEADER_SIZE) {
            return error.FileTooSmall;
        }

        const data = try posix.mmap(
            null,
            stat.size,
            posix.PROT.READ,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        if (!std.mem.eql(u8, data[0..MAGIC.len], MAGIC)) {
            posix.munmap(data);
            return error.InvalidMagic;
        }

        const num_docs = std.mem.readInt(u32, data[MAGIC.len..][0..4], .big);
        const num_deleted = std.mem.readInt(u32, data[MAGIC.len + 4 ..][0..4], .big);

        return .{
            .data = data,
            .fd = fd,
            .num_docs = num_docs,
            .num_deleted = num_deleted,
        };
    }

    pub fn close(self: *DeletionBitmap) void {
        posix.munmap(self.data);
        posix.close(self.fd);
    }

    pub fn isDeleted(self: *const DeletionBitmap, doc_id: u32) bool {
        if (doc_id >= self.num_docs) return true;
        const byte_idx = HEADER_SIZE + doc_id / 8;
        const bit_idx: u3 = @intCast(doc_id % 8);
        return (self.data[byte_idx] >> bit_idx) & 1 == 1;
    }

    pub fn deletedCount(self: *const DeletionBitmap) u64 {
        return self.num_deleted;
    }
};

pub const DeletionBitmapWriter = struct {
    allocator: std.mem.Allocator,
    num_docs: u32,
    bits: []u8,
    num_deleted: u32,

    pub fn init(allocator: std.mem.Allocator, num_docs: u32) !DeletionBitmapWriter {
        const num_bytes = (num_docs + 7) / 8;
        const bits = try allocator.alloc(u8, num_bytes);
        @memset(bits, 0);
        return .{
            .allocator = allocator,
            .num_docs = num_docs,
            .bits = bits,
            .num_deleted = 0,
        };
    }

    pub fn initFromExisting(allocator: std.mem.Allocator, existing: *const DeletionBitmap) !DeletionBitmapWriter {
        const num_bytes = (existing.num_docs + 7) / 8;
        const bits = try allocator.alloc(u8, num_bytes);
        const src = existing.data[DeletionBitmap.HEADER_SIZE..][0..num_bytes];
        @memcpy(bits, src);
        return .{
            .allocator = allocator,
            .num_docs = existing.num_docs,
            .bits = bits,
            .num_deleted = existing.num_deleted,
        };
    }

    pub fn deinit(self: *DeletionBitmapWriter) void {
        self.allocator.free(self.bits);
    }

    pub fn markDeleted(self: *DeletionBitmapWriter, doc_id: u32) void {
        if (doc_id >= self.num_docs) return;
        const byte_idx = doc_id / 8;
        const bit_idx: u3 = @intCast(doc_id % 8);
        const mask: u8 = @as(u8, 1) << bit_idx;
        if (self.bits[byte_idx] & mask == 0) {
            self.bits[byte_idx] |= mask;
            self.num_deleted += 1;
        }
    }

    pub fn isDeleted(self: *const DeletionBitmapWriter, doc_id: u32) bool {
        if (doc_id >= self.num_docs) return true;
        const byte_idx = doc_id / 8;
        const bit_idx: u3 = @intCast(doc_id % 8);
        return (self.bits[byte_idx] >> bit_idx) & 1 == 1;
    }

    pub fn write(self: *const DeletionBitmapWriter, path: []const u8) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        const file = try std.fs.cwd().createFile(tmp_path, .{});
        errdefer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        try file.writeAll(DeletionBitmap.MAGIC);

        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], self.num_docs, .big);
        std.mem.writeInt(u32, header[4..8], self.num_deleted, .big);
        try file.writeAll(&header);

        try file.writeAll(self.bits);
        try file.sync();
        file.close();

        try std.fs.cwd().rename(tmp_path, path);
    }
};

test "segment id generation and formatting" {
    const id = generateSegmentId();
    const formatted = formatSegmentId(id);
    const parsed = try parseSegmentId(&formatted);
    try std.testing.expectEqualSlices(u8, &id, &parsed);
}

test "segment writer basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_segment_test.seg";
    const id = generateSegmentId();

    {
        var writer = try SegmentWriter.init(allocator, test_path, id);
        defer writer.deinit();

        try writer.addFile("test.txt", "hello world");
        try writer.addFile("foo.txt", "hello there");
        const meta = try writer.finish();

        try std.testing.expectEqual(@as(u32, 2), meta.num_docs);
        try std.testing.expectEqualSlices(u8, &id, &meta.id);
    }

    var reader = try reader_mod.IndexReader.open(allocator, test_path);
    defer reader.close();
    try std.testing.expectEqual(@as(u64, 2), reader.nameCount());
}

test "segment reader basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_segment_reader_test.seg";
    const id = generateSegmentId();

    {
        var writer = try SegmentWriter.init(allocator, test_path, id);
        defer writer.deinit();
        try writer.addFile("a.txt", "hello world");
        try writer.addFile("b.txt", "foo bar");
        _ = try writer.finish();
    }

    var reader = try SegmentReader.open(allocator, test_path, null, id, 0);
    defer reader.close();

    try std.testing.expectEqual(@as(u64, 2), reader.nameCount());
    try std.testing.expectEqual(@as(u64, 2), reader.liveDocCount());
    try std.testing.expectEqualSlices(u8, "a.txt", reader.getName(0).?);
    try std.testing.expect(!reader.isDeleted(0));
    try std.testing.expect(!reader.isDeleted(1));
}

test "deletion bitmap write and read" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_deletion_test.del";

    {
        var writer = try DeletionBitmapWriter.init(allocator, 100);
        defer writer.deinit();

        writer.markDeleted(0);
        writer.markDeleted(50);
        writer.markDeleted(99);

        try std.testing.expect(writer.isDeleted(0));
        try std.testing.expect(!writer.isDeleted(1));
        try std.testing.expect(writer.isDeleted(50));
        try std.testing.expect(writer.isDeleted(99));
        try std.testing.expectEqual(@as(u32, 3), writer.num_deleted);

        try writer.write(test_path);
    }

    var bitmap = try DeletionBitmap.open(test_path);
    defer bitmap.close();

    try std.testing.expectEqual(@as(u32, 100), bitmap.num_docs);
    try std.testing.expectEqual(@as(u32, 3), bitmap.num_deleted);
    try std.testing.expect(bitmap.isDeleted(0));
    try std.testing.expect(!bitmap.isDeleted(1));
    try std.testing.expect(bitmap.isDeleted(50));
    try std.testing.expect(bitmap.isDeleted(99));
}

test "segment reader with deletions" {
    const allocator = std.testing.allocator;
    const seg_path = "/tmp/hound_seg_del_test.seg";
    const del_path = "/tmp/hound_seg_del_test.del";
    const id = generateSegmentId();

    {
        var writer = try SegmentWriter.init(allocator, seg_path, id);
        defer writer.deinit();
        try writer.addFile("a.txt", "hello");
        try writer.addFile("b.txt", "world");
        try writer.addFile("c.txt", "foo");
        _ = try writer.finish();
    }

    {
        var del_writer = try DeletionBitmapWriter.init(allocator, 3);
        defer del_writer.deinit();
        del_writer.markDeleted(1);
        try del_writer.write(del_path);
    }

    var reader = try SegmentReader.open(allocator, seg_path, del_path, id, 0);
    defer reader.close();

    try std.testing.expectEqual(@as(u64, 3), reader.nameCount());
    try std.testing.expectEqual(@as(u64, 2), reader.liveDocCount());
    try std.testing.expect(!reader.isDeleted(0));
    try std.testing.expect(reader.isDeleted(1));
    try std.testing.expect(!reader.isDeleted(2));
}
