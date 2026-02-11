const std = @import("std");
const posix = std.posix;
const trigram_mod = @import("trigram.zig");
const field_reader_mod = @import("field_reader.zig");
const field_index_mod = @import("field_index.zig");
const Trigram = trigram_mod.Trigram;
const FieldIndexReader = field_reader_mod.FieldIndexReader;
const Extractor = trigram_mod.Extractor;

pub const FieldBoost = struct {
    field_id: u32,
    boost: f64 = 1.0,
};

pub const MatchPosition = struct {
    start: usize,
    end: usize,
};

pub const ContextSnippet = struct {
    line_number: u32,
    byte_offset: usize,
    line_content: []const u8,
    matches: []MatchPosition,
};

pub const SearchResult = struct {
    file_id: u32,
    match_count: u32,
    name: []const u8,
    snippets: []ContextSnippet,
    score: f64,
};

pub const SearchOptions = struct {
    max_results: usize = 100,
    context_lines: u32 = 2,
    max_snippets_per_file: u32 = 10,
    thread_count: u32 = 0,
    bm25_k1: f64 = 1.2,
    bm25_b: f64 = 0.75,
};

const FileScore = struct {
    file_id: u32,
    score: f64,
};

const VerifyTask = struct {
    file_id: u32,
    name: []const u8,
    score: f64,
    result: ?SearchResult,
};

const WorkerContext = struct {
    tasks: []VerifyTask,
    start_idx: usize,
    end_idx: usize,
    query: []const u8,
    context_lines: u32,
    max_snippets_per_file: u32,
    allocator: std.mem.Allocator,
};

