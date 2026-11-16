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
const posix = std.posix;
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;
pub const RecvBuffer = linux.IoUring.RecvBuffer;
pub const ReadBuffer = linux.IoUring.ReadBuffer;

const clock = @import("clock.zig");

pub const Ring = @This();

/// Ring setup, in place of the raw `io_uring_setup` flag word.
///
/// The kernel's flags are a bitmask of unrelated booleans plus three values
/// that are meaningless without their bit, so a `u32` lets a caller pass
/// `IORING_SETUP_SQ_AFF` without a CPU or `CQSIZE` without a size. Here each
/// bit has a name and the values sit beside it.
pub const Setup = struct {
    /// Complete each operation by polling the device: O_DIRECT block and
    /// char devices, not sockets or pipes.
    iopoll: bool = false,
    /// A kernel thread submits SQEs. The ring must then be shared only for
    /// completion reads; submitting from userspace races it.
    sqpoll: bool = false,
    /// Pin the SQPOLL thread to `sq_thread_cpu`.
    sq_aff: bool = false,
    /// Let the kernel clamp `entries` to what it can allocate instead of
    /// failing the setup.
    clamp: bool = false,
    /// Start disabled: `Ring.enable` turns it on later, which lets a process
    /// set up a ring before it has the privileges to submit.
    r_disabled: bool = false,
    /// Submit every SQE in the batch even after one fails, instead of
    /// stopping at the first error.
    submit_all: bool = false,
    /// Deferred completions run in the submitting task. Cheaper than the
    /// default task work, and it cannot be combined with a ring shared across
    /// threads.
    coop_taskrun: bool = false,
    /// Set `IORING_SQ_TASKRUN` on the SQ ring when task work is pending.
    taskrun_flag: bool = false,
    /// 128-byte SQEs, for operations that carry more than 64 bytes.
    sqe128: bool = false,
    /// 32-byte CQEs, for the flags of CQE32 operations.
    cqe32: bool = false,
    /// One thread may submit. Required by `defer_taskrun`.
    single_issuer: bool = false,
    /// Deferred completions run only inside the submit-side enter, so the
    /// completions cannot arrive as interrupts. Requires `single_issuer`.
    defer_taskrun: bool = false,
    /// The ring's memory is not mmap'd by the kernel; the caller maps it.
    no_mmap: bool = false,
    /// Only registered files may be used.
    registered_fd_only: bool = false,
    /// The SQ array (the indirection from submission order to SQE slots) is
    /// not allocated; SQEs are consumed in order.
    no_sqarray: bool = false,

    /// `CQSIZE`: completion queue entries, when they must differ from the
    /// submission queue's. Zero keeps the kernel's default.
    cq_entries: u32 = 0,
    /// `SQ_AFF`: the CPU for the SQPOLL thread.
    sq_thread_cpu: u32 = 0,
    /// `SQPOLL`: how long the thread idles before sleeping, in milliseconds.
    sq_thread_idle: u32 = 1000,
    /// `ATTACH_WQ`: share the io-wq worker pool of an existing ring.
    wq_fd: ?linux.fd_t = null,

    /// Each boolean and the kernel bit it stands for.
    const bits = .{
        .{ "iopoll", linux.IORING_SETUP_IOPOLL },
        .{ "sqpoll", linux.IORING_SETUP_SQPOLL },
        .{ "sq_aff", linux.IORING_SETUP_SQ_AFF },
        .{ "clamp", linux.IORING_SETUP_CLAMP },
        .{ "r_disabled", linux.IORING_SETUP_R_DISABLED },
        .{ "submit_all", linux.IORING_SETUP_SUBMIT_ALL },
        .{ "coop_taskrun", linux.IORING_SETUP_COOP_TASKRUN },
        .{ "taskrun_flag", linux.IORING_SETUP_TASKRUN_FLAG },
        .{ "sqe128", linux.IORING_SETUP_SQE128 },
        .{ "cqe32", linux.IORING_SETUP_CQE32 },
        .{ "single_issuer", linux.IORING_SETUP_SINGLE_ISSUER },
        .{ "defer_taskrun", linux.IORING_SETUP_DEFER_TASKRUN },
        .{ "no_mmap", linux.IORING_SETUP_NO_MMAP },
        .{ "registered_fd_only", linux.IORING_SETUP_REGISTERED_FD_ONLY },
        .{ "no_sqarray", linux.IORING_SETUP_NO_SQARRAY },
    };

    /// The flag word `io_uring_setup` wants, with `CQSIZE` and `ATTACH_WQ`
    /// derived from the values beside them.
    pub fn flags(self: Setup) u32 {
        var out: u32 = 0;
        inline for (bits) |b| {
            if (@field(self, b[0])) out |= b[1];
        }
        if (self.cq_entries != 0) out |= linux.IORING_SETUP_CQSIZE;
        if (self.wq_fd != null) out |= linux.IORING_SETUP_ATTACH_WQ;
        return out;
    }

    /// The bits of a flag word, for a caller that has one.
    ///
    /// Lossy on purpose: `CQSIZE` and `ATTACH_WQ` exist only to say that a
    /// value is present, and a word does not carry the value. Those two bits
    /// come back false here, because a `Setup` with the bit and no value is
    /// not expressible. Set `cq_entries` or `wq_fd` to restore them.
    pub fn fromFlags(word: u32) Setup {
        var out: Setup = .{};
        inline for (bits) |b| {
            @field(out, b[0]) = word & b[1] != 0;
        }
        return out;
    }

    fn params(self: Setup) linux.io_uring_params {
        // The kernel refuses this pair in the other direction, so it is a
        // caller error worth naming here.
        assert(!self.defer_taskrun or self.single_issuer);
        assert(self.sq_aff or self.sq_thread_cpu == 0);
        var p = mem.zeroInit(linux.io_uring_params, .{
            .flags = self.flags(),
            .sq_thread_cpu = self.sq_thread_cpu,
            .sq_thread_idle = self.sq_thread_idle,
        });
        p.cq_entries = self.cq_entries;
        p.wq_fd = if (self.wq_fd) |fd| @intCast(fd) else 0;
        return p;
    }
};

