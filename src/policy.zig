// Sender cooldown, retry, and connect backoff policy.
//
// State machines stay in applications. This module only holds the shared
// timing constants, the permanent-error predicate, and a small backoff
// iterator.

const std = @import("std");

/// Quiet period after a drop before consulting `inuse=` again.
pub const COOLDOWN_MS: i64 = 2000;

/// How long cooldown resolution waits for a fresh resolve.
pub const REQUERY_TIMEOUT_MS: i64 = 5000;

/// Delay before retrying a failed sink creation.
pub const RETRY_MS: i64 = 2000;

/// How often searching requeries a busy receiver.
pub const SEARCHING_POLL_MS: i64 = 5000;

/// Poll step inside state-machine loops.
pub const POLL_STEP_MS: i64 = 100;

/// Initial and maximum connect-retry backoff.
pub const CONNECT_BACKOFF_INITIAL_MS: u64 = 500;
pub const CONNECT_BACKOFF_MAX_MS: u64 = 8000;

/// Maximum connect attempts before bailing out to cooldown.
pub const CONNECT_MAX_RETRIES: u32 = 5;

/// Writer initialization errors that cannot succeed on a retry.
pub fn isPermanentConnectError(err: anyerror) bool {
    return switch (err) {
        error.UnsupportedConfig,
        error.InvalidDepth,
        error.InvalidChunkSize,
        error.AlreadyInitialized,
        => true,
        else => false,
    };
}

/// Exponential connect-retry schedule. A caller attempts a connect, calls
/// `failed` on error, and sleeps `delay` milliseconds before the next
/// attempt. `failed` returns false when the retry budget is exhausted.
pub const Backoff = struct {
    delay_ms: u64 = CONNECT_BACKOFF_INITIAL_MS,
    attempts: u32 = 0,

    pub const Failure = struct {
        attempts: u32,
        delay_ms: u64,
    };

    /// Record a failure. Returns the delay to observe before the next
    /// attempt, or null when no further attempt should be made.
    pub fn failed(self: *Backoff) ?Failure {
        self.attempts += 1;
        if (self.attempts >= CONNECT_MAX_RETRIES) return null;
        const result = Failure{
            .attempts = self.attempts,
            .delay_ms = self.delay_ms,
        };
        if (self.delay_ms < CONNECT_BACKOFF_MAX_MS) self.delay_ms *= 2;
        return result;
    }

    pub fn reset(self: *Backoff) void {
        self.* = .{};
    }

    /// Return the current delay and advance to the next step, capped at
    /// CONNECT_BACKOFF_MAX_MS. Use this for callers that retry without a
    /// fixed attempt limit.
    pub fn nextDelay(self: *Backoff) u64 {
        self.attempts += 1;
        const delay = self.delay_ms;
        if (self.delay_ms < CONNECT_BACKOFF_MAX_MS) self.delay_ms *= 2;
        return delay;
    }
};

// Tests

const testing = std.testing;

test "permanent connect errors" {
    try testing.expect(isPermanentConnectError(error.UnsupportedConfig));
    try testing.expect(isPermanentConnectError(error.InvalidDepth));
    try testing.expect(isPermanentConnectError(error.InvalidChunkSize));
    try testing.expect(isPermanentConnectError(error.AlreadyInitialized));
    try testing.expect(!isPermanentConnectError(error.ConnectionRefused));
    try testing.expect(!isPermanentConnectError(error.OutOfMemory));
}

test "backoff doubles and stops at the retry limit" {
    var backoff: Backoff = .{};
    const first = backoff.failed().?;
    try testing.expectEqual(@as(u32, 1), first.attempts);
    try testing.expectEqual(CONNECT_BACKOFF_INITIAL_MS, first.delay_ms);

    const second = backoff.failed().?;
    try testing.expectEqual(CONNECT_BACKOFF_INITIAL_MS * 2, second.delay_ms);

    _ = backoff.failed().?;
    _ = backoff.failed().?;
    try testing.expect(backoff.failed() == null);
    try testing.expectEqual(CONNECT_MAX_RETRIES, backoff.attempts);
}

test "backoff reset" {
    var backoff: Backoff = .{};
    _ = backoff.failed();
    backoff.reset();
    try testing.expectEqual(@as(u32, 0), backoff.attempts);
    try testing.expectEqual(CONNECT_BACKOFF_INITIAL_MS, backoff.delay_ms);
}
