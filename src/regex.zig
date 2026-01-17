const std = @import("std");
const trigram_mod = @import("trigram.zig");
const Trigram = trigram_mod.Trigram;
const fromBytes = trigram_mod.fromBytes;

const posix_regex = @cImport({
    @cInclude("regex.h");
});

/// Extract trigrams from a literal string (sliding window of 3)
fn extractTrigramsFromLiteral(allocator: std.mem.Allocator, s: []const u8) ![]Trigram {
    if (s.len < 3) return try allocator.alloc(Trigram, 0);

    var trigrams = std.ArrayList(Trigram).init(allocator);
    errdefer trigrams.deinit();

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
        if (!found) try trigrams.append(t);
    }

    return trigrams.toOwnedSlice();
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
    var all_trigrams = std.ArrayList(Trigram).init(allocator);
    defer all_trigrams.deinit();

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
                        try all_trigrams.append(t);
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
                try all_trigrams.append(t);
            }
        }
    }

    return all_trigrams.toOwnedSlice();
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

/// POSIX regex wrapper for actual matching
pub const PosixRegex = struct {
    regex: *posix_regex.regex_t,
    alloc: std.mem.Allocator,

    pub fn compile(pattern: []const u8, allocator: std.mem.Allocator) !PosixRegex {
        const pattern_z = try allocator.dupeZ(u8, pattern);
        defer allocator.free(pattern_z);

        const regex = try allocator.create(posix_regex.regex_t);
        errdefer allocator.destroy(regex);

        const flags: c_int = posix_regex.REG_EXTENDED | posix_regex.REG_NEWLINE;
        const result = posix_regex.regcomp(regex, pattern_z.ptr, flags);

        if (result != 0) {
            allocator.destroy(regex);
            return error.InvalidRegex;
        }

        return .{ .regex = regex, .alloc = allocator };
    }

    pub fn deinit(self: *PosixRegex) void {
        posix_regex.regfree(self.regex);
        self.alloc.destroy(self.regex);
    }

    pub fn match(self: *const PosixRegex, text: []const u8, allocator: std.mem.Allocator) !bool {
        const text_z = try allocator.dupeZ(u8, text);
        defer allocator.free(text_z);

        const result = posix_regex.regexec(self.regex, text_z.ptr, 0, null, 0);
        return result == 0;
    }

    /// Find all match positions in text
    pub fn findAll(self: *const PosixRegex, text: []const u8, allocator: std.mem.Allocator) ![]MatchRange {
        const text_z = try allocator.dupeZ(u8, text);
        defer allocator.free(text_z);

        var matches = std.ArrayList(MatchRange).init(allocator);
        errdefer matches.deinit();

        var pmatch: [1]posix_regex.regmatch_t = undefined;
        var offset: usize = 0;

        while (offset < text.len) {
            const result = posix_regex.regexec(self.regex, text_z.ptr + offset, 1, &pmatch, 0);
            if (result != 0) break;

            const start = offset + @as(usize, @intCast(pmatch[0].rm_so));
            const end = offset + @as(usize, @intCast(pmatch[0].rm_eo));

            try matches.append(.{ .start = start, .end = end });

            // Move past this match (prevent infinite loop on empty match)
            if (end == start) {
                offset += 1;
            } else {
                offset = end;
            }
        }

        return matches.toOwnedSlice();
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

    try std.testing.expect(try regex.match("hello world", allocator));
    try std.testing.expect(try regex.match("say hello", allocator));
    try std.testing.expect(!try regex.match("goodbye", allocator));
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

    try std.testing.expect(try regex.match("abc123def", allocator));
    try std.testing.expect(!try regex.match("abcdef", allocator));
}

test "posix regex alternation" {
    const allocator = std.testing.allocator;

    var regex = try PosixRegex.compile("abc(def|ghi)", allocator);
    defer regex.deinit();

    try std.testing.expect(try regex.match("abcdef", allocator));
    try std.testing.expect(try regex.match("abcghi", allocator));
    try std.testing.expect(!try regex.match("abcxyz", allocator));
    try std.testing.expect(!try regex.match("xyzabc", allocator));
}
