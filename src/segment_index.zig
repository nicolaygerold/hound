const std = @import("std");
const segment_mod = @import("segment.zig");
const meta_mod = @import("meta.zig");
const trigram_mod = @import("trigram.zig");
const reader_mod = @import("reader.zig");

const SegmentId = segment_mod.SegmentId;
const SegmentMeta = segment_mod.SegmentMeta;
const SegmentWriter = segment_mod.SegmentWriter;
const SegmentReader = segment_mod.SegmentReader;
const DeletionBitmapWriter = segment_mod.DeletionBitmapWriter;
const IndexMeta = meta_mod.IndexMeta;
const PathIndex = meta_mod.PathIndex;
const DocumentAddress = meta_mod.DocumentAddress;
const Trigram = trigram_mod.Trigram;

pub const DEFAULT_FLUSH_THRESHOLD: usize = 10000;

pub const SegmentIndexWriter = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    meta: IndexMeta,
    path_index: PathIndex,
    pending_docs: std.ArrayList(PendingDoc),
    pending_deletes: std.AutoHashMap(usize, std.ArrayList(u32)),
    flush_threshold: usize,
    owns_meta: bool,

    const PendingDoc = struct {
        path: []const u8,
        content: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !SegmentIndexWriter {
        return initWithOptions(allocator, dir, .{});
    }

    pub const Options = struct {
        flush_threshold: usize = DEFAULT_FLUSH_THRESHOLD,
    };

    pub fn initWithOptions(allocator: std.mem.Allocator, dir: []const u8, options: Options) !SegmentIndexWriter {
        const dir_copy = try allocator.dupe(u8, dir);
        errdefer allocator.free(dir_copy);

        var meta = try meta_mod.loadMeta(allocator, dir);
        errdefer meta.deinit(allocator);

        var path_index = PathIndex.init(allocator);
        errdefer path_index.deinit();

        try rebuildPathIndex(allocator, dir_copy, &meta, &path_index);

        return .{
            .allocator = allocator,
            .dir = dir_copy,
            .meta = meta,
            .path_index = path_index,
            .pending_docs = std.ArrayList(PendingDoc).init(allocator),
            .pending_deletes = std.AutoHashMap(usize, std.ArrayList(u32)).init(allocator),
            .flush_threshold = options.flush_threshold,
            .owns_meta = true,
        };
    }

    pub fn deinit(self: *SegmentIndexWriter) void {
        for (self.pending_docs.items) |doc| {
            self.allocator.free(doc.path);
            self.allocator.free(doc.content);
        }
        self.pending_docs.deinit();

        var del_it = self.pending_deletes.valueIterator();
        while (del_it.next()) |list| {
            list.deinit();
        }
        self.pending_deletes.deinit();

        self.path_index.deinit();
        if (self.owns_meta) {
            self.meta.deinit(self.allocator);
        }
        self.allocator.free(self.dir);
    }

    pub fn addFile(self: *SegmentIndexWriter, path: []const u8, content: []const u8) !void {
        if (self.path_index.get(path)) |existing_addr| {
            const del_list = try self.pending_deletes.getOrPut(existing_addr.segment_idx);
            if (!del_list.found_existing) {
                del_list.value_ptr.* = std.ArrayList(u32).init(self.allocator);
            }
            try del_list.value_ptr.append(existing_addr.local_id);
        }

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const content_copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_copy);

        try self.pending_docs.append(.{ .path = path_copy, .content = content_copy });

        if (self.pending_docs.items.len >= self.flush_threshold) {
            try self.commit();
        }
    }

    pub fn deleteFile(self: *SegmentIndexWriter, path: []const u8) !void {
        if (self.path_index.get(path)) |addr| {
            const del_list = try self.pending_deletes.getOrPut(addr.segment_idx);
            if (!del_list.found_existing) {
                del_list.value_ptr.* = std.ArrayList(u32).init(self.allocator);
            }
            try del_list.value_ptr.append(addr.local_id);
            _ = self.path_index.remove(path);
        }
    }

    pub fn commit(self: *SegmentIndexWriter) !void {
        var new_segments = std.ArrayList(SegmentMeta).init(self.allocator);
        defer new_segments.deinit();

        for (self.meta.segments) |seg| {
            try new_segments.append(seg);
        }

        if (self.pending_docs.items.len > 0) {
            const new_seg = try self.flushPendingDocs();
            try new_segments.append(new_seg);

            const seg_idx = new_segments.items.len - 1;
            for (self.pending_docs.items, 0..) |doc, local_id| {
                try self.path_index.put(doc.path, .{
                    .segment_idx = seg_idx,
                    .local_id = @intCast(local_id),
                });
            }

            for (self.pending_docs.items) |doc| {
                self.allocator.free(doc.path);
                self.allocator.free(doc.content);
            }
            self.pending_docs.clearRetainingCapacity();
        }

        var del_it = self.pending_deletes.iterator();
        while (del_it.next()) |entry| {
            const seg_idx = entry.key_ptr.*;
            const to_delete = entry.value_ptr.items;

            if (seg_idx < new_segments.items.len) {
                try self.applyDeletions(&new_segments.items[seg_idx], to_delete);
            }
            entry.value_ptr.deinit();
        }
        self.pending_deletes.clearRetainingCapacity();

        const new_meta = IndexMeta{
            .version = 1,
            .opstamp = self.meta.opstamp + 1,
            .segments = try self.allocator.dupe(SegmentMeta, new_segments.items),
        };

        try meta_mod.saveMeta(self.allocator, self.dir, &new_meta);

        if (self.owns_meta) {
            self.allocator.free(self.meta.segments);
        }
        self.meta = new_meta;
        self.owns_meta = true;
    }

    fn flushPendingDocs(self: *SegmentIndexWriter) !SegmentMeta {
        const id = segment_mod.generateSegmentId();
        const id_str = segment_mod.formatSegmentId(id);

        const segments_dir = try std.fmt.allocPrint(self.allocator, "{s}/segments", .{self.dir});
        defer self.allocator.free(segments_dir);
        try std.fs.cwd().makePath(segments_dir);

        const seg_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.seg", .{ segments_dir, &id_str });
        defer self.allocator.free(seg_path);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{seg_path});
        defer self.allocator.free(tmp_path);

        var writer = try SegmentWriter.init(self.allocator, tmp_path, id);
        errdefer {
            writer.deinit();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        for (self.pending_docs.items) |doc| {
            writer.addFile(doc.path, doc.content) catch continue;
        }

        const meta = try writer.finish();
        writer.deinit();

        try std.fs.cwd().rename(tmp_path, seg_path);

        return meta;
    }

    fn applyDeletions(self: *SegmentIndexWriter, seg: *SegmentMeta, to_delete: []const u32) !void {
        if (to_delete.len == 0) return;

        const id_str = segment_mod.formatSegmentId(seg.id);
        const del_path = try std.fmt.allocPrint(self.allocator, "{s}/segments/{s}.del", .{ self.dir, &id_str });
        defer self.allocator.free(del_path);

        var del_writer: DeletionBitmapWriter = undefined;

        if (seg.has_deletions) {
            const maybe_existing = segment_mod.DeletionBitmap.open(del_path);
            if (maybe_existing) |existing| {
                var existing_copy = existing;
                defer existing_copy.close();
                del_writer = try DeletionBitmapWriter.initFromExisting(self.allocator, &existing_copy);
            } else |_| {
                del_writer = try DeletionBitmapWriter.init(self.allocator, seg.num_docs);
            }
        } else {
            del_writer = try DeletionBitmapWriter.init(self.allocator, seg.num_docs);
        }
        defer del_writer.deinit();

        for (to_delete) |local_id| {
            del_writer.markDeleted(local_id);
        }

        try del_writer.write(del_path);

        seg.has_deletions = true;
        seg.del_gen += 1;
        seg.num_deleted_docs = del_writer.num_deleted;
    }

    pub fn segmentCount(self: *const SegmentIndexWriter) usize {
        return self.meta.segments.len;
    }

    pub fn documentCount(self: *const SegmentIndexWriter) u64 {
        return self.meta.liveDocs();
    }
};