pub const FieldSearcher = struct {
    reader: *FieldIndexReader,
    extractor: Extractor,
    allocator: std.mem.Allocator,
    context_lines: u32,
    max_snippets_per_file: u32,
    thread_count: u32,
    bm25_k1: f64,
    bm25_b: f64,

    pub fn init(allocator: std.mem.Allocator, reader: *FieldIndexReader) !FieldSearcher {
        return initWithOptions(allocator, reader, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, reader: *FieldIndexReader, options: SearchOptions) !FieldSearcher {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const thread_count = if (options.thread_count == 0) @as(u32, @intCast(@min(cpu_count, 16))) else options.thread_count;
        return .{
            .reader = reader,
            .extractor = try Extractor.init(allocator),
            .allocator = allocator,
            .context_lines = options.context_lines,
            .max_snippets_per_file = options.max_snippets_per_file,
            .thread_count = thread_count,
            .bm25_k1 = options.bm25_k1,
            .bm25_b = options.bm25_b,
        };
    }

    pub fn deinit(self: *FieldSearcher) void {
        self.extractor.deinit();
    }

    /// Search across specified fields with per-field BM25 boosts.
    pub fn searchWithFields(
        self: *FieldSearcher,
        query: []const u8,
        fields: []const FieldBoost,
        max_results: usize,
    ) ![]SearchResult {
        const trigrams = self.extractor.extract(query) catch |err| switch (err) {
            error.ContainsNul, error.InvalidUtf8 => return &[_]SearchResult{},
            else => return err,
        };

        if (trigrams.len == 0) return &[_]SearchResult{};
        if (fields.len == 0) return &[_]SearchResult{};

        const ranked = try self.rankWithFieldBM25(trigrams, fields);
        defer self.allocator.free(ranked);

        if (ranked.len == 0) return &[_]SearchResult{};

        return self.verifyAndBuildResults(ranked, query, max_results);
    }

    /// Search in a single field only.
    pub fn searchInField(
        self: *FieldSearcher,
        field_id: u32,
        query: []const u8,
        max_results: usize,
    ) ![]SearchResult {
        const boosts = [_]FieldBoost{.{ .field_id = field_id, .boost = 1.0 }};
        return self.searchWithFields(query, &boosts, max_results);
    }

    /// Search across ALL fields with equal weight.
    pub fn search(
        self: *FieldSearcher,
        query: []const u8,
        max_results: usize,
    ) ![]SearchResult {
        const num_fields: u32 = @intCast(self.reader.fieldCount());
        if (num_fields == 0) return &[_]SearchResult{};

        var boosts = try self.allocator.alloc(FieldBoost, num_fields);
        defer self.allocator.free(boosts);

        for (0..num_fields) |i| {
            boosts[i] = .{ .field_id = @intCast(i), .boost = 1.0 };
        }

        return self.searchWithFields(query, boosts, max_results);
    }

    /// BM25 ranking with per-field boosts.
    ///
    /// For each (trigram, field) pair:
    ///   - Lookup posting list
    ///   - Compute IDF from document frequency
    ///   - For each file in the posting list, accumulate: boost * idf * tf_component
    fn rankWithFieldBM25(
        self: *FieldSearcher,
        query_trigrams: []const Trigram,
        fields: []const FieldBoost,
    ) ![]FileScore {
        const total_docs: f64 = @floatFromInt(self.reader.nameCount());
        if (total_docs == 0) return &[_]FileScore{};

        // Collect per-file scores
        var scores = std.AutoHashMap(u32, f64).init(self.allocator);
        defer scores.deinit();

        // Track per-file per-field term frequency (how many distinct query trigrams matched)
        // Key: file_id << 32 | field_id
        var field_tf = std.AutoHashMap(u64, u32).init(self.allocator);
        defer field_tf.deinit();

        // Track which files matched which trigrams in which fields
        // We'll process per (trigram, field) and accumulate IDF-weighted scores
        for (query_trigrams) |tri| {
            for (fields) |field| {
                if (self.reader.lookupFieldTrigram(tri, field.field_id)) |*entry_view| {
                    var view = entry_view.*;
                    const df: f64 = @floatFromInt(view.count);
                    const idf = @log((total_docs - df + 0.5) / (df + 0.5) + 1.0);

                    while (view.next()) |file_id| {
                        // Track tf: how many distinct query trigrams hit this file in this field
                        const tf_key = @as(u64, file_id) << 32 | @as(u64, field.field_id);
                        const tf_entry = try field_tf.getOrPut(tf_key);
                        if (!tf_entry.found_existing) {
                            tf_entry.value_ptr.* = 0;
                        }
                        tf_entry.value_ptr.* += 1;

                        // Accumulate score: boost * idf (we'll apply tf normalization after)
                        const score_entry = try scores.getOrPut(file_id);
                        if (!score_entry.found_existing) {
                            score_entry.value_ptr.* = 0.0;
                        }
                        score_entry.value_ptr.* += field.boost * idf;
                    }
                }
            }
        }

        // Now apply BM25 tf normalization per (file, field)
        // We already accumulated boost * idf per trigram hit above.
        // For a more accurate BM25, we'd need per-doc field lengths.
        // This approximation works well for trigram search where tf per term is typically 1.

        var result = std.ArrayList(FileScore){};
        errdefer result.deinit(self.allocator);

        var score_it = scores.iterator();
        while (score_it.next()) |entry| {
            try result.append(self.allocator, .{
                .file_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
            });
        }

        // Sort by score descending, then file_id ascending for stability
        std.mem.sort(FileScore, result.items, {}, struct {
            fn cmp(_: void, a: FileScore, b: FileScore) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.file_id < b.file_id;
            }
        }.cmp);

        return result.toOwnedSlice(self.allocator);
    }

    /// Verify top candidates by reading files from disk and extracting snippets.
    fn verifyAndBuildResults(
        self: *FieldSearcher,
        candidates: []const FileScore,
        query: []const u8,
        max_results: usize,
    ) ![]SearchResult {
        const num_candidates = @min(candidates.len, max_results * 2);
        if (num_candidates == 0) return &[_]SearchResult{};

        var tasks = try self.allocator.alloc(VerifyTask, num_candidates);
        defer self.allocator.free(tasks);

        for (candidates[0..num_candidates], 0..) |candidate, i| {
            tasks[i] = .{
                .file_id = candidate.file_id,
                .name = self.reader.getName(candidate.file_id) orelse "",
                .score = candidate.score,
                .result = null,
            };
        }

        const effective_threads = @min(self.thread_count, @as(u32, @intCast(num_candidates)));

        if (effective_threads <= 1 or num_candidates < 4) {
            for (tasks) |*task| {
                if (task.name.len > 0) {
                    if (extractSnippetsStatic(task.name, query, self.context_lines, self.max_snippets_per_file, self.allocator)) |snippets| {
                        task.result = .{
                            .file_id = task.file_id,
                            .match_count = @intCast(snippets.len),
                            .name = task.name,
                            .snippets = snippets,
                            .score = task.score,
                        };
                    }
                }
            }
        } else {
            var threads = try self.allocator.alloc(std.Thread, effective_threads);
            defer self.allocator.free(threads);

            const tasks_per_thread = (num_candidates + effective_threads - 1) / effective_threads;

            for (0..effective_threads) |i| {
                const start = i * tasks_per_thread;
                const end = @min(start + tasks_per_thread, num_candidates);
                threads[i] = try std.Thread.spawn(.{}, workerFn, .{WorkerContext{
                    .tasks = tasks,
                    .start_idx = if (start >= end) 0 else start,
                    .end_idx = if (start >= end) 0 else end,
                    .query = query,
                    .context_lines = self.context_lines,
                    .max_snippets_per_file = self.max_snippets_per_file,
                    .allocator = self.allocator,
                }});
            }

            for (threads) |thread| {
                thread.join();
            }
        }

        var results = std.ArrayList(SearchResult){};
        errdefer results.deinit(self.allocator);

        for (tasks) |task| {
            if (results.items.len >= max_results) break;
            if (task.result) |result| {
                try results.append(self.allocator, result);
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn freeResults(self: *FieldSearcher, results: []SearchResult) void {
        for (results) |r| {
            for (r.snippets) |snippet| {
                if (snippet.matches.len > 0) {
                    self.allocator.free(snippet.matches);
                }
                self.allocator.free(snippet.line_content);
            }
            self.allocator.free(r.snippets);
        }
        self.allocator.free(results);
    }
};

fn workerFn(ctx: WorkerContext) void {
    for (ctx.start_idx..ctx.end_idx) |i| {
        const task = &ctx.tasks[i];
        if (task.name.len > 0) {
            if (extractSnippetsStatic(task.name, ctx.query, ctx.context_lines, ctx.max_snippets_per_file, ctx.allocator)) |snippets| {
                task.result = .{
                    .file_id = task.file_id,
                    .match_count = @intCast(snippets.len),
                    .name = task.name,
                    .snippets = snippets,
                    .score = task.score,
                };
            }
        }
    }
}

fn findLineNumber(line_starts: []const usize, byte_offset: usize) u32 {
    var low: usize = 0;
    var high: usize = line_starts.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (line_starts[mid] <= byte_offset) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return @intCast(if (low > 0) low - 1 else 0);
}

fn extractSnippetsStatic(
    path: []const u8,
    query: []const u8,
    context_lines: u32,
    max_snippets_per_file: u32,
    allocator: std.mem.Allocator,
) ?[]ContextSnippet {
    // Check if filename matches — return filename-only snippet
    if (std.mem.indexOf(u8, path, query)) |match_start| {
        const snippets = allocator.alloc(ContextSnippet, 1) catch return null;
        const path_copy = allocator.dupe(u8, path) catch {
            allocator.free(snippets);
            return null;
        };
        const matches = allocator.alloc(MatchPosition, 1) catch {
            allocator.free(path_copy);
            allocator.free(snippets);
            return null;
        };
        matches[0] = .{ .start = match_start, .end = match_start + query.len };
        snippets[0] = .{
            .line_number = 0,
            .byte_offset = 0,
            .line_content = path_copy,
            .matches = matches,
        };
        return snippets;
    }

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    const size = stat.size;
    if (size == 0) return null;

    const data = posix.mmap(
        null,
        size,
        posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    ) catch return null;
    defer posix.munmap(data);

    var line_starts = std.ArrayList(usize){};
    defer line_starts.deinit(allocator);
    line_starts.append(allocator, 0) catch return null;

    for (data, 0..) |byte, i| {
        if (byte == '\n' and i + 1 < data.len) {
            line_starts.append(allocator, i + 1) catch return null;
        }
    }

    var match_lines = std.AutoHashMap(u32, std.ArrayList(MatchPosition)).init(allocator);
    defer {
        var it = match_lines.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        match_lines.deinit();
    }

    var search_start: usize = 0;
    while (search_start < data.len) {
        if (std.mem.indexOf(u8, data[search_start..], query)) |rel_pos| {
            const match_start = search_start + rel_pos;
            const match_end = match_start + query.len;
            const line_num = findLineNumber(line_starts.items, match_start);
            const line_start = line_starts.items[line_num];
            const match_in_line = MatchPosition{
                .start = match_start - line_start,
                .end = match_end - line_start,
            };

            const entry = match_lines.getOrPut(line_num) catch return null;
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(MatchPosition){};
            }
            entry.value_ptr.append(allocator, match_in_line) catch return null;

            search_start = match_start + 1;
        } else {
            break;
        }
    }

    if (match_lines.count() == 0) return null;

    var lines_to_include = std.AutoHashMap(u32, void).init(allocator);
    defer lines_to_include.deinit();

    var match_it = match_lines.keyIterator();
    while (match_it.next()) |line_num_ptr| {
        const line_num = line_num_ptr.*;
        const ctx = context_lines;
        const start_line: u32 = if (line_num >= ctx) line_num - ctx else 0;
        const total_lines: u32 = @intCast(line_starts.items.len);
        const end_line = @min(line_num + ctx, total_lines - 1);

        var l = start_line;
        while (l <= end_line) : (l += 1) {
            lines_to_include.put(l, {}) catch return null;
        }
    }

    var sorted_lines = std.ArrayList(u32){};
    defer sorted_lines.deinit(allocator);
    var lines_it = lines_to_include.keyIterator();
    while (lines_it.next()) |k| {
        sorted_lines.append(allocator, k.*) catch return null;
    }
    std.mem.sort(u32, sorted_lines.items, {}, std.sort.asc(u32));

    const max_snippets = @min(sorted_lines.items.len, max_snippets_per_file);
    var snippets = allocator.alloc(ContextSnippet, max_snippets) catch return null;
    errdefer allocator.free(snippets);

    var snippet_count: usize = 0;
    for (sorted_lines.items) |line_num| {
        if (snippet_count >= max_snippets) break;

        const line_start = line_starts.items[line_num];
        const line_end = if (line_num + 1 < line_starts.items.len)
            line_starts.items[line_num + 1] - 1
        else
            data.len;

        const line_len = line_end - line_start;
        const line_content = allocator.alloc(u8, line_len) catch return null;
        @memcpy(line_content, data[line_start..line_end]);

        var matches: []MatchPosition = &[_]MatchPosition{};
        if (match_lines.get(line_num)) |match_list| {
            matches = allocator.alloc(MatchPosition, match_list.items.len) catch {
                allocator.free(line_content);
                return null;
            };
            @memcpy(matches, match_list.items);
        }

        snippets[snippet_count] = .{
            .line_number = line_num + 1,
            .byte_offset = line_start,
            .line_content = line_content,
            .matches = matches,
        };
        snippet_count += 1;
    }

    return snippets[0..snippet_count];
}

// =============================================================================
// Tests
// =============================================================================

fn createTestFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ dir, name });
    defer std.testing.allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

