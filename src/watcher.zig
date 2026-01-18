const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const kqueue = @import("backends/kqueue.zig");
pub const inotify = @import("backends/inotify.zig");

pub const WatchDescriptor = enum(i32) { _ };

pub const EventMask = struct {
    modify: bool = false,
    delete: bool = false,
    create: bool = false,
    rename: bool = false,
    attrib: bool = false,

    pub const ALL: EventMask = .{
        .modify = true,
        .delete = true,
        .create = true,
        .rename = true,
        .attrib = true,
    };
};

pub const Event = struct {
    wd: WatchDescriptor,
    mask: EventMask,
    path: []const u8,
    name: ?[]const u8,
};

const BackendType = switch (builtin.os.tag) {
    .macos, .freebsd, .openbsd, .netbsd, .dragonfly => kqueue.KqueueBackend,
    .linux => inotify.InotifyBackend,
    else => @compileError("Unsupported OS for file watching"),
};

pub const Watcher = struct {
    allocator: Allocator,
    backend: BackendType,
    events: std.ArrayList(Event),

    pub fn init(allocator: Allocator) !Watcher {
        return .{
            .allocator = allocator,
            .backend = try BackendType.init(allocator),
            .events = std.ArrayList(Event){},
        };
    }

    pub fn deinit(self: *Watcher) void {
        self.backend.deinit();
        self.events.deinit(self.allocator);
    }

    pub fn addWatch(self: *Watcher, path: []const u8, mask: EventMask) !WatchDescriptor {
        const backend_mask = switch (builtin.os.tag) {
            .macos, .freebsd, .openbsd, .netbsd, .dragonfly => blk: {
                var m = kqueue.EventMask{};
                if (mask.modify) m.write = true;
                if (mask.delete) m.delete = true;
                if (mask.rename) m.rename = true;
                if (mask.attrib) m.attrib = true;
                break :blk m;
            },
            .linux => blk: {
                var m = inotify.EventMask{};
                if (mask.modify) m.modify = true;
                if (mask.delete) {
                    m.delete = true;
                    m.delete_self = true;
                }
                if (mask.create) m.create = true;
                if (mask.rename) {
                    m.moved_from = true;
                    m.moved_to = true;
                    m.move_self = true;
                }
                if (mask.attrib) m.attrib = true;
                break :blk m;
            },
            else => unreachable,
        };

        const backend_wd = try self.backend.addWatch(path, backend_mask);
        return @enumFromInt(@intFromEnum(backend_wd));
    }

    pub fn removeWatch(self: *Watcher, wd: WatchDescriptor) void {
        switch (builtin.os.tag) {
            .macos, .freebsd, .openbsd, .netbsd, .dragonfly => {
                self.backend.removeWatch(@enumFromInt(@intFromEnum(wd)));
            },
            .linux => {
                self.backend.removeWatch(@enumFromInt(@intFromEnum(wd)));
            },
            else => unreachable,
        }
    }

    pub fn poll(self: *Watcher, timeout_ms: ?u32) ![]Event {
        self.events.clearRetainingCapacity();

        const backend_events = try self.backend.poll(timeout_ms);

        for (backend_events) |ev| {
            const mask = switch (builtin.os.tag) {
                .macos, .freebsd, .openbsd, .netbsd, .dragonfly => EventMask{
                    .modify = ev.mask.write or ev.mask.extend,
                    .delete = ev.mask.delete or ev.mask.revoke,
                    .rename = ev.mask.rename,
                    .attrib = ev.mask.attrib,
                    .create = false,
                },
                .linux => EventMask{
                    .modify = ev.mask.modify or ev.mask.close_write,
                    .delete = ev.mask.delete or ev.mask.delete_self,
                    .create = ev.mask.create,
                    .rename = ev.mask.moved_from or ev.mask.moved_to or ev.mask.move_self,
                    .attrib = ev.mask.attrib,
                },
                else => unreachable,
            };

            const name = switch (builtin.os.tag) {
                .linux => ev.name,
                else => null,
            };

            try self.events.append(self.allocator, .{
                .wd = @enumFromInt(@intFromEnum(ev.wd)),
                .mask = mask,
                .path = ev.path,
                .name = name,
            });
        }

        return self.events.items;
    }

    pub fn fd(self: *const Watcher) posix.fd_t {
        return self.backend.fd();
    }
};

test "watcher unified api" {
    const allocator = std.testing.allocator;
    var watcher = try Watcher.init(allocator);
    defer watcher.deinit();

    const tmp_path = "/tmp/hound_watcher_basic_test.txt";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const wd = try watcher.addWatch(tmp_path, EventMask.ALL);

    {
        const file = try std.fs.cwd().openFile(tmp_path, .{ .mode = .write_only });
        defer file.close();
        try file.writeAll("hello");
    }

    const events = try watcher.poll(100);
    try std.testing.expect(events.len > 0);
    try std.testing.expect(events[0].mask.modify);

    watcher.removeWatch(wd);
}
