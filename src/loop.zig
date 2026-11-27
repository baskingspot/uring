//! The tick: one pass over the completion queue, one enter, one dispatch.
//!
//! The loop is parameterized by the caller's tag, the value `user_data` carries
//! home. Any type that is 64 bits — a packed struct of op/slot/generation, a
//! `*Node`, a bare `u64` — works, and the loop never interprets it. That is the
//! whole interface: the caller says what a completion is, the loop only says
//! when.
//!
//! What the loop owns: the ring, the submit discipline, the enter, the cached
//! clock, the deferred queue, and the one decode from `user_data` to `Tag`.
//! What it refuses: buffers, fds, connection state, close ordering, and any
//! opinion about what a completion means. It never closes a descriptor, never
//! frees a byte, and never rearms an operation.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const clock = @import("clock.zig");

/// The kernel's provided-buffer ring. `BufferGroup.init` takes the ring:
/// `try uring.BufferGroup.init(&loop.ring.inner, allocator, group_id, size, count)`.
///
/// That constructor is `std`'s, and it requests incremental consumption: the
/// kernel retains a buffer across completions and writes further bytes at a
/// further offset, so one buffer id can produce several completions
/// (`F_BUF_MORE`). A buffer is a stream chunk, not a message. The request
/// needs kernel 6.12; `std` retries without the flag on an older kernel, which
/// gives whole-buffer mode. `initBufferGroup` registers either mode
/// explicitly, and whole-buffer mode consumes one buffer per completion.
pub const BufferGroup = linux.IoUring.BufferGroup;

/// How `initBufferGroup` registers the ring.
// ast-grep-ignore: public-struct-field-default -- options bag: call sites set the one knob
pub const BufferGroupOptions = struct {
    /// Incremental consumption (`IOU_PBUF_RING_INC`, kernel 6.12): the kernel
    /// keeps a buffer across completions, sets `F_BUF_MORE`, and writes at a
    /// further offset. One buffer id carries a stream, not a message. On an
    /// older kernel the registration falls back to whole-buffer mode.
    ///
    /// `false` is whole-buffer mode: the kernel consumes one buffer per
    /// completion, the completion carries the id and its length, and `put`
    /// returns that buffer to the ring.
    incremental: bool = true,
};

/// A provided-buffer group registered with `std`'s hardcoded choice replaced
/// by an explicit one. `std`'s `BufferGroup.init` always registers
/// incrementally; this is the same group either way, and `get`, `put`, and
/// `recvMultishot` work on both, because `put` already handles the
/// non-incremental return.
pub fn initBufferGroup(
    ring: *linux.IoUring,
    allocator: Allocator,
    group_id: u16,
    buffer_size: u32,
    buffers_count: u16,
    options: BufferGroupOptions,
) !BufferGroup {
    const buffers = try allocator.alloc(u8, buffer_size * buffers_count);
    errdefer allocator.free(buffers);
    const heads = try allocator.alloc(u32, buffers_count);
    errdefer allocator.free(heads);

    const br = try linux.IoUring.setup_buf_ring(ring.fd, buffers_count, group_id, .{
        .inc = options.incremental,
    });
    linux.IoUring.buf_ring_init(br);

    const mask = linux.IoUring.buf_ring_mask(buffers_count);
    var i: u16 = 0;
    while (i < buffers_count) : (i += 1) {
        const pos = buffer_size * i;
        heads[i] = 0;
        linux.IoUring.buf_ring_add(br, buffers[pos..][0..buffer_size], i, mask, i);
    }
    linux.IoUring.buf_ring_advance(br, buffers_count);

    return .{
        .ring = ring,
        .group_id = group_id,
        .br = br,
        .buffers = buffers,
        .heads = heads,
        .buffer_size = buffer_size,
        .buffers_count = buffers_count,
    };
}
const Ring = @import("Ring.zig").Ring;

