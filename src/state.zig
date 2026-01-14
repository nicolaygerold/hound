const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FileState = struct {
    path: []const u8,
    mtime: i128,
    size: u64,
    file_id: ?u32,
};

pub const ChangeType = enum {
    added,
    modified,
    deleted,
};

pub const FileChange = struct {
    path: []const u8,
    change_type: ChangeType,
    old_file_id: ?u32,
};

pub const StateTracker = struct {
    allocator: Allocator,
    states: std.StringHashMap(FileState),
    pending_changes: std.ArrayList(FileChange),

    pub fn init(allocator: Allocator) StateTracker {
        return .{
            .allocator = allocator,
            .states = std.StringHashMap(FileState).init(allocator),
            .pending_changes = std.ArrayList(FileChange).init(allocator),
        };
    }

    pub fn deinit(self: *StateTracker) void {
        var it = self.states.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.states.deinit();

        for (self.pending_changes.items) |change| {
            self.allocator.free(change.path);
        }
        self.pending_changes.deinit();
    }

    pub fn scanDirectory(self: *StateTracker, dir_path: []const u8) !void {
        self.pending_changes.clearRetainingCapacity();

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir) return;
            return err;
        };
        defer dir.close();

        try self.scanDirRecursive(dir, dir_path, &seen);

        var it = self.states.iterator();
        while (it.next()) |entry| {
            if (!seen.contains(entry.key_ptr.*)) {
                const path_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                try self.pending_changes.append(.{
                    .path = path_copy,
                    .change_type = .deleted,
                    .old_file_id = entry.value_ptr.file_id,
                });
            }
        }
    }

    fn scanDirRecursive(
        self: *StateTracker,
        dir: std.fs.Dir,
        base_path: []const u8,
        seen: *std.StringHashMap(void),
    ) !void {
        var walker = dir.iterate();

        while (try walker.next()) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &.{ base_path, entry.name });
            defer self.allocator.free(full_path);

            if (entry.kind == .directory) {
                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer subdir.close();
                try self.scanDirRecursive(subdir, full_path, seen);
            } else if (entry.kind == .file) {
                try self.checkFile(dir, entry.name, full_path, seen);
            }
        }
    }

    fn checkFile(
        self: *StateTracker,
        dir: std.fs.Dir,
        name: []const u8,
        full_path: []const u8,
        seen: *std.StringHashMap(void),
    ) !void {
        const stat = dir.statFile(name) catch return;

        const path_key = try self.allocator.dupe(u8, full_path);
        errdefer self.allocator.free(path_key);

        try seen.put(path_key, {});

        if (self.states.get(full_path)) |existing| {
            if (existing.mtime != stat.mtime or existing.size != stat.size) {
                const change_path = try self.allocator.dupe(u8, full_path);
                try self.pending_changes.append(.{
                    .path = change_path,
                    .change_type = .modified,
                    .old_file_id = existing.file_id,
                });

                if (self.states.fetchRemove(full_path)) |old_entry| {
                    self.allocator.free(old_entry.key);
                }

                try self.states.put(path_key, .{
                    .path = path_key,
                    .mtime = stat.mtime,
                    .size = stat.size,
                    .file_id = null,
                });
            } else {
                self.allocator.free(path_key);
            }
        } else {
            const change_path = try self.allocator.dupe(u8, full_path);
            try self.pending_changes.append(.{
                .path = change_path,
                .change_type = .added,
                .old_file_id = null,
            });

            try self.states.put(path_key, .{
                .path = path_key,
                .mtime = stat.mtime,
                .size = stat.size,
                .file_id = null,
            });
        }
    }

    pub fn markIndexed(self: *StateTracker, path: []const u8, file_id: u32) void {
        if (self.states.getPtr(path)) |state| {
            state.file_id = file_id;
        }
    }

    pub fn removeFile(self: *StateTracker, path: []const u8) void {
        if (self.states.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    pub fn getChanges(self: *StateTracker) []const FileChange {
        return self.pending_changes.items;
    }

    pub fn clearChanges(self: *StateTracker) void {
        for (self.pending_changes.items) |change| {
            self.allocator.free(change.path);
        }
        self.pending_changes.clearRetainingCapacity();
    }

    pub fn fileCount(self: *const StateTracker) usize {
        return self.states.count();
    }
};

test "state tracker basic" {
    const allocator = std.testing.allocator;
    var tracker = StateTracker.init(allocator);
    defer tracker.deinit();

    const tmp_dir = "/tmp/hound_state_test";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makeDir(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    {
        const file = try std.fs.cwd().createFile(tmp_dir ++ "/test1.txt", .{});
        defer file.close();
        try file.writeAll("hello");
    }
    {
        const file = try std.fs.cwd().createFile(tmp_dir ++ "/test2.txt", .{});
        defer file.close();
        try file.writeAll("world");
    }

    try tracker.scanDirectory(tmp_dir);
    const changes = tracker.getChanges();

    try std.testing.expectEqual(@as(usize, 2), changes.len);
    for (changes) |c| {
        try std.testing.expectEqual(ChangeType.added, c.change_type);
    }
}

test "state tracker detects modifications" {
    const allocator = std.testing.allocator;
    var tracker = StateTracker.init(allocator);
    defer tracker.deinit();

    const tmp_dir = "/tmp/hound_state_mod_test";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makeDir(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const file_path = tmp_dir ++ "/test.txt";
    {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("hello");
    }

    try tracker.scanDirectory(tmp_dir);
    tracker.clearChanges();

    std.time.sleep(10 * std.time.ns_per_ms);

    {
        const file = try std.fs.cwd().openFile(file_path, .{ .mode = .write_only });
        defer file.close();
        try file.writeAll("hello world modified");
    }

    try tracker.scanDirectory(tmp_dir);
    const changes = tracker.getChanges();

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(ChangeType.modified, changes[0].change_type);
}

test "state tracker detects deletions" {
    const allocator = std.testing.allocator;
    var tracker = StateTracker.init(allocator);
    defer tracker.deinit();

    const tmp_dir = "/tmp/hound_state_del_test";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makeDir(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const file_path = tmp_dir ++ "/test.txt";
    {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("hello");
    }

    try tracker.scanDirectory(tmp_dir);
    tracker.clearChanges();

    try std.fs.cwd().deleteFile(file_path);

    try tracker.scanDirectory(tmp_dir);
    const changes = tracker.getChanges();

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(ChangeType.deleted, changes[0].change_type);
}
