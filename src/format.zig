// PCM format descriptors, sample-rate lists, and receiver capabilities.
//
// A PcmFormat describes the wire format. `s24_32` means 24-bit audio in a
// 32-bit container, so it maps to 24 wire bits. Never pass
// `@intFromEnum(PcmFormat)` to sctp-wps as `bits_per_sample`; use
// `wireBits` instead.

const std = @import("std");

/// Maximum number of sample rates advertised or accepted anywhere.
pub const MAX_RATES: usize = 16;

/// Maximum number of distinct PCM formats, derived from the enum.
pub const MAX_FORMATS: usize = @typeInfo(PcmFormat).@"enum".fields.len;

/// Upper bound for a legal PCM sample rate, shared by all parsers.
pub const MAX_SAMPLE_RATE: u32 = 768_000;

/// True when `rate` is a finite whole-number sample rate within
/// MAX_SAMPLE_RATE. Nominal-rate validation on both ends goes through
/// this predicate so an incoming f64 is never truncated before it is
/// accepted.
pub fn isWholeRate(rate: f64) bool {
    return std.math.isFinite(rate) and
        rate >= 1.0 and
        rate <= @as(f64, @floatFromInt(MAX_SAMPLE_RATE)) and
        rate == @trunc(rate);
}

/// Default receiver rates when a TXT record omits the key.
pub const DEFAULT_RATES = [_]u32{ 44100, 48000 };

/// Default receiver formats when a TXT record omits the key. Lists every
/// PcmFormat.
pub const DEFAULT_FORMATS = [_]PcmFormat{ .s16, .s24, .s24_32 };

comptime {
    if (DEFAULT_FORMATS.len != MAX_FORMATS) @compileError("DEFAULT_FORMATS must list every PcmFormat");
}

/// Integer-PCM bit depth understood by both ends of the wire.
pub const PcmFormat = enum {
    s16,
    s24,
    s24_32,
};

/// Bits per sample carried by a supported format. `s24_32` carries 24.
pub fn wireBits(f: PcmFormat) u8 {
    return switch (f) {
        .s16 => 16,
        .s24, .s24_32 => 24,
    };
}

/// Parse a TXT format token. Tokens are matched case-insensitively.
pub fn formatFromToken(token: []const u8) ?PcmFormat {
    if (std.ascii.eqlIgnoreCase(token, "s16")) return .s16;
    if (std.ascii.eqlIgnoreCase(token, "s24")) return .s24;
    if (std.ascii.eqlIgnoreCase(token, "s24_32")) return .s24_32;
    return null;
}

/// Canonical TXT token for a format.
pub fn formatToken(f: PcmFormat) []const u8 {
    return switch (f) {
        .s16 => "s16",
        .s24 => "s24",
        .s24_32 => "s24_32",
    };
}

/// Parse one rate token. Returns null for invalid, zero, or above-range
/// values.
fn parseRateToken(token: []const u8) ?u32 {
    const rate = std.fmt.parseInt(u32, token, 10) catch return null;
    if (rate == 0 or rate > MAX_SAMPLE_RATE) return null;
    return rate;
}

/// Split `value` on commas and parse each trimmed token with `parseToken`.
/// Invalid tokens and duplicates are dropped, and the list caps at `max`
/// entries. Returns the number of valid entries written to `buf`.
fn parseCsvList(
    comptime T: type,
    comptime parseToken: *const fn ([]const u8) ?T,
    comptime max: usize,
    value: []const u8,
    buf: *[max]T,
) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |tok| {
        if (n >= max) break;
        const trimmed = std.mem.trim(u8, tok, " \t");
        const item = parseToken(trimmed) orelse continue;
        for (buf[0..n]) |existing| {
            if (existing == item) break;
        } else {
            buf[n] = item;
            n += 1;
        }
    }
    return n;
}

/// Parse a TXT formats CSV value into `buf` using the shared CSV list
/// policy. Returns the number of valid entries.
pub fn parseFormatsCsv(value: []const u8, buf: *[MAX_FORMATS]PcmFormat) usize {
    return parseCsvList(PcmFormat, formatFromToken, MAX_FORMATS, value, buf);
}

/// Ordered list of allowed or advertised sample rates.
/// Parsing drops entries outside 1..MAX_SAMPLE_RATE, removes duplicates,
/// and caps the list at MAX_RATES.
pub const RateList = struct {
    values: [MAX_RATES]u32 = [_]u32{0} ** MAX_RATES,
    len: usize = 0,

    pub fn parseCsv(self: *RateList, csv: []const u8) void {
        self.len = parseCsvList(u32, parseRateToken, MAX_RATES, csv, &self.values);
    }

    pub fn contains(self: *const RateList, rate: u32) bool {
        for (self.slice()) |r| {
            if (r == rate) return true;
        }
        return false;
    }

    pub fn eql(a: *const RateList, b: *const RateList) bool {
        return std.mem.eql(u32, a.slice(), b.slice());
    }

    pub fn slice(self: *const RateList) []const u32 {
        return self.values[0..self.len];
    }

    /// Render the list as CSV into `buf`. Returns an empty slice when the
    /// buffer is too small for the whole list.
    pub fn formatCsv(self: *const RateList, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        for (self.slice(), 0..) |rate, i| {
            if (i != 0) w.writeByte(',') catch return buf[0..0];
            w.print("{d}", .{rate}) catch return buf[0..0];
        }
        return buf[0..w.end];
    }
};

