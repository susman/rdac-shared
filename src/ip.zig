// Printable IP address formatting, parsing, normalization, comparison,
// socket-address conversion, and unspecified-address checks.
//
// The receiver renders the peer address for the `inuse=` TXT value. The
// sender parses that value and compares parsed addresses, so formatting
// differences and IPv4-mapped IPv6 forms do not affect the comparison.

const std = @import("std");

/// Maximum printable length of any address this module renders: eight
/// groups of four lowercase hex digits plus seven separators is 39 bytes.
/// 46 matches INET6_ADDRSTRLEN.
pub const MAX_IP_STR_LEN: usize = 46;

/// The unspecified IPv4 address.
pub const UNSPECIFIED_IP4: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = [_]u8{0} ** 4, .port = 0 } };

/// Render an IP address without a port.
/// Returns an empty slice when `buf` is too small.
pub fn formatIp(addr: std.Io.net.IpAddress, buf: []u8) []const u8 {
    return switch (normalize(addr)) {
        .ip4 => |a| formatIp4(a.bytes, buf),
        .ip6 => |a| formatIp6(a.bytes, buf),
    };
}

/// Parse a printable address, ignoring an IPv6 zone suffix.
/// Returns null for invalid input. IPv4-mapped IPv6 addresses are
/// normalized to IPv4 so they compare equal to the plain IPv4 form.
pub fn parseIp(text: []const u8, port: u16) ?std.Io.net.IpAddress {
    const no_zone = if (std.mem.indexOfScalar(u8, text, '%')) |i| text[0..i] else text;
    const parsed = std.Io.net.IpAddress.parse(no_zone, port) catch return null;
    return normalize(parsed);
}

/// Convert an IPv4-mapped IPv6 address to IPv4. Other addresses pass
/// through.
pub fn normalize(addr: std.Io.net.IpAddress) std.Io.net.IpAddress {
    return switch (addr) {
        .ip4 => addr,
        .ip6 => |a| std.Io.net.IpAddress.fromIp6(a),
    };
}

/// Compare two addresses by family and bytes. Port, flow, and interface
/// scope are ignored so a zone suffix cannot make the same address
/// compare unequal.
pub fn sameAddress(a: std.Io.net.IpAddress, b: std.Io.net.IpAddress) bool {
    const na = normalize(a);
    const nb = normalize(b);
    return switch (na) {
        .ip4 => |x| switch (nb) {
            .ip4 => |y| std.mem.eql(u8, &x.bytes, &y.bytes),
            .ip6 => false,
        },
        .ip6 => |x| switch (nb) {
            .ip4 => false,
            .ip6 => |y| std.mem.eql(u8, &x.bytes, &y.bytes),
        },
    };
}

/// True when the address is the unspecified address of its family.
pub fn isUnspecified(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| std.mem.allEqual(u8, &a.bytes, 0),
        .ip6 => |a| std.mem.allEqual(u8, &a.bytes, 0),
    };
}

/// Convert a socket address to a parsed IP address. IPv4-mapped IPv6
/// forms are normalized to IPv4. The port and interface scope are
/// dropped.
pub fn ipFromSockaddr(sa: *const std.posix.sockaddr) ?std.Io.net.IpAddress {
    return switch (sa.family) {
        std.posix.AF.INET => blk: {
            const in4: *const std.posix.sockaddr.in = @ptrCast(@alignCast(sa));
            const bytes: [4]u8 = @bitCast(in4.addr);
            break :blk .{ .ip4 = .{ .bytes = bytes, .port = 0 } };
        },
        std.posix.AF.INET6 => blk: {
            const in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(sa));
            break :blk normalize(.{ .ip6 = .{ .bytes = in6.addr, .port = 0 } });
        },
        else => null,
    };
}

/// Render an IPv4 address as dotted quad ("192.168.1.10").
/// Returns an empty slice when `buf` is too small.
pub fn formatIp4(bytes: [4]u8, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch return buf[0..0];
    return buf[0..w.end];
}

/// Render an IPv6 address as eight uncompressed lowercase hex groups,
/// e.g. "fe80:0:0:0:1aa:2bb3:cc4d:5e6f". No zero compression, matching
/// what the publisher writes into its TXT records.
/// Returns an empty slice when `buf` is too small.
pub fn formatIp6(bytes: [16]u8, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (0..8) |i| {
        if (i != 0) w.writeByte(':') catch return buf[0..0];
        w.print("{x}", .{std.mem.readInt(u16, bytes[i * 2 ..][0..2], .big)}) catch return buf[0..0];
    }
    return buf[0..w.end];
}

// Tests

const testing = std.testing;