/// What this loop wants by default: completions deferred to the submit-side
/// enter, one issuer. The kernel requires the pair, and it is the
/// configuration the loop's timings were measured with.
pub const default_setup: Setup = .{
    .single_issuer = true,
    .defer_taskrun = true,
};

inner: linux.IoUring,
entries: u16,

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

pub const InitError = error{
    /// The kernel has no IORING_FEAT_EXT_ARG, so `enter` cannot take a
    /// deadline. 5.11 or newer.
    KernelTooOld,
};

pub fn init(entries: u16, setup: Setup) !Ring {
    var params = setup.params();
    var inner: linux.IoUring = try .init_params(entries, &params);
    errdefer inner.deinit();
    // Every wait in this library enters with IORING_ENTER_EXT_ARG. Without the
    // feature the enter fails as EINVAL, which reads as a malformed SQE and
    // sends the reader hunting the wrong bug.
    if (inner.features & linux.IORING_FEAT_EXT_ARG == 0) return error.KernelTooOld;
    return .{ .inner = inner, .entries = entries };
}

pub fn deinit(self: *Ring) void {
    self.inner.deinit();
    self.* = undefined;
}

/// SQEs prepped but not published yet.
pub fn sqPending(self: *Ring) u32 {
    return self.inner.sq.sqe_tail -% self.inner.sq.sqe_head;
}

/// The room left in the submission queue.
pub fn available(self: *Ring) u32 {
    return @as(u32, self.entries) -| self.inner.sq_ready();
}

// ---- Registered resources ------------------------------------------------
//
// Ring-wide state, not per operation: registration has no tag and no
// completion. Everything the kernel lets a ring register, std encodes.

/// Register `fds` so operations can name them by index with
/// `IOSQE_FIXED_FILE` instead of paying an fd-table lookup per operation.
/// The result of assigning a file is unusable: the kernel has taken the
/// reference, and the caller's fd must close it when it is done.
pub fn registerFiles(self: *Ring, fds: []const linux.fd_t) !void {
    try self.inner.register_files(fds);
}

