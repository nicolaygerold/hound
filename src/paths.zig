const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const XdgPaths = struct {
    allocator: Allocator,
    cache_home: []const u8,
    data_home: []const u8,
    config_home: []const u8,

    pub fn init(allocator: Allocator) !XdgPaths {
        return .{
            .allocator = allocator,
            .cache_home = try getCacheHome(allocator),
            .data_home = try getDataHome(allocator),
            .config_home = try getConfigHome(allocator),
        };
    }

    pub fn deinit(self: *XdgPaths) void {
        self.allocator.free(self.cache_home);
        self.allocator.free(self.data_home);
        self.allocator.free(self.config_home);
    }

    pub fn getIndexPath(self: *const XdgPaths, project_name: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.cache_home, "hound", project_name, "index.hound" });
    }

    pub fn getStatePath(self: *const XdgPaths, project_name: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.data_home, "hound", project_name, "state.json" });
    }

    pub fn getConfigPath(self: *const XdgPaths) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.config_home, "hound", "config.json" });
    }
};

fn getCacheHome(allocator: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CACHE_HOME")) |xdg| {
        return allocator.dupe(u8, xdg);
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    return switch (builtin.os.tag) {
        .macos => std.fs.path.join(allocator, &.{ home, "Library", "Caches" }),
        else => std.fs.path.join(allocator, &.{ home, ".cache" }),
    };
}

fn getDataHome(allocator: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
        return allocator.dupe(u8, xdg);
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    return switch (builtin.os.tag) {
        .macos => std.fs.path.join(allocator, &.{ home, "Library", "Application Support" }),
        else => std.fs.path.join(allocator, &.{ home, ".local", "share" }),
    };
}

fn getConfigHome(allocator: Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return allocator.dupe(u8, xdg);
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    return switch (builtin.os.tag) {
        .macos => std.fs.path.join(allocator, &.{ home, "Library", "Application Support" }),
        else => std.fs.path.join(allocator, &.{ home, ".config" }),
    };
}

pub fn ensureDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    std.fs.cwd().makePath(dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

pub fn projectNameFromPath(allocator: Allocator, path: []const u8) ![]const u8 {
    const real = std.fs.cwd().realpathAlloc(allocator, path) catch path;
    defer if (real.ptr != path.ptr) allocator.free(real);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(real);
    const hash = hasher.final();

    const basename = std.fs.path.basename(real);
    return std.fmt.allocPrint(allocator, "{s}-{x:0>8}", .{ basename, @as(u32, @truncate(hash)) });
}

test "xdg paths" {
    const allocator = std.testing.allocator;

    var paths = try XdgPaths.init(allocator);
    defer paths.deinit();

    const index_path = try paths.getIndexPath("myproject-abc123");
    defer allocator.free(index_path);

    try std.testing.expect(std.mem.indexOf(u8, index_path, "hound") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_path, "myproject-abc123") != null);
    try std.testing.expect(std.mem.endsWith(u8, index_path, "index.hound"));
}

test "project name from path" {
    const allocator = std.testing.allocator;

    const name = try projectNameFromPath(allocator, "/Users/alice/code/myproject");
    defer allocator.free(name);

    try std.testing.expect(std.mem.startsWith(u8, name, "myproject-"));
}
