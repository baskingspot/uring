//! The ring, and the one syscall std cannot make for us.
//!
//! `std.os.linux.IoUring` encodes every SQE this library submits and owns both
//! queues. What it cannot do is wait with a deadline: `linux.io_uring_enter`
//! hardcodes the extended-argument size, so no `io_uring_getevents_arg` fits
//! through it and a kernel timeout needs an `IORING_OP_TIMEOUT` SQE plus a
//! cancel to move it. This file adds that enter, and the submit bookkeeping
//! around it. It re-implements no SQE: `prep_*` on the standard SQE is the one
//! encoding, and it overwrites the whole 64 bytes, so a reused slot carries no
//! stale `IOSQE_` bit into the next operation.
//!
//! One thread owns a ring, submits on it, and enters it. `DEFER_TASKRUN` makes
//! that a kernel requirement, not a convention.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const clock = @import("clock.zig");
const mem = std.mem;
const assert = std.debug.assert;
pub const RecvBuffer = linux.IoUring.RecvBuffer;
pub const ReadBuffer = linux.IoUring.ReadBuffer;

pub const Ring = @This();

/// Deferred completions run inside the submit-side enter instead of arriving
/// as interrupts, which is the pair this loop was measured with. The kernel
/// requires SINGLE_ISSUER alongside DEFER_TASKRUN. Pass `flags` to `init` to
/// ask for another mask; an unsupported one fails at ring setup.
pub const default_flags: u32 = linux.IORING_SETUP_DEFER_TASKRUN |
    linux.IORING_SETUP_SINGLE_ISSUER;

inner: linux.IoUring,
entries: u16,
/// SQEs prepped since the last submit. std's prep helpers queue into the
/// shared ring without telling us, so the loop keeps the fact itself and
/// submits once per tick instead of once per operation.
dirty: bool = false,

pub const EnterError = error{
    /// The kernel ran out of memory or resources. Wait for completions and retry.
    SystemResources,
    FileDescriptorInvalid,
    FileDescriptorInBadState,
    /// Too many requests in flight. Wait for completions and retry.
    CompletionQueueOvercommitted,
    SubmissionQueueEntryInvalid,
    BufferInvalid,
    RingShuttingDown,
    OpcodeNotSupported,
    /// GETEVENTS came from a thread that does not own the ring.
    InvalidThread,
    /// Interrupted before `min_complete`. Nothing is lost; CQEs stay queued.
    SignalInterrupt,
    /// An errno the enter has no case for.
    Unexpected,
};

pub const Waited = struct {
    /// SQEs this call handed to the kernel. Zero is normal: a submit earlier
    /// in the tick already published them.
    submitted: u32,
    /// The deadline passed before `min_complete` completions arrived.
    timed_out: bool,
};

pub fn init(entries: u16, flags: u32) !Ring {
    return .{
        .inner = try .init(entries, flags),
        .entries = entries,
    };
}

pub fn deinit(self: *Ring) void {
    self.inner.deinit();
    self.* = undefined;
}

/// The room left in the submission queue.
pub fn available(self: *Ring) u32 {
    return @as(u32, self.entries) -| self.inner.sq_ready();
}

/// A blank SQE whose `user_data` is the caller's. The escape hatch: every
/// operation the loop does not wrap is still one `prep_*` away.
pub fn sqe(self: *Ring, user_data: u64) !*linux.io_uring_sqe {
    const slot = try self.getSqe();
    slot.* = mem.zeroes(linux.io_uring_sqe);
    slot.user_data = user_data;
    self.dirty = true;
    return slot;
}

fn getSqe(self: *Ring) !*linux.io_uring_sqe {
    return self.inner.get_sqe() catch |err| switch (err) {
        // Publishing is what frees the space: the enter behind `submit` lets
        // the kernel consume its side of the queue before we ask again.
        error.SubmissionQueueFull => blk: {
            _ = try self.inner.submit();
            self.dirty = false;
            break :blk try self.inner.get_sqe();
        },
        else => |e| return e,
    };
}

/// Publish the queued SQEs. Never blocks and never waits for a completion.
pub fn submit(self: *Ring) !void {
    if (!self.dirty) return;
    _ = try self.inner.submit();
    self.dirty = false;
}

/// Run the completions the kernel deferred without waiting for one. Under
/// DEFER_TASKRUN these run only inside an enter, so an empty completion queue
/// is not proof that there is no work.
pub fn poll(self: *Ring) EnterError!void {
    _ = try self.enter(true, 0, null);
}

/// Block until `min_complete` completions arrive, the deadline passes, or a
/// signal interrupts. `timeout_ns` is relative to the call; `null` waits
/// without a deadline.
pub fn wait(self: *Ring, min_complete: u32, timeout_ns: ?u64) EnterError!Waited {
    assert(min_complete > 0);
    return self.enter(true, min_complete, timeout_ns);
}

