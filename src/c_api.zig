const std = @import("std");
const index_mod = @import("index.zig");
const reader_mod = @import("reader.zig");
const search_mod = @import("search.zig");
const incremental_mod = @import("incremental.zig");
const state_mod = @import("state.zig");
const segment_index_mod = @import("segment_index.zig");
const index_manager_mod = @import("index_manager.zig");
const trigram_mod = @import("trigram.zig");
const field_index_mod = @import("field_index.zig");
const field_reader_mod = @import("field_reader.zig");
const field_search_mod = @import("field_search.zig");

const IndexWriter = index_mod.IndexWriter;
const IndexReader = reader_mod.IndexReader;
const Searcher = search_mod.Searcher;
const SearchResult = search_mod.SearchResult;
const ContextSnippet = search_mod.ContextSnippet;
const MatchPosition = search_mod.MatchPosition;
const IncrementalIndexer = incremental_mod.IncrementalIndexer;
const SegmentIndexWriter = segment_index_mod.SegmentIndexWriter;
const SegmentIndexReader = segment_index_mod.SegmentIndexReader;
const IndexManager = index_manager_mod.IndexManager;
const FieldIndexWriter = field_index_mod.FieldIndexWriter;
const FieldIndexReader = field_reader_mod.FieldIndexReader;
const FieldSearcher = field_search_mod.FieldSearcher;
const FieldSearchResult = field_search_mod.SearchResult;
const FieldBoost = field_search_mod.FieldBoost;

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

pub const HoundMatchPosition = extern struct {
    start: usize,
    end: usize,
};

pub const HoundContextSnippet = extern struct {
    line_number: u32,
    byte_offset: usize,
    line_content: [*:0]const u8,
    line_content_len: usize,
    matches: [*]HoundMatchPosition,
    match_count: usize,
};

pub const HoundSearchResult = extern struct {
    file_id: u32,
    match_count: u32,
    name: [*:0]const u8,
    name_len: usize,
    snippets: [*]HoundContextSnippet,
    snippet_count: usize,
    score: f64,
};

pub const HoundFieldBoost = extern struct {
    field_id: u32,
    boost: f64,
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
            freePartialCResults(c_results, i);
            searcher.freeResults(results);
            return null;
        };
        @memcpy(name_copy, r.name);

        const c_snippets = allocator.alloc(HoundContextSnippet, r.snippets.len) catch {
            allocator.free(name_copy);
            freePartialCResults(c_results, i);
            searcher.freeResults(results);
            return null;
        };

        for (r.snippets, 0..) |snippet, si| {
            const line_copy = allocator.allocSentinel(u8, snippet.line_content.len, 0) catch {
                for (0..si) |sj| {
                    allocator.free(std.mem.span(c_snippets[sj].line_content));
                    if (c_snippets[sj].match_count > 0) allocator.free(c_snippets[sj].matches[0..c_snippets[sj].match_count]);
                }
                allocator.free(c_snippets);
                allocator.free(name_copy);
                freePartialCResults(c_results, i);
                searcher.freeResults(results);
                return null;
            };
            @memcpy(line_copy, snippet.line_content);

            const c_matches = allocator.alloc(HoundMatchPosition, snippet.matches.len) catch {
                allocator.free(line_copy);
                for (0..si) |sj| {
                    allocator.free(std.mem.span(c_snippets[sj].line_content));
                    if (c_snippets[sj].match_count > 0) allocator.free(c_snippets[sj].matches[0..c_snippets[sj].match_count]);
                }
                allocator.free(c_snippets);
                allocator.free(name_copy);
                freePartialCResults(c_results, i);
                searcher.freeResults(results);
                return null;
            };

            for (snippet.matches, 0..) |m, mi| {
                c_matches[mi] = .{ .start = m.start, .end = m.end };
            }

            c_snippets[si] = .{
                .line_number = snippet.line_number,
                .byte_offset = snippet.byte_offset,
                .line_content = line_copy.ptr,
                .line_content_len = snippet.line_content.len,
                .matches = c_matches.ptr,
                .match_count = snippet.matches.len,
            };
        }

        c_results[i] = .{
            .file_id = r.file_id,
            .match_count = r.match_count,
            .name = name_copy.ptr,
            .name_len = r.name.len,
            .snippets = c_snippets.ptr,
            .snippet_count = r.snippets.len,
            .score = 0.0,
        };
    }

    searcher.freeResults(results);

    const output = allocator.create(HoundSearchResults) catch {
        freePartialCResults(c_results, c_results.len);
        return null;
    };
    output.* = .{ .results = c_results.ptr, .count = c_results.len };
    return output;
}

