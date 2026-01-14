const std = @import("std");
const posix = std.posix;
const trigram_mod = @import("trigram.zig");
const reader_mod = @import("reader.zig");
const regex_mod = @import("regex.zig");
const Trigram = trigram_mod.Trigram;
const IndexReader = reader_mod.IndexReader;
const PostingListView = reader_mod.PostingListView;
const Extractor = trigram_mod.Extractor;
const PosixRegex = regex_mod.PosixRegex;

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
};

pub const RankingMode = enum {
    trigram_count,
    bm25,
};

pub const SearchOptions = struct {
    max_results: usize = 100,
    context_lines: u32 = 2,
    max_snippets_per_file: u32 = 10,
    thread_count: u32 = 0,
    ranking_mode: RankingMode = .bm25,
    bm25_k1: f64 = 1.2,
    bm25_b: f64 = 0.75,
};

const VerifyTask = struct {
    file_id: u32,
    name: []const u8,
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

const RegexWorkerContext = struct {
    tasks: []VerifyTask,
    start_idx: usize,
    end_idx: usize,
    pattern: []const u8,
    context_lines: u32,
    max_snippets_per_file: u32,
    allocator: std.mem.Allocator,
};

pub const Searcher = struct {
    reader: *IndexReader,
    extractor: Extractor,
    allocator: std.mem.Allocator,
    context_lines: u32,
    max_snippets_per_file: u32,
    thread_count: u32,
    ranking_mode: RankingMode,
    bm25_k1: f64,
    bm25_b: f64,

    pub fn init(allocator: std.mem.Allocator, reader: *IndexReader) !Searcher {
        return initWithOptions(allocator, reader, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, reader: *IndexReader, options: SearchOptions) !Searcher {
        _ = options.max_results;
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const thread_count = if (options.thread_count == 0) @as(u32, @intCast(@min(cpu_count, 16))) else options.thread_count;
        return .{
            .reader = reader,
            .extractor = try Extractor.init(allocator),
            .allocator = allocator,
            .context_lines = options.context_lines,
            .max_snippets_per_file = options.max_snippets_per_file,
            .thread_count = thread_count,
            .ranking_mode = options.ranking_mode,
            .bm25_k1 = options.bm25_k1,
            .bm25_b = options.bm25_b,
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

        var posting_list_sizes = std.ArrayList(u32).init(self.allocator);
        defer posting_list_sizes.deinit();

        for (trigrams) |tri| {
            if (self.reader.lookupTrigram(tri)) |*view| {
                var v = view.*;
                const file_ids = try v.collect(self.allocator);
                try posting_list_sizes.append(@intCast(file_ids.len));
                try posting_lists.append(file_ids);
            }
        }

        if (posting_lists.items.len == 0) return &[_]SearchResult{};

        const ranked = switch (self.ranking_mode) {
            .trigram_count => try self.intersectAndRank(posting_lists.items),
            .bm25 => try self.intersectAndRankBM25(posting_lists.items, posting_list_sizes.items),
        };
        defer self.allocator.free(ranked);

        return self.verifyFilesParallel(ranked, query, max_results);
    }

    fn verifyFilesParallel(self: *Searcher, candidates: []const FileCount, query: []const u8, max_results: usize) ![]SearchResult {
        const num_candidates = @min(candidates.len, max_results * 2);
        if (num_candidates == 0) return &[_]SearchResult{};

        var tasks = try self.allocator.alloc(VerifyTask, num_candidates);
        defer self.allocator.free(tasks);

        for (candidates[0..num_candidates], 0..) |candidate, i| {
            tasks[i] = .{
                .file_id = candidate.file_id,
                .name = self.reader.getName(candidate.file_id) orelse "",
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
                if (start >= end) {
                    threads[i] = try std.Thread.spawn(.{}, workerFn, .{WorkerContext{
                        .tasks = tasks,
                        .start_idx = 0,
                        .end_idx = 0,
                        .query = query,
                        .context_lines = self.context_lines,
                        .max_snippets_per_file = self.max_snippets_per_file,
                        .allocator = self.allocator,
                    }});
                } else {
                    threads[i] = try std.Thread.spawn(.{}, workerFn, .{WorkerContext{
                        .tasks = tasks,
                        .start_idx = start,
                        .end_idx = end,
                        .query = query,
                        .context_lines = self.context_lines,
                        .max_snippets_per_file = self.max_snippets_per_file,
                        .allocator = self.allocator,
                    }});
                }
            }

            for (threads) |thread| {
                thread.join();
            }
        }

        var results = std.ArrayList(SearchResult).init(self.allocator);
        errdefer results.deinit();

        for (tasks) |task| {
            if (results.items.len >= max_results) break;
            if (task.result) |result| {
                try results.append(result);
            }
        }

        return results.toOwnedSlice();
    }

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
                    };
                }
            }
        }
    }

    fn regexWorkerFn(ctx: RegexWorkerContext) void {
        var regex = PosixRegex.compile(ctx.pattern, ctx.allocator) catch return;
        defer regex.deinit();

        for (ctx.start_idx..ctx.end_idx) |i| {
            const task = &ctx.tasks[i];
            if (task.name.len > 0) {
                if (extractRegexSnippetsStatic(task.name, &regex, ctx.context_lines, ctx.max_snippets_per_file, ctx.allocator)) |snippets| {
                    task.result = .{
                        .file_id = task.file_id,
                        .match_count = @intCast(snippets.len),
                        .name = task.name,
                        .snippets = snippets,
                    };
                }
            }
        }
    }

    const FileCount = struct {
        file_id: u32,
        count: u32,
    };

    fn extractSnippets(self: *Searcher, path: []const u8, query: []const u8) ?[]ContextSnippet {
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

        var line_starts = std.ArrayList(usize).init(self.allocator);
        defer line_starts.deinit();
        line_starts.append(0) catch return null;

        for (data, 0..) |byte, i| {
            if (byte == '\n' and i + 1 < data.len) {
                line_starts.append(i + 1) catch return null;
            }
        }

        var match_lines = std.AutoHashMap(u32, std.ArrayList(MatchPosition)).init(self.allocator);
        defer {
            var it = match_lines.valueIterator();
            while (it.next()) |list| list.deinit();
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
                    entry.value_ptr.* = std.ArrayList(MatchPosition).init(self.allocator);
                }
                entry.value_ptr.append(match_in_line) catch return null;

                search_start = match_start + 1;
            } else {
                break;
            }
        }

        if (match_lines.count() == 0) return null;

        var lines_to_include = std.AutoHashMap(u32, void).init(self.allocator);
        defer lines_to_include.deinit();

        var match_it = match_lines.keyIterator();
        while (match_it.next()) |line_num_ptr| {
            const line_num = line_num_ptr.*;
            const context = self.context_lines;
            const start_line: u32 = if (line_num >= context) line_num - context else 0;
            const total_lines: u32 = @intCast(line_starts.items.len);
            const end_line = @min(line_num + context, total_lines - 1);

            var l = start_line;
            while (l <= end_line) : (l += 1) {
                lines_to_include.put(l, {}) catch return null;
            }
        }

        var sorted_lines = std.ArrayList(u32).init(self.allocator);
        defer sorted_lines.deinit();
        var lines_it = lines_to_include.keyIterator();
        while (lines_it.next()) |k| {
            sorted_lines.append(k.*) catch return null;
        }
        std.mem.sort(u32, sorted_lines.items, {}, std.sort.asc(u32));

        const max_snippets = @min(sorted_lines.items.len, self.max_snippets_per_file);
        var snippets = self.allocator.alloc(ContextSnippet, max_snippets) catch return null;
        errdefer self.allocator.free(snippets);

        var snippet_count: usize = 0;
        for (sorted_lines.items) |line_num| {
            if (snippet_count >= max_snippets) break;

            const line_start = line_starts.items[line_num];
            const line_end = if (line_num + 1 < line_starts.items.len)
                line_starts.items[line_num + 1] - 1
            else
                data.len;

            const line_len = line_end - line_start;
            const line_content = self.allocator.alloc(u8, line_len) catch return null;
            @memcpy(line_content, data[line_start..line_end]);

            var matches: []MatchPosition = &[_]MatchPosition{};
            if (match_lines.get(line_num)) |match_list| {
                matches = self.allocator.alloc(MatchPosition, match_list.items.len) catch {
                    self.allocator.free(line_content);
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

    fn intersectAndRankBM25(self: *Searcher, lists: [][]u32, posting_list_sizes: []u32) ![]FileCount {
        const total_docs: f64 = @floatFromInt(self.reader.nameCount());
        if (total_docs == 0) return &[_]FileCount{};

        const avg_doc_length: f64 = @as(f64, @floatFromInt(lists.len));

        var tf_map = std.AutoHashMap(u32, std.ArrayList(u32)).init(self.allocator);
        defer {
            var vit = tf_map.valueIterator();
            while (vit.next()) |list| list.deinit();
            tf_map.deinit();
        }

        for (lists, 0..) |list, term_idx| {
            for (list) |file_id| {
                const entry = try tf_map.getOrPut(file_id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = std.ArrayList(u32).init(self.allocator);
                }
                try entry.value_ptr.append(@intCast(term_idx));
            }
        }

        var idf_values = try self.allocator.alloc(f64, lists.len);
        defer self.allocator.free(idf_values);

        for (posting_list_sizes, 0..) |doc_freq, i| {
            const df: f64 = @floatFromInt(doc_freq);
            idf_values[i] = @log((total_docs - df + 0.5) / (df + 0.5) + 1.0);
        }

        var scores = std.AutoHashMap(u32, f64).init(self.allocator);
        defer scores.deinit();

        var tf_it = tf_map.iterator();
        while (tf_it.next()) |entry| {
            const file_id = entry.key_ptr.*;
            const term_indices = entry.value_ptr.items;

            var term_freqs = try self.allocator.alloc(u32, lists.len);
            defer self.allocator.free(term_freqs);
            @memset(term_freqs, 0);

            for (term_indices) |term_idx| {
                term_freqs[term_idx] += 1;
            }

            const doc_length: f64 = @floatFromInt(term_indices.len);
            const length_norm = 1.0 - self.bm25_b + self.bm25_b * (doc_length / avg_doc_length);

            var score: f64 = 0.0;
            for (term_freqs, 0..) |tf, term_idx| {
                if (tf > 0) {
                    const tf_f: f64 = @floatFromInt(tf);
                    const numerator = tf_f * (self.bm25_k1 + 1.0);
                    const denominator = tf_f + self.bm25_k1 * length_norm;
                    score += idf_values[term_idx] * (numerator / denominator);
                }
            }

            try scores.put(file_id, score);
        }

        var result = std.ArrayList(FileCount).init(self.allocator);
        errdefer result.deinit();

        var score_it = scores.iterator();
        while (score_it.next()) |entry| {
            const score_u32: u32 = @intFromFloat(@max(0.0, entry.value_ptr.* * 1000.0));
            try result.append(.{
                .file_id = entry.key_ptr.*,
                .count = score_u32,
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

    /// Search using a regex pattern
    /// Extracts required trigrams from regex to filter candidates, then verifies with full regex match
    pub fn searchRegex(self: *Searcher, pattern: []const u8, max_results: usize) ![]SearchResult {
        const trigrams = try regex_mod.extractTrigrams(self.allocator, pattern);
        defer self.allocator.free(trigrams);

        if (trigrams.len == 0) {
            var regex = PosixRegex.compile(pattern, self.allocator) catch return &[_]SearchResult{};
            defer regex.deinit();
            return self.searchRegexFullScan(&regex, max_results);
        }

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

        return self.verifyFilesParallelRegex(ranked, pattern, max_results);
    }

    fn verifyFilesParallelRegex(self: *Searcher, candidates: []const FileCount, pattern: []const u8, max_results: usize) ![]SearchResult {
        const num_candidates = @min(candidates.len, max_results * 2);
        if (num_candidates == 0) return &[_]SearchResult{};

        var tasks = try self.allocator.alloc(VerifyTask, num_candidates);
        defer self.allocator.free(tasks);

        for (candidates[0..num_candidates], 0..) |candidate, i| {
            tasks[i] = .{
                .file_id = candidate.file_id,
                .name = self.reader.getName(candidate.file_id) orelse "",
                .result = null,
            };
        }

        const effective_threads = @min(self.thread_count, @as(u32, @intCast(num_candidates)));

        if (effective_threads <= 1 or num_candidates < 4) {
            var regex = PosixRegex.compile(pattern, self.allocator) catch return &[_]SearchResult{};
            defer regex.deinit();

            for (tasks) |*task| {
                if (task.name.len > 0) {
                    if (extractRegexSnippetsStatic(task.name, &regex, self.context_lines, self.max_snippets_per_file, self.allocator)) |snippets| {
                        task.result = .{
                            .file_id = task.file_id,
                            .match_count = @intCast(snippets.len),
                            .name = task.name,
                            .snippets = snippets,
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
                if (start >= end) {
                    threads[i] = try std.Thread.spawn(.{}, regexWorkerFn, .{RegexWorkerContext{
                        .tasks = tasks,
                        .start_idx = 0,
                        .end_idx = 0,
                        .pattern = pattern,
                        .context_lines = self.context_lines,
                        .max_snippets_per_file = self.max_snippets_per_file,
                        .allocator = self.allocator,
                    }});
                } else {
                    threads[i] = try std.Thread.spawn(.{}, regexWorkerFn, .{RegexWorkerContext{
                        .tasks = tasks,
                        .start_idx = start,
                        .end_idx = end,
                        .pattern = pattern,
                        .context_lines = self.context_lines,
                        .max_snippets_per_file = self.max_snippets_per_file,
                        .allocator = self.allocator,
                    }});
                }
            }

            for (threads) |thread| {
                thread.join();
            }
        }

        var results = std.ArrayList(SearchResult).init(self.allocator);
        errdefer results.deinit();

        for (tasks) |task| {
            if (results.items.len >= max_results) break;
            if (task.result) |result| {
                try results.append(result);
            }
        }

        return results.toOwnedSlice();
    }

    /// Full scan when no trigrams available (fallback for regex like .* or [a-z]*)
    fn searchRegexFullScan(self: *Searcher, regex: *const PosixRegex, max_results: usize) ![]SearchResult {
        var results = std.ArrayList(SearchResult).init(self.allocator);
        errdefer results.deinit();

        // Iterate through all indexed files
        var file_id: u32 = 0;
        while (results.items.len < max_results) : (file_id += 1) {
            const name = self.reader.getName(file_id) orelse break;
            if (self.extractRegexSnippets(name, regex)) |snippets| {
                try results.append(.{
                    .file_id = file_id,
                    .match_count = @intCast(snippets.len),
                    .name = name,
                    .snippets = snippets,
                });
            }
        }

        return results.toOwnedSlice();
    }

    /// Extract snippets for regex matches
    fn extractRegexSnippets(self: *Searcher, path: []const u8, regex: *const PosixRegex) ?[]ContextSnippet {
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

        // Build line starts
        var line_starts = std.ArrayList(usize).init(self.allocator);
        defer line_starts.deinit();
        line_starts.append(0) catch return null;

        for (data, 0..) |byte, i| {
            if (byte == '\n' and i + 1 < data.len) {
                line_starts.append(i + 1) catch return null;
            }
        }

        // Find all regex matches
        const matches = regex.findAll(data, self.allocator) catch return null;
        defer self.allocator.free(matches);

        if (matches.len == 0) return null;

        // Group matches by line
        var match_lines = std.AutoHashMap(u32, std.ArrayList(MatchPosition)).init(self.allocator);
        defer {
            var it = match_lines.valueIterator();
            while (it.next()) |list| list.deinit();
            match_lines.deinit();
        }

        for (matches) |m| {
            const line_num = findLineNumber(line_starts.items, m.start);
            const line_start = line_starts.items[line_num];
            const match_in_line = MatchPosition{
                .start = m.start - line_start,
                .end = m.end - line_start,
            };

            const entry = match_lines.getOrPut(line_num) catch return null;
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(MatchPosition).init(self.allocator);
            }
            entry.value_ptr.append(match_in_line) catch return null;
        }

        // Build context lines
        var lines_to_include = std.AutoHashMap(u32, void).init(self.allocator);
        defer lines_to_include.deinit();

        var match_it = match_lines.keyIterator();
        while (match_it.next()) |line_num_ptr| {
            const line_num = line_num_ptr.*;
            const context = self.context_lines;
            const start_line: u32 = if (line_num >= context) line_num - context else 0;
            const total_lines: u32 = @intCast(line_starts.items.len);
            const end_line = @min(line_num + context, total_lines - 1);

            var l = start_line;
            while (l <= end_line) : (l += 1) {
                lines_to_include.put(l, {}) catch return null;
            }
        }

        // Sort and build snippets
        var sorted_lines = std.ArrayList(u32).init(self.allocator);
        defer sorted_lines.deinit();
        var lines_it = lines_to_include.keyIterator();
        while (lines_it.next()) |k| {
            sorted_lines.append(k.*) catch return null;
        }
        std.mem.sort(u32, sorted_lines.items, {}, std.sort.asc(u32));

        const max_snippets = @min(sorted_lines.items.len, self.max_snippets_per_file);
        var snippets = self.allocator.alloc(ContextSnippet, max_snippets) catch return null;
        errdefer self.allocator.free(snippets);

        var snippet_count: usize = 0;
        for (sorted_lines.items) |line_num| {
            if (snippet_count >= max_snippets) break;

            const line_start = line_starts.items[line_num];
            const line_end = if (line_num + 1 < line_starts.items.len)
                line_starts.items[line_num + 1] - 1
            else
                data.len;

            const line_len = line_end - line_start;
            const line_content = self.allocator.alloc(u8, line_len) catch return null;
            @memcpy(line_content, data[line_start..line_end]);

            var match_positions: []MatchPosition = &[_]MatchPosition{};
            if (match_lines.get(line_num)) |match_list| {
                match_positions = self.allocator.alloc(MatchPosition, match_list.items.len) catch {
                    self.allocator.free(line_content);
                    return null;
                };
                @memcpy(match_positions, match_list.items);
            }

            snippets[snippet_count] = .{
                .line_number = line_num + 1,
                .byte_offset = line_start,
                .line_content = line_content,
                .matches = match_positions,
            };
            snippet_count += 1;
        }

        return snippets[0..snippet_count];
    }
};

fn extractSnippetsStatic(path: []const u8, query: []const u8, context_lines: u32, max_snippets_per_file: u32, allocator: std.mem.Allocator) ?[]ContextSnippet {
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

    var line_starts = std.ArrayList(usize).init(allocator);
    defer line_starts.deinit();
    line_starts.append(0) catch return null;

    for (data, 0..) |byte, i| {
        if (byte == '\n' and i + 1 < data.len) {
            line_starts.append(i + 1) catch return null;
        }
    }

    var match_lines = std.AutoHashMap(u32, std.ArrayList(MatchPosition)).init(allocator);
    defer {
        var it = match_lines.valueIterator();
        while (it.next()) |list| list.deinit();
        match_lines.deinit();
    }

    var search_start: usize = 0;
    while (search_start < data.len) {
        if (std.mem.indexOf(u8, data[search_start..], query)) |rel_pos| {
            const match_start = search_start + rel_pos;
            const match_end = match_start + query.len;
            const line_num = findLineNumberStatic(line_starts.items, match_start);
            const line_start = line_starts.items[line_num];
            const match_in_line = MatchPosition{
                .start = match_start - line_start,
                .end = match_end - line_start,
            };

            const entry = match_lines.getOrPut(line_num) catch return null;
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(MatchPosition).init(allocator);
            }
            entry.value_ptr.append(match_in_line) catch return null;

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
        const start_line: u32 = if (line_num >= context_lines) line_num - context_lines else 0;
        const total_lines: u32 = @intCast(line_starts.items.len);
        const end_line = @min(line_num + context_lines, total_lines - 1);

        var l = start_line;
        while (l <= end_line) : (l += 1) {
            lines_to_include.put(l, {}) catch return null;
        }
    }

    var sorted_lines = std.ArrayList(u32).init(allocator);
    defer sorted_lines.deinit();
    var lines_it = lines_to_include.keyIterator();
    while (lines_it.next()) |k| {
        sorted_lines.append(k.*) catch return null;
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

fn extractRegexSnippetsStatic(path: []const u8, regex: *const PosixRegex, context_lines: u32, max_snippets_per_file: u32, allocator: std.mem.Allocator) ?[]ContextSnippet {
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

    var line_starts = std.ArrayList(usize).init(allocator);
    defer line_starts.deinit();
    line_starts.append(0) catch return null;

    for (data, 0..) |byte, i| {
        if (byte == '\n' and i + 1 < data.len) {
            line_starts.append(i + 1) catch return null;
        }
    }

    const matches = regex.findAll(data, allocator) catch return null;
    defer allocator.free(matches);

    if (matches.len == 0) return null;

    var match_lines = std.AutoHashMap(u32, std.ArrayList(MatchPosition)).init(allocator);
    defer {
        var it = match_lines.valueIterator();
        while (it.next()) |list| list.deinit();
        match_lines.deinit();
    }

    for (matches) |m| {
        const line_num = findLineNumberStatic(line_starts.items, m.start);
        const line_start = line_starts.items[line_num];
        const match_in_line = MatchPosition{
            .start = m.start - line_start,
            .end = m.end - line_start,
        };

        const entry = match_lines.getOrPut(line_num) catch return null;
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(MatchPosition).init(allocator);
        }
        entry.value_ptr.append(match_in_line) catch return null;
    }

    var lines_to_include = std.AutoHashMap(u32, void).init(allocator);
    defer lines_to_include.deinit();

    var match_it = match_lines.keyIterator();
    while (match_it.next()) |line_num_ptr| {
        const line_num = line_num_ptr.*;
        const start_line: u32 = if (line_num >= context_lines) line_num - context_lines else 0;
        const total_lines: u32 = @intCast(line_starts.items.len);
        const end_line = @min(line_num + context_lines, total_lines - 1);

        var l = start_line;
        while (l <= end_line) : (l += 1) {
            lines_to_include.put(l, {}) catch return null;
        }
    }

    var sorted_lines = std.ArrayList(u32).init(allocator);
    defer sorted_lines.deinit();
    var lines_it = lines_to_include.keyIterator();
    while (lines_it.next()) |k| {
        sorted_lines.append(k.*) catch return null;
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

        var match_positions: []MatchPosition = &[_]MatchPosition{};
        if (match_lines.get(line_num)) |match_list| {
            match_positions = allocator.alloc(MatchPosition, match_list.items.len) catch {
                allocator.free(line_content);
                return null;
            };
            @memcpy(match_positions, match_list.items);
        }

        snippets[snippet_count] = .{
            .line_number = line_num + 1,
            .byte_offset = line_start,
            .line_content = line_content,
            .matches = match_positions,
        };
        snippet_count += 1;
    }

    return snippets[0..snippet_count];
}

fn findLineNumberStatic(line_starts: []const usize, byte_offset: usize) u32 {
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

test "context snippets with line numbers and positions" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_snippet_test.idx";
    const test_dir = "/tmp/hound_snippet_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const content =
        \\line one
        \\line two
        \\hello world here
        \\line four
        \\line five
    ;

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/multi.txt", .{});
        defer file.close();
        try file.writeAll(content);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/multi.txt", content);
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    const results = try searcher.search("hello", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    const r = results[0];

    try std.testing.expect(r.snippets.len > 0);

    var found_match_line = false;
    for (r.snippets) |snippet| {
        if (snippet.line_number == 3) {
            found_match_line = true;
            try std.testing.expect(std.mem.indexOf(u8, snippet.line_content, "hello world") != null);
            try std.testing.expect(snippet.matches.len > 0);
            try std.testing.expectEqual(@as(usize, 0), snippet.matches[0].start);
            try std.testing.expectEqual(@as(usize, 5), snippet.matches[0].end);
        }
    }
    try std.testing.expect(found_match_line);
}

test "context snippets include surrounding lines" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_ctx_test.idx";
    const test_dir = "/tmp/hound_ctx_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const content =
        \\aaa
        \\bbb
        \\ccc
        \\target here
        \\ddd
        \\eee
        \\fff
    ;

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/context.txt", .{});
        defer file.close();
        try file.writeAll(content);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/context.txt", content);
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .context_lines = 2 });
    defer searcher.deinit();

    const results = try searcher.search("target", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);

    var line_numbers = std.AutoHashMap(u32, void).init(allocator);
    defer line_numbers.deinit();
    for (results[0].snippets) |snippet| {
        try line_numbers.put(snippet.line_number, {});
    }

    try std.testing.expect(line_numbers.contains(2));
    try std.testing.expect(line_numbers.contains(3));
    try std.testing.expect(line_numbers.contains(4));
    try std.testing.expect(line_numbers.contains(5));
    try std.testing.expect(line_numbers.contains(6));
}

test "multiple matches on same line" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_multi_match_test.idx";
    const test_dir = "/tmp/hound_multi_match_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const content = "foo bar foo baz foo";

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/multi_match.txt", .{});
        defer file.close();
        try file.writeAll(content);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/multi_match.txt", content);
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    const results = try searcher.search("foo", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);

    const snippet = results[0].snippets[0];
    try std.testing.expectEqual(@as(usize, 3), snippet.matches.len);
    try std.testing.expectEqual(@as(usize, 0), snippet.matches[0].start);
    try std.testing.expectEqual(@as(usize, 8), snippet.matches[1].start);
    try std.testing.expectEqual(@as(usize, 16), snippet.matches[2].start);
}

test "regex search basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_regex_test.idx";
    const test_dir = "/tmp/hound_regex_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const files = .{
        .{ "hello.txt", "hello world" },
        .{ "world.txt", "world peace" },
        .{ "numbers.txt", "foo123bar" },
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

    // Simple literal regex
    const results = try searcher.searchRegex("hello", 10);
    defer searcher.freeResults(results);

    try std.testing.expect(results.len >= 1);
}

test "regex search with pattern" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_regex_pattern_test.idx";
    const test_dir = "/tmp/hound_regex_pattern_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const content = "foo123bar baz456qux";

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/nums.txt", .{});
        defer file.close();
        try file.writeAll(content);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/nums.txt", content);
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    // Regex with numbers
    const results = try searcher.searchRegex("foo[0-9]+bar", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].snippets.len > 0);
}

test "regex search alternation" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_regex_alt_test.idx";
    const test_dir = "/tmp/hound_regex_alt_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const files = .{
        .{ "abc.txt", "abcdef" },
        .{ "ghi.txt", "abcghi" },
        .{ "xyz.txt", "xyzabc" },
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

    // Search for abc followed by def or ghi
    const results = try searcher.searchRegex("abc(def|ghi)", 10);
    defer searcher.freeResults(results);

    // Should match abc.txt and ghi.txt but not xyz.txt (abc at end)
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "regex search with quantifiers" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_regex_quant_test.idx";
    const test_dir = "/tmp/hound_regex_quant_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const content = "hellooooo world";

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/oooo.txt", .{});
        defer file.close();
        try file.writeAll(content);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/oooo.txt", content);
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.init(allocator, &reader_inst);
    defer searcher.deinit();

    // + quantifier
    const results = try searcher.searchRegex("hello+", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "parallel search with many files" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_parallel_test.idx";
    const test_dir = "/tmp/hound_parallel_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const num_files = 20;
    var file_contents: [num_files][]const u8 = undefined;
    for (0..num_files) |i| {
        const content = if (i % 3 == 0) "searchterm in this file" else "no match here";
        file_contents[i] = content;
    }

    for (0..num_files) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}/file{d}.txt", .{ test_dir, i }) catch unreachable;
        const file = try std.fs.cwd().createFile(name, .{});
        defer file.close();
        try file.writeAll(file_contents[i]);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        for (0..num_files) |i| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}/file{d}.txt", .{ test_dir, i }) catch unreachable;
            try writer.addFile(name, file_contents[i]);
        }
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .thread_count = 4 });
    defer searcher.deinit();

    const results = try searcher.search("searchterm", 50);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 7), results.len);

    for (results) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r.snippets[0].line_content, "searchterm") != null);
    }
}

