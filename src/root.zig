// Shared RDAC protocol policy: addresses, local interfaces, inuse
// classification, PCM format descriptors, TXT parsing, targets, PCM
// conversion, time, and retry policy.
//
// The package is pure Zig and std. It has no allocator, no logging, and
// no global Io. Callers own all long-lived state and apply policy.

pub const ip = @import("ip.zig");
pub const local_ips = @import("local_ips.zig");
pub const inuse = @import("inuse.zig");
pub const format = @import("format.zig");
pub const txt = @import("txt.zig");
pub const target = @import("target.zig");
pub const pcm = @import("pcm.zig");
pub const time = @import("time.zig");
pub const policy = @import("policy.zig");
pub const sanitize = @import("sanitize.zig");

pub const PcmFormat = format.PcmFormat;
pub const RateList = format.RateList;
pub const Capabilities = format.Capabilities;
pub const LocalIps = local_ips.LocalIps;
pub const Verdict = inuse.Verdict;
pub const Target = target.Target;

test {
    _ = ip;
    _ = local_ips;
    _ = inuse;
    _ = format;
    _ = txt;
    _ = target;
    _ = pcm;
    _ = time;
    _ = policy;
    _ = sanitize;
}
