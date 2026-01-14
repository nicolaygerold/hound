const std = @import("std");
const hound = @import("hound");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const test_dir = "/tmp/hound_inspect_test";
    
    std.fs.cwd().deleteTree(test_dir) catch {};
    
    std.debug.print("=== Creating segment-based index ===\n\n", .{});
    
    // Commit 1: Add 2 files
    {
        var writer = try hound.segment_index.SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();
        try writer.addFile("src/main.zig", "const std = @import(\"std\"); // hello world");
        try writer.addFile("src/lib.zig", "pub fn hello() void {} // hello function");
        try writer.commit();
        std.debug.print("Commit 1: Added 2 files\n", .{});
        std.debug.print("  Segments: {d}, Documents: {d}\n\n", .{ writer.segmentCount(), writer.documentCount() });
    }
    
    // Commit 2: Add another file
    {
        var writer = try hound.segment_index.SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();
        try writer.addFile("README.md", "# Hello World\nThis is a test.");
        try writer.commit();
        std.debug.print("Commit 2: Added README.md\n", .{});
        std.debug.print("  Segments: {d}, Documents: {d}\n\n", .{ writer.segmentCount(), writer.documentCount() });
    }
    
    // Commit 3: Delete a file
    {
        var writer = try hound.segment_index.SegmentIndexWriter.init(allocator, test_dir);
        defer writer.deinit();
        try writer.deleteFile("src/lib.zig");
        try writer.commit();
        std.debug.print("Commit 3: Deleted src/lib.zig\n", .{});
        std.debug.print("  Segments: {d}, Documents: {d}\n\n", .{ writer.segmentCount(), writer.documentCount() });
    }
    
    // Read and search
    {
        var reader = try hound.segment_index.SegmentIndexReader.open(allocator, test_dir);
        defer reader.close();
        
        std.debug.print("=== Reading index ===\n", .{});
        std.debug.print("Segments: {d}\n", .{reader.segmentCount()});
        std.debug.print("Live documents: {d}\n\n", .{reader.documentCount()});
        
        // Search for "hel" trigram
        const tri = hound.trigram.fromBytes('h', 'e', 'l');
        var iter = reader.lookupTrigram(tri);
        const matches = try iter.collect(allocator);
        defer allocator.free(matches);
        
        std.debug.print("Files containing 'hel' trigram: {d}\n", .{matches.len});
        for (matches) |gid| {
            const name = reader.getName(gid) orelse "unknown";
            std.debug.print("  - {s}\n", .{name});
        }
    }
    
    std.debug.print("\n=== Demo complete ===\n", .{});
}
