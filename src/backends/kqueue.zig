const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const WatchDescriptor = enum(i32) { _ };

pub const EventMask = packed struct(u32) {
    delete: bool = false,
    write: bool = false,
    extend: bool = false,
    attrib: bool = false,
    link: bool = false,
    rename: bool = false,
    revoke: bool = false,
    _padding: u25 = 0,

    pub const ALL: EventMask = .{
        .delete = true,
        .write = true,
        .extend = true,
        .attrib = true,
        .rename = true,
    };

    fn toFflags(self: EventMask) u32 {
        var flags: u32 = 0;
        if (self.delete) flags |= NOTE.DELETE;
        if (self.write) flags |= NOTE.WRITE;
        if (self.extend) flags |= NOTE.EXTEND;
        if (self.attrib) flags |= NOTE.ATTRIB;
        if (self.link) flags |= NOTE.LINK;
        if (self.rename) flags |= NOTE.RENAME;
        if (self.revoke) flags |= NOTE.REVOKE;
        return flags;
    }

    fn fromFflags(fflags: u32) EventMask {
        return .{
            .delete = (fflags & NOTE.DELETE) != 0,
            .write = (fflags & NOTE.WRITE) != 0,
            .extend = (fflags & NOTE.EXTEND) != 0,
            .attrib = (fflags & NOTE.ATTRIB) != 0,
            .link = (fflags & NOTE.LINK) != 0,
            .rename = (fflags & NOTE.RENAME) != 0,
            .revoke = (fflags & NOTE.REVOKE) != 0,
        };
    }
};

const NOTE = struct {
    const DELETE: u32 = 0x00000001;
    const WRITE: u32 = 0x00000002;
    const EXTEND: u32 = 0x00000004;
    const ATTRIB: u32 = 0x00000008;
    const LINK: u32 = 0x00000010;
    const RENAME: u32 = 0x00000020;
    const REVOKE: u32 = 0x00000040;
};

const EV = struct {
    const ADD: u16 = 0x0001;
    const DELETE: u16 = 0x0002;
    const ENABLE: u16 = 0x0004;
    const CLEAR: u16 = 0x0020;
};

const EVFILT = struct {
    const VNODE: i16 = -4;
};

pub const Event = struct {
    wd: WatchDescriptor,
    mask: EventMask,
    path: []const u8,
};

const WatchEntry = struct {
    fd: posix.fd_t,
    path: []const u8,
    mask: EventMask,
};

pub const KqueueBackend = struct {
    allocator: Allocator,
    kq: posix.fd_t,
    watches: std.AutoArrayHashMap(i32, WatchEntry),
    event_buf: [64]posix.Kevent,
    pending_events: std.ArrayList(Event),

    pub fn init(allocator: Allocator) !KqueueBackend {
        const kq = try posix.kqueue();
        errdefer posix.close(kq);

        return .{
            .allocator = allocator,
            .kq = kq,
            .watches = std.AutoArrayHashMap(i32, WatchEntry).init(allocator),
            .event_buf = undefined,
            .pending_events = std.ArrayList(Event).init(allocator),
        };
    }

    pub fn deinit(self: *KqueueBackend) void {
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            posix.close(entry.value_ptr.fd);
            self.allocator.free(entry.value_ptr.path);
        }
        self.watches.deinit();
        self.pending_events.deinit();
        posix.close(self.kq);
    }

    pub fn addWatch(self: *KqueueBackend, path: []const u8, mask: EventMask) !WatchDescriptor {
        const file_fd = posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
            return switch (err) {
                error.FileNotFound => error.PathNotFound,
                else => err,
            };
        };
        errdefer posix.close(file_fd);

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        var changelist = [1]posix.Kevent{.{
            .ident = @intCast(file_fd),
            .filter = EVFILT.VNODE,
            .flags = EV.ADD | EV.ENABLE | EV.CLEAR,
            .fflags = mask.toFflags(),
            .data = 0,
            .udata = @intCast(file_fd),
        }};

        _ = try posix.kevent(self.kq, &changelist, &[_]posix.Kevent{}, null);

        try self.watches.put(file_fd, .{
            .fd = file_fd,
            .path = path_copy,
            .mask = mask,
        });

        return @enumFromInt(file_fd);
    }

    pub fn removeWatch(self: *KqueueBackend, wd: WatchDescriptor) void {
        const wd_fd = @intFromEnum(wd);
        if (self.watches.fetchSwapRemove(wd_fd)) |entry| {
            var changelist = [1]posix.Kevent{.{
                .ident = @intCast(wd_fd),
                .filter = EVFILT.VNODE,
                .flags = EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = posix.kevent(self.kq, &changelist, &[_]posix.Kevent{}, null) catch {};
            posix.close(entry.value.fd);
            self.allocator.free(entry.value.path);
        }
    }

    pub fn poll(self: *KqueueBackend, timeout_ms: ?u32) ![]Event {
        self.pending_events.clearRetainingCapacity();

        const timeout: ?posix.timespec = if (timeout_ms) |ms| .{
            .tv_sec = @intCast(ms / 1000),
            .tv_nsec = @intCast((ms % 1000) * 1_000_000),
        } else null;

        const n_events = try posix.kevent(
            self.kq,
            &[_]posix.Kevent{},
            &self.event_buf,
            if (timeout) |*t| t else null,
        );

        for (self.event_buf[0..n_events]) |ev| {
            const ev_fd: i32 = @intCast(ev.ident);
            if (self.watches.get(ev_fd)) |entry| {
                try self.pending_events.append(.{
                    .wd = @enumFromInt(ev_fd),
                    .mask = EventMask.fromFflags(ev.fflags),
                    .path = entry.path,
                });
            }
        }

        return self.pending_events.items;
    }

    pub fn fd(self: *const KqueueBackend) posix.fd_t {
        return self.kq;
    }
};

test "kqueue backend basic" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend = try KqueueBackend.init(allocator);
    defer backend.deinit();

    const tmp_path = "/tmp/hound_kqueue_test.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const wd = try backend.addWatch(tmp_path, EventMask.ALL);
    _ = wd;

    {
        const file = try std.fs.cwd().openFile(tmp_path, .{ .mode = .write_only });
        defer file.close();
        try file.writeAll("test");
    }

    const events = try backend.poll(100);
    try std.testing.expect(events.len > 0);
    try std.testing.expect(events[0].mask.write or events[0].mask.extend);
}