fn freePartialCResults(c_results: []HoundSearchResult, count: usize) void {
    for (c_results[0..count]) |cr| {
        for (cr.snippets[0..cr.snippet_count]) |snippet| {
            allocator.free(std.mem.span(snippet.line_content));
            if (snippet.match_count > 0) allocator.free(snippet.matches[0..snippet.match_count]);
        }
        if (cr.snippet_count > 0) allocator.free(cr.snippets[0..cr.snippet_count]);
        allocator.free(std.mem.span(cr.name));
    }
    allocator.free(c_results);
}

pub export fn hound_search_results_free(results_ptr: ?*HoundSearchResults) void {
    const results: *HoundSearchResults = results_ptr orelse return;
    if (results.count > 0) {
        for (results.results[0..results.count]) |r| {
            for (r.snippets[0..r.snippet_count]) |snippet| {
                allocator.free(std.mem.span(snippet.line_content));
                if (snippet.match_count > 0) allocator.free(snippet.matches[0..snippet.match_count]);
            }
            if (r.snippet_count > 0) allocator.free(r.snippets[0..r.snippet_count]);
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
// Segment Index Writer API
// ============================================================================

pub const HoundSegmentIndexWriter = opaque {};

pub export fn hound_segment_index_writer_create(dir: [*:0]const u8) ?*HoundSegmentIndexWriter {
    const writer = allocator.create(SegmentIndexWriter) catch return null;
    writer.* = SegmentIndexWriter.init(allocator, std.mem.span(dir)) catch {
        allocator.destroy(writer);
        return null;
    };
    return @ptrCast(writer);
}

pub export fn hound_segment_index_writer_add_file(
    writer_ptr: ?*HoundSegmentIndexWriter,
    name: [*:0]const u8,
    content: [*]const u8,
    content_len: usize,
) bool {
    const writer: *SegmentIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return false));
    writer.addFile(std.mem.span(name), content[0..content_len]) catch return false;
    return true;
}

pub export fn hound_segment_index_writer_delete_file(
    writer_ptr: ?*HoundSegmentIndexWriter,
    name: [*:0]const u8,
) bool {
    const writer: *SegmentIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return false));
    writer.deleteFile(std.mem.span(name)) catch return false;
    return true;
}

pub export fn hound_segment_index_writer_commit(writer_ptr: ?*HoundSegmentIndexWriter) bool {
    const writer: *SegmentIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return false));
    writer.commit() catch return false;
    return true;
}

pub export fn hound_segment_index_writer_segment_count(writer_ptr: ?*HoundSegmentIndexWriter) usize {
    const writer: *SegmentIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return 0));
    return writer.segmentCount();
}

pub export fn hound_segment_index_writer_document_count(writer_ptr: ?*HoundSegmentIndexWriter) u64 {
    const writer: *SegmentIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return 0));
    return writer.documentCount();
}

pub export fn hound_segment_index_writer_destroy(writer_ptr: ?*HoundSegmentIndexWriter) void {
    const writer: *SegmentIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return));
    writer.deinit();
    allocator.destroy(writer);
}

// ============================================================================
// Segment Index Reader API
// ============================================================================

pub const HoundSegmentIndexReader = opaque {};

pub export fn hound_segment_index_reader_open(dir: [*:0]const u8) ?*HoundSegmentIndexReader {
    const reader = allocator.create(SegmentIndexReader) catch return null;
    reader.* = SegmentIndexReader.open(allocator, std.mem.span(dir)) catch {
        allocator.destroy(reader);
        return null;
    };
    return @ptrCast(reader);
}

