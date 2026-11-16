// PCM conversion helpers.
//
// These run on hot paths: the sender's real-time process callback and the
// receiver's feed thread. The loops are unrolled by four where possible
// for instruction-level parallelism.
//
// Float conversion contract:
//   - Non-finite inputs map to silence: a raw integer cast of NaN or of a
//     value beyond the integer range is illegal behavior.
//   - Finite inputs clamp to [-1, 1] before scaling, so the cast is
//     always defined.
//   - Scaling truncates toward zero, matching typical integer-PCM
//     encoders.

const std = @import("std");
const format = @import("format.zig");

/// Full-scale integer magnitude for a format. Both supported depths are
/// symmetric; `-scale - 1` endpoints are deliberately not produced.
pub fn fullScale(f: format.PcmFormat) f32 {
    return switch (f) {
        .s16 => 0x7FFF,
        .s24, .s24_32 => 0x7FFFFF,
    };
}

/// Convert one float sample in [-inf, +inf] to integer PCM at the given
/// full-scale magnitude. Never traps.
pub fn convertSample(x: f32, scale: f32) i32 {
    if (!std.math.isFinite(x)) return 0;
    const clamped = std.math.clamp(x, -1.0, 1.0);
    return @intFromFloat(@trunc(clamped * scale));
}

/// Unpack packed 3-byte little-endian signed samples into right-justified
/// i32 values, i.e. S24 to S24_32.
///
/// Converts `min(out.len, in.len / 3)` samples.
pub fn convertS24ToS24_32(in: []const u8, out: []i32) void {
    const n = @min(out.len, in.len / 3);
    var src = in;
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        inline for (0..4) |k| {
            out[i + k] = readS24(src);
            src = src[3..];
        }
    }
    while (i < n) : (i += 1) {
        out[i] = readS24(src);
        src = src[3..];
    }
}

fn readS24(src: []const u8) i32 {
    return std.mem.readInt(i24, src[0..3], .little);
}

/// Sign-extend little-endian i16 samples into i32.
/// Converts `min(in.len, out.len)` samples.
pub fn convertS16ToS32(in: []const i16, out: []i32) void {
    const n = @min(in.len, out.len);
    for (0..n) |i| {
        out[i] = in[i];
    }
}

/// Clamp an i32 sample into the i16 range.
pub fn clampI32ToI16(value: i32) i16 {
    return @intCast(std.math.clamp(value, -0x8000, 0x7FFF));
}

// Tests

const testing = std.testing;

test "full scale values" {
    try testing.expectEqual(@as(f32, 32767), fullScale(.s16));
    try testing.expectEqual(@as(f32, 8388607), fullScale(.s24));
    try testing.expectEqual(@as(f32, 8388607), fullScale(.s24_32));
}

test "convert identity across range" {
    const scale = fullScale(.s16);
    try testing.expectEqual(@as(i32, 8191), convertSample(0.25, scale));
    try testing.expectEqual(@as(i32, -16383), convertSample(-0.5, scale));
}

test "convert boundaries map to plus and minus scale" {
    const s16 = fullScale(.s16);
    const s24 = fullScale(.s24);
    try testing.expectEqual(@as(i32, 32767), convertSample(1.0, s16));
    try testing.expectEqual(@as(i32, -32767), convertSample(-1.0, s16));
    try testing.expectEqual(@as(i32, 8388607), convertSample(1.0, s24));
    try testing.expectEqual(@as(i32, -8388607), convertSample(-1.0, s24));
}

test "convert clamps out-of-range input" {
    const scale = fullScale(.s16);
    try testing.expectEqual(@as(i32, 32767), convertSample(2.0, scale));
    try testing.expectEqual(@as(i32, 32767), convertSample(1000.0, scale));
    try testing.expectEqual(@as(i32, 32767), convertSample(std.math.floatMax(f32), scale));
    try testing.expectEqual(@as(i32, -32767), convertSample(-2.0, scale));
    try testing.expectEqual(@as(i32, -32767), convertSample(-std.math.floatMax(f32), scale));
}