fn rebuildPathIndex(
    allocator: std.mem.Allocator,
    dir: []const u8,
    meta: *const IndexMeta,
    path_index: *PathIndex,
) !void {
    for (meta.segments, 0..) |seg, seg_idx| {
        const id_str = segment_mod.formatSegmentId(seg.id);
        const seg_path = try std.fmt.allocPrint(allocator, "{s}/segments/{s}.seg", .{ dir, &id_str });
        defer allocator.free(seg_path);

        const del_path = if (seg.has_deletions) blk: {
            break :blk try std.fmt.allocPrint(allocator, "{s}/segments/{s}.del", .{ dir, &id_str });
        } else null;
        defer if (del_path) |p| allocator.free(p);

        var reader = SegmentReader.open(allocator, seg_path, del_path, seg.id, 0) catch continue;
        defer reader.close();

        const num_docs = reader.nameCount();
        for (0..@intCast(num_docs)) |local_id| {
            const lid: u32 = @intCast(local_id);
            if (reader.isDeleted(lid)) continue;

            if (reader.getName(lid)) |name| {
                try path_index.put(name, .{
                    .segment_idx = seg_idx,
                    .local_id = lid,
                });
            }
        }
    }
}

pub const SegmentIndexReader = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    meta: IndexMeta,
    segments: []SegmentReader,
    owns_meta: bool,

    pub const OpenError = SegmentReader.OpenError || std.mem.Allocator.Error || error{InvalidMetaFormat};

    pub fn open(allocator: std.mem.Allocator, dir: []const u8) OpenError!SegmentIndexReader {
        const dir_copy = try allocator.dupe(u8, dir);
        errdefer allocator.free(dir_copy);

        var meta = meta_mod.loadMeta(allocator, dir) catch {
            return error.InvalidMetaFormat;
        };
        errdefer meta.deinit(allocator);

        const segments = try allocator.alloc(SegmentReader, meta.segments.len);
        errdefer allocator.free(segments);

        var opened: usize = 0;
        errdefer {
            for (0..opened) |i| {
                segments[i].close();
            }
        }

        var base_doc_id: u32 = 0;
        for (meta.segments, 0..) |seg, i| {
            const id_str = segment_mod.formatSegmentId(seg.id);
            const seg_path = try std.fmt.allocPrint(allocator, "{s}/segments/{s}.seg", .{ dir, &id_str });
            defer allocator.free(seg_path);

            const del_path = if (seg.has_deletions) blk: {
                break :blk try std.fmt.allocPrint(allocator, "{s}/segments/{s}.del", .{ dir, &id_str });
            } else null;
            defer if (del_path) |p| allocator.free(p);

            segments[i] = try SegmentReader.open(allocator, seg_path, del_path, seg.id, base_doc_id);
            opened += 1;
            base_doc_id += seg.num_docs;
        }

        return .{
            .allocator = allocator,
            .dir = dir_copy,
            .meta = meta,
            .segments = segments,
            .owns_meta = true,
        };
    }

    pub fn close(self: *SegmentIndexReader) void {
        for (self.segments) |*seg| {
            seg.close();
        }
        self.allocator.free(self.segments);
        if (self.owns_meta) {
            self.meta.deinit(self.allocator);
        }
        self.allocator.free(self.dir);
    }

    pub fn segmentCount(self: *const SegmentIndexReader) usize {
        return self.segments.len;
    }

    pub fn documentCount(self: *const SegmentIndexReader) u64 {
        var total: u64 = 0;
        for (self.segments) |seg| {
            total += seg.liveDocCount();
        }
        return total;
    }

    pub fn getName(self: *const SegmentIndexReader, global_id: u32) ?[]const u8 {
        var offset: u32 = 0;
        for (self.segments) |seg| {
            const seg_docs: u32 = @intCast(seg.nameCount());
            if (global_id < offset + seg_docs) {
                const local_id = global_id - offset;
                return seg.getName(local_id);
            }
            offset += seg_docs;
        }
        return null;
    }

    pub fn lookupTrigram(self: *const SegmentIndexReader, tri: Trigram) TrigramIterator {
        return TrigramIterator.init(self, tri);
    }

    pub const TrigramIterator = struct {
        reader: *const SegmentIndexReader,
        tri: Trigram,
        seg_idx: usize,
        current_view: ?reader_mod.PostingListView,

        pub fn init(reader: *const SegmentIndexReader, tri: Trigram) TrigramIterator {
            var iter = TrigramIterator{
                .reader = reader,
                .tri = tri,
                .seg_idx = 0,
                .current_view = null,
            };
            iter.advanceToNextSegment();
            return iter;
        }

        fn advanceToNextSegment(self: *TrigramIterator) void {
            while (self.seg_idx < self.reader.segments.len) {
                if (self.reader.segments[self.seg_idx].lookupTrigram(self.tri)) |view| {
                    self.current_view = view;
                    return;
                }
                self.seg_idx += 1;
            }
            self.current_view = null;
        }

        pub const DocResult = struct {
            file_id: u32,
            global_id: u32,
            segment_idx: usize,
        };

        pub fn next(self: *TrigramIterator) ?DocResult {
            while (true) {
                if (self.current_view) |*view| {
                    if (view.next()) |local_id| {
                        const seg = &self.reader.segments[self.seg_idx];
                        if (seg.isDeleted(local_id)) {
                            continue;
                        }
                        return .{
                            .file_id = local_id,
                            .global_id = seg.base_doc_id + local_id,
                            .segment_idx = self.seg_idx,
                        };
                    }
                    self.seg_idx += 1;
                    self.advanceToNextSegment();
                } else {
                    return null;
                }
            }
        }

        pub fn collect(self: *TrigramIterator, allocator: std.mem.Allocator) ![]u32 {
            var results = std.ArrayList(u32).init(allocator);
            errdefer results.deinit();

            while (self.next()) |doc| {
                try results.append(doc.global_id);
            }

            return results.toOwnedSlice();
        }
    };
};