pub export fn hound_segment_index_reader_close(reader_ptr: ?*HoundSegmentIndexReader) void {
    const reader: *SegmentIndexReader = @ptrCast(@alignCast(reader_ptr orelse return));
    reader.close();
    allocator.destroy(reader);
}

pub export fn hound_segment_index_reader_segment_count(reader_ptr: ?*HoundSegmentIndexReader) usize {
    const reader: *SegmentIndexReader = @ptrCast(@alignCast(reader_ptr orelse return 0));
    return reader.segmentCount();
}

pub export fn hound_segment_index_reader_document_count(reader_ptr: ?*HoundSegmentIndexReader) u64 {
    const reader: *SegmentIndexReader = @ptrCast(@alignCast(reader_ptr orelse return 0));
    return reader.documentCount();
}

pub export fn hound_segment_index_reader_get_name(
    reader_ptr: ?*HoundSegmentIndexReader,
    global_id: u32,
    out_len: *usize,
) ?[*]const u8 {
    const reader: *SegmentIndexReader = @ptrCast(@alignCast(reader_ptr orelse return null));
    const name = reader.getName(global_id) orelse return null;
    out_len.* = name.len;
    return name.ptr;
}

pub export fn hound_segment_index_reader_lookup_trigram(
    reader_ptr: ?*HoundSegmentIndexReader,
    b0: u8,
    b1: u8,
    b2: u8,
    out_count: *usize,
) ?[*]u32 {
    const reader: *SegmentIndexReader = @ptrCast(@alignCast(reader_ptr orelse return null));
    const tri = trigram_mod.fromBytes(b0, b1, b2);
    var iter = reader.lookupTrigram(tri);
    const matches = iter.collect(allocator) catch return null;
    out_count.* = matches.len;
    return matches.ptr;
}

pub export fn hound_free_trigram_results(results: ?[*]u32, count: usize) void {
    if (results) |ptr| {
        allocator.free(ptr[0..count]);
    }
}

// ============================================================================
// Index Manager API
// ============================================================================

pub const HoundIndexManager = opaque {};

pub export fn hound_index_manager_create(dir: [*:0]const u8) ?*HoundIndexManager {
    const manager = allocator.create(IndexManager) catch return null;
    manager.* = IndexManager.init(allocator, std.mem.span(dir)) catch {
        allocator.destroy(manager);
        return null;
    };
    return @ptrCast(manager);
}

pub export fn hound_index_manager_destroy(manager_ptr: ?*HoundIndexManager) void {
    const manager: *IndexManager = @ptrCast(@alignCast(manager_ptr orelse return));
    manager.deinit();
    allocator.destroy(manager);
}

pub export fn hound_index_manager_open_writer(
    manager_ptr: ?*HoundIndexManager,
    index: [*:0]const u8,
) ?*HoundSegmentIndexWriter {
    const manager: *IndexManager = @ptrCast(@alignCast(manager_ptr orelse return null));
    const writer = allocator.create(SegmentIndexWriter) catch return null;
    writer.* = manager.openWriter(std.mem.span(index)) catch {
        allocator.destroy(writer);
        return null;
    };
    return @ptrCast(writer);
}

pub export fn hound_index_manager_open_reader(
    manager_ptr: ?*HoundIndexManager,
    index: [*:0]const u8,
) ?*HoundSegmentIndexReader {
    const manager: *IndexManager = @ptrCast(@alignCast(manager_ptr orelse return null));
    const reader = allocator.create(SegmentIndexReader) catch return null;
    reader.* = manager.openReader(std.mem.span(index)) catch {
        allocator.destroy(reader);
        return null;
    };
    return @ptrCast(reader);
}

// ============================================================================
// Field Index Writer API
// ============================================================================

pub const HoundFieldIndexWriter = opaque {};

