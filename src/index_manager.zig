const std = @import("std");
const segment_index = @import("segment_index.zig");

pub const SegmentIndexWriter = segment_index.SegmentIndexWriter;
pub const SegmentIndexReader = segment_index.SegmentIndexReader;

pub const IndexManager = struct {
    allocator: std.mem.Allocator,
    base_dir: []const u8,

    pub const Document = struct {
        name: []const u8,
        content: []const u8,
    };

    pub const Error = anyerror;

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !IndexManager {
        const dir_copy = try allocator.dupe(u8, dir);
        return .{
            .allocator = allocator,
            .base_dir = dir_copy,
        };
    }

    pub fn deinit(self: *IndexManager) void {
        self.allocator.free(self.base_dir);
    }

    pub fn openWriter(self: *const IndexManager, index: []const u8) Error!SegmentIndexWriter {
        const index_dir = try self.indexDirectory(index);
        defer self.allocator.free(index_dir);
        return try SegmentIndexWriter.init(self.allocator, index_dir);
    }

    pub fn openReader(self: *const IndexManager, index: []const u8) Error!SegmentIndexReader {
        const index_dir = try self.indexDirectory(index);
        defer self.allocator.free(index_dir);
        return try SegmentIndexReader.open(self.allocator, index_dir);
    }

    pub fn rebuild(self: *const IndexManager, index: []const u8, documents: []const Document) Error!void {
        const index_dir = try self.indexDirectory(index);
        defer self.allocator.free(index_dir);

        std.fs.cwd().deleteTree(index_dir) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        var writer = try SegmentIndexWriter.init(self.allocator, index_dir);
        defer writer.deinit();

        for (documents) |doc| {
            try writer.addFile(doc.name, doc.content);
        }
        try writer.commit();
    }

    fn indexDirectory(self: *const IndexManager, index: []const u8) Error![]const u8 {
        const sanitized = try sanitizeIndexName(self.allocator, index);
        defer self.allocator.free(sanitized);

        return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_dir, sanitized });
    }
};

fn sanitizeIndexName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) {
        return error.InvalidIndexName;
    }

    var normalized = std.ArrayList(u8){};
    defer normalized.deinit(allocator);

    for (name) |ch| {
        const lower = std.ascii.toLower(ch);
        const is_alpha = lower >= 'a' and lower <= 'z';
        const is_digit = lower >= '0' and lower <= '9';
        if (is_alpha or is_digit or lower == '-') {
            try normalized.append(allocator, lower);
        } else {
            try normalized.append(allocator, '-');
        }
    }

    const items = normalized.items;
    var start: usize = 0;
    while (start < items.len and items[start] == '-') : (start += 1) {}
    if (start == items.len) {
        return error.InvalidIndexName;
    }

    var end: usize = items.len;
    while (end > start and items[end - 1] == '-') : (end -= 1) {}

    return allocator.dupe(u8, items[start..end]);
}

test "index manager sanitizes names" {
    const allocator = std.testing.allocator;

    const result = try sanitizeIndexName(allocator, "Title Only Index");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("title-only-index", result);
}
