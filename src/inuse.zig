// Classify a receiver's `inuse=` TXT value against this host's interface
// addresses.
//
// Empty means the receiver is idle. A value that parses as one of our own
// addresses means the receiver is serving us. Anything else, including an
// unparseable non-empty value, belongs to another sender.

const std = @import("std");
const ip = @import("ip.zig");
const local_ips = @import("local_ips.zig");

pub const Verdict = enum {
    free_or_ours,
    someone_else,
};

/// True when `needle` matches one of the local interface addresses.
pub fn isOurs(needle: std.Io.net.IpAddress, local: *const local_ips.LocalIps) bool {
    for (local.slice()) |addr| {
        if (ip.sameAddress(addr, needle)) return true;
    }
    return false;
}

/// Classify a receiver's current `inuse=` value.
pub fn classify(value: []const u8, local: *const local_ips.LocalIps) Verdict {
    if (value.len == 0) return .free_or_ours;
    const parsed = ip.parseIp(value, 0) orelse return .someone_else;
    return if (isOurs(parsed, local)) .free_or_ours else .someone_else;
}

/// Compare two raw `inuse=` values. Parsed addresses compare by address so
/// an IPv4-mapped IPv6 form matches the plain IPv4 form. When both values
/// are unparseable they compare by bytes, and a value that parses never
/// equals one that does not.
pub fn sameValue(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return a.len == b.len;
    const pa = ip.parseIp(a, 0);
    const pb = ip.parseIp(b, 0);
    if (pa == null and pb == null) return std.mem.eql(u8, a, b);
    const x = pa orelse return false;
    const y = pb orelse return false;
    return ip.sameAddress(x, y);
}

// Tests

const testing = std.testing;

fn testLocal() !local_ips.LocalIps {
    var local: local_ips.LocalIps = .{};
    local.addrs[0] = try std.Io.net.IpAddress.parseIp4("10.0.0.5", 0);
    local.addrs[1] = try std.Io.net.IpAddress.parseIp6("2001:db8::1", 0);
    local.len = 2;
    return local;
}

test "classify empty value is free" {
    const local = try testLocal();
    try testing.expectEqual(.free_or_ours, classify("", &local));
}

test "classify our IPv4 and IPv6 addresses" {
    const local = try testLocal();
    try testing.expectEqual(.free_or_ours, classify("10.0.0.5", &local));
    try testing.expectEqual(.free_or_ours, classify("2001:db8::1", &local));
    try testing.expectEqual(.free_or_ours, classify("2001:db8:0:0:0:0:0:1", &local));
}

test "classify mapped IPv6 form of our address" {
    const local = try testLocal();
    try testing.expectEqual(.free_or_ours, classify("::ffff:10.0.0.5", &local));
}

test "classify zone suffix" {
    const local = try testLocal();
    try testing.expectEqual(.someone_else, classify("fe80::1%eth0", &local));
    try testing.expectEqual(.free_or_ours, classify("10.0.0.5%eth0", &local));
}

test "classify someone else and partial matches" {
    const local = try testLocal();
    try testing.expectEqual(.someone_else, classify("172.16.0.9", &local));
    try testing.expectEqual(.someone_else, classify("10.0.0.50", &local));
    try testing.expectEqual(.someone_else, classify("10.0.0.", &local));
}

test "classify unparseable non-empty value stays occupied" {
    const local = try testLocal();
    try testing.expectEqual(.someone_else, classify("not-an-address", &local));
}

test "sameValue uses parsed address comparison" {
    try testing.expect(sameValue("", ""));
    try testing.expect(!sameValue("", "10.0.0.5"));
    try testing.expect(sameValue("10.0.0.5", "10.0.0.5"));
    try testing.expect(sameValue("::ffff:10.0.0.5", "10.0.0.5"));
    try testing.expect(!sameValue("10.0.0.5", "10.0.0.6"));
    try testing.expect(sameValue("garbage", "garbage"));
    try testing.expect(!sameValue("garbage", "other"));
}