test "formatIp4" {
    var buf: [MAX_IP_STR_LEN]u8 = undefined;
    try testing.expectEqualStrings("192.168.1.10", formatIp4(.{ 192, 168, 1, 10 }, &buf));
    try testing.expectEqualStrings("0.0.0.0", formatIp4(.{ 0, 0, 0, 0 }, &buf));
    try testing.expectEqualStrings("255.255.255.255", formatIp4(.{ 255, 255, 255, 255 }, &buf));
}

test "formatIp6 groups" {
    var buf: [MAX_IP_STR_LEN]u8 = undefined;
    const bytes = [16]u8{
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };
    try testing.expectEqualStrings(
        "2001:db8:0:0:0:0:0:1",
        formatIp6(bytes, &buf),
    );
}

test "formatIp ip4 and ip6" {
    var buf: [MAX_IP_STR_LEN]u8 = undefined;
    const v4 = try std.Io.net.IpAddress.parseIp4("192.168.1.10", 4010);
    try testing.expectEqualStrings("192.168.1.10", formatIp(v4, &buf));

    const v6 = try std.Io.net.IpAddress.parseIp6("2001:db8::1", 4010);
    try testing.expectEqualStrings("2001:db8:0:0:0:0:0:1", formatIp(v6, &buf));
}

test "formatIp6 too small buffer yields empty slice" {
    var small: [8]u8 = undefined;
    const bytes = [_]u8{0} ** 16;
    try testing.expectEqual(@as(usize, 0), formatIp6(bytes, &small).len);
}

test "formatIp4 too small buffer yields empty slice" {
    var small: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), formatIp4(.{ 1, 2, 3, 4 }, &small).len);
}

test "parseIp normalizes IPv4-mapped IPv6" {
    const mapped = parseIp("::ffff:192.168.1.10", 0).?;
    try testing.expectEqual([4]u8{ 192, 168, 1, 10 }, mapped.ip4.bytes);

    var buf: [MAX_IP_STR_LEN]u8 = undefined;
    try testing.expectEqualStrings("192.168.1.10", formatIp(mapped, &buf));
}

test "parseIp ignores IPv6 zone suffix" {
    const addr = parseIp("fe80::1%eth0", 0).?;
    try testing.expectEqual(@as(u8, 0xfe), addr.ip6.bytes[0]);
    try testing.expectEqual(@as(u8, 0x80), addr.ip6.bytes[1]);
    try testing.expectEqual(@as(u8, 0x01), addr.ip6.bytes[15]);
}

test "parseIp rejects invalid input" {
    try testing.expect(parseIp("not-an-address", 0) == null);
    try testing.expect(parseIp("999.1.1.1", 0) == null);
    try testing.expect(parseIp("", 0) == null);
}

test "sameAddress ignores port and mapped form" {
    const mapped = parseIp("::ffff:10.0.0.5", 4010).?;
    const plain = try std.Io.net.IpAddress.parseIp4("10.0.0.5", 9999);
    try testing.expect(sameAddress(mapped, plain));

    const other = try std.Io.net.IpAddress.parseIp4("10.0.0.6", 4010);
    try testing.expect(!sameAddress(mapped, other));
}

test "isUnspecified" {
    const zero4 = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
    const zero6 = try std.Io.net.IpAddress.parseIp6("::", 0);
    const loop4 = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const loop6 = try std.Io.net.IpAddress.parseIp6("::1", 0);

    try testing.expect(isUnspecified(zero4));
    try testing.expect(isUnspecified(zero6));
    try testing.expect(!isUnspecified(loop4));
    try testing.expect(!isUnspecified(loop6));
}

test "ipFromSockaddr parses IPv4" {
    var sa = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = 0,
        .addr = 0x0100007f,
    };
    const parsed = ipFromSockaddr(@ptrCast(&sa)).?;
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, parsed.ip4.bytes);
}

test "ipFromSockaddr parses IPv6" {
    var sa = std.mem.zeroes(std.posix.sockaddr.in6);
    sa.family = std.posix.AF.INET6;
    sa.addr = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    const parsed = ipFromSockaddr(@ptrCast(&sa)).?;
    try testing.expectEqual(sa.addr, parsed.ip6.bytes);
}

test "ipFromSockaddr normalizes mapped IPv6" {
    var sa = std.mem.zeroes(std.posix.sockaddr.in6);
    sa.family = std.posix.AF.INET6;
    sa.addr = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 5 };

    const parsed = ipFromSockaddr(@ptrCast(&sa)).?;
    try testing.expectEqual([4]u8{ 10, 0, 0, 5 }, parsed.ip4.bytes);
}

test "ipFromSockaddr rejects unsupported families" {
    var sa = std.mem.zeroes(std.posix.sockaddr);
    sa.family = std.posix.AF.UNIX;
    try testing.expect(ipFromSockaddr(&sa) == null);
}