pub fn Loop(comptime Tag: type) type {
    if (@bitSizeOf(Tag) != 64) {
        @compileError("uring: Tag must be 64 bits, because user_data is one u64. " ++
            "Use a packed struct, a pointer, or a u64 itself.");
    }
    return struct {
        const Self = @This();

        pub const TagType = Tag;

        pub const Options = struct {
            /// Submission queue depth. Must be a power of two.
            entries: u16 = 256,
            /// Ring setup. The default is deferred completions with a single
            /// issuer; a mask the kernel refuses fails at `init`.
            setup: Ring.Setup = Ring.default_setup,
            /// Where completions land before dispatch. Sized by the caller:
            /// the loop allocates nothing and holds nothing back. Bigger
            /// batches mean fewer enters and more work per tick.
            cqes: []linux.io_uring_cqe,
            /// The deferred queue: one slot per tag waiting for `nextTick`. A
            /// zero-length slice disables `nextTick`.
            deferred: []Tag = &.{},
            /// Flush the submission queue once this many slots are left. A
            /// prep that finds the queue full retries once and then fails
            /// with `error.SubmissionQueueFull`, so the loop publishes early
            /// rather than at the edge.
            sq_floor: u16 = 8,
        };

        pub const Cqe = struct {
            tag: Tag,
            /// The kernel's result: bytes moved, a descriptor, or a negative
            /// errno. Decoding it is the caller's business, because only the
            /// caller knows which operation it armed.
            res: i32,
            flags: u32,
            /// True when the loop synthesized this with `nextTick`: no kernel
            /// operation finished, and `res` is zero.
            deferred: bool = false,

            /// The errno in `res`, or `.SUCCESS`. An io_uring result uses the
            /// syscall convention, so this is the std decoder and not a
            /// second copy of it.
            pub inline fn errno(self: *const Cqe) linux.E {
                return linux.errno(self.res);
            }

            /// The operation that produced this completion is still armed and
            /// will produce more: a multishot accept or receive.
            pub inline fn more(self: *const Cqe) bool {
                return self.flags & linux.IORING_CQE_F_MORE != 0;
            }

            /// The selected buffer group's id, for a receive that used buffer
            /// selection.
            pub inline fn bufferId(self: *const Cqe) ?u16 {
                if (self.flags & linux.IORING_CQE_F_BUFFER == 0) return null;
                return @intCast(self.flags >> linux.IORING_CQE_BUFFER_SHIFT);
            }
        };

        /// How long one tick may spend waiting for work.
        pub const Wait = union(enum) {
            /// Enter on every pass, even when completions are already visible,
            /// and never wait. Under DEFER_TASKRUN only an enter runs the
            /// kernel's deferred completions, so a caller whose completion
            /// queue never empties needs this or starves them.
            poll,
            /// Copy what is ready, enter only when nothing is, and never
            /// block. The cheap pass for a caller with no such starvation.
            no_wait,
            /// Block until a completion arrives.
            once,
            /// Block until a completion arrives or `at_ns` passes on the
            /// monotonic clock, whichever comes first.
            until: i64,
        };

        pub const Stats = struct {
            ticks: u64,
            /// Completions the kernel delivered.
            cqes: u64,
            /// Tags the loop synthesized from `nextTick`.
            deferred: u64,

            const zero: Stats = .{
                .ticks = 0,
                .cqes = 0,
                .deferred = 0,
            };
        };

        ring: Ring,
        cqes: []linux.io_uring_cqe,
        deferred: []Tag,
        deferred_head: usize = 0,
        deferred_len: usize = 0,
        deferred_stopped: bool = false,
        sq_floor: u16,
        now_ns: i64 = 0,
        stopped: bool = false,
        stats: Stats = .zero,

        pub fn init(options: Options) !Self {
            if (options.cqes.len == 0) return error.NoCompletionBatch;
            if (options.sq_floor == 0) return error.NoSubmissionFloor;
            return .{
                .ring = try .init(options.entries, options.setup),
                .cqes = options.cqes,
                .deferred = options.deferred,
                .sq_floor = options.sq_floor,
                // A deadline computed from a zeroed clock is in the past, so
                // the clock starts at init.
                .now_ns = clock.monotonic(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.ring.deinit();
            self.* = undefined;
        }

        /// The tag as the ring sees it. `@bitCast` for everything that is
        /// exactly 64 bits, `@ptrToInt` for a pointer.
        pub inline fn encode(tag: Tag) u64 {
            return switch (@typeInfo(Tag)) {
                .pointer => @intFromPtr(tag),
                else => @bitCast(tag),
            };
        }

        pub inline fn decode(raw: u64) Tag {
            return switch (@typeInfo(Tag)) {
                .pointer => @ptrFromInt(raw),
                else => @bitCast(raw),
            };
        }

        /// The loop's view of one kernel completion. For a caller that copies
        /// the completion queue itself instead of going through `tick`, which
        /// is the only other place that decodes a tag from a CQE.
        pub fn fromRaw(raw: linux.io_uring_cqe) Cqe {
            return .{ .tag = decode(raw.user_data), .res = raw.res, .flags = raw.flags };
        }

        /// The monotonic timestamp of this tick, in nanoseconds. It is read
        /// once per tick, after the enter, so it is also the moment the kernel
        /// finished the work the tick waited on. Every timestamp a handler
        /// takes from here agrees within one tick.
        pub fn now(self: *const Self) i64 {
            return self.now_ns;
        }

        /// Ask the loop to finish. `run` honors this at its next tick
        /// boundary, and the batch it is in still drains: a completion that
        /// arrived is work that happened. A caller that drives `tick` itself
        /// reads `stopped` and decides, which is what lets a shutdown keep
        /// serving its last connections.
        ///
        /// Idempotent on purpose: two completions in one batch can each
        /// decide the loop is done, and that is not a bug in the caller.
        pub fn stop(self: *Self) void {
            self.stopped = true;
        }

        /// Post `tag` for dispatch on the next tick, as though it completed.
        /// A post from inside a handler runs one tick later, never in the
        /// middle of the current batch.
        /// Dispatch `tag` on the next tick, as though a completion had
        /// arrived for it: the handler sees `res` zero, no flags, and
        /// `Cqe.deferred` set. Nothing is submitted, and the kernel is not
        /// involved; this is the loop's one synthetic completion.
        ///
        /// A `nextTick` from inside a handler runs one tick later, so work
        /// that arrived while dispatching cannot extend the current pass. The
        /// queue is the caller's slice from `Options.deferred`, and a full
        /// queue returns `error.DeferredFull` rather than dropping the tag.
        pub fn nextTick(self: *Self, tag: Tag) error{DeferredFull}!void {
            if (self.deferred_len == self.deferred.len) return error.DeferredFull;
            const tail = (self.deferred_head + self.deferred_len) % self.deferred.len;
            self.deferred[tail] = tag;
            self.deferred_len += 1;
        }

        /// End this pass's deferred dispatch, leaving the rest of the queue in
        /// place and in order. A handler that cannot take any more deferred
        /// work this pass calls this instead of deferring the remainder again:
        /// deferring moves them behind whatever arrived during the pass, which
        /// starves them under a steady arrival rate. The next pass resumes at
        /// the same head.
        ///
        /// It takes effect after the current handler returns, and the tag that
        /// handler was given has already been popped: a caller must finish its
        /// work, then stop. Stopping instead of working consumes that tag
        /// undriven.
        pub fn stopDeferred(self: *Self) void {
            self.deferred_stopped = true;
        }

        /// One tick: wait, reap, dispatch, defer, submit.
        ///
        /// `handler` is `fn (ctx: anytype, loop: *Self, cqe: Cqe) !void`, known
        /// at comptime, so each completion is a direct call with no function
        /// pointer and no erased context. An error from it is returned from
        /// the tick, and the loop keeps no restart policy: the caller decides.
        /// What one tick did, for a caller whose policy depends on it: a
        /// busy-poll gate needs the gap, and the DEFER_TASKRUN rule needs to
        /// know the kernel ran its deferred completions.
        pub const Tick = struct {
            /// Completions from the kernel this tick.
            cqes: u32,
            /// Deferred tags this tick.
            deferred: u32,
            /// The tick made a GETEVENTS enter. Under DEFER_TASKRUN this is
            /// the only way the kernel runs deferred completions.
            entered: bool,
            /// That enter blocked for a completion or a deadline.
            waited: bool,
            /// When the tick started, before the enter.
            start_ns: i64,
            /// When the kernel's work became visible: after the enter, or the
            /// tick's start when it did not enter. `now_ns - start_ns` is what
            /// the tick spent entering and dispatching.
            now_ns: i64,
        };

        pub fn tick(
            self: *Self,
            ctx: anytype,
            comptime handler: anytype,
            wait: Wait,
        ) !Tick {
            return self.tickStarting(ctx, null, handler, wait);
        }

        /// `tick`, with a function called once per pass after the enter and
        /// before the first handler, receiving the pass's settled facts.
        ///
        /// A caller whose handlers read a cached clock needs exactly this
        /// point: refreshing after `tick` returns is too late, because every
        /// handler has already run on the previous pass's sample, and
        /// refreshing before the tick is too early, because it would stamp an
        /// idle worker's first post-wake work with the park-start time.
        ///
        /// `before_dispatch` is `fn (ctx: anytype, loop: *Self, done: Tick)
        /// void`, known at comptime; pass `null` for none.
        pub fn tickStarting(
            self: *Self,
            ctx: anytype,
            comptime before_dispatch: anytype,
            comptime handler: anytype,
            wait: Wait,
        ) !Tick {
            // No stop check here on purpose. The stop decision belongs to
            // whoever owns the loop's lifetime, and a tick that quietly
            // returns is a hang with no syscall to show for it. A shutdown
            // that has to finish work needs ticks after the decision.
            //
            // The tick's span needs a sample on each side of the enter:
            // callers that measure an idle gap would otherwise have to sample
            // the clock themselves, in every case.
            const start_ns = clock.monotonic();

            // The deferred count is a snapshot taken before dispatch: a tag
            // queued by a handler above runs on the next tick, so a handler
            // that queues work cannot starve the enter.
            const deferred = self.deferred_len;

            // Publish whatever is queued before reaping, so work armed outside
            // a handler is not a tick late. The guard is `sqPending`, not a
            // flag: it counts what std's prep helpers queued too, including
            // through `ring.inner`, and it is zero when a previous tick
            // already published, so it costs no syscall.
            if (self.ring.sqPending() != 0) try self.ring.submit();

            var reaped: u32 = undefined;
            var entered = false;
            var waited = false;

            switch (wait) {
                // The caller asked for an enter regardless of what is ready.
                .poll => {
                    entered = true;
                    try self.ring.poll();
                    reaped = try self.ring.copyCqes(self.cqes);
                },
                .no_wait, .once, .until => {
                    reaped = try self.ring.copyCqes(self.cqes);
                    if (reaped == 0 and deferred == 0) {
                        entered = true;
                        switch (wait) {
                            .poll => unreachable,
                            .no_wait => {
                                // Still an enter: under DEFER_TASKRUN, an
                                // empty completion queue is not proof that
                                // there is no work.
                                try self.ring.poll();
                            },
                            .once => {
                                waited = true;
                                _ = try self.ring.wait(1, null);
                            },
                            .until => |deadline_ns| {
                                const remaining = deadline_ns - clock.monotonic();
                                const wait_ns: u64 = @intCast(@max(0, remaining));
                                if (wait_ns == 0) {
                                    // The deadline already passed. Poll, which
                                    // is the same enter without a wait for a
                                    // completion that cannot arrive first.
                                    try self.ring.poll();
                                } else {
                                    waited = true;
                                    _ = try self.ring.wait(1, wait_ns);
                                }
                            },
                        }
                        // The enter may have produced completions — a poll
                        // especially, which is how a deferred completion
                        // becomes visible at all under DEFER_TASKRUN. Reap
                        // them now, not next tick.
                        reaped = try self.ring.copyCqes(self.cqes);
                    }
                },
            }

            // After the enter, so an idle worker's first post-wake work is
            // not stamped with the park-start time.
            const now_ns = clock.monotonic();
            self.now_ns = now_ns;

            const done: Tick = .{
                .cqes = reaped,
                .deferred = @intCast(deferred),
                .entered = entered,
                .waited = waited,
                .start_ns = start_ns,
                .now_ns = now_ns,
            };
            if (comptime @TypeOf(before_dispatch) != @TypeOf(null)) {
                before_dispatch(ctx, self, done);
            }

            for (self.cqes[0..reaped]) |cqe| try handler(ctx, self, Self.fromRaw(cqe));
            self.stats.cqes += reaped;

            // The snapshot bounds the pass. A handler may end it early with
            // `stopDeferred`, which leaves the remaining tags at the head, in
            // arrival order, for the next pass.
            var n = deferred;
            while (n > 0 and !self.deferred_stopped) : (n -= 1) {
                const tag = self.deferred[self.deferred_head];
                self.deferred_head = (self.deferred_head + 1) % self.deferred.len;
                self.deferred_len -= 1;
                self.stats.deferred += 1;
                try handler(ctx, self, .{ .tag = tag, .res = 0, .flags = 0, .deferred = true });
            }
            self.deferred_stopped = false;

            self.stats.ticks += 1;

            // One submit per tick, whatever the handlers queued. This is the
            // line that replaces a submit call at every arm site.
            if (self.ring.sqPending() != 0) try self.ring.submit();

            return done;
        }

        /// `tick` until `stop`. The waiting mode is comptime, so a run that
        /// never blocks pays no branch for it.
        ///
        /// `Wait.until` is one absolute deadline for the whole run, not a
        /// timeout per tick: the value is fixed when `run` is called, so
        /// `.{ .until = now + 50ms }` means "run for 50 ms" and spins after
        /// that. A deadline that moves, such as a connection's idle timeout,
        /// means calling `tick` in the caller's own loop with a deadline
        /// computed from the loop's clock each pass.
        pub fn run(
            self: *Self,
            ctx: anytype,
            comptime handler: anytype,
            comptime wait: Wait,
        ) !void {
            while (!self.stopped) _ = try self.tick(ctx, handler, wait);
        }

        /// A blank SQE with this tag: the escape hatch for an operation the
        /// loop does not wrap. The caller sets the opcode and its arguments,
        /// and the loop submits it at the end of the tick.
        pub fn sqe(self: *Self, tag: Tag) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.sqe(Self.encode(tag));
        }

        pub fn nop(self: *Self, tag: Tag) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.nop(Self.encode(tag));
        }

        /// A multishot accept. Every completion keeps `IORING_CQE_F_MORE` set
        /// until the operation ends, so one accept answers many connections.
        pub fn acceptMultishot(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            addr: ?*posix.sockaddr,
            addrlen: ?*posix.socklen_t,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.accept_multishot(Self.encode(tag), fd, addr, addrlen, flags);
        }

        pub fn connect(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            addr: *const posix.sockaddr,
            addrlen: posix.socklen_t,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.connect(Self.encode(tag), fd, addr, addrlen);
        }

        pub fn recv(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            buffer: Ring.RecvBuffer,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.recv(Self.encode(tag), fd, buffer, flags);
        }

        pub fn recvmsg(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            msg: *linux.msghdr,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.recvmsg(Self.encode(tag), fd, msg, flags);
        }

        pub fn send(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            buffer: []const u8,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.send(Self.encode(tag), fd, buffer, flags);
        }

        pub fn sendmsg(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            msg: *const linux.msghdr_const,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.sendmsg(Self.encode(tag), fd, msg, flags);
        }

        /// Close a descriptor on the ring. The caller still owns the lifetime
        /// question: the kernel borrows buffers until the operation completes,
        /// so a slot can only be reused after this completion lands.
        pub fn close(self: *Self, tag: Tag, fd: linux.fd_t) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.close(Self.encode(tag), fd);
        }

        /// Cancel a request by its tag. A cancel finds only requests the
        /// kernel already holds, so the queued submissions go out first:
        /// without that, cancelling an operation armed moments ago returns
        /// ENOENT and the target runs on.
        pub fn cancel(
            self: *Self,
            tag: Tag,
            target: Tag,
            flags: u32,
        ) !*linux.io_uring_sqe {
            if (self.ring.sqPending() != 0) try self.ring.submit();
            try self.room();
            return self.ring.inner.cancel(Self.encode(tag), Self.encode(target), flags);
        }

        /// One `IORING_OP_TIMEOUT`, for a caller that wants the kernel to own
        /// the clock. The loop's own deadlines ride the enter and need no
        /// operation; this exists for a deadline that outlives one tick or
        /// must fire while the loop is busy.
        pub fn timeout(
            self: *Self,
            tag: Tag,
            deadline: *const linux.kernel_timespec,
            count: u32,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.timeout(Self.encode(tag), deadline, count, flags);
        }

        pub fn pollAdd(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            poll_mask: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.poll_add(Self.encode(tag), fd, poll_mask);
        }

        pub fn shutdown(
            self: *Self,
            tag: Tag,
            sockfd: posix.socket_t,
            how: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.shutdown(Self.encode(tag), sockfd, how);
        }

        // ---- The rest of the operation set ----------------------------------
        //
        // One wrapper per op `std.os.linux.IoUring` encodes. Each takes the
        // caller's tag in place of a raw user_data, publishes when the queue
        // is near full, and returns the SQE so every flag stays the caller's.
        //
        // Registered files: pass the index where an fd goes and set
        // `IOSQE_FIXED_FILE` on the returned SQE, as liburing requires. The
        // `*Direct` variants below are the ones liburing also has: they take
        // the destination index for a newly created file.

        pub fn fsync(self: *Self, tag: Tag, fd: linux.fd_t, flags: u32) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.fsync(Self.encode(tag), fd, flags);
        }

        pub fn read(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            buffer: Ring.ReadBuffer,
            offset: u64,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.read(Self.encode(tag), fd, buffer, offset);
        }

        pub fn write(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            buffer: []const u8,
            offset: u64,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.write(Self.encode(tag), fd, buffer, offset);
        }

        /// Both ends registered: `IOSQE_FIXED_FILE` on each, and the offsets
        /// are ignored (io_uring splices at the file positions).
        pub fn splice(
            self: *Self,
            tag: Tag,
            fd_in: linux.fd_t,
            off_in: u64,
            fd_out: linux.fd_t,
            off_out: u64,
            len: usize,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.splice(Self.encode(tag), fd_in, off_in, fd_out, off_out, len);
        }

        /// `buffer` must have been registered with `ring.registerBuffers`, and
        /// `buffer_index` is its index there.
        pub fn readFixed(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            buffer: *posix.iovec,
            offset: u64,
            buffer_index: u16,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.read_fixed(
                Self.encode(tag),
                fd,
                buffer,
                offset,
                buffer_index,
            );
        }

        pub fn writev(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            iovecs: []const posix.iovec_const,
            offset: u64,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.writev(Self.encode(tag), fd, iovecs, offset);
        }

        pub fn writeFixed(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            buffer: *posix.iovec,
            offset: u64,
            buffer_index: u16,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.write_fixed(
                Self.encode(tag),
                fd,
                buffer,
                offset,
                buffer_index,
            );
        }

        /// A single accept. `acceptMultishot` above is the one that keeps
        /// producing completions from one SQE.
        pub fn accept(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            addr: ?*posix.sockaddr,
            addrlen: ?*posix.socklen_t,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.accept(Self.encode(tag), fd, addr, addrlen, flags);
        }

        /// Accept into registered file slot `file_index` (see
        /// `ring.registerFiles`), or `IORING_FILE_INDEX_ALLOC` to let the
        /// kernel pick.
        pub fn acceptDirect(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            addr: ?*posix.sockaddr,
            addrlen: ?*posix.socklen_t,
            flags: u32,
            file_index: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            // std's convenience pins this to IORING_FILE_INDEX_ALLOC; the
            // kernel takes any slot the caller reserved.
            const direct = try self.ring.inner.get_sqe();
            direct.prep_accept_direct(fd, addr, addrlen, flags, file_index);
            direct.user_data = Self.encode(tag);
            return direct;
        }

        pub fn acceptMultishotDirect(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            addr: ?*posix.sockaddr,
            addrlen: ?*posix.socklen_t,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.accept_multishot_direct(
                Self.encode(tag),
                fd,
                addr,
                addrlen,
                flags,
            );
        }

        pub fn epollCtl(
            self: *Self,
            tag: Tag,
            epfd: linux.fd_t,
            fd: linux.fd_t,
            op: u32,
            ev: ?*linux.epoll_event,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.epoll_ctl(Self.encode(tag), epfd, fd, op, ev);
        }

        /// Zerocopy send. Produces two completions: the result, then a
        /// notification (`IORING_CQE_F_NOTIF`) that the buffer is free.
        pub fn sendZc(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            buffer: []const u8,
            send_flags: u32,
            zc_flags: u16,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.send_zc(Self.encode(tag), fd, buffer, send_flags, zc_flags);
        }

        pub fn sendZcFixed(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            buffer: []const u8,
            send_flags: u32,
            zc_flags: u16,
            buffer_index: u16,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.send_zc_fixed(
                Self.encode(tag),
                fd,
                buffer,
                send_flags,
                zc_flags,
                buffer_index,
            );
        }

        pub fn sendmsgZc(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            msg: *const linux.msghdr_const,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.sendmsg_zc(Self.encode(tag), fd, msg, flags);
        }

        pub fn openat(
            self: *Self,
            tag: Tag,
            dir_fd: linux.fd_t,
            path: [*:0]const u8,
            flags: linux.O,
            mode: posix.mode_t,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.openat(Self.encode(tag), dir_fd, path, flags, mode);
        }

        /// Open into registered file slot `file_index`.
        pub fn openatDirect(
            self: *Self,
            tag: Tag,
            dir_fd: linux.fd_t,
            path: [*:0]const u8,
            flags: linux.O,
            mode: posix.mode_t,
            file_index: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.openat_direct(
                Self.encode(tag),
                dir_fd,
                path,
                flags,
                mode,
                file_index,
            );
        }

        /// Close registered file slot `file_index`.
        pub fn closeDirect(self: *Self, tag: Tag, file_index: u32) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.close_direct(Self.encode(tag), file_index);
        }

        /// Cancel a timeout armed with `timeout` by its tag.
        pub fn timeoutRemove(
            self: *Self,
            tag: Tag,
            target: Tag,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.timeout_remove(Self.encode(tag), Self.encode(target), flags);
        }

        /// A timeout linked to the SQE before it, so it fires only if that
        /// operation has not completed.
        pub fn linkTimeout(
            self: *Self,
            tag: Tag,
            deadline: *const linux.kernel_timespec,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.link_timeout(Self.encode(tag), deadline, flags);
        }

        pub fn pollRemove(self: *Self, tag: Tag, target: Tag) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.poll_remove(Self.encode(tag), Self.encode(target));
        }

        pub fn pollUpdate(
            self: *Self,
            tag: Tag,
            old: Tag,
            new: Tag,
            poll_mask: u32,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.poll_update(
                Self.encode(tag),
                Self.encode(old),
                Self.encode(new),
                poll_mask,
                flags,
            );
        }

        pub fn fallocate(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            mode: i32,
            offset: u64,
            len: u64,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.fallocate(Self.encode(tag), fd, mode, offset, len);
        }

        pub fn statx(
            self: *Self,
            tag: Tag,
            dir_fd: linux.fd_t,
            path: [:0]const u8,
            flags: u32,
            mask: linux.STATX,
            buf: *linux.Statx,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.statx(Self.encode(tag), dir_fd, path, flags, mask, buf);
        }

        pub fn renameat(
            self: *Self,
            tag: Tag,
            old_dir_fd: linux.fd_t,
            old_path: [*:0]const u8,
            new_dir_fd: linux.fd_t,
            new_path: [*:0]const u8,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.renameat(
                Self.encode(tag),
                old_dir_fd,
                old_path,
                new_dir_fd,
                new_path,
                flags,
            );
        }

        pub fn unlinkat(
            self: *Self,
            tag: Tag,
            dir_fd: linux.fd_t,
            path: [*:0]const u8,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.unlinkat(Self.encode(tag), dir_fd, path, flags);
        }

        pub fn mkdirat(
            self: *Self,
            tag: Tag,
            dir_fd: linux.fd_t,
            path: [*:0]const u8,
            mode: posix.mode_t,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.mkdirat(Self.encode(tag), dir_fd, path, mode);
        }

        pub fn symlinkat(
            self: *Self,
            tag: Tag,
            target: [*:0]const u8,
            new_dir_fd: linux.fd_t,
            link_path: [*:0]const u8,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.symlinkat(Self.encode(tag), target, new_dir_fd, link_path);
        }

        pub fn linkat(
            self: *Self,
            tag: Tag,
            old_dir_fd: linux.fd_t,
            old_path: [*:0]const u8,
            new_dir_fd: linux.fd_t,
            new_path: [*:0]const u8,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.linkat(
                Self.encode(tag),
                old_dir_fd,
                old_path,
                new_dir_fd,
                new_path,
                flags,
            );
        }

        pub fn waitid(
            self: *Self,
            tag: Tag,
            id_type: linux.P,
            id: i32,
            infop: *linux.siginfo_t,
            options: u32,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.waitid(Self.encode(tag), id_type, id, infop, options, flags);
        }

        pub fn socket(
            self: *Self,
            tag: Tag,
            domain: u32,
            socket_type: u32,
            protocol: u32,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.socket(Self.encode(tag), domain, socket_type, protocol, flags);
        }

        /// Socket into registered file slot `file_index`.
        pub fn socketDirect(
            self: *Self,
            tag: Tag,
            domain: u32,
            socket_type: u32,
            protocol: u32,
            flags: u32,
            file_index: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.socket_direct(
                Self.encode(tag),
                domain,
                socket_type,
                protocol,
                flags,
                file_index,
            );
        }

        /// Socket into a slot the kernel picks (`IORING_FILE_INDEX_ALLOC`).
        /// The completion's `res` is the index.
        pub fn socketDirectAlloc(
            self: *Self,
            tag: Tag,
            domain: u32,
            socket_type: u32,
            protocol: u32,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.socket_direct_alloc(
                Self.encode(tag),
                domain,
                socket_type,
                protocol,
                flags,
            );
        }

        pub fn bind(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            addr: *const posix.sockaddr,
            addrlen: posix.socklen_t,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.bind(Self.encode(tag), fd, addr, addrlen, flags);
        }

        pub fn listen(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            backlog: usize,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.listen(Self.encode(tag), fd, backlog, flags);
        }

        /// `IORING_OP_URING_CMD` on a socket: the only uring_cmd std encodes.
        pub fn cmdSock(
            self: *Self,
            tag: Tag,
            cmd_op: linux.IO_URING_SOCKET_OP,
            fd: linux.fd_t,
            level: u32,
            optname: u32,
            optval: u64,
            optlen: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.cmd_sock(
                Self.encode(tag),
                cmd_op,
                fd,
                level,
                optname,
                optval,
                optlen,
            );
        }

        pub fn setsockopt(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            level: u32,
            optname: u32,
            opt: []const u8,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.setsockopt(Self.encode(tag), fd, level, optname, opt);
        }

        pub fn getsockopt(
            self: *Self,
            tag: Tag,
            fd: linux.fd_t,
            level: u32,
            optname: u32,
            opt: []u8,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.getsockopt(Self.encode(tag), fd, level, optname, opt);
        }

        /// Multishot receive over a provided-buffer group: one SQE, one
        /// `IORING_CQE_F_BUFFER` completion per buffer, until the operation
        /// ends. In incremental mode (the default constructor) a buffer can
        /// carry several completions and a completion is a chunk; with
        /// `initBufferGroup(..., .{ .incremental = false })` one completion is
        /// one whole buffer. Return it with `bufferPut`.
        ///
        /// When the group empties before a buffer is returned, the operation
        /// ends with `-ENOBUFS`, `more()` clear, and no `F_BUFFER`. That is
        /// flow control: re-arm the receive rather than closing the socket.
        pub fn recvMultishot(
            self: *Self,
            tag: Tag,
            group: *BufferGroup,
            fd: linux.fd_t,
            flags: u32,
        ) !*linux.io_uring_sqe {
            try self.room();
            return group.recv_multishot(Self.encode(tag), fd, flags);
        }

        /// The bytes a provided-buffer completion filled, by its buffer id.
        pub fn bufferGet(_: *Self, group: *BufferGroup, cqe: Cqe) ![]u8 {
            const id = cqe.bufferId() orelse return error.NoBufferSelected;
            return group.get_by_id(id)[0..@intCast(cqe.res)];
        }

        /// Give the buffer back to the kernel. `IORING_CQE_F_BUF_MORE` means
        /// the kernel retained it and will write at a further offset; without
        /// the flag the whole buffer is returned to the ring for reuse.
        pub fn bufferPut(_: *Self, group: *BufferGroup, cqe: Cqe) !void {
            try group.put(.{
                .user_data = 0,
                .res = cqe.res,
                .flags = cqe.flags,
            });
        }

        /// Give a buffer group to the kernel the old way, one
        /// `IORING_OP_PROVIDE_BUFFERS` per call. `BufferGroup` uses the
        /// registered ring instead; this exists for the op itself.
        pub fn provideBuffers(
            self: *Self,
            tag: Tag,
            buffers: [*]u8,
            buffer_size: usize,
            buffers_count: usize,
            group_id: usize,
            buffer_id: usize,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.provide_buffers(
                Self.encode(tag),
                buffers,
                buffer_size,
                buffers_count,
                group_id,
                buffer_id,
            );
        }

        /// Take back buffers provided with `provideBuffers`.
        pub fn removeBuffers(
            self: *Self,
            tag: Tag,
            buffers_count: usize,
            group_id: usize,
        ) !*linux.io_uring_sqe {
            try self.room();
            return self.ring.inner.remove_buffers(Self.encode(tag), buffers_count, group_id);
        }

        /// Publish the submission queue before it fills. A prep that finds it
        /// full loses the operation, so the loop spends the syscall early.
        /// After the enter behind `submit`, the kernel has consumed its side
        /// and the next prep has room.
        inline fn room(self: *Self) !void {
            if (self.ring.available() < self.sq_floor) try self.ring.submit();
        }
    };
}
