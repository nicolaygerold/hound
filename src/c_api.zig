const std = @import("std");
const index_mod = @import("index.zig");
const reader_mod = @import("reader.zig");
const search_mod = @import("search.zig");
const incremental_mod = @import("incremental.zig");
const state_mod = @import("state.zig");

const IndexWriter = index_mod.IndexWriter;
const IndexReader = reader_mod.IndexReader;
const Searcher = search_mod.Searcher;
const SearchResult = search_mod.SearchResult;
const IncrementalIndexer = incremental_mod.IncrementalIndexer;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// ============================================================================
// Index Writer API
// ============================================================================

pub const HoundIndexWriter = opaque {};

pub export fn hound_index_writer_create(path: [*:0]const u8) ?*HoundIndexWriter {
    const writer = allocator.create(IndexWriter) catch return null;
    writer.* = IndexWriter.init(allocator, std.mem.span(path)) catch {
        allocator.destroy(writer);
        return null;
    };
    return @ptrCast(writer);
}

pub export fn hound_index_writer_add_file(
    writer_ptr: ?*HoundIndexWriter,
    name: [*:0]const u8,
    content: [*]const u8,
    content_len: usize,
) bool {
    const writer: *IndexWriter = @ptrCast(@alignCast(writer_ptr orelse return false));
    writer.addFile(std.mem.span(name), content[0..content_len]) catch return false;
    return true;
}

pub export fn hound_index_writer_finish(writer_ptr: ?*HoundIndexWriter) bool {
    const writer: *IndexWriter = @ptrCast(@alignCast(writer_ptr orelse return false));
    writer.finish() catch return false;
    return true;
}

pub export fn hound_index_writer_destroy(writer_ptr: ?*HoundIndexWriter) void {
    const writer: *IndexWriter = @ptrCast(@alignCast(writer_ptr orelse return));
    writer.deinit();
    allocator.destroy(writer);
}

// ============================================================================
// Index Reader API
// ============================================================================

pub const HoundIndexReader = opaque {};

pub export fn hound_index_reader_open(path: [*:0]const u8) ?*HoundIndexReader {
    const reader = allocator.create(IndexReader) catch return null;
    reader.* = IndexReader.open(allocator, std.mem.span(path)) catch {
        allocator.destroy(reader);
        return null;
    };
    return @ptrCast(reader);
}

pub export fn hound_index_reader_close(reader_ptr: ?*HoundIndexReader) void {
    const reader: *IndexReader = @ptrCast(@alignCast(reader_ptr orelse return));
    reader.close();
    allocator.destroy(reader);
}

pub export fn hound_index_reader_file_count(reader_ptr: ?*HoundIndexReader) u64 {
    const reader: *IndexReader = @ptrCast(@alignCast(reader_ptr orelse return 0));
    return reader.nameCount();
}

pub export fn hound_index_reader_trigram_count(reader_ptr: ?*HoundIndexReader) usize {
    const reader: *IndexReader = @ptrCast(@alignCast(reader_ptr orelse return 0));
    return reader.trigramCount();
}

// ============================================================================
// Searcher API
// ============================================================================

pub const HoundSearcher = opaque {};

pub const HoundSearchResult = extern struct {
    file_id: u32,
    match_count: u32,
    name: [*:0]const u8,
    name_len: usize,
};

pub const HoundSearchResults = extern struct {
    results: [*]HoundSearchResult,
    count: usize,
};

pub export fn hound_searcher_create(reader_ptr: ?*HoundIndexReader) ?*HoundSearcher {
    const reader: *IndexReader = @ptrCast(@alignCast(reader_ptr orelse return null));
    const searcher = allocator.create(Searcher) catch return null;
    searcher.* = Searcher.init(allocator, reader) catch {
        allocator.destroy(searcher);
        return null;
    };
    return @ptrCast(searcher);
}

pub export fn hound_searcher_destroy(searcher_ptr: ?*HoundSearcher) void {
    const searcher: *Searcher = @ptrCast(@alignCast(searcher_ptr orelse return));
    searcher.deinit();
    allocator.destroy(searcher);
}