/// Replace `fds.len` slots starting at `offset`.
pub fn registerFilesUpdate(self: *Ring, offset: u32, fds: []const linux.fd_t) !void {
    try self.inner.register_files_update(offset, fds);
}

/// Reserve `fd_count` slots without naming any file: the indexes can be
/// filled later by operations that create a file (`*Direct`) or by
/// `registerFilesUpdate`.
pub fn registerFilesSparse(self: *Ring, fd_count: u32) !void {
    try self.inner.register_files_sparse(fd_count);
}

/// Bind slot `offset` for `len` slots to the kernel's file-index allocator,
/// so `IORING_FILE_INDEX_ALLOC` lands in that range.
pub fn registerFileAllocRange(self: *Ring, offset: u32, len: u32) !void {
    try self.inner.register_file_alloc_range(offset, len);
}

pub fn unregisterFiles(self: *Ring) !void {
    try self.inner.unregister_files();
}

/// Register `buffers` for `readFixed`/`writeFixed`/`sendZcFixed`.
pub fn registerBuffers(self: *Ring, buffers: []const posix.iovec) !void {
    try self.inner.register_buffers(buffers);
}

pub fn unregisterBuffers(self: *Ring) !void {
    try self.inner.unregister_buffers();
}

/// The ring posts a completion on `fd` (an eventfd) each time one arrives, so
/// a thread that is not entering the ring can still be woken by it.
pub fn registerEventfd(self: *Ring, fd: linux.fd_t) !void {
    try self.inner.register_eventfd(fd);
}

/// As `registerEventfd`, but the wakeup happens before the CQE is posted.
pub fn registerEventfdAsync(self: *Ring, fd: linux.fd_t) !void {
    try self.inner.register_eventfd_async(fd);
}

pub fn unregisterEventfd(self: *Ring) !void {
    try self.inner.unregister_eventfd();
}

/// NAPI busy polling for the given NAPI ids.
pub fn registerNapi(self: *Ring, napi: *linux.io_uring_napi) !void {
    try self.inner.register_napi(napi);
}

pub fn unregisterNapi(self: *Ring) !void {
    try self.inner.unregister_napi();
}

/// What this kernel's ring supports. Ask before choosing an op or a flag if
/// the deployment target's kernel is not known.
pub fn probe(self: *Ring) !linux.io_uring_probe {
    return self.inner.get_probe();
}

/// True when the ring can do `op` on this kernel.
pub fn supports(probe_result: *const linux.io_uring_probe, op: linux.IORING_OP) bool {
    const index = @backingInt(op);
    if (index >= probe_result.ops.len) return false;
    return probe_result.ops[index].flags != 0;
}

/// A blank SQE whose `user_data` is the caller's. The escape hatch: every
/// operation the loop does not wrap is still one `prep_*` away.
pub fn sqe(self: *Ring, user_data: u64) !*linux.io_uring_sqe {
    const slot = try self.getSqe();
    slot.* = mem.zeroes(linux.io_uring_sqe);
    slot.user_data = user_data;
    return slot;
}

fn getSqe(self: *Ring) !*linux.io_uring_sqe {
    return self.inner.get_sqe() catch |err| switch (err) {
        // Publishing is what frees the space: the enter behind `submit` lets
        // the kernel consume its side of the queue before we ask again.
        error.SubmissionQueueFull => blk: {
            _ = try self.inner.submit();
            break :blk try self.inner.get_sqe();
        },
        else => |e| return e,
    };
}

/// Publish the queued SQEs. Never blocks and never waits for a completion.
///
/// It always enters, even with nothing obvious to publish: SQE prep can happen
/// through `inner` without the ring noticing, so a conditional submit would
/// strand those operations. std's `submit` is the contract.
pub fn submit(self: *Ring) !void {
    _ = try self.inner.submit();
}