pub export fn hound_field_index_writer_create(path: [*:0]const u8) ?*HoundFieldIndexWriter {
    const writer = allocator.create(FieldIndexWriter) catch return null;
    writer.* = FieldIndexWriter.init(allocator, std.mem.span(path)) catch {
        allocator.destroy(writer);
        return null;
    };
    return @ptrCast(writer);
}

pub export fn hound_field_index_writer_add_field(
    writer_ptr: ?*HoundFieldIndexWriter,
    name: [*:0]const u8,
) i64 {
    const writer: *FieldIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return -1));
    const field_id = writer.addField(std.mem.span(name)) catch return -1;
    return @intCast(field_id);
}

pub export fn hound_field_index_writer_add_file_field(
    writer_ptr: ?*HoundFieldIndexWriter,
    name: [*:0]const u8,
    field_id: u32,
    content: [*]const u8,
    content_len: usize,
) bool {
    const writer: *FieldIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return false));
    writer.addFileField(std.mem.span(name), field_id, content[0..content_len]) catch return false;
    return true;
}

pub export fn hound_field_index_writer_finish(writer_ptr: ?*HoundFieldIndexWriter) bool {
    const writer: *FieldIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return false));
    writer.finish() catch return false;
    return true;
}

pub export fn hound_field_index_writer_destroy(writer_ptr: ?*HoundFieldIndexWriter) void {
    const writer: *FieldIndexWriter = @ptrCast(@alignCast(writer_ptr orelse return));
    writer.deinit();
    allocator.destroy(writer);
}

// ============================================================================
// Field Index Reader API
// ============================================================================

pub const HoundFieldIndexReader = opaque {};

pub export fn hound_field_index_reader_open(path: [*:0]const u8) ?*HoundFieldIndexReader {
    const reader = allocator.create(FieldIndexReader) catch return null;
    reader.* = FieldIndexReader.open(allocator, std.mem.span(path)) catch {
        allocator.destroy(reader);
        return null;
    };
    return @ptrCast(reader);
}

pub export fn hound_field_index_reader_close(reader_ptr: ?*HoundFieldIndexReader) void {
    const reader: *FieldIndexReader = @ptrCast(@alignCast(reader_ptr orelse return));
    reader.close();
    allocator.destroy(reader);
}

pub export fn hound_field_index_reader_field_count(reader_ptr: ?*HoundFieldIndexReader) u64 {
    const reader: *FieldIndexReader = @ptrCast(@alignCast(reader_ptr orelse return 0));
    return reader.fieldCount();
}

pub export fn hound_field_index_reader_name_count(reader_ptr: ?*HoundFieldIndexReader) u64 {
    const reader: *FieldIndexReader = @ptrCast(@alignCast(reader_ptr orelse return 0));
    return reader.nameCount();
}

// ============================================================================
// Field Searcher API
// ============================================================================

pub const HoundFieldSearcher = opaque {};

pub export fn hound_field_searcher_create(reader_ptr: ?*HoundFieldIndexReader) ?*HoundFieldSearcher {
    const reader: *FieldIndexReader = @ptrCast(@alignCast(reader_ptr orelse return null));
    const searcher = allocator.create(FieldSearcher) catch return null;
    searcher.* = FieldSearcher.init(allocator, reader) catch {
        allocator.destroy(searcher);
        return null;
    };
    return @ptrCast(searcher);
}

pub export fn hound_field_searcher_destroy(searcher_ptr: ?*HoundFieldSearcher) void {
    const searcher: *FieldSearcher = @ptrCast(@alignCast(searcher_ptr orelse return));
    searcher.deinit();
    allocator.destroy(searcher);
}

pub export fn hound_field_search(
    searcher_ptr: ?*HoundFieldSearcher,
    query: [*:0]const u8,
    max_results: usize,
) ?*HoundSearchResults {
    const searcher: *FieldSearcher = @ptrCast(@alignCast(searcher_ptr orelse return null));
    const results = searcher.search(std.mem.span(query), max_results) catch return null;
    return convertFieldResultsToC(results, searcher);
}

