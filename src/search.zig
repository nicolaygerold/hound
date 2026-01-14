const std = @import("std");
const posix = std.posix;
const trigram_mod = @import("trigram.zig");
const reader_mod = @import("reader.zig");
const Trigram = trigram_mod.Trigram;
const IndexReader = reader_mod.IndexReader;
const PostingListView = reader_mod.PostingListView;
const Extractor = trigram_mod.Extractor;

pub const SearchResult = struct {
    file_id: u32,
    match_count: u32,
    name: []const u8,
};

pub const Searcher = struct {
    reader: *IndexReader,
    extractor: Extractor,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, reader: *IndexReader) !Searcher {
        return .{
            .reader = reader,
            .extractor = try Extractor.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Searcher) void {
        self.extractor.deinit();
    }

    pub fn search(self: *Searcher, query: []const u8, max_results: usize) ![]SearchResult {
        const trigrams = self.extractor.extract(query) catch |err| switch (err) {
            error.ContainsNul, error.InvalidUtf8 => return &[_]SearchResult{},
            else => return err,
        };

        if (trigrams.len == 0) return &[_]SearchResult{};

        var posting_lists = std.ArrayList([]u32).init(self.allocator);
        defer {
            for (posting_lists.items) |list| self.allocator.free(list);
            posting_lists.deinit();
        }

        for (trigrams) |tri| {
            if (self.reader.lookupTrigram(tri)) |*view| {
                var v = view.*;
                const file_ids = try v.collect(self.allocator);
                try posting_lists.append(file_ids);
            }
        }

        if (posting_lists.items.len == 0) return &[_]SearchResult{};

        const ranked = try self.intersectAndRank(posting_lists.items);
        defer self.allocator.free(ranked);

        var results = std.ArrayList(SearchResult).init(self.allocator);
        errdefer results.deinit();

        for (ranked) |candidate| {
            if (results.items.len >= max_results) break;

            const name = self.reader.getName(candidate.file_id) orelse continue;
            if (self.verifyMatch(name, query)) {
                try results.append(.{
                    .file_id = candidate.file_id,
                    .match_count = candidate.count,
                    .name = name,
                });
            }
        }

        return results.toOwnedSlice();
    }

    const FileCount = struct {
        file_id: u32,
        count: u32,
    };

    fn verifyMatch(self: *Searcher, path: []const u8, query: []const u8) bool {
        _ = self;
        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        defer file.close();

        const stat = file.stat() catch return false;
        const size = stat.size;
        if (size == 0) return false;

        const data = posix.mmap(
            null,
            size,
            posix.PROT.READ,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        ) catch return false;
        defer posix.munmap(data);

        return std.mem.indexOf(u8, data, query) != null;
    }

    fn intersectAndRank(self: *Searcher, lists: [][]u32) ![]FileCount {
        var counts = std.AutoHashMap(u32, u32).init(self.allocator);
        defer counts.deinit();

        for (lists) |list| {
            for (list) |file_id| {
                const entry = try counts.getOrPut(file_id);
                if (entry.found_existing) {
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                }
            }
        }

        var result = std.ArrayList(FileCount).init(self.allocator);
        errdefer result.deinit();

        var it = counts.iterator();
        while (it.next()) |entry| {
            try result.append(.{
                .file_id = entry.key_ptr.*,
                .count = entry.value_ptr.*,
            });
        }

        std.mem.sort(FileCount, result.items, {}, struct {
            fn cmp(_: void, a: FileCount, b: FileCount) bool {
                if (a.count != b.count) return a.count > b.count;
                return a.file_id < b.file_id;
            }
        }.cmp);

        return result.toOwnedSlice();
    }

    pub fn freeResults(self: *Searcher, results: []SearchResult) void {
        self.allocator.free(results);
    }
};

test "searcher basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_search_test.idx";
    const test_dir = "/tmp/hound_search_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const files = .{
        .{ "hello.txt", "hello world" },
        .{ "world.txt", "world peace" },
        .{ "helloworld.txt", "hello world peace" },
    };

    inline for (files) |f| {
        const file = try std.fs.cwd().createFile(test_dir ++ "/" ++ f[0], .{});
        defer file.close();
        try file.writeAll(f[1]);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        inline for (files) |f| {
            try writer.addFile(test_dir ++ "/" ++ f[0], f[1]);
        }
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    const results = try searcher.search("hello", 10);
    defer searcher.freeResults(results);

    try std.testing.expect(results.len >= 2);

    for (results) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r.name, ".txt") != null);
    }
}

test "searcher ranking" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_search_rank_test.idx";
    const test_dir = "/tmp/hound_search_rank_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const files = .{
        .{ "partial.txt", "hello" },
        .{ "full.txt", "hello world" },
        .{ "none.txt", "goodbye" },
    };

    inline for (files) |f| {
        const file = try std.fs.cwd().createFile(test_dir ++ "/" ++ f[0], .{});
        defer file.close();
        try file.writeAll(f[1]);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        inline for (files) |f| {
            try writer.addFile(test_dir ++ "/" ++ f[0], f[1]);
        }
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    const results = try searcher.search("hello world", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(std.mem.indexOf(u8, results[0].name, "full.txt") != null);
}

test "searcher empty query" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_search_empty_test.idx";
    const test_dir = "/tmp/hound_search_empty_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/test.txt", .{});
        defer file.close();
        try file.writeAll("hello");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile(test_dir ++ "/test.txt", "hello");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    const results = try searcher.search("ab", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "searcher no matches" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_search_nomatch_test.idx";
    const test_dir = "/tmp/hound_search_nomatch_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/test.txt", .{});
        defer file.close();
        try file.writeAll("hello world");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile(test_dir ++ "/test.txt", "hello world");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    const results = try searcher.search("xyz123", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "content verification filters false positives" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_verify_test.idx";
    const test_dir = "/tmp/hound_verify_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/abc_def.txt", .{});
        defer file.close();
        try file.writeAll("abc def ghi");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/abcdef.txt", .{});
        defer file.close();
        try file.writeAll("abcdef");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        try writer.addFile(test_dir ++ "/abc_def.txt", "abc def ghi");
        try writer.addFile(test_dir ++ "/abcdef.txt", "abcdef");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    const results = try searcher.search("abcdef", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(std.mem.indexOf(u8, results[0].name, "abcdef.txt") != null);
}