/// Run the completions the kernel deferred without waiting for one. Under
/// DEFER_TASKRUN these run only inside an enter, so an empty completion queue
/// is not proof that there is no work.
///
/// A signal cannot interrupt anything here: the enter asks for no completion
/// and waits for nothing, so `SignalInterrupt` is absorbed rather than handed
/// to every caller. `wait` still reports it.
pub fn poll(self: *Ring) EnterError!void {
    _ = self.enter(true, 0, null) catch |err| switch (err) {
        error.SignalInterrupt => return,
        else => |e| return e,
    };
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

pub fn cqReady(self: *Ring) u32 {
    return self.inner.cq_ready();
}

test "a ring with the default mask opens, reports its depth, and closes" {
    var ring: Ring = try .init(8, default_setup);
    defer ring.deinit();
    try testing.expectEqual(@as(u32, 8), ring.available());
}

test "a prepped SQE is one submit away and its user_data survives" {
    var ring: Ring = try .init(8, default_setup);
    defer ring.deinit();

    _ = try ring.sqe(0xDEAD_BEEF);
    try ring.submit();

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
    var ring: Ring = try .init(8, default_setup);
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
    var ring: Ring = try .init(8, default_setup);
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
    var ring: Ring = try .init(8, default_setup);
    defer ring.deinit();

    try ring.poll();

    var buf: [8]linux.io_uring_cqe = undefined;
    try testing.expectEqual(@as(u32, 0), try ring.copyCqes(&buf));
}

test "a full submission queue flushes instead of failing" {
    // Depth 8, nine preps, no submit between them. The ninth asks for room the
    // queue does not have, and gets it by publishing what is already there.
    var ring: Ring = try .init(8, default_setup);
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

test "registered files round-trip" {
    var ring: Ring = try .init(8, default_setup);
    defer ring.deinit();
    const rc = linux.open("/dev/null", .{}, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    try ring.registerFiles(&.{fd});
    try ring.registerFilesUpdate(0, &.{fd});
    try ring.unregisterFiles();
}

test "registered buffers round-trip" {
    var ring: Ring = try .init(8, default_setup);
    defer ring.deinit();
    var buf: [4096]u8 align(4096) = undefined;
    const iov: posix.iovec = .{ .base = &buf, .len = buf.len };

    try ring.registerBuffers(&.{iov});
    try ring.unregisterBuffers();
}

test "the probe names what this kernel supports" {
    var ring: Ring = try .init(8, default_setup);
    defer ring.deinit();
    const caps = try ring.probe();
    try testing.expect(caps.ops.len > 0);
    try testing.expect(supports(&caps, .NOP));
}

test "setup is a struct of named bits, not a flag word" {
    // The default is the measured pair, and it survives a round trip through
    // the raw word.
    try testing.expectEqual(
        linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_SINGLE_ISSUER,
        default_setup.flags(),
    );
    try testing.expectEqual(default_setup, Setup.fromFlags(default_setup.flags()));

    // Values imply their bits: CQSIZE without a size would be a caller bug
    // that the struct cannot express.
    const sized: Setup = .{ .cq_entries = 512, .sqpoll = true, .sq_aff = true, .sq_thread_cpu = 3 };
    try testing.expect(sized.flags() & linux.IORING_SETUP_CQSIZE != 0);
    try testing.expect(sized.flags() & linux.IORING_SETUP_SQPOLL != 0);
    try testing.expect(sized.flags() & linux.IORING_SETUP_ATTACH_WQ == 0);
    // A word cannot carry the sizes beside a bit, so those two bits come
    // back clear rather than claiming a value the caller does not have.
    const recovered = Setup.fromFlags(sized.flags());
    try testing.expectEqual(@as(u32, 0), recovered.cq_entries);
    try testing.expectEqual(
        linux.IORING_SETUP_SQPOLL | linux.IORING_SETUP_SQ_AFF,
        recovered.flags(),
    );

    const attached: Setup = .{ .wq_fd = 7 };
    try testing.expect(attached.flags() & linux.IORING_SETUP_ATTACH_WQ != 0);
    try testing.expect(Setup.fromFlags(attached.flags()).wq_fd == null);
}

test "a ring opens from a Setup, including values that ride beside a bit" {
    // CQSIZE changes the completion queue's depth, so the ring reports it.
    var ring: Ring = try .init(64, .{ .cq_entries = 128 });
    defer ring.deinit();
    try testing.expectEqual(@as(u32, 64), ring.available());
}
