// Log-safe string rendering for attacker-controlled values.
//
// DNS-SD service names and TXT values come from the local network and
// may contain control characters or terminal escape sequences.
// Sanitize every such value before it reaches a log line or other
// fixed output.

const std = @import("std");

/// Copy `input` into `buf`, replacing bytes outside printable ASCII
/// with '?'. Returns the sanitized copy, truncated to `buf.len`.
pub fn slice(buf: []u8, input: []const u8) []const u8 {
    const n = @min(input.len, buf.len);
    for (input[0..n], 0..) |c, i| {
        buf[i] = if (c >= 0x20 and c < 0x7f) c else '?';
    }
    return buf[0..n];
}

const testing = std.testing;

test "printable ASCII passes through" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("abc", slice(&buf, "abc"));
}

test "control and high bytes become ?" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a?b?", slice(&buf, "a\x01b\xff"));
}

test "truncates to the buffer" {
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), slice(&buf, "abcdefg").len);
    try testing.expectEqualStrings("abcd", slice(&buf, "abcdefg"));
}