/// `io_uring_enter` with `IORING_ENTER_EXT_ARG`, which is the only way to hand
/// the kernel a timeout without submitting an SQE for it.
fn enter(
    self: *Ring,
    comptime getevents: bool,
    min_complete: u32,
    timeout_ns: ?u64,
) EnterError!Waited {
    assert(self.inner.fd >= 0);
    const to_submit = self.inner.flush_sq();

    var flags: u32 = 0;
    const needs_enter = self.inner.sq_ring_needs_enter(&flags);
    if (!needs_enter and !getevents and to_submit == 0) {
        return .{ .submitted = 0, .timed_out = false };
    }

    if (getevents) flags |= linux.IORING_ENTER_GETEVENTS;
    flags |= linux.IORING_ENTER_EXT_ARG;

    var ts: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 };
    var arg: linux.io_uring_getevents_arg = .{
        // No sigmask: the process blocks signals where it needs to, and a
        // signal here would only cost an EINTR.
        .sigmask = 0,
        .sigmask_sz = linux.NSIG / 8,
        .pad = 0,
        .ts = 0,
    };
    if (timeout_ns) |ns| {
        ts = .{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        // `ts` is on this frame and `arg` points at it for the length of the
        // syscall. Do not move it into the argument struct.
        arg.ts = @intFromPtr(&ts);
    }

    // std's `io_uring_enter` hardcodes `NSIG / 8` for the sixth argument, so
    // the extended argument has no way through it. This is the raw call.
    const res = linux.syscall6(
        .io_uring_enter,
        @as(usize, @bitCast(@as(isize, self.inner.fd))),
        to_submit,
        min_complete,
        flags,
        @intFromPtr(&arg),
        @sizeOf(linux.io_uring_getevents_arg),
    );

    return switch (linux.errno(res)) {
        .SUCCESS => .{ .submitted = @intCast(res), .timed_out = false },
        // The deadline passed before min_complete arrived. The SQEs above are
        // still submitted; only the wait ended.
        .TIME => .{ .submitted = to_submit, .timed_out = true },
        .AGAIN => error.SystemResources,
        .BADF => error.FileDescriptorInvalid,
        .BADFD => error.FileDescriptorInBadState,
        .BUSY => error.CompletionQueueOvercommitted,
        .INVAL => error.SubmissionQueueEntryInvalid,
        .FAULT => error.BufferInvalid,
        .NXIO => error.RingShuttingDown,
        .OPNOTSUPP => error.OpcodeNotSupported,
        .EXIST => error.InvalidThread,
        .INTR => error.SignalInterrupt,
        else => error.Unexpected,
    };
}

/// Move the ready completions into `buf`. Never blocks: with `wait_nr` zero,
/// the standard call enters only to flush an overflowing completion queue.
pub fn copyCqes(self: *Ring, buf: []linux.io_uring_cqe) !u32 {
    return self.inner.copy_cqes(buf, 0);
}

pub fn cqReady(self: *const Ring) u32 {
    return self.inner.cq_ready();
}

test "a ring with the default mask opens, reports its depth, and closes" {
    var ring: Ring = try .init(8, default_flags);
    defer ring.deinit();
    try testing.expectEqual(@as(u32, 8), ring.available());
}

test "a prepped SQE is one submit away and its user_data survives" {
    var ring: Ring = try .init(8, default_flags);
    defer ring.deinit();

    _ = try ring.sqe(0xDEAD_BEEF);
    try testing.expect(ring.dirty);
    try ring.submit();
    try testing.expect(!ring.dirty);

    var buf: [8]linux.io_uring_cqe = undefined;
    const waited = try ring.wait(1, 2 * std.time.ns_per_s);
    try testing.expect(!waited.timed_out);
    const n = try ring.copyCqes(&buf);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), buf[0].user_data);
    try testing.expectEqual(@as(i32, 0), buf[0].res);
}

test "the enter deadline ends the wait with nothing in flight" {
    // The claim this library exists for: a timeout with no SQE submitted for
    // it. Nothing is queued and nothing is armed, so only the extended
    // argument can end this wait.
    var ring: Ring = try .init(8, default_flags);
    defer ring.deinit();

    const started = clock.monotonic();
    const waited = try ring.wait(1, 20 * std.time.ns_per_ms);
    const elapsed: u64 = @intCast(clock.monotonic() - started);

    try testing.expect(waited.timed_out);
    try testing.expectEqual(@as(u32, 0), waited.submitted);
    try testing.expect(elapsed >= 20 * std.time.ns_per_ms);
    // A deadline, not a hang: a generous ceiling catches a masked errno that
    // turns the timeout into an infinite wait.
    try testing.expect(elapsed < 2 * std.time.ns_per_s);
}

test "a deadline does not eat a completion that arrives first" {
    var ring: Ring = try .init(8, default_flags);
    defer ring.deinit();

    _ = try ring.sqe(7);
    try ring.submit();

    const waited = try ring.wait(1, 2 * std.time.ns_per_s);
    try testing.expect(!waited.timed_out);
    // The earlier submit consumed the SQE, so this enter handed over none.
    try testing.expectEqual(@as(u32, 0), waited.submitted);

    var buf: [8]linux.io_uring_cqe = undefined;
    try testing.expectEqual(@as(u32, 1), try ring.copyCqes(&buf));
    try testing.expectEqual(@as(u64, 7), buf[0].user_data);
}

test "poll runs deferred completions without waiting" {
    var ring: Ring = try .init(8, default_flags);
    defer ring.deinit();

    try ring.poll();

    var buf: [8]linux.io_uring_cqe = undefined;
    try testing.expectEqual(@as(u32, 0), try ring.copyCqes(&buf));
}

test "a full submission queue flushes instead of failing" {
    // Depth 8, nine preps, no submit between them. The ninth asks for room the
    // queue does not have, and gets it by publishing what is already there.
    var ring: Ring = try .init(8, default_flags);
    defer ring.deinit();

    var i: u64 = 0;
    while (i < 9) : (i += 1) _ = try ring.sqe(i);
    try testing.expect(ring.available() > 0);
    try ring.submit();

    var seen: u32 = 0;
    var buf: [16]linux.io_uring_cqe = undefined;
    while (seen < 9) {
        _ = try ring.wait(1, 2 * std.time.ns_per_s);
        seen += try ring.copyCqes(&buf);
    }
    try testing.expectEqual(@as(u32, 9), seen);
}
