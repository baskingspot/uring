//! An io_uring completion loop for Zig: one ring, one tick, and a user_data type
//! you define.
//!
//! io_uring is the architecture here, not a driver choice. Every operation is a
//! submission that completes later, and the loop's job is the part std does not
//! do: when to submit, when to enter, and what runs when.
//!
//! The tag is yours. `Loop(Tag)` takes any 64-bit type — a packed struct of
//! op/slot/generation, a `*Node`, a bare `u64` — and never interprets it. The
//! caller decides what a completion is; the loop only decides when.
//!
//! ```zig
//! const std = @import("std");
//! const uring = @import("uring");
//!
//! const Tag = packed struct(u64) { op: u8, slot: u16, gen: u16, spare: u24 };
//!
//! var cqes: [64]std.os.linux.io_uring_cqe = undefined;
//! var loop: uring.Loop(Tag) = try .init(.{ .cqes = &cqes });
//! defer loop.deinit();
//!
//! _ = try loop.recv(.{ .op = 1, .slot = 7, .gen = 1 }, fd, .{ .buffer = buf }, 0);
//! try loop.tick(&app, App.onCompletion, .{ .until = loop.now() + 10 * std.time.ns_per_ms });
//! ```
//!
//! The loop never closes a descriptor, never frees a byte, and never rearms an
//! operation. Those are the caller's calls, which is what lets one loop serve a
//! proxy, a database, and a test.

pub const Loop = @import("loop.zig").Loop;
pub const Ring = @import("Ring.zig");

test {
    _ = Ring;
    _ = Loop;
    _ = @import("loop_test.zig");
    _ = @import("clock.zig");
}
