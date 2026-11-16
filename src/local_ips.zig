// Local interface IP enumeration for `inuse=` comparison.
//
// The sender compares its own interface addresses against the receiver's
// `inuse=` TXT value. Both sides parse addresses, so formatting and
// IPv4-mapped IPv6 differences do not affect the comparison.

const std = @import("std");
const ip = @import("ip.zig");

/// Maximum number of local interface addresses tracked.
pub const MAX_LOCAL_IPS: usize = 32;

/// getifaddrs(3) structures, declared here as extern structs so field
/// offsets match the C ABI without pulling in a full C import.
const Ifaddrs = extern struct {
    ifa_next: [*c]Ifaddrs,
    ifa_name: [*c]u8,
    ifa_flags: c_uint,
    ifa_addr: [*c]std.posix.sockaddr,
    ifa_netmask: [*c]std.posix.sockaddr,
    ifa_ifu: [*c]std.posix.sockaddr,
    ifa_data: [*c]u8,
};

extern fn getifaddrs(ifap: [*c][*c]Ifaddrs) c_int;
extern fn freeifaddrs(ifa: [*c]Ifaddrs) void;

/// Fixed list of this host's interface addresses.
pub const LocalIps = struct {
    addrs: [MAX_LOCAL_IPS]std.Io.net.IpAddress = [_]std.Io.net.IpAddress{ip.UNSPECIFIED_IP4} ** MAX_LOCAL_IPS,
    len: usize = 0,

    /// Populate the list from getifaddrs(3). Link-local addresses are
    /// included because SCTP can report them as the peer address in
    /// `inuse=`. Unspecified addresses are skipped, and the list truncates
    /// at MAX_LOCAL_IPS.
    ///
    /// The list is replaced only after a successful getifaddrs(3) call.
    /// A failed refresh keeps the previous list instead of leaving the
    /// sender blind.
    pub fn refresh(self: *LocalIps) error{RefreshFailed}!void {
        var head: [*c]Ifaddrs = null;
        if (getifaddrs(&head) != 0) return error.RefreshFailed;
        defer freeifaddrs(head);

        var count: usize = 0;
        var cur: [*c]Ifaddrs = head;
        while (cur != null and count < MAX_LOCAL_IPS) : (cur = cur.*.ifa_next) {
            const sa: [*c]std.posix.sockaddr = cur.*.ifa_addr;
            if (sa == null) continue;

            const addr = ip.ipFromSockaddr(sa) orelse continue;
            if (ip.isUnspecified(addr)) continue;
            self.addrs[count] = addr;
            count += 1;
        }
        self.len = count;
    }

    pub fn slice(self: *const LocalIps) []const std.Io.net.IpAddress {
        return self.addrs[0..self.len];
    }
};

test "empty list" {
    const empty: LocalIps = .{};
    try std.testing.expectEqual(@as(usize, 0), empty.slice().len);
}
