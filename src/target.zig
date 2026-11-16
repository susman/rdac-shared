// Resolved receiver snapshot and change detection.
//
// A Target is produced by discovery and copied by value into applications.
// It owns the endpoint, the receiver name, one capability snapshot, and the
// raw `inuse=` value. Change helpers are pure and lock-free.

const std = @import("std");
const format = @import("format.zig");
const ip = @import("ip.zig");
const txt = @import("txt.zig");
const inuse = @import("inuse.zig");

/// Maximum number of bytes kept from a resolved hostname.
pub const MAX_NAME_LEN: usize = 64;

pub const Target = struct {
    endpoint: std.Io.net.IpAddress = ip.UNSPECIFIED_IP4,
    name_buf: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: usize = 0,
    caps: format.Capabilities = format.Capabilities.defaults(),
    inuse_buf: [txt.MAX_INUSE_LEN]u8 = [_]u8{0} ** txt.MAX_INUSE_LEN,
    inuse_len: usize = 0,

    pub fn name(self: *const Target) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn inuse(self: *const Target) []const u8 {
        return self.inuse_buf[0..self.inuse_len];
    }

    pub fn setName(self: *Target, value: []const u8) void {
        const n = @min(value.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], value[0..n]);
        self.name_len = n;
    }

    pub fn setInuse(self: *Target, value: []const u8) void {
        const n = @min(value.len, self.inuse_buf.len);
        @memcpy(self.inuse_buf[0..n], value[0..n]);
        self.inuse_len = n;
    }

    pub fn applyPair(self: *Target, key: []const u8, value: []const u8) void {
        txt.applyPair(&self.caps, &self.inuse_buf, &self.inuse_len, key, value);
    }
};

/// True when the advertised rate list changed.
pub fn ratesChanged(a: *const Target, b: *const Target) bool {
    return !a.caps.rates.eql(&b.caps.rates);
}

/// True when the receiver endpoint or advertised rate list changed.
pub fn endpointChanged(a: *const Target, b: *const Target) bool {
    if (!ip.sameAddress(a.endpoint, b.endpoint)) return true;
    if (a.endpoint.getPort() != b.endpoint.getPort()) return true;
    return ratesChanged(a, b);
}

/// True when any field that can affect the stream or takeover decision
/// changed: endpoint, port, rates, formats, or `inuse=`.
pub fn changed(a: *const Target, b: *const Target) bool {
    if (endpointChanged(a, b)) return true;
    if (!std.mem.eql(format.PcmFormat, a.caps.formats(), b.caps.formats())) return true;
    return !inuse.sameValue(a.inuse(), b.inuse());
}

// Tests

const testing = std.testing;

fn baseTarget() Target {
    return .{
        .endpoint = std.Io.net.IpAddress.parseIp4("10.0.0.1", 4010) catch @panic("test address"),
    };
}

test "name and inuse accessors truncate" {
    var t = baseTarget();
    t.setName("receiver");
    try testing.expectEqualStrings("receiver", t.name());
    t.setInuse("10.0.0.5");
    try testing.expectEqualStrings("10.0.0.5", t.inuse());

    var long: [MAX_NAME_LEN + 10]u8 = undefined;
    @memset(&long, 'x');
    t.setName(&long);
    try testing.expectEqual(MAX_NAME_LEN, t.name_len);
}

test "applyPair updates caps and inuse" {
    var t = baseTarget();
    t.applyPair("RATES", "96000,192000");
    t.applyPair("formats", "s24");
    t.applyPair("InUse", "10.0.0.5");
    try testing.expectEqual(@as(usize, 2), t.caps.rates.len);
    try testing.expectEqual(@as(u32, 96000), t.caps.rates.values[0]);
    try testing.expectEqual(@as(usize, 1), t.caps.formats_len);
    try testing.expectEqualStrings("10.0.0.5", t.inuse());
}

test "endpoint and rate change detection" {
    const a = baseTarget();
    try testing.expect(!endpointChanged(&a, &a));
    try testing.expect(!changed(&a, &a));

    var moved = a;
    moved.endpoint = std.Io.net.IpAddress.parseIp4("10.0.0.2", 4010) catch @panic("test address");
    try testing.expect(endpointChanged(&a, &moved));
    try testing.expect(changed(&a, &moved));

    var other_port = a;
    other_port.endpoint = std.Io.net.IpAddress.parseIp4("10.0.0.1", 4011) catch @panic("test address");
    try testing.expect(endpointChanged(&a, &other_port));

    var other_rates = a;
    other_rates.caps.rates.parseCsv("96000");
    try testing.expect(ratesChanged(&a, &other_rates));
    try testing.expect(endpointChanged(&a, &other_rates));
}

test "inuse change detection uses parsed addresses" {
    const a = baseTarget();
    var b = a;
    b.setInuse("10.0.0.5");
    try testing.expect(changed(&a, &b));

    var c = b;
    c.setInuse("::ffff:10.0.0.5");
    try testing.expect(!changed(&b, &c));

    var d = b;
    d.setInuse("");
    try testing.expect(changed(&b, &d));
}

test "format change detection" {
    const a = baseTarget();
    var b = a;
    b.caps.formats_buf[0] = .s24;
    b.caps.formats_len = 1;
    try testing.expect(changed(&a, &b));
    try testing.expect(!endpointChanged(&a, &b));
}