/// Receiver audio capabilities. Missing TXT fields keep these defaults.
pub const Capabilities = struct {
    rates: RateList = .{},
    formats_buf: [MAX_FORMATS]PcmFormat = [_]PcmFormat{.s16} ** MAX_FORMATS,
    formats_len: usize = 0,

    pub fn formats(self: *const Capabilities) []const PcmFormat {
        return self.formats_buf[0..self.formats_len];
    }

    pub fn defaults() Capabilities {
        var caps: Capabilities = .{};
        for (DEFAULT_RATES, 0..) |rate, i| caps.rates.values[i] = rate;
        caps.rates.len = DEFAULT_RATES.len;
        for (DEFAULT_FORMATS, 0..) |f, i| caps.formats_buf[i] = f;
        caps.formats_len = DEFAULT_FORMATS.len;
        return caps;
    }

    pub fn eql(a: *const Capabilities, b: *const Capabilities) bool {
        if (!a.rates.eql(&b.rates)) return false;
        return std.mem.eql(PcmFormat, a.formats(), b.formats());
    }

    /// True when the format list contains `f`.
    pub fn supportsFormat(self: *const Capabilities, f: PcmFormat) bool {
        for (self.formats()) |candidate| {
            if (candidate == f) return true;
        }
        return false;
    }
};

// Tests

const testing = std.testing;

test "isWholeRate accepts finite whole rates in range" {
    try testing.expect(isWholeRate(44100.0));
    try testing.expect(isWholeRate(768000.0));
    try testing.expect(!isWholeRate(48000.5));
    try testing.expect(!isWholeRate(0.0));
    try testing.expect(!isWholeRate(-48000.0));
    try testing.expect(!isWholeRate(std.math.nan(f64)));
    try testing.expect(!isWholeRate(std.math.inf(f64)));
    try testing.expect(!isWholeRate(768001.0));
}

test "wireBits maps s24_32 to 24 wire bits" {
    try testing.expectEqual(@as(u8, 16), wireBits(.s16));
    try testing.expectEqual(@as(u8, 24), wireBits(.s24));
    try testing.expectEqual(@as(u8, 24), wireBits(.s24_32));
}

test "format tokens" {
    try testing.expectEqual(PcmFormat.s16, formatFromToken("S16").?);
    try testing.expectEqual(PcmFormat.s24, formatFromToken("s24").?);
    try testing.expectEqual(PcmFormat.s24_32, formatFromToken("S24_32").?);
    try testing.expect(formatFromToken("s99") == null);
    try testing.expectEqualStrings("s24_32", formatToken(.s24_32));
}

test "parseFormatsCsv drops unknown tokens and duplicates" {
    var buf: [MAX_FORMATS]PcmFormat = undefined;
    const n = parseFormatsCsv(" S24 , s16_typo , S24_32 , s24 ", &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(PcmFormat.s24, buf[0]);
    try testing.expectEqual(PcmFormat.s24_32, buf[1]);

    try testing.expectEqual(@as(usize, 0), parseFormatsCsv("garbage", &buf));
}

test "RateList parse and contains" {
    var list: RateList = .{};
    list.parseCsv("44100,48000");
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(u32, 44100), list.values[0]);
    try testing.expectEqual(@as(u32, 48000), list.values[1]);
    try testing.expect(list.contains(48000));
    try testing.expect(!list.contains(96000));

    list.parseCsv("44100,44100,48000,48000");
    try testing.expectEqual(@as(usize, 2), list.len);
}

test "RateList rejects invalid and overflow tokens" {
    var list: RateList = .{};
    list.parseCsv("0,999999999999,768001, 44100 ");
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(u32, 44100), list.values[0]);

    list.parseCsv("4000000000000,48000");
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(u32, 48000), list.values[0]);
}

test "RateList caps at MAX_RATES" {
    var list: RateList = .{};
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    for (0..MAX_RATES + 4) |i| {
        if (i != 0) w.writeByte(',') catch unreachable;
        w.print("{d}", .{44100 + i}) catch unreachable;
    }
    list.parseCsv(buf[0..w.end]);
    try testing.expectEqual(MAX_RATES, list.len);
}

test "RateList formatCsv round trip" {
    var list: RateList = .{};
    list.parseCsv("44100,48000,96000");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("44100,48000,96000", list.formatCsv(&buf));

    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), list.formatCsv(&small).len);
}

test "Capabilities defaults and equality" {
    const a = Capabilities.defaults();
    const b = Capabilities.defaults();
    try testing.expect(a.eql(&b));
    try testing.expectEqual(@as(usize, 2), a.rates.len);
    try testing.expectEqual(@as(u32, 44100), a.rates.values[0]);
    try testing.expectEqual(@as(usize, 3), a.formats().len);
    try testing.expect(a.supportsFormat(.s24_32));
}
