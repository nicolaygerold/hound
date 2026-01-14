const std = @import("std");

pub fn encode(value: u64, buf: []u8) usize {
    var v = value;
    var i: usize = 0;
    while (v >= 0x80) : (i += 1) {
        buf[i] = @truncate(v | 0x80);
        v >>= 7;
    }
    buf[i] = @truncate(v);
    return i + 1;
}

pub fn decode(buf: []const u8) struct { value: u64, bytes_read: usize } {
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;

    while (i < buf.len) : (i += 1) {
        const b = buf[i];
        result |= @as(u64, b & 0x7F) << shift;
        if (b & 0x80 == 0) {
            return .{ .value = result, .bytes_read = i + 1 };
        }
        shift += 7;
    }
    return .{ .value = result, .bytes_read = i };
}

pub fn encodedLen(value: u64) usize {
    if (value == 0) return 1;
    var v = value;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        v >>= 7;
    }
    return len;
}

test "varint encode decode" {
    var buf: [10]u8 = undefined;

    const values = [_]u64{ 0, 1, 127, 128, 255, 256, 16383, 16384, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF };

    for (values) |v| {
        const n = encode(v, &buf);
        const result = decode(buf[0..n]);
        try std.testing.expectEqual(v, result.value);
        try std.testing.expectEqual(n, result.bytes_read);
    }
}

test "varint encoded length" {
    try std.testing.expectEqual(@as(usize, 1), encodedLen(0));
    try std.testing.expectEqual(@as(usize, 1), encodedLen(127));
    try std.testing.expectEqual(@as(usize, 2), encodedLen(128));
    try std.testing.expectEqual(@as(usize, 2), encodedLen(16383));
    try std.testing.expectEqual(@as(usize, 3), encodedLen(16384));
}