test "parallel regex search with many files" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_parallel_regex_test.idx";
    const test_dir = "/tmp/hound_parallel_regex_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    const num_files = 16;
    var file_contents: [num_files][]const u8 = undefined;
    for (0..num_files) |i| {
        const content = if (i % 4 == 0) "test123value here" else "nothing";
        file_contents[i] = content;
    }

    for (0..num_files) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}/rfile{d}.txt", .{ test_dir, i }) catch unreachable;
        const file = try std.fs.cwd().createFile(name, .{});
        defer file.close();
        try file.writeAll(file_contents[i]);
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();

        for (0..num_files) |i| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}/rfile{d}.txt", .{ test_dir, i }) catch unreachable;
            try writer.addFile(name, file_contents[i]);
        }
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .thread_count = 4 });
    defer searcher.deinit();

    const results = try searcher.searchRegex("test[0-9]+value", 50);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 4), results.len);
}

test "single threaded fallback for small candidate sets" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_single_thread_test.idx";
    const test_dir = "/tmp/hound_single_thread_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/small.txt", .{});
        defer file.close();
        try file.writeAll("unique content here");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/small.txt", "unique content here");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .thread_count = 8 });
    defer searcher.deinit();

    const results = try searcher.search("unique", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "bm25 ranking basic" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_bm25_basic_test.idx";
    const test_dir = "/tmp/hound_bm25_basic_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/doc1.txt", .{});
        defer file.close();
        try file.writeAll("hello world hello hello");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/doc2.txt", .{});
        defer file.close();
        try file.writeAll("hello there friend");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/doc3.txt", .{});
        defer file.close();
        try file.writeAll("goodbye world");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/doc1.txt", "hello world hello hello");
        try writer.addFile(test_dir ++ "/doc2.txt", "hello there friend");
        try writer.addFile(test_dir ++ "/doc3.txt", "goodbye world");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .ranking_mode = .bm25 });
    defer searcher.deinit();

    const results = try searcher.search("hello", 10);
    defer searcher.freeResults(results);

    try std.testing.expect(results.len >= 2);
}