pub fn mergeSegments(
    allocator: std.mem.Allocator,
    dir: []const u8,
    segment_ids: []const SegmentId,
) !SegmentMeta {
    var meta = try meta_mod.loadMeta(allocator, dir);
    defer meta.deinit(allocator);

    const new_id = segment_mod.generateSegmentId();
    const new_id_str = segment_mod.formatSegmentId(new_id);
    const new_seg_path = try std.fmt.allocPrint(allocator, "{s}/segments/{s}.seg", .{ dir, &new_id_str });
    defer allocator.free(new_seg_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{new_seg_path});
    defer allocator.free(tmp_path);

    var writer = try SegmentWriter.init(allocator, tmp_path, new_id);
    errdefer {
        writer.deinit();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    for (segment_ids) |id| {
        for (meta.segments) |seg| {
            if (std.mem.eql(u8, &seg.id, &id)) {
                const id_str = segment_mod.formatSegmentId(seg.id);
                const seg_path = try std.fmt.allocPrint(allocator, "{s}/segments/{s}.seg", .{ dir, &id_str });
                defer allocator.free(seg_path);

                const del_path = if (seg.has_deletions) blk: {
                    break :blk try std.fmt.allocPrint(allocator, "{s}/segments/{s}.del", .{ dir, &id_str });
                } else null;
                defer if (del_path) |p| allocator.free(p);

                var reader = SegmentReader.open(allocator, seg_path, del_path, seg.id, 0) catch continue;
                defer reader.close();

                const num_docs = reader.nameCount();
                for (0..@intCast(num_docs)) |local_id| {
                    const lid: u32 = @intCast(local_id);
                    if (reader.isDeleted(lid)) continue;

                    const name = reader.getName(lid) orelse continue;

                    const content = std.fs.cwd().readFileAlloc(allocator, name, 10 * 1024 * 1024) catch continue;
                    defer allocator.free(content);

                    writer.addFile(name, content) catch continue;
                }

                break;
            }
        }
    }

    const new_seg_meta = try writer.finish();
    writer.deinit();

    try std.fs.cwd().rename(tmp_path, new_seg_path);

    var new_segments = std.ArrayList(SegmentMeta).init(allocator);
    defer new_segments.deinit();

    for (meta.segments) |seg| {
        var found = false;
        for (segment_ids) |id| {
            if (std.mem.eql(u8, &seg.id, &id)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try new_segments.append(seg);
        }
    }
    try new_segments.append(new_seg_meta);

    const new_meta = IndexMeta{
        .version = 1,
        .opstamp = meta.opstamp + 1,
        .segments = new_segments.items,
    };

    try meta_mod.saveMeta(allocator, dir, &new_meta);

    return new_seg_meta;
}

test "segment index writer basic" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_segidx_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("test1.txt", "hello world");
        try writer.addFile("test2.txt", "foo bar baz");
        try writer.commit();

        try std.testing.expectEqual(@as(usize, 1), writer.segmentCount());
        try std.testing.expectEqual(@as(u64, 2), writer.documentCount());
    }

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try std.testing.expectEqual(@as(usize, 1), writer.segmentCount());
        try std.testing.expectEqual(@as(u64, 2), writer.documentCount());
    }
}

