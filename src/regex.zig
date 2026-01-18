const std = @import("std");
const trigram_mod = @import("trigram.zig");
const Trigram = trigram_mod.Trigram;
const fromBytes = trigram_mod.fromBytes;
const Regex = @import("regex").Regex;

/// Extract trigrams from a literal string (sliding window of 3)
fn extractTrigramsFromLiteral(allocator: std.mem.Allocator, s: []const u8) ![]Trigram {
    if (s.len < 3) return try allocator.alloc(Trigram, 0);

    var trigrams = std.ArrayList(Trigram){};
    errdefer trigrams.deinit(allocator);

    var i: usize = 0;
    while (i + 3 <= s.len) : (i += 1) {
        const t = fromBytes(s[i], s[i + 1], s[i + 2]);
        // Deduplicate
        var found = false;
        for (trigrams.items) |existing| {
            if (existing == t) {
                found = true;
                break;
            }
        }
        if (!found) try trigrams.append(allocator, t);
    }

    return trigrams.toOwnedSlice(allocator);
}

/// Extract trigrams from a regex pattern by finding literal sequences.
/// This is a simplified approach that:
/// 1. Finds literal character runs (no special regex chars)
/// 2. Extracts trigrams from those runs
/// 3. Returns the intersection of trigrams that MUST be present
///
/// Special handling:
/// - Alternation (|): Only include trigrams common to all branches
/// - Quantifiers (*, +, ?): The quantified part doesn't guarantee trigrams
/// - Character classes []: Treated as non-literal
/// - Escape sequences (\): The escaped char is literal
pub fn extractTrigrams(allocator: std.mem.Allocator, pattern: []const u8) ![]Trigram {
    var all_trigrams = std.ArrayList(Trigram){};
    defer all_trigrams.deinit(allocator);

    // Find all literal sequences and extract their trigrams
    var i: usize = 0;
    var literal_start: ?usize = null;

    while (i < pattern.len) {
        const ch = pattern[i];

        // Check for special regex characters
        if (isSpecialChar(ch)) {
            // End current literal sequence
            if (literal_start) |start| {
                const literal = pattern[start..i];
                const tris = try extractTrigramsFromLiteral(allocator, literal);
                defer allocator.free(tris);
                for (tris) |t| {
                    if (!containsTrigram(all_trigrams.items, t)) {
                        try all_trigrams.append(allocator, t);
                    }
                }
                literal_start = null;
            }

            // Handle escape sequences
            if (ch == '\\' and i + 1 < pattern.len) {
                i += 2; // Skip escaped char
                continue;
            }

            // Handle groups - skip inside but don't break trigram continuity for simple groups
            if (ch == '(') {
                var depth: usize = 1;
                i += 1;
                while (i < pattern.len and depth > 0) {
                    if (pattern[i] == '(') depth += 1;
                    if (pattern[i] == ')') depth -= 1;
                    if (pattern[i] == '\\' and i + 1 < pattern.len) {
                        i += 1;
                    }
                    i += 1;
                }
                continue;
            }

            // Handle character classes
            if (ch == '[') {
                while (i < pattern.len and pattern[i] != ']') {
                    if (pattern[i] == '\\' and i + 1 < pattern.len) {
                        i += 1;
                    }
                    i += 1;
                }
                if (i < pattern.len) i += 1;
                continue;
            }

            i += 1;
        } else {
            // Regular character - part of a literal sequence
            if (literal_start == null) {
                literal_start = i;
            }
            i += 1;
        }
    }

    // Handle final literal sequence
    if (literal_start) |start| {
        const literal = pattern[start..];
        const tris = try extractTrigramsFromLiteral(allocator, literal);
        defer allocator.free(tris);
        for (tris) |t| {
            if (!containsTrigram(all_trigrams.items, t)) {
                try all_trigrams.append(allocator, t);
            }
        }
    }

    return all_trigrams.toOwnedSlice(allocator);
}

fn isSpecialChar(ch: u8) bool {
    return switch (ch) {
        '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$', '\\' => true,
        else => false,
    };
}

fn containsTrigram(trigrams: []const Trigram, t: Trigram) bool {
    for (trigrams) |existing| {
        if (existing == t) return true;
    }
    return false;
}

// ============ POSIX Regex Matching ============

pub const MatchRange = struct {
    start: usize,
    end: usize,
};

