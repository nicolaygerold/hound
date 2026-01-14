const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const WatchDescriptor = enum(i32) { _ };

pub const EventMask = packed struct(u32) {
    access: bool = false,
    modify: bool = false,
    attrib: bool = false,
    close_write: bool = false,
    close_nowrite: bool = false,
    open: bool = false,
    moved_from: bool = false,
    moved_to: bool = false,
    create: bool = false,
    delete: bool = false,
    delete_self: bool = false,
    move_self: bool = false,
    _padding: u20 = 0,

    pub const ALL: EventMask = .{
        .modify = true,
        .attrib = true,
        .close_write = true,
        .moved_from = true,
        .moved_to = true,
        .create = true,
        .delete = true,
        .delete_self = true,
        .move_self = true,
    };

    fn toMask(self: EventMask) u32 {
        return @bitCast(self);
    }

    fn fromMask(mask: u32) EventMask {
        return @bitCast(mask & 0xFFF);
    }
};

pub const Event = struct {
    wd: WatchDescriptor,
    mask: EventMask,
    path: []const u8,
    name: ?[]const u8,
};

const WatchEntry = struct {
    wd: i32,
    path: []const u8,
};

pub const InotifyBackend = struct {
    allocator: Allocator,
    inotify_fd: posix.fd_t,
    watches: std.AutoArrayHashMap(i32, WatchEntry),
    event_buf: [4096]u8,
    pending_events: std.ArrayList(Event),
    name_buf: std.ArrayList(u8),

    pub fn init(allocator: Allocator) !InotifyBackend {
        const inotify_fd = try posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        errdefer posix.close(inotify_fd);

        return .{
            .allocator = allocator,
            .inotify_fd = inotify_fd,
            .watches = std.AutoArrayHashMap(i32, WatchEntry).init(allocator),
            .event_buf = undefined,
            .pending_events = std.ArrayList(Event).init(allocator),
            .name_buf = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *InotifyBackend) void {
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
        }
        self.watches.deinit();
        self.pending_events.deinit();
        self.name_buf.deinit();
        posix.close(self.inotify_fd);
    }

    pub fn addWatch(self: *InotifyBackend, path: []const u8, mask: EventMask) !WatchDescriptor {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const wd = linux.inotify_add_watch(self.inotify_fd, path_z, mask.toMask());
        if (@as(isize, @bitCast(wd)) < 0) {
            return error.WatchFailed;
        }

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        try self.watches.put(@intCast(wd), .{
            .wd = @intCast(wd),
            .path = path_copy,
        });

        return @enumFromInt(@as(i32, @intCast(wd)));
    }

    pub fn removeWatch(self: *InotifyBackend, wd: WatchDescriptor) void {
        const wd_int = @intFromEnum(wd);
        if (self.watches.fetchSwapRemove(wd_int)) |entry| {
            _ = linux.inotify_rm_watch(self.inotify_fd, @intCast(wd_int));
            self.allocator.free(entry.value.path);
        }
    }

    pub fn poll(self: *InotifyBackend, timeout_ms: ?u32) ![]Event {
        self.pending_events.clearRetainingCapacity();

        var fds = [1]posix.pollfd{.{
            .fd = self.inotify_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const timeout: i32 = if (timeout_ms) |ms| @intCast(ms) else -1;
        const poll_result = try posix.poll(&fds, timeout);

        if (poll_result == 0) return self.pending_events.items;
        if ((fds[0].revents & posix.POLL.IN) == 0) return self.pending_events.items;

        const n_bytes = posix.read(self.inotify_fd, &self.event_buf) catch |err| {
            if (err == error.WouldBlock) return self.pending_events.items;
            return err;
        };

        var offset: usize = 0;
        const event_size = @sizeOf(linux.inotify_event);

        while (offset + event_size <= n_bytes) {
            const event: *align(1) const linux.inotify_event = @ptrCast(&self.event_buf[offset]);

            const name: ?[]const u8 = if (event.len == 0) null else blk: {
                const name_start = offset + event_size;
                const name_slice = self.event_buf[name_start .. name_start + event.len];
                const null_idx = std.mem.indexOfScalar(u8, name_slice, 0) orelse event.len;
                break :blk name_slice[0..null_idx];
            };

            if (self.watches.get(event.wd)) |entry| {
                try self.pending_events.append(.{
                    .wd = @enumFromInt(event.wd),
                    .mask = EventMask.fromMask(event.mask),
                    .path = entry.path,
                    .name = name,
                });
            }

            offset += event_size + event.len;
        }

        return self.pending_events.items;
    }

    pub fn fd(self: *const InotifyBackend) posix.fd_t {
        return self.inotify_fd;
    }
};

test "inotify backend basic" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try InotifyBackend.init(allocator);
    defer backend.deinit();

    const tmp_dir = "/tmp/hound_inotify_test";
    std.fs.cwd().makeDir(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const wd = try backend.addWatch(tmp_dir, EventMask.ALL);
    _ = wd;

    const test_file = tmp_dir ++ "/test.txt";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        file.close();
    }

    const events = try backend.poll(100);
    try std.testing.expect(events.len > 0);
}
