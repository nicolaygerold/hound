// Compiler-rt builtins needed for 128-bit float operations used by Zig's stdlib.
// These are required when linking Zig static libraries with non-Zig linkers (e.g. Apple ld).

export fn __divtf3(a: f128, b: f128) f128 {
    return a / b;
}
export fn __multf3(a: f128, b: f128) f128 {
    return a * b;
}
export fn __gttf2(a: f128, b: f128) i32 {
    if (a > b) return 1;
    if (a == b) return 0;
    return -1;
}
export fn __lttf2(a: f128, b: f128) i32 {
    if (a < b) return -1;
    if (a == b) return 0;
    return 1;
}
export fn __netf2(a: f128, b: f128) i32 {
    if (a != b) return 1;
    return 0;
}
export fn __fixtfti(a: f128) i128 {
    return @intFromFloat(a);
}
export fn __floatuntitf(a: u128) f128 {
    return @floatFromInt(a);
}
export fn roundq(a: f128) f128 {
    return @round(a);
}
