const std = @import("std");
const Allocator = std.mem.Allocator;
const index_mod = @import("index.zig");
const state_mod = @import("state.zig");
const watcher_mod = @import("watcher.zig");

const IndexWriter = index_mod.IndexWriter;
const StateTracker = state_mod.StateTracker;
const FileChange = state_mod.FileChange;
const ChangeType = state_mod.ChangeType;
const Watcher = watcher_mod.Watcher;
const EventMask = watcher_mod.EventMask;

pub const IncrementalIndexer = struct {
    allocator: Allocator,
    state: StateTracker,
    watcher: ?Watcher,
    index_path: []const u8,
    watch_paths: std.ArrayList([]const u8),
    batch_window_ms: u32,
    pending_paths: std.StringHashMap(void),

    pub const Config = struct {
        index_path: []const u8,
        batch_window_ms: u32 = 1000,
        enable_watcher: bool = true,
    };

    pub fn init(allocator: Allocator, config: Config) !IncrementalIndexer {
        const index_path = try allocator.dupe(u8, config.index_path);
        errdefer allocator.free(index_path);

        var watcher: ?Watcher = null;
        if (config.enable_watcher) {
            watcher = try Watcher.init(allocator);
        }
        errdefer if (watcher) |*w| w.deinit();

        return .{
            .allocator = allocator,
            .state = StateTracker.init(allocator),
            .watcher = watcher,
            .index_path = index_path,
            .watch_paths = std.ArrayList([]const u8){},
            .batch_window_ms = config.batch_window_ms,
            .pending_paths = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *IncrementalIndexer) void {
        self.state.deinit();
        if (self.watcher) |*w| w.deinit();

        for (self.watch_paths.items) |path| {
            self.allocator.free(path);
        }
        self.watch_paths.deinit(self.allocator);

        var it = self.pending_paths.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.pending_paths.deinit();

        self.allocator.free(self.index_path);
    }

    pub fn addDirectory(self: *IncrementalIndexer, dir_path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, dir_path);
        errdefer self.allocator.free(path_copy);

        try self.watch_paths.append(self.allocator, path_copy);

        if (self.watcher) |*w| {
            _ = w.addWatch(dir_path, EventMask.ALL) catch |err| {
                if (err != error.PathNotFound) return err;
            };
        }
    }

    pub fn scan(self: *IncrementalIndexer) ![]const FileChange {
        for (self.watch_paths.items) |path| {
            try self.state.scanDirectory(path);
        }
        return self.state.getChanges();
    }

    pub fn pollEvents(self: *IncrementalIndexer) !bool {
        if (self.watcher) |*w| {
            const events = try w.poll(0);
            for (events) |ev| {
                const full_path = if (ev.name) |name|
                    try std.fs.path.join(self.allocator, &.{ ev.path, name })
                else
                    try self.allocator.dupe(u8, ev.path);

                try self.pending_paths.put(full_path, {});
            }
            return events.len > 0;
        }
        return false;
    }

    pub fn hasPendingChanges(self: *const IncrementalIndexer) bool {
        return self.pending_paths.count() > 0;
    }

    pub fn rebuildIndex(self: *IncrementalIndexer) !void {
        var writer = try IndexWriter.init(self.allocator, self.index_path);
        defer writer.deinit();

        var file_id: u32 = 0;
        var it = self.state.states.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch continue;
            defer self.allocator.free(content);

            writer.addFile(path, content) catch continue;
            self.state.markIndexed(path, file_id);
            file_id += 1;
        }

        try writer.finish();

        self.state.clearChanges();
        var pending_it = self.pending_paths.keyIterator();
        while (pending_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.pending_paths.clearRetainingCapacity();
    }

    pub fn applyChanges(self: *IncrementalIndexer) !void {
        const changes = self.state.getChanges();
        if (changes.len == 0 and self.pending_paths.count() == 0) return;

        try self.rebuildIndex();
    }
};

pub const Daemon = struct {
    indexer: *IncrementalIndexer,
    running: bool,
    poll_interval_ms: u32,

    pub fn init(indexer: *IncrementalIndexer, poll_interval_ms: u32) Daemon {
        return .{
            .indexer = indexer,
            .running = false,
            .poll_interval_ms = poll_interval_ms,
        };
    }

    pub fn runOnce(self: *Daemon) !bool {
        _ = try self.indexer.pollEvents();

        if (self.indexer.hasPendingChanges()) {
            std.time.sleep(@as(u64, self.indexer.batch_window_ms) * std.time.ns_per_ms);

            while (try self.indexer.pollEvents()) {}

            try self.indexer.applyChanges();
            return true;
        }

        return false;
    }

    pub fn stop(self: *Daemon) void {
        self.running = false;
    }
};

test "incremental indexer basic" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/hound_incr_basic_test";
    const index_path = "/tmp/hound_incr_basic_test.idx";

    std.fs.cwd().deleteTree(tmp_dir) catch {};
    std.fs.cwd().deleteFile(index_path) catch {};

    try std.fs.cwd().makeDir(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};
    defer std.fs.cwd().deleteFile(index_path) catch {};

    {
        const file = try std.fs.cwd().createFile(tmp_dir ++ "/test1.txt", .{});
        defer file.close();
        try file.writeAll("hello world");
    }
    {
        const file = try std.fs.cwd().createFile(tmp_dir ++ "/test2.txt", .{});
        defer file.close();
        try file.writeAll("foo bar baz");
    }

    var indexer = try IncrementalIndexer.init(allocator, .{
        .index_path = index_path,
        .enable_watcher = false,
    });
    defer indexer.deinit();

    try indexer.addDirectory(tmp_dir);
    const changes = try indexer.scan();

    try std.testing.expectEqual(@as(usize, 2), changes.len);

    try indexer.rebuildIndex();

    const stat = try std.fs.cwd().statFile(index_path);
    try std.testing.expect(stat.size > 0);
}

test "incremental indexer detects changes" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/hound_incr_changes_test";
    const index_path = "/tmp/hound_incr_changes_test.idx";

    std.fs.cwd().deleteTree(tmp_dir) catch {};
    std.fs.cwd().deleteFile(index_path) catch {};

    std.fs.cwd().makePath(tmp_dir) catch return;
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};
    defer std.fs.cwd().deleteFile(index_path) catch {};

    {
        const file = std.fs.cwd().createFile(tmp_dir ++ "/test.txt", .{}) catch return;
        defer file.close();
        file.writeAll("initial content") catch return;
    }

    var indexer = IncrementalIndexer.init(allocator, .{
        .index_path = index_path,
        .enable_watcher = false,
    }) catch return;
    defer indexer.deinit();

    indexer.addDirectory(tmp_dir) catch return;
    _ = indexer.scan() catch return;
    indexer.rebuildIndex() catch return;

    std.Thread.sleep(100 * std.time.ns_per_ms);

    {
        const file = std.fs.cwd().openFile(tmp_dir ++ "/test.txt", .{ .mode = .write_only }) catch return;
        defer file.close();
        file.writeAll("modified content that is longer") catch return;
    }

    const changes = indexer.scan() catch return;
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(state_mod.ChangeType.modified, changes[0].change_type);
}