pub export fn hound_field_search_in_field(
    searcher_ptr: ?*HoundFieldSearcher,
    field_id: u32,
    query: [*:0]const u8,
    max_results: usize,
) ?*HoundSearchResults {
    const searcher: *FieldSearcher = @ptrCast(@alignCast(searcher_ptr orelse return null));
    const results = searcher.searchInField(field_id, std.mem.span(query), max_results) catch return null;
    return convertFieldResultsToC(results, searcher);
}

pub export fn hound_field_search_with_fields(
    searcher_ptr: ?*HoundFieldSearcher,
    query: [*:0]const u8,
    field_ids: [*]const u32,
    boosts: [*]const f64,
    num_fields: usize,
    max_results: usize,
) ?*HoundSearchResults {
    const searcher: *FieldSearcher = @ptrCast(@alignCast(searcher_ptr orelse return null));

    const field_boosts = allocator.alloc(FieldBoost, num_fields) catch return null;
    defer allocator.free(field_boosts);

    for (0..num_fields) |i| {
        field_boosts[i] = .{ .field_id = field_ids[i], .boost = boosts[i] };
    }

    const results = searcher.searchWithFields(std.mem.span(query), field_boosts, max_results) catch return null;
    return convertFieldResultsToC(results, searcher);
}

fn convertFieldResultsToC(results: []FieldSearchResult, searcher: *FieldSearcher) ?*HoundSearchResults {
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
            freePartialCResults(c_results, i);
            searcher.freeResults(results);
            return null;
        };
        @memcpy(name_copy, r.name);

        const c_snippets = allocator.alloc(HoundContextSnippet, r.snippets.len) catch {
            allocator.free(name_copy);
            freePartialCResults(c_results, i);
            searcher.freeResults(results);
            return null;
        };

        for (r.snippets, 0..) |snippet, si| {
            const line_copy = allocator.allocSentinel(u8, snippet.line_content.len, 0) catch {
                for (0..si) |sj| {
                    allocator.free(std.mem.span(c_snippets[sj].line_content));
                    if (c_snippets[sj].match_count > 0) allocator.free(c_snippets[sj].matches[0..c_snippets[sj].match_count]);
                }
                allocator.free(c_snippets);
                allocator.free(name_copy);
                freePartialCResults(c_results, i);
                searcher.freeResults(results);
                return null;
            };
            @memcpy(line_copy, snippet.line_content);

            const c_matches = allocator.alloc(HoundMatchPosition, snippet.matches.len) catch {
                allocator.free(line_copy);
                for (0..si) |sj| {
                    allocator.free(std.mem.span(c_snippets[sj].line_content));
                    if (c_snippets[sj].match_count > 0) allocator.free(c_snippets[sj].matches[0..c_snippets[sj].match_count]);
                }
                allocator.free(c_snippets);
                allocator.free(name_copy);
                freePartialCResults(c_results, i);
                searcher.freeResults(results);
                return null;
            };

            for (snippet.matches, 0..) |m, mi| {
                c_matches[mi] = .{ .start = m.start, .end = m.end };
            }

            c_snippets[si] = .{
                .line_number = snippet.line_number,
                .byte_offset = snippet.byte_offset,
                .line_content = line_copy.ptr,
                .line_content_len = snippet.line_content.len,
                .matches = c_matches.ptr,
                .match_count = snippet.matches.len,
            };
        }

        c_results[i] = .{
            .file_id = r.file_id,
            .match_count = r.match_count,
            .name = name_copy.ptr,
            .name_len = r.name.len,
            .snippets = c_snippets.ptr,
            .snippet_count = r.snippets.len,
            .score = r.score,
        };
    }

    searcher.freeResults(results);

    const output = allocator.create(HoundSearchResults) catch {
        freePartialCResults(c_results, c_results.len);
        return null;
    };
    output.* = .{ .results = c_results.ptr, .count = c_results.len };
    return output;
}

// ============================================================================
// Version API
// ============================================================================

pub export fn hound_version() [*:0]const u8 {
    return "0.2.1";
}