test "segment index writer incremental" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_segidx_incr_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("file1.txt", "content one");
        try writer.commit();

        try std.testing.expectEqual(@as(usize, 1), writer.segmentCount());
    }

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("file2.txt", "content two");
        try writer.commit();

        try std.testing.expectEqual(@as(usize, 2), writer.segmentCount());
        try std.testing.expectEqual(@as(u64, 2), writer.documentCount());
    }
}

test "segment index writer deletions" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_segidx_del_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("file1.txt", "content one");
        try writer.addFile("file2.txt", "content two");
        try writer.commit();

        try std.testing.expectEqual(@as(u64, 2), writer.documentCount());
    }

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.deleteFile("file1.txt");
        try writer.commit();

        try std.testing.expectEqual(@as(u64, 1), writer.documentCount());
    }
}

test "segment index reader basic" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_segidx_reader_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("hello.txt", "hello world");
        try writer.addFile("foo.txt", "foo bar");
        try writer.commit();
    }

    var reader = try SegmentIndexReader.open(allocator, test_dir);
    defer reader.close();

    try std.testing.expectEqual(@as(usize, 1), reader.segmentCount());
    try std.testing.expectEqual(@as(u64, 2), reader.documentCount());
}

test "segment index reader trigram lookup" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_segidx_tri_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("hello.txt", "hello");
        try writer.addFile("world.txt", "world");
        try writer.addFile("helloworld.txt", "helloworld");
        try writer.commit();
    }

    var reader = try SegmentIndexReader.open(allocator, test_dir);
    defer reader.close();

    const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');
    var iter = reader.lookupTrigram(tri_hel);
    const file_ids = try iter.collect(allocator);
    defer allocator.free(file_ids);

    try std.testing.expect(file_ids.len >= 2);
}