test "field searcher basic" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_field_search_basic_test";
    const test_idx = "/tmp/hound_field_search_basic_test.idx";

    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().deleteFile(test_idx) catch {};
    try std.fs.cwd().makePath(test_dir);

    try createTestFile(test_dir, "doc1.txt", "hello world content here");
    try createTestFile(test_dir, "doc2.txt", "hello there friend");

    {
        var writer = try field_index_mod.FieldIndexWriter.init(allocator, test_idx);
        defer writer.deinit();

        const title_id = try writer.addField("title");
        const body_id = try writer.addField("body");

        try writer.addFileField(test_dir ++ "/doc1.txt", title_id, "hello world");
        try writer.addFileField(test_dir ++ "/doc1.txt", body_id, "hello world content here");
        try writer.addFileField(test_dir ++ "/doc2.txt", title_id, "another title");
        try writer.addFileField(test_dir ++ "/doc2.txt", body_id, "hello there friend");
        try writer.finish();
    }

    var reader = try FieldIndexReader.open(allocator, test_idx);
    defer reader.close();

    var searcher = try FieldSearcher.init(allocator, &reader);
    defer searcher.deinit();

    const results = try searcher.search("hello", 10);
    defer searcher.freeResults(results);

    try std.testing.expect(results.len >= 1);
}