test "bm25 vs trigram_count mode switch" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_bm25_mode_test.idx";
    const test_dir = "/tmp/hound_bm25_mode_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/a.txt", .{});
        defer file.close();
        try file.writeAll("searchterm here");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/b.txt", .{});
        defer file.close();
        try file.writeAll("searchterm there too");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/a.txt", "searchterm here");
        try writer.addFile(test_dir ++ "/b.txt", "searchterm there too");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    {
        var searcher_bm25 = try Searcher.initWithOptions(allocator, &reader_inst, .{ .ranking_mode = .bm25 });
        defer searcher_bm25.deinit();

        const results = try searcher_bm25.search("searchterm", 10);
        defer searcher_bm25.freeResults(results);

        try std.testing.expectEqual(@as(usize, 2), results.len);
    }

    {
        var searcher_count = try Searcher.initWithOptions(allocator, &reader_inst, .{ .ranking_mode = .trigram_count });
        defer searcher_count.deinit();

        const results = try searcher_count.search("searchterm", 10);
        defer searcher_count.freeResults(results);

        try std.testing.expectEqual(@as(usize, 2), results.len);
    }
}

test "bm25 idf favors rare terms" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_bm25_idf_test.idx";
    const test_dir = "/tmp/hound_bm25_idf_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/common1.txt", .{});
        defer file.close();
        try file.writeAll("common word here");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/common2.txt", .{});
        defer file.close();
        try file.writeAll("common word there");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/common3.txt", .{});
        defer file.close();
        try file.writeAll("common word everywhere");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/rare.txt", .{});
        defer file.close();
        try file.writeAll("common uniqueterm special");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/common1.txt", "common word here");
        try writer.addFile(test_dir ++ "/common2.txt", "common word there");
        try writer.addFile(test_dir ++ "/common3.txt", "common word everywhere");
        try writer.addFile(test_dir ++ "/rare.txt", "common uniqueterm special");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .ranking_mode = .bm25 });
    defer searcher.deinit();

    const results = try searcher.search("uniqueterm", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(std.mem.indexOf(u8, results[0].name, "rare.txt") != null);
}