test "segment index reader with deletions" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_segidx_reader_del_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("a.txt", "hello");
        try writer.addFile("b.txt", "hello");
        try writer.addFile("c.txt", "hello");
        try writer.commit();
    }

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.deleteFile("b.txt");
        try writer.commit();
    }

    var reader = try SegmentIndexReader.open(allocator, test_dir);
    defer reader.close();

    try std.testing.expectEqual(@as(u64, 2), reader.documentCount());

    const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');
    var iter = reader.lookupTrigram(tri_hel);
    const file_ids = try iter.collect(allocator);
    defer allocator.free(file_ids);

    try std.testing.expectEqual(@as(usize, 2), file_ids.len);
}

test "segment index multi segment" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_segidx_multi_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("a.txt", "hello");
        try writer.commit();
    }

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("b.txt", "hello");
        try writer.commit();
    }

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("c.txt", "hello");
        try writer.commit();
    }

    var reader = try SegmentIndexReader.open(allocator, test_dir);
    defer reader.close();

    try std.testing.expectEqual(@as(usize, 3), reader.segmentCount());
    try std.testing.expectEqual(@as(u64, 3), reader.documentCount());

    const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');
    var iter = reader.lookupTrigram(tri_hel);
    const file_ids = try iter.collect(allocator);
    defer allocator.free(file_ids);

    try std.testing.expectEqual(@as(usize, 3), file_ids.len);
}

