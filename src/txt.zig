// DNS-SD TXT policy for `_rdac._udp`.
//
// The wire format is a sequence of length-prefixed strings, each a
// `key=value` pair. Avahi exposes the same pairs as a string list. Both
// paths call `applyPair`, so rate dropping, case-insensitive keys, and
// hostile-value handling are identical.

const std = @import("std");
const format = @import("format.zig");

/// Service type advertised by RDAC receivers and browsed by senders.
pub const SERVICE_TYPE = "_rdac._udp";

/// Maximum length of the `inuse=` TXT value.
pub const MAX_INUSE_LEN: usize = 64;

/// Fields parsed from a receiver TXT record.
pub const TxtData = struct {
    caps: format.Capabilities = format.Capabilities.defaults(),
    inuse_buf: [MAX_INUSE_LEN]u8 = [_]u8{0} ** MAX_INUSE_LEN,
    inuse_len: usize = 0,

    pub fn inuse(self: *const TxtData) []const u8 {
        return self.inuse_buf[0..self.inuse_len];
    }

    pub fn apply(self: *TxtData, key: []const u8, value: []const u8) void {
        applyPair(&self.caps, &self.inuse_buf, &self.inuse_len, key, value);
    }
};

/// Apply one key/value pair to the mutable TXT state.
///
/// Keys are matched case-insensitively. Unknown keys are ignored. A
/// `rates` or `formats` value that produces no valid entry leaves the
/// previous list in place, so defaults survive hostile records. An empty
/// `inuse` value clears the field.
pub fn applyPair(
    caps: *format.Capabilities,
    inuse_buf: *[MAX_INUSE_LEN]u8,
    inuse_len: *usize,
    key: []const u8,
    value: []const u8,
) void {
    if (std.ascii.eqlIgnoreCase(key, "rates")) {
        var parsed: format.RateList = .{};
        parsed.parseCsv(value);
        if (parsed.len > 0) caps.rates = parsed;
    } else if (std.ascii.eqlIgnoreCase(key, "formats")) {
        var buf: [format.MAX_FORMATS]format.PcmFormat = undefined;
        const n = format.parseFormatsCsv(value, &buf);
        if (n > 0) {
            caps.formats_buf = buf;
            caps.formats_len = n;
        }
    } else if (std.ascii.eqlIgnoreCase(key, "inuse")) {
        const n = @min(value.len, MAX_INUSE_LEN);
        @memcpy(inuse_buf[0..n], value[0..n]);
        inuse_len.* = n;
    }
}

/// Parse a raw DNS-SD TXT record. Malformed records stop parsing at the
/// first bad length prefix; valid pairs seen earlier are kept.
pub fn parseBlob(txt: []const u8) TxtData {
    var data: TxtData = .{};

    var offset: usize = 0;
    while (offset < txt.len) {
        const str_len: usize = txt[offset];
        offset += 1;
        if (offset + str_len > txt.len) break;
        const entry = txt[offset .. offset + str_len];
        offset += str_len;

        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            data.apply(entry[0..eq], entry[eq + 1 ..]);
        }
    }

    return data;
}

// Tests

const testing = std.testing;

fn buildTxtBuf(entries: []const []const u8, buf: []u8) []u8 {
    var n: usize = 0;
    for (entries) |e| {
        buf[n] = @intCast(e.len);
        n += 1;
        @memcpy(buf[n..][0..e.len], e);
        n += e.len;
    }
    return buf[0..n];
}

test "missing txt keeps defaults" {
    const data = parseBlob(&.{});
    try testing.expectEqual(@as(usize, 2), data.caps.rates.len);
    try testing.expectEqual(@as(u32, 44100), data.caps.rates.values[0]);
    try testing.expectEqual(@as(u32, 48000), data.caps.rates.values[1]);
    try testing.expectEqual(@as(usize, 3), data.caps.formats_len);
    try testing.expectEqual(@as(usize, 0), data.inuse_len);
}

test "rates only" {
    var buf: [64]u8 = undefined;
    const data = parseBlob(buildTxtBuf(&.{"rates=96000,192000"}, &buf));
    try testing.expectEqual(@as(usize, 2), data.caps.rates.len);
    try testing.expectEqual(@as(u32, 96000), data.caps.rates.values[0]);
    try testing.expectEqual(@as(u32, 192000), data.caps.rates.values[1]);
    try testing.expectEqual(@as(usize, 3), data.caps.formats_len);
    try testing.expectEqual(@as(usize, 0), data.inuse_len);
}

test "formats only and case-insensitive" {
    var buf: [64]u8 = undefined;
    const data = parseBlob(buildTxtBuf(&.{"Formats=S24,S16_typo,S24_32"}, &buf));
    try testing.expectEqual(@as(usize, 2), data.caps.formats_len);
    try testing.expectEqual(format.PcmFormat.s24, data.caps.formats_buf[0]);
    try testing.expectEqual(format.PcmFormat.s24_32, data.caps.formats_buf[1]);
}

