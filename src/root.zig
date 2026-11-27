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
//!
//! ## Coverage
//!
//! Every operation `std.os.linux.IoUring` encodes has a wrapper here, and the
//! wrapper takes the caller's tag in place of a raw `user_data`: accept
//! (single, multishot, direct), connect, bind, listen, socket (plain, direct,
//! direct-alloc), send, sendmsg, send_zc (plain and fixed), recv, recvmsg,
//! recv_multishot, read, read_fixed, write, writev, write_fixed, close,
//! close_direct, fsync, fallocate, statx, splice, openat (plain and direct),
//! renameat, unlinkat, mkdirat, symlinkat, linkat, waitid, epoll_ctl, timeout,
//! link_timeout, timeout_remove, poll_add, poll_remove, poll_update, cancel,
//! shutdown, nop, provide_buffers, remove_buffers, and `URING_CMD` on a socket
//! (cmd_sock, setsockopt, getsockopt).
//!
//! `Ring` covers what the kernel lets a ring register: files (plain, sparse,
//! alloc-range, update, unregister), buffers, eventfd (plain and async), NAPI,
//! and the probe (`Ring.supports` asks it about an op).
//!
//! Provided buffers are `BufferGroup` plus `recvMultishot`, `bufferGet`, and
//! `bufferPut`. `std`'s `BufferGroup.init` requests incremental consumption
//! (kernel 6.12; older kernels fall back to whole-buffer), where one buffer
//! carries a stream chunk and several completions; `initBufferGroup` takes
//! `.{ .incremental = false }` for one whole buffer per completion.
//!
//! Not encoded, because `std` does not encode them: `msg_ring`, `futex_wait`,
//! `futex_wake`, `futex_waitv`, `tee`, `madvise`, `openat2`,
//! `timeout_update`, and a generic `URING_CMD` for non-socket commands.
//! Registration that `std` does not expose either: personalities,
//! restrictions, `iowq` worker limits, `sync_cancel`, `clamp`, `pbuf_status`,
//! and `files_update2`. Those need an SQE or a registration built by hand; the
//! `sqe()` escape hatch is where that goes.

pub const Loop = @import("loop.zig").Loop;
pub const Ring = @import("Ring.zig");

pub const BufferGroup = @import("loop.zig").BufferGroup;
pub const BufferGroupOptions = @import("loop.zig").BufferGroupOptions;
pub const initBufferGroup = @import("loop.zig").initBufferGroup;

test {
    _ = Ring;
    _ = Loop;
    _ = @import("loop_test.zig");
    _ = @import("ops_test.zig");
    _ = @import("clock.zig");
}