test "segment index update existing file" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_segidx_update_test";

    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("file.txt", "original content");
        try writer.commit();
        try std.testing.expectEqual(@as(u64, 1), writer.documentCount());
    }

    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();

        try writer.addFile("file.txt", "updated content");
        try writer.commit();

        try std.testing.expectEqual(@as(u64, 1), writer.documentCount());
    }
}

test "e2e segment workflow with files on disk" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_e2e_manual";
    
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    
    // First commit: add 2 files
    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();
        
        try writer.addFile("hello.txt", "hello world");
        try writer.addFile("foo.txt", "hello there foo bar");
        try writer.commit();
        
        try std.testing.expectEqual(@as(usize, 1), writer.segmentCount());
        try std.testing.expectEqual(@as(u64, 2), writer.documentCount());
    }
    
    // Second commit: add 1 more file
    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();
        
        try writer.addFile("code.zig", "pub fn hello() void {}");
        try writer.commit();
        
        try std.testing.expectEqual(@as(usize, 2), writer.segmentCount());
        try std.testing.expectEqual(@as(u64, 3), writer.documentCount());
    }
    
    // Read and verify trigram search
    {
        var reader = try SegmentIndexReader.open(allocator, test_dir);
        defer reader.close();
        
        try std.testing.expectEqual(@as(usize, 2), reader.segmentCount());
        try std.testing.expectEqual(@as(u64, 3), reader.documentCount());
        
        // Search for "hel" trigram - should find 3 files
        const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');
        var iter = reader.lookupTrigram(tri_hel);
        const matches = try iter.collect(allocator);
        defer allocator.free(matches);
        
        try std.testing.expectEqual(@as(usize, 3), matches.len);
    }
    
    // Third commit: delete foo.txt
    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();
        
        try writer.deleteFile("foo.txt");
        try writer.commit();
        
        try std.testing.expectEqual(@as(u64, 2), writer.documentCount());
    }
    
    // Verify deletion works in search
    {
        var reader = try SegmentIndexReader.open(allocator, test_dir);
        defer reader.close();
        
        try std.testing.expectEqual(@as(u64, 2), reader.documentCount());
        
        const tri_hel = trigram_mod.fromBytes('h', 'e', 'l');
        var iter = reader.lookupTrigram(tri_hel);
        const matches = try iter.collect(allocator);
        defer allocator.free(matches);
        
        // Should now find only 2 files (foo.txt deleted)
        try std.testing.expectEqual(@as(usize, 2), matches.len);
    }
    
    // Fourth commit: update hello.txt
    {
        var writer = try SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();
        
        try writer.addFile("hello.txt", "updated hello content");
        try writer.commit();
        
        // Still 2 docs (old hello.txt deleted, new one added)
        try std.testing.expectEqual(@as(u64, 2), writer.documentCount());
        // But now 3 segments
        try std.testing.expectEqual(@as(usize, 3), writer.segmentCount());
    }
}
