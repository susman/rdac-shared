// Monotonic time and sleep helpers.
//
// Callers own the Io instance. These helpers do not log; sleep errors are
// returned so the caller can decide whether an interrupted wait matters.

const std = @import("std");

/// Monotonic time in milliseconds.
pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Sleep for at least `ms` milliseconds. Negative values sleep zero.
pub fn sleepMs(io: std.Io, ms: i64) !void {
    const clamped: i64 = if (ms <= 0) 0 else ms;
    try std.Io.sleep(io, .fromMilliseconds(clamped), .awake);
}