/// Pure Zig regex wrapper for actual matching
pub const PosixRegex = struct {
    regex: Regex,

    pub fn compile(pattern: []const u8, allocator: std.mem.Allocator) !PosixRegex {
        const regex = Regex.compile(allocator, pattern) catch return error.InvalidRegex;
        return .{ .regex = regex };
    }

    pub fn deinit(self: *PosixRegex) void {
        self.regex.deinit();
    }

    pub fn match(self: *PosixRegex, text: []const u8) bool {
        return self.regex.partialMatch(text) catch false;
    }

    /// Find all match positions in text
    pub fn findAll(self: *PosixRegex, text: []const u8, allocator: std.mem.Allocator) ![]MatchRange {
        var matches = std.ArrayList(MatchRange){};
        errdefer matches.deinit(allocator);

        var offset: usize = 0;
        while (offset < text.len) {
            if (try self.regex.captures(text[offset..])) |caps_val| {
                var caps = caps_val;
                defer caps.deinit();
                const span = caps.boundsAt(0) orelse {
                    offset += 1;
                    continue;
                };
                const start = offset + span.lower;
                const end = offset + span.upper;
                try matches.append(allocator, .{ .start = start, .end = end });
                offset = if (end == start) offset + 1 else end;
            } else {
                offset += 1;
            }
        }
        return matches.toOwnedSlice(allocator);
    }
};

// ============ Tests ============

test "extract trigrams from literal pattern" {
    const allocator = std.testing.allocator;
    const trigrams = try extractTrigrams(allocator, "hello");
    defer allocator.free(trigrams);

    // "hello" -> "hel", "ell", "llo"
    try std.testing.expectEqual(@as(usize, 3), trigrams.len);
}

test "extract trigrams with regex special chars" {
    const allocator = std.testing.allocator;

    // Pattern with . (any char) breaks literal
    {
        const trigrams = try extractTrigrams(allocator, "hel.o");
        defer allocator.free(trigrams);
        // "hel" is a literal, then "o" is too short
        try std.testing.expectEqual(@as(usize, 1), trigrams.len);
    }

    // Pattern with character class
    {
        const trigrams = try extractTrigrams(allocator, "foo[0-9]+bar");
        defer allocator.free(trigrams);
        // "foo" and "bar" - each has 1 trigram
        try std.testing.expectEqual(@as(usize, 2), trigrams.len);
    }
}

test "extract trigrams with alternation" {
    const allocator = std.testing.allocator;

    // Simple alternation - literals before/after
    const trigrams = try extractTrigrams(allocator, "abc(def|ghi)jkl");
    defer allocator.free(trigrams);

    // "abc" and "jkl" give us trigrams, the group is skipped
    try std.testing.expectEqual(@as(usize, 2), trigrams.len);

    const abc = fromBytes('a', 'b', 'c');
    const jkl = fromBytes('j', 'k', 'l');
    try std.testing.expect(containsTrigram(trigrams, abc));
    try std.testing.expect(containsTrigram(trigrams, jkl));
}

test "extract trigrams with quantifiers" {
    const allocator = std.testing.allocator;

    // Quantifier breaks the literal sequence
    const trigrams = try extractTrigrams(allocator, "hello+world");
    defer allocator.free(trigrams);

    // "hello" before +, then "world" after
    // "hello" -> "hel", "ell", "llo"
    // "world" -> "wor", "orl", "rld"
    try std.testing.expectEqual(@as(usize, 6), trigrams.len);
}

test "extract trigrams with escape sequence" {
    const allocator = std.testing.allocator;

    // Escaped special char is treated as break (conservative)
    const trigrams = try extractTrigrams(allocator, "foo\\.bar");
    defer allocator.free(trigrams);

    // Both "foo" and "bar" give trigrams
    try std.testing.expectEqual(@as(usize, 2), trigrams.len);
}

test "posix regex compile and match" {
    const allocator = std.testing.allocator;

    var regex = try PosixRegex.compile("hello", allocator);
    defer regex.deinit();

    try std.testing.expect(regex.match("hello world"));
    try std.testing.expect(regex.match("say hello"));
    try std.testing.expect(!regex.match("goodbye"));
}

test "posix regex find all" {
    const allocator = std.testing.allocator;

    var regex = try PosixRegex.compile("foo", allocator);
    defer regex.deinit();

    const matches = try regex.findAll("foo bar foo baz foo", allocator);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].start);
    try std.testing.expectEqual(@as(usize, 8), matches[1].start);
    try std.testing.expectEqual(@as(usize, 16), matches[2].start);
}

test "posix regex with pattern" {
    const allocator = std.testing.allocator;

    var regex = try PosixRegex.compile("[0-9]+", allocator);
    defer regex.deinit();

    try std.testing.expect(regex.match("abc123def"));
    try std.testing.expect(!regex.match("abcdef"));
}

test "posix regex alternation" {
    const allocator = std.testing.allocator;

    var regex = try PosixRegex.compile("abc(def|ghi)", allocator);
    defer regex.deinit();

    try std.testing.expect(regex.match("abcdef"));
    try std.testing.expect(regex.match("abcghi"));
    try std.testing.expect(!regex.match("abcxyz"));
    try std.testing.expect(!regex.match("xyzabc"));
}