test "both rates and formats" {
    var buf: [96]u8 = undefined;
    const data = parseBlob(buildTxtBuf(&.{ "rates=44100,48000,96000", "formats=s16,s24,s24_32" }, &buf));
    try testing.expectEqual(@as(usize, 3), data.caps.rates.len);
    try testing.expectEqual(@as(usize, 3), data.caps.formats_len);
    try testing.expectEqual(format.PcmFormat.s16, data.caps.formats_buf[0]);
    try testing.expectEqual(format.PcmFormat.s24, data.caps.formats_buf[1]);
    try testing.expectEqual(format.PcmFormat.s24_32, data.caps.formats_buf[2]);
}

test "unknown keys and entries without equals are ignored" {
    var buf: [96]u8 = undefined;
    const data = parseBlob(buildTxtBuf(&.{ "garbage", "garbage=value", "rates=88200", "other=thing" }, &buf));
    try testing.expectEqual(@as(usize, 1), data.caps.rates.len);
    try testing.expectEqual(@as(u32, 88200), data.caps.rates.values[0]);
    try testing.expectEqual(@as(usize, 0), data.inuse_len);
}

test "malformed length prefix stops parsing" {
    const blob = [_]u8{ 99, 'x', 'y', 'z', 'w' };
    const data = parseBlob(&blob);
    try testing.expectEqual(@as(usize, 2), data.caps.rates.len);
    try testing.expectEqual(@as(usize, 0), data.inuse_len);
}

test "zero length entry and trailing byte are ignored" {
    const blob = [_]u8{ 0, 'x' };
    const data = parseBlob(&blob);
    try testing.expectEqual(@as(usize, 2), data.caps.rates.len);
}

test "inuse ipv4" {
    var buf: [64]u8 = undefined;
    const data = parseBlob(buildTxtBuf(&.{"inuse=192.168.1.10"}, &buf));
    try testing.expectEqualStrings("192.168.1.10", data.inuse());
    try testing.expectEqual(@as(usize, 12), data.inuse_len);
}

test "inuse empty clears field" {
    var buf: [64]u8 = undefined;
    const blob = buildTxtBuf(&.{ "inuse=10.0.0.1", "inuse=" }, &buf);
    const data = parseBlob(blob);
    try testing.expectEqual(@as(usize, 0), data.inuse_len);
}

test "inuse truncated at max" {
    var entry_buf: [MAX_INUSE_LEN + 10]u8 = undefined;
    @memcpy(entry_buf[0..6], "inuse=");
    for (6..entry_buf.len) |i| entry_buf[i] = 'a';
    var blob_buf: [1 + entry_buf.len]u8 = undefined;
    blob_buf[0] = @intCast(entry_buf.len);
    @memcpy(blob_buf[1..], &entry_buf);
    const data = parseBlob(&blob_buf);
    try testing.expectEqual(MAX_INUSE_LEN, data.inuse_len);
}

test "duplicate keys use the last valid value" {
    var buf: [64]u8 = undefined;
    const data = parseBlob(buildTxtBuf(&.{ "rates=44100", "rates=48000" }, &buf));
    try testing.expectEqual(@as(usize, 1), data.caps.rates.len);
    try testing.expectEqual(@as(u32, 48000), data.caps.rates.values[0]);
}

test "hostile rates are dropped and deduplicated" {
    var buf: [96]u8 = undefined;
    const data = parseBlob(buildTxtBuf(&.{"rates=4000000000,0,48000,48000,768000,768001"}, &buf));
    try testing.expectEqual(@as(usize, 2), data.caps.rates.len);
    try testing.expectEqual(@as(u32, 48000), data.caps.rates.values[0]);
    try testing.expectEqual(@as(u32, 768000), data.caps.rates.values[1]);
}

test "rates beyond max are dropped" {
    const values = [_][]const u8{
        "44100", "48001", "48002", "48003", "48004",
        "48005", "48006", "48007", "48008", "48009",
        "48010", "48011", "48012", "48013", "48014",
        "48015", "48016", "48017", "48018", "48019",
    };
    var entry: [128]u8 = undefined;
    var n: usize = 0;
    @memcpy(entry[0..6], "rates=");
    n = 6;
    for (values, 0..) |v, i| {
        if (i > 0) {
            entry[n] = ',';
            n += 1;
        }
        @memcpy(entry[n..][0..v.len], v);
        n += v.len;
    }

    var blob: [1 + entry.len]u8 = undefined;
    blob[0] = @intCast(n);
    @memcpy(blob[1 .. 1 + n], entry[0..n]);

    const data = parseBlob(blob[0 .. 1 + n]);
    try testing.expectEqual(format.MAX_RATES, data.caps.rates.len);
    try testing.expectEqual(@as(u32, 44100), data.caps.rates.values[0]);
    try testing.expectEqual(@as(u32, 48015), data.caps.rates.values[format.MAX_RATES - 1]);
}