test "convert non-finite maps to silence" {
    const scale = fullScale(.s24);
    try testing.expectEqual(@as(i32, 0), convertSample(std.math.nan(f32), scale));
    try testing.expectEqual(@as(i32, 0), convertSample(std.math.inf(f32), scale));
    try testing.expectEqual(@as(i32, 0), convertSample(-std.math.inf(f32), scale));
}

test "convert tiny values truncate to zero" {
    const scale = fullScale(.s24);
    try testing.expectEqual(@as(i32, 0), convertSample(1e-9, scale));
    try testing.expectEqual(@as(i32, 0), convertSample(-1e-9, scale));
}

test "convertS24ToS24_32 positive values" {
    const in = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
    var out: [2]i32 = undefined;
    convertS24ToS24_32(&in, &out);
    try testing.expectEqual(@as(i32, 0x030201), out[0]);
    try testing.expectEqual(@as(i32, 0x060504), out[1]);
}

test "convertS24ToS24_32 sign extension" {
    const in = [_]u8{
        0x00, 0x00, 0x80,
        0xFF, 0xFF, 0x7F,
        0xFF, 0xFF, 0xFF,
    };
    var out: [3]i32 = undefined;
    convertS24ToS24_32(&in, &out);
    try testing.expectEqual(@as(i32, -8388608), out[0]);
    try testing.expectEqual(@as(i32, 8388607), out[1]);
    try testing.expectEqual(@as(i32, -1), out[2]);
}

test "convertS24ToS24_32 empty input leaves output untouched" {
    const in: [0]u8 = .{};
    var out = [_]i32{0x12345678};
    convertS24ToS24_32(&in, &out);
    try testing.expectEqual(@as(i32, 0x12345678), out[0]);
}

test "convertS24ToS24_32 unrolled path plus tail" {
    var in: [15]u8 = undefined;
    for (0..5) |i| {
        const v: u32 = @intCast(0x10000 * i + 0x0201);
        in[i * 3] = @truncate(v);
        in[i * 3 + 1] = @truncate(v >> 8);
        in[i * 3 + 2] = @truncate(v >> 16);
    }
    var out: [5]i32 = undefined;
    convertS24ToS24_32(&in, &out);
    for (0..5) |i| {
        const expected: i32 = @intCast(0x10000 * i + 0x0201);
        try testing.expectEqual(expected, out[i]);
    }
}

test "convertS16ToS32" {
    const in = [_]i16{ 1, -1, 0x7FFF, -0x8000 };
    var out: [4]i32 = undefined;
    convertS16ToS32(&in, &out);
    try testing.expectEqual(@as(i32, 1), out[0]);
    try testing.expectEqual(@as(i32, -1), out[1]);
    try testing.expectEqual(@as(i32, 0x7FFF), out[2]);
    try testing.expectEqual(@as(i32, -0x8000), out[3]);
}

test "convertS16ToS32 tail" {
    const in = [_]i16{ 100, -100, 0x7FFF, -0x8000, 42 };
    var out: [5]i32 = undefined;
    convertS16ToS32(&in, &out);
    try testing.expectEqual(@as(i32, 42), out[4]);
    try testing.expectEqual(@as(i32, 100), out[0]);
    try testing.expectEqual(@as(i32, -100), out[1]);
}

test "clampI32ToI16" {
    try testing.expectEqual(@as(i16, 0), clampI32ToI16(0));
    try testing.expectEqual(@as(i16, 32767), clampI32ToI16(32767));
    try testing.expectEqual(@as(i16, -32768), clampI32ToI16(-32768));
    try testing.expectEqual(@as(i16, 32767), clampI32ToI16(1_000_000));
    try testing.expectEqual(@as(i16, -32768), clampI32ToI16(-1_000_000));
}
