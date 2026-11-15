//! The tick: one pass over the completion queue, one enter, one dispatch.
//!
//! The loop is parameterized by the caller's tag, the value `user_data` carries
//! home. Any type that is 64 bits — a packed struct of op/slot/generation, a
//! `*Node`, a bare `u64` — works, and the loop never interprets it. That is the
//! whole interface: the caller says what a completion is, the loop only says
//! when.
//!
//! What the loop owns: the ring, the submit discipline, the enter, the cached
//! clock, the posted queue, and the one decode from `user_data` to `Tag`.
//! What it refuses: buffers, fds, connection state, close ordering, and any
//! opinion about what a completion means. It never closes a descriptor, never
//! frees a byte, and never rearms an operation.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;

const clock = @import("clock.zig");
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
            /// The io_uring setup mask. The default is DEFER_TASKRUN with
            /// SINGLE_ISSUER; an unsupported mask fails at `init`.
            flags: u32 = Ring.default_flags,
            /// Where completions land before dispatch. Sized by the caller:
            /// the loop allocates nothing and holds nothing back. Bigger
            /// batches mean fewer enters and more work per tick.
            cqes: []linux.io_uring_cqe,
            /// The posted queue, one slot per pending `post`. A zero-length
            /// slice disables `post`.
            posted: []Tag = &.{},
            /// Flush the submission queue once this many slots are left. A
            /// prep that finds the queue full loses the operation, so the
            /// loop publishes early rather than at the edge.
            sq_floor: u16 = 8,
        };

        pub const Cqe = struct {
            tag: Tag,
            /// The kernel's result: bytes moved, a descriptor, or a negative
            /// errno. Decoding it is the caller's business, because only the
            /// caller knows which operation it armed.
            res: i32,
            flags: u32,
            /// True when the loop synthesized this from `post`: no kernel
            /// operation finished, and `res` is zero.
            posted: bool = false,

            /// The errno in `res`, or `.SUCCESS`. An io_uring result uses the
            /// syscall convention, so this is the std decoder and not a
            /// second copy of it.
            pub fn errno(self: *const Cqe) linux.E {
                return linux.errno(self.res);
            }

            /// The operation that produced this completion is still armed and
            /// will produce more: a multishot accept or receive.
            pub fn more(self: Cqe) bool {
                return self.flags & linux.IORING_CQE_F_MORE != 0;
            }

            /// The selected buffer group's id, for a receive that used buffer
            /// selection.
            pub fn bufferId(self: Cqe) ?u16 {
                if (self.flags & linux.IORING_CQE_F_BUFFER == 0) return null;
                return @intCast(self.flags >> linux.IORING_CQE_BUFFER_SHIFT);
            }
        };

        /// How long one tick may spend waiting for work.
        pub const Wait = union(enum) {
            /// Copy what is ready and return. Never blocks.
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
            /// Tags the loop synthesized from `post`.
            posted: u64,
            /// Time inside the enter.
            kernel_ns: i64,
            /// Time inside the caller's handler.
            dispatch_ns: i64,

            const zero: Stats = .{
                .ticks = 0,
                .cqes = 0,
                .posted = 0,
                .kernel_ns = 0,
                .dispatch_ns = 0,
            };
        };

        ring: Ring,
        cqes: []linux.io_uring_cqe,
        posted: []Tag,
        posted_head: usize = 0,
        posted_len: usize = 0,
        sq_floor: u16,
        now_ns: i64 = 0,
        stopped: bool = false,
        stats: Stats = .zero,

        pub fn init(options: Options) !Self {
            if (options.cqes.len == 0) return error.NoCompletionBatch;
            if (options.sq_floor == 0) return error.NoSubmissionFloor;
            return .{
                .ring = try .init(options.entries, options.flags),
                .cqes = options.cqes,
                .posted = options.posted,
                .sq_floor = options.sq_floor,
                // A deadline computed from a zeroed clock is a deadline in
                // the past, so the clock starts at init, not at the first tick.
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

        /// The monotonic timestamp of this tick, in nanoseconds. It is read
        /// once per tick and after the enter, so every timestamp a handler
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
        pub fn post(self: *Self, tag: Tag) error{PostedFull}!void {
            if (self.posted_len == self.posted.len) return error.PostedFull;
            const tail = (self.posted_head + self.posted_len) % self.posted.len;
            self.posted[tail] = tag;
            self.posted_len += 1;
        }

        /// One tick: wait, reap, dispatch, post, submit.
        ///
        /// `handler` is `fn (ctx: anytype, loop: *Self, cqe: Cqe) !void`, known
        /// at comptime, so each completion is a direct call with no function
        /// pointer and no erased context. An error from it is returned from
        /// the tick, and the loop keeps no restart policy: the caller decides.
        pub fn tick(
            self: *Self,
            ctx: anytype,
            comptime handler: anytype,
            wait: Wait,
        ) !void {
            // No stop check here on purpose. The stop decision belongs to
            // whoever owns the loop's lifetime, and a tick that quietly
            // returns is a hang with no syscall to show for it. A shutdown
            // that has to finish work needs ticks after the decision.
            // The posted count is a snapshot taken before dispatch: one
            // posted from a handler above runs on the next tick, so a handler
            // that posts cannot starve the enter.
            const posted = self.posted_len;

            // Publish whatever was queued since the last tick before reaping,
            // so work armed outside a handler is not a tick late.
            try self.ring.submit();

            var now_ns = clock.monotonic();
            var reaped: u32 = try self.ring.copyCqes(self.cqes);

            if (reaped == 0 and posted == 0) {
                const kernel_start = clock.monotonic();
                switch (wait) {
                    .no_wait => {
                        // Still an enter: under DEFER_TASKRUN, an empty
                        // completion queue is not proof that there is no work.
                        self.ring.poll() catch |err| switch (err) {
                            error.SignalInterrupt => {},
                            else => |e| return e,
                        };
                    },
                    .once => {
                        const waited = self.ring.wait(1, null) catch |err| switch (err) {
                            // A signal is an external wakeup, not a fault:
                            // nothing was lost, and the next tick retries.
                            error.SignalInterrupt => return,
                            else => |e| return e,
                        };
                        if (!waited.timed_out) reaped = try self.ring.copyCqes(self.cqes);
                    },
                    .until => |deadline_ns| {
                        const wait_ns: u64 = @intCast(@max(0, deadline_ns - kernel_start));
                        if (wait_ns == 0) {
                            // The deadline already passed. Poll, which is the
                            // same enter without a wait for a completion that
                            // cannot arrive before it.
                            self.ring.poll() catch |err| switch (err) {
                                error.SignalInterrupt => {},
                                else => |e| return e,
                            };
                        } else {
                            const waited = self.ring.wait(1, wait_ns) catch |err| switch (err) {
                                error.SignalInterrupt => return,
                                else => |e| return e,
                            };
                            if (!waited.timed_out) reaped = try self.ring.copyCqes(self.cqes);
                        }
                    },
                }
                self.stats.kernel_ns += clock.monotonic() - kernel_start;
                // Refresh after the sleep: a timestamp taken before it would
                // stamp the first work of the day with the park's start.
                now_ns = clock.monotonic();
            }
            self.now_ns = now_ns;

            const dispatch_start = clock.monotonic();
            for (self.cqes[0..reaped]) |cqe| {
                const completion: Cqe = .{
                    .tag = decode(cqe.user_data),
                    .res = cqe.res,
                    .flags = cqe.flags,
                };
                try handler(ctx, self, completion);
            }
            self.stats.cqes += reaped;

            var n = posted;
            while (n > 0) : (n -= 1) {
                const tag = self.posted[self.posted_head];
                self.posted_head = (self.posted_head + 1) % self.posted.len;
                self.posted_len -= 1;
                self.stats.posted += 1;
                try handler(ctx, self, .{ .tag = tag, .res = 0, .flags = 0, .posted = true });
            }
            self.stats.dispatch_ns += clock.monotonic() - dispatch_start;
            self.stats.ticks += 1;

            // One submit per tick, whatever the handlers queued. This is the
            // line that replaces a submit call at every arm site.
            try self.ring.submit();
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
            while (!self.stopped) try self.tick(ctx, handler, wait);
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

        pub fn cancel(
            self: *Self,
            tag: Tag,
            target: Tag,
            flags: u32,
        ) !*linux.io_uring_sqe {
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

        /// Publish the submission queue before it fills. A prep that finds it
        /// full loses the operation, so the loop spends the syscall early.
        /// After the enter behind `submit`, the kernel has consumed its side
        /// and the next prep has room.
        inline fn room(self: *Self) !void {
            if (self.ring.available() < self.sq_floor) {
                _ = try self.ring.inner.submit();
            }
            self.ring.dirty = true;
        }
    };
}
