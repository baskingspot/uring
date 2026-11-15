//! Monotonic time, in nanoseconds. The loop reads it once per tick and hands
//! that sample to every handler, so a tick's timestamps agree with each other
//! and with the deadline the tick was given.

const std = @import("std");
const linux = std.os.linux;

pub fn monotonic() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}