pub export fn hound_search(
    searcher_ptr: ?*HoundSearcher,
    query: [*:0]const u8,
    max_results: usize,
) ?*HoundSearchResults {
    const searcher: *Searcher = @ptrCast(@alignCast(searcher_ptr orelse return null));

    const results = searcher.search(std.mem.span(query), max_results) catch return null;
    if (results.len == 0) {
        searcher.freeResults(results);
        const empty = allocator.create(HoundSearchResults) catch return null;
        empty.* = .{ .results = undefined, .count = 0 };
        return empty;
    }

    const c_results = allocator.alloc(HoundSearchResult, results.len) catch {
        searcher.freeResults(results);
        return null;
    };

    for (results, 0..) |r, i| {
        const name_copy = allocator.allocSentinel(u8, r.name.len, 0) catch {
            for (0..i) |j| allocator.free(std.mem.span(c_results[j].name));
            allocator.free(c_results);
            searcher.freeResults(results);
            return null;
        };
        @memcpy(name_copy, r.name);

        c_results[i] = .{
            .file_id = r.file_id,
            .match_count = r.match_count,
            .name = name_copy.ptr,
            .name_len = r.name.len,
        };
    }

    searcher.freeResults(results);

    const output = allocator.create(HoundSearchResults) catch {
        for (c_results) |cr| allocator.free(std.mem.span(cr.name));
        allocator.free(c_results);
        return null;
    };
    output.* = .{ .results = c_results.ptr, .count = c_results.len };
    return output;
}

pub export fn hound_search_results_free(results_ptr: ?*HoundSearchResults) void {
    const results: *HoundSearchResults = results_ptr orelse return;
    if (results.count > 0) {
        for (results.results[0..results.count]) |r| {
            allocator.free(std.mem.span(r.name));
        }
        allocator.free(results.results[0..results.count]);
    }
    allocator.destroy(results);
}

// ============================================================================
// Incremental Indexer API
// ============================================================================

pub const HoundIncrementalIndexer = opaque {};

pub export fn hound_incremental_indexer_create(
    index_path: [*:0]const u8,
    batch_window_ms: u32,
    enable_watcher: bool,
) ?*HoundIncrementalIndexer {
    const indexer = allocator.create(IncrementalIndexer) catch return null;
    indexer.* = IncrementalIndexer.init(allocator, .{
        .index_path = std.mem.span(index_path),
        .batch_window_ms = batch_window_ms,
        .enable_watcher = enable_watcher,
    }) catch {
        allocator.destroy(indexer);
        return null;
    };
    return @ptrCast(indexer);
}

pub export fn hound_incremental_indexer_destroy(indexer_ptr: ?*HoundIncrementalIndexer) void {
    const indexer: *IncrementalIndexer = @ptrCast(@alignCast(indexer_ptr orelse return));
    indexer.deinit();
    allocator.destroy(indexer);
}

pub export fn hound_incremental_indexer_add_directory(
    indexer_ptr: ?*HoundIncrementalIndexer,
    path: [*:0]const u8,
) bool {
    const indexer: *IncrementalIndexer = @ptrCast(@alignCast(indexer_ptr orelse return false));
    indexer.addDirectory(std.mem.span(path)) catch return false;
    return true;
}

pub export fn hound_incremental_indexer_scan(indexer_ptr: ?*HoundIncrementalIndexer) usize {
    const indexer: *IncrementalIndexer = @ptrCast(@alignCast(indexer_ptr orelse return 0));
    const changes = indexer.scan() catch return 0;
    return changes.len;
}

pub export fn hound_incremental_indexer_rebuild(indexer_ptr: ?*HoundIncrementalIndexer) bool {
    const indexer: *IncrementalIndexer = @ptrCast(@alignCast(indexer_ptr orelse return false));
    indexer.rebuildIndex() catch return false;
    return true;
}

pub export fn hound_incremental_indexer_poll_events(indexer_ptr: ?*HoundIncrementalIndexer) bool {
    const indexer: *IncrementalIndexer = @ptrCast(@alignCast(indexer_ptr orelse return false));
    return indexer.pollEvents() catch false;
}

pub export fn hound_incremental_indexer_has_pending_changes(indexer_ptr: ?*HoundIncrementalIndexer) bool {
    const indexer: *IncrementalIndexer = @ptrCast(@alignCast(indexer_ptr orelse return false));
    return indexer.hasPendingChanges();
}

// ============================================================================
// Version API
// ============================================================================

pub export fn hound_version() [*:0]const u8 {
    return "0.1.0";
}