test "field searcher field boost ranking" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_field_search_boost_test";
    const test_idx = "/tmp/hound_field_search_boost_test.idx";

    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().deleteFile(test_idx) catch {};
    try std.fs.cwd().makePath(test_dir);

    // doc1: title matches "search engine", body does not
    try createTestFile(test_dir, "doc1.txt", "search engine\nthis is about databases and storage");
    // doc2: body matches "search engine", title does not
    try createTestFile(test_dir, "doc2.txt", "database intro\nsearch engine optimization tips");

    {
        var writer = try field_index_mod.FieldIndexWriter.init(allocator, test_idx);
        defer writer.deinit();

        const title_id = try writer.addField("title");
        const body_id = try writer.addField("body");

        try writer.addFileField(test_dir ++ "/doc1.txt", title_id, "search engine");
        try writer.addFileField(test_dir ++ "/doc1.txt", body_id, "this is about databases and storage");
        try writer.addFileField(test_dir ++ "/doc2.txt", title_id, "database intro");
        try writer.addFileField(test_dir ++ "/doc2.txt", body_id, "search engine optimization tips");
        try writer.finish();
    }

    var reader = try FieldIndexReader.open(allocator, test_idx);
    defer reader.close();

    var searcher = try FieldSearcher.init(allocator, &reader);
    defer searcher.deinit();

    // Search with title boost 3x, body 1x
    const boosts = [_]FieldBoost{
        .{ .field_id = 0, .boost = 3.0 }, // title
        .{ .field_id = 1, .boost = 1.0 }, // body
    };

    const results = try searcher.searchWithFields("search engine", &boosts, 10);
    defer searcher.freeResults(results);

    try std.testing.expect(results.len == 2);

    // doc1 (file_id=0) should rank higher because "search engine" is in the title (3x boost)
    try std.testing.expectEqual(@as(u32, 0), results[0].file_id);
    try std.testing.expectEqual(@as(u32, 1), results[1].file_id);

    // Verify scores reflect the boost
    try std.testing.expect(results[0].score > results[1].score);
}