test "bm25 multi-term query ranking" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_bm25_multi_test.idx";
    const test_dir = "/tmp/hound_bm25_multi_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/both.txt", .{});
        defer file.close();
        try file.writeAll("alpha beta gamma");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/alpha_only.txt", .{});
        defer file.close();
        try file.writeAll("alpha delta epsilon");
    }
    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/beta_only.txt", .{});
        defer file.close();
        try file.writeAll("beta zeta theta");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/both.txt", "alpha beta gamma");
        try writer.addFile(test_dir ++ "/alpha_only.txt", "alpha delta epsilon");
        try writer.addFile(test_dir ++ "/beta_only.txt", "beta zeta theta");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .ranking_mode = .bm25 });
    defer searcher.deinit();

    const results = try searcher.search("alpha beta", 10);
    defer searcher.freeResults(results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, results[0].name, "both.txt") != null);
}

test "bm25 custom k1 and b parameters" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_bm25_params_test.idx";
    const test_dir = "/tmp/hound_bm25_params_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/doc.txt", .{});
        defer file.close();
        try file.writeAll("parameter test content");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/doc.txt", "parameter test content");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{
        .ranking_mode = .bm25,
        .bm25_k1 = 2.0,
        .bm25_b = 0.5,
    });
    defer searcher.deinit();

    const results = try searcher.search("parameter", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "bm25 empty index" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_bm25_empty_test.idx";
    const index = @import("index.zig");

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .ranking_mode = .bm25 });
    defer searcher.deinit();

    const results = try searcher.search("anything", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "bm25 no matching trigrams" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/hound_bm25_nomatch_test.idx";
    const test_dir = "/tmp/hound_bm25_nomatch_files";
    const index = @import("index.zig");

    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makePath(test_dir);

    {
        const file = try std.fs.cwd().createFile(test_dir ++ "/doc.txt", .{});
        defer file.close();
        try file.writeAll("hello world");
    }

    {
        var writer = try index.IndexWriter.init(allocator, test_path);
        defer writer.deinit();
        try writer.addFile(test_dir ++ "/doc.txt", "hello world");
        try writer.finish();
    }

    var reader_inst = try IndexReader.open(allocator, test_path);
    defer reader_inst.close();

    var searcher = try Searcher.initWithOptions(allocator, &reader_inst, .{ .ranking_mode = .bm25 });
    defer searcher.deinit();

    const results = try searcher.search("zzzzz", 10);
    defer searcher.freeResults(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}