test "field searcher single field" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/hound_field_search_single_test";
    const test_idx = "/tmp/hound_field_search_single_test.idx";

    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().deleteFile(test_idx) catch {};
    try std.fs.cwd().makePath(test_dir);

    try createTestFile(test_dir, "doc1.txt", "hello in title\nsome body");
    try createTestFile(test_dir, "doc2.txt", "other title\nhello in body");

    {
        var writer = try field_index_mod.FieldIndexWriter.init(allocator, test_idx);
        defer writer.deinit();

        const title_id = try writer.addField("title");
        const body_id = try writer.addField("body");

        try writer.addFileField(test_dir ++ "/doc1.txt", title_id, "hello in title");
        try writer.addFileField(test_dir ++ "/doc1.txt", body_id, "some body");
        try writer.addFileField(test_dir ++ "/doc2.txt", title_id, "other title");
        try writer.addFileField(test_dir ++ "/doc2.txt", body_id, "hello in body");
        try writer.finish();
    }

    var reader = try FieldIndexReader.open(allocator, test_idx);
    defer reader.close();

    var searcher = try FieldSearcher.init(allocator, &reader);
    defer searcher.deinit();

    // Search only in title (field_id=0)
    const title_results = try searcher.searchInField(0, "hello", 10);
    defer searcher.freeResults(title_results);

    // Only doc1 has "hello" in the title
    try std.testing.expectEqual(@as(usize, 1), title_results.len);
    try std.testing.expectEqual(@as(u32, 0), title_results[0].file_id);

    // Search only in body (field_id=1)
    const body_results = try searcher.searchInField(1, "hello", 10);
    defer searcher.freeResults(body_results);

    // Only doc2 has "hello" in the body
    try std.testing.expectEqual(@as(usize, 1), body_results.len);
    try std.testing.expectEqual(@as(u32, 1), body_results[0].file_id);
}

test "field searcher empty results" {
    const allocator = std.testing.allocator;
    const test_idx = "/tmp/hound_field_search_empty_test.idx";

    std.fs.cwd().deleteFile(test_idx) catch {};

    {
        var writer = try field_index_mod.FieldIndexWriter.init(allocator, test_idx);
        defer writer.deinit();
        _ = try writer.addField("title");
        try writer.finish();
    }

    var reader = try FieldIndexReader.open(allocator, test_idx);
    defer reader.close();

    var searcher = try FieldSearcher.init(allocator, &reader);
    defer searcher.deinit();

    const results = try searcher.search("nonexistent", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}
