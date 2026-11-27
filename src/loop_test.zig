//! The loop's tests. Every one of them runs a real ring: this library's claims
//! are about the kernel's behavior, and a mock would prove nothing about the
//! enter.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;

const Loop = @import("loop.zig").Loop;
const BufferGroup = @import("loop.zig").BufferGroup;
const initBufferGroup = @import("loop.zig").initBufferGroup;

/// A packed tag in handoff's shape: an operation, a slot, and a generation that
/// makes a stale completion detectable.
const Tag = packed struct(u64) {
    op: Op,
    slot: u16,
    gen: u16,
    spare: u24 = 0,

    const Op = enum(u8) { recv, send, timer, _ };
};

const Wait = Loop(Tag).Wait;

const App = struct {
    seen: [16]Tag = undefined,
    results: [16]i32 = undefined,
    count: usize = 0,
    deferred_seen: usize = 0,
    stop_at: usize = 0,
    defer_back: bool = false,

    fn onCompletion(app: *App, loop: *Loop(Tag), cqe: Loop(Tag).Cqe) !void {
        if (app.count == app.seen.len) return error.BatchFull;
        app.seen[app.count] = cqe.tag;
        app.results[app.count] = cqe.res;
        app.count += 1;
        if (cqe.deferred) app.deferred_seen += 1;
        if (app.defer_back and cqe.tag.op == .send) try loop.nextTick(cqe.tag);
        if (app.stop_at != 0 and app.count == app.stop_at) loop.stop();
    }
};

test "a tag of op, slot, and generation survives the ring unchanged" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    const tag: Tag = .{ .op = .recv, .slot = 0xBEEF, .gen = 0x1234 };
    _ = try loop.nop(tag);

    var app: App = .{};
    _ = try loop.tick(&app, App.onCompletion, .once);

    try testing.expectEqual(@as(usize, 1), app.count);
    try testing.expectEqual(@as(u16, 0xBEEF), app.seen[0].slot);
    try testing.expectEqual(@as(u16, 0x1234), app.seen[0].gen);
    try testing.expectEqual(Tag.Op.recv, app.seen[0].op);
    try testing.expectEqual(@as(usize, 0), app.deferred_seen);
}

test "a pointer tag works the same way" {
    const Node = struct { completed: bool = false };
    var node: Node = .{};
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(*Node) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    _ = try loop.nop(&node);
    _ = try loop.tick({}, struct {
        fn on(_: void, _: *Loop(*Node), cqe: Loop(*Node).Cqe) !void {
            cqe.tag.completed = true;
        }
    }.on, .once);

    try testing.expect(node.completed);
}

test "one tick dispatches a batch, then submits nothing left behind" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    for (0..4) |i| {
        _ = try loop.nop(.{ .op = .timer, .slot = @intCast(i), .gen = 1 });
    }
    var app: App = .{};
    _ = try loop.tick(&app, App.onCompletion, .once);

    try testing.expectEqual(@as(usize, 4), app.count);
    try testing.expectEqual(@as(u64, 4), loop.stats.cqes);
    try testing.expectEqual(@as(u64, 1), loop.stats.ticks);
}

test "a handler that submits mid-batch does not re-enter the copy path" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 16, .cqes = &cqes, .sq_floor = 4 });
    defer loop.deinit();

    const Arm = struct {
        fn on(_: void, l: *Loop(Tag), cqe: Loop(Tag).Cqe) !void {
            // Four completions produce four more operations, from inside the
            // dispatch loop. The new completions land next tick.
            if (cqe.tag.gen == 0) {
                _ = try l.nop(.{ .op = .timer, .slot = cqe.tag.slot, .gen = 1 });
            }
        }
    };

    for (0..4) |i| {
        _ = try loop.nop(.{ .op = .timer, .slot = @intCast(i), .gen = 0 });
    }
    _ = try loop.tick({}, Arm.on, .once);

    var buf: [8]linux.io_uring_cqe = undefined;
    try testing.expectEqual(@as(u32, 4), try loop.ring.copyCqes(&buf));
}

test "the enter deadline ends a tick with nothing in flight" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    var app: App = .{};
    const start = loop.now();
    _ = try loop.tick(&app, App.onCompletion, .{ .until = start + 20 * std.time.ns_per_ms });

    const elapsed = loop.now() - start;
    try testing.expect(elapsed >= 20 * std.time.ns_per_ms);
    try testing.expect(elapsed < 2 * std.time.ns_per_s);
    // The clock was refreshed after the sleep, not before it.
    try testing.expect(loop.now() > start);
}

test "nextTick dispatches without a kernel completion, one tick later" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var deferred: [4]Tag = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .deferred = &deferred });
    defer loop.deinit();

    const tag: Tag = .{ .op = .send, .slot = 1, .gen = 1 };
    try loop.nextTick(tag);

    var app: App = .{};
    _ = try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expectEqual(@as(usize, 1), app.count);
    try testing.expectEqual(@as(usize, 1), app.deferred_seen);
    try testing.expectEqual(@as(u16, 1), app.seen[0].slot);
    try testing.expectEqual(@as(u64, 0), loop.stats.cqes);
}

test "a nextTick from a handler runs on the next tick, never inside the batch" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var deferred: [4]Tag = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .deferred = &deferred });
    defer loop.deinit();

    _ = try loop.nop(.{ .op = .send, .slot = 5, .gen = 1 });

    var app: App = .{ .defer_back = true };
    _ = try loop.tick(&app, App.onCompletion, .once);
    // The completion was dispatched, and its handler queued one post.
    try testing.expectEqual(@as(usize, 1), app.count);
    try testing.expectEqual(@as(usize, 0), app.deferred_seen);
    try testing.expectEqual(@as(usize, 1), loop.deferred_len);

    _ = try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expectEqual(@as(usize, 2), app.count);
    try testing.expectEqual(@as(usize, 1), app.deferred_seen);
}

test "a full deferred queue refuses rather than dropping" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var deferred: [1]Tag = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .deferred = &deferred });
    defer loop.deinit();

    const tag: Tag = .{ .op = .timer, .slot = 0, .gen = 0 };
    try loop.nextTick(tag);
    try testing.expectError(error.DeferredFull, loop.nextTick(tag));

    var none: [0]Tag = undefined;
    var loop_none: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .deferred = &none });
    defer loop_none.deinit();
    try testing.expectError(error.DeferredFull, loop_none.nextTick(tag));
}

test "run ticks until a handler stops it" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    _ = try loop.nop(.{ .op = .timer, .slot = 0, .gen = 0 });
    _ = try loop.nop(.{ .op = .timer, .slot = 1, .gen = 0 });

    var app: App = .{ .stop_at = 1 };
    try loop.run(&app, App.onCompletion, .no_wait);

    try testing.expect(loop.stopped);
    // stop() is checked between ticks, not inside a batch: a completion that
    // arrived is work that happened, and the rest of the batch still runs.
    try testing.expectEqual(@as(usize, 2), app.count);
}

test "an error from a handler returns from the tick and the loop keeps its batch" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    _ = try loop.nop(.{ .op = .timer, .slot = 0, .gen = 0 });

    var app: App = .{ .count = 16 };
    try testing.expectError(error.BatchFull, loop.tick(&app, App.onCompletion, .once));
    // Not stopped: the caller decides whether a handler error ends the program.
    try testing.expect(!loop.stopped);
}

test "tick ignores stop, because a shutdown still has work to do" {
    // The drain shape: the app decided to finish, and still has to serve the
    // connections it holds. A tick that no-ops after stop would make that
    // impossible without a second flag.
    var cqes: [8]linux.io_uring_cqe = undefined;
    var deferred: [4]Tag = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .deferred = &deferred });
    defer loop.deinit();

    var app: App = .{};
    loop.stop();
    try testing.expect(loop.stopped);

    // run does nothing now.
    try loop.run(&app, App.onCompletion, .no_wait);
    try testing.expectEqual(@as(usize, 0), app.count);

    // tick still does one pass.
    try loop.nextTick(.{ .op = .timer, .slot = 3, .gen = 1 });
    _ = try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expectEqual(@as(usize, 1), app.count);
    try testing.expectEqual(@as(u16, 3), app.seen[0].slot);
}

test "a cancel publishes what is still queued, or it finds nothing" {
    var fds: [2]linux.fd_t = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };

    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    const polled: Tag = .{ .op = .timer, .slot = 1, .gen = 1 };
    const cancelled: Tag = .{ .op = .send, .slot = 2, .gen = 1 };

    // An empty pipe never becomes readable, and nothing is submitted: the
    // poll is in the userspace queue when the cancel is prepped.
    _ = try loop.pollAdd(polled, fds[0], linux.POLL.IN);
    try testing.expect(loop.ring.sqPending() != 0);
    _ = try loop.cancel(cancelled, polled, 0);

    var app: App = .{};
    _ = try loop.tick(&app, App.onCompletion, .once);
    _ = try loop.tick(&app, App.onCompletion, .once);

    try testing.expectEqual(@as(usize, 2), app.count);
    // The cancel found the poll, because it was published first.
    try testing.expectEqual(Tag.Op.send, app.seen[0].op);
    try testing.expectEqual(@as(i32, 0), app.results[0]);
    // And the poll it cancelled ended in ECANCELED.
    try testing.expectEqual(Tag.Op.timer, app.seen[1].op);
    try testing.expectEqual(linux.E.CANCELED, linux.errno(app.results[1]));
}

test "a tick reports the facts a caller's policy needs" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    var app: App = .{};
    _ = try loop.nop(.{ .op = .timer, .slot = 1, .gen = 1 });

    // A tick with work already complete does not enter.
    const busy = try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expectEqual(@as(u32, 1), busy.cqes);
    try testing.expectEqual(@as(u32, 0), busy.deferred);
    try testing.expect(!busy.entered);
    try testing.expect(!busy.waited);
    try testing.expect(loop.now() > 0);

    // An idle tick enters: under DEFER_TASKRUN that is the only way the
    // kernel runs its deferred completions.
    const idle = try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expectEqual(@as(u32, 0), idle.cqes);
    try testing.expect(idle.entered);
    try testing.expect(!idle.waited);

    // A deadline tick waits, and says so; the timestamps bracket it.
    const start = loop.now();
    const until: Wait = .{ .until = start + 10 * std.time.ns_per_ms };
    const timed = try loop.tick(&app, App.onCompletion, until);
    try testing.expect(timed.entered);
    try testing.expect(timed.waited);
    try testing.expect(timed.now_ns - timed.start_ns >= 10 * std.time.ns_per_ms);
}

test "a polling tick reaps what its own poll revealed" {
    // DEFER_TASKRUN leaves a ready eventfd invisible until an enter. A tick
    // that polls must copy afterwards, or the completion it just made visible
    // waits for the next tick.
    var ev: [1]linux.fd_t = undefined;
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    ev[0] = @intCast(rc);
    defer _ = linux.close(ev[0]);

    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    const tag: Tag = .{ .op = .timer, .slot = 9, .gen = 1 };
    _ = try loop.pollAdd(tag, ev[0], linux.POLL.IN);
    try loop.ring.submit();
    const one: u64 = 1;
    try testing.expectEqual(@as(usize, 8), linux.write(ev[0], @ptrCast(&one), 8));
    try testing.expectEqual(@as(u32, 0), loop.ring.cqReady());

    var app: App = .{};
    const ticked = try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expect(ticked.entered);
    try testing.expectEqual(@as(u32, 1), ticked.cqes);
    try testing.expectEqual(@as(usize, 1), app.count);
    try testing.expectEqual(@as(u16, 9), app.seen[0].slot);
}

test "a poll tick enters even when a completion is already visible" {
    // The case that made this mode exist: a caller whose queue never empties,
    // with kernel-deferred work waiting behind it. `.no_wait` would copy the
    // visible completion and never enter; `.poll` enters anyway.
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    _ = try loop.nop(.{ .op = .timer, .slot = 1, .gen = 1 });
    try loop.ring.submit();
    try testing.expectEqual(@as(u32, 1), loop.ring.cqReady());

    var app: App = .{};
    // The visible completion is reaped either way; the difference is the
    // enter, which is what runs the kernel's deferred work.
    const plain = try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expect(!plain.entered);
    try testing.expectEqual(@as(u32, 1), plain.cqes);

    _ = try loop.nop(.{ .op = .timer, .slot = 2, .gen = 1 });
    try loop.ring.submit();
    const polled = try loop.tick(&app, App.onCompletion, .poll);
    try testing.expect(polled.entered);
    try testing.expect(!polled.waited);
    try testing.expectEqual(@as(u32, 1), polled.cqes);
}

test "provided buffers: a multishot receive fills a ring buffer" {
    var sv: [2]linux.fd_t = undefined;
    try testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &sv)),
    );
    defer for (sv) |fd| {
        _ = linux.close(fd);
    };

    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    var group: BufferGroup = try .init(&loop.ring.inner, testing.allocator, 0, 64, 4);

    const Capture = struct {
        const Self = @This();

        cqe: ?Loop(Tag).Cqe = null,

        fn on(self: *Self, _: *Loop(Tag), cqe: Loop(Tag).Cqe) !void {
            self.cqe = cqe;
        }
    };
    var cap: Capture = .{};

    _ = try loop.recvMultishot(.{ .op = .recv, .slot = 4, .gen = 1 }, &group, sv[1], 0);
    try loop.ring.submit();
    try testing.expectEqual(@as(usize, 6), linux.write(sv[0], "hello!", 6));

    const ticked = try loop.tick(&cap, Capture.on, .once);
    try testing.expectEqual(@as(u32, 1), ticked.cqes);
    const cqe = cap.cqe.?;
    try testing.expectEqual(@as(u16, 4), cqe.tag.slot);
    try testing.expectEqual(@as(i32, 6), cqe.res);

    const got = try loop.bufferGet(&group, cqe);
    try testing.expectEqualStrings("hello!", got);
    try loop.bufferPut(&group, cqe);

    // The multishot is still armed and borrows the buffer ring: cancel it and
    // reap the cancellation before freeing either, or the unregister lands on
    // a closed ring.
    const recv_tag: Tag = .{ .op = .recv, .slot = 4, .gen = 1 };
    _ = try loop.cancel(.{ .op = .timer, .slot = 5, .gen = 1 }, recv_tag, 0);
    var spins: usize = 0;
    while (cap.cqe == null or cap.cqe.?.errno() != linux.E.CANCELED) : (spins += 1) {
        if (spins == 8) return error.TestUnexpectedResult;
        _ = try loop.tick(&cap, Capture.on, .{ .until = loop.now() + std.time.ns_per_s });
    }

    group.deinit(testing.allocator);
    loop.deinit();
}

test "provided buffers: incremental mode keeps one buffer across completions" {
    var sv: [2]linux.fd_t = undefined;
    try testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &sv)),
    );
    defer for (sv) |fd| {
        _ = linux.close(fd);
    };

    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();
    // `std`'s constructor requests incremental consumption. One buffer carries
    // the stream until it is full, and a completion is the new bytes, not a
    // message. Four buffers, so filling one never empties the ring: a
    // multishot that retries inline cannot end with -ENOBUFS mid-test.
    var group: BufferGroup = try .init(&loop.ring.inner, testing.allocator, 0, 64, 4);
    defer group.deinit(testing.allocator);

    const Capture = struct {
        const Self = @This();

        cqes: [8]Loop(Tag).Cqe = undefined,
        n: usize = 0,

        fn on(self: *Self, _: *Loop(Tag), cqe: Loop(Tag).Cqe) !void {
            if (self.n == self.cqes.len) return error.BatchFull;
            self.cqes[self.n] = cqe;
            self.n += 1;
        }
    };
    var cap: Capture = .{};

    _ = try loop.recvMultishot(.{ .op = .recv, .slot = 4, .gen = 1 }, &group, sv[1], 0);
    try loop.ring.submit();

    var payload: [64]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast('a' + (i % 26));

    // A partial read leaves room, so the kernel keeps the buffer and posts the
    // next bytes against the same id with `F_BUF_MORE`. The third write fills
    // the buffer and the flag clears, which is when `put` recycles it.
    const chunks = [_][]const u8{ payload[0..10], payload[10..15], payload[15..64] };
    var buffer_id: ?u16 = null;
    var offset: usize = 0;
    var fell_back = false;
    for (chunks) |chunk| {
        try testing.expectEqual(chunk.len, linux.write(sv[0], chunk.ptr, chunk.len));
        cap.n = 0;
        var spins: usize = 0;
        while (cap.n < 1 and spins < 8) : (spins += 1) {
            _ = try loop.tick(&cap, Capture.on, .once);
        }
        try testing.expectEqual(@as(usize, 1), cap.n);

        const cqe = cap.cqes[0];
        try testing.expectEqual(@as(i32, @intCast(chunk.len)), cqe.res);
        const id = cqe.bufferId().?;
        if (buffer_id) |wanted| {
            try testing.expectEqual(wanted, id);
        } else {
            buffer_id = id;
        }

        const bytes = try loop.bufferGet(&group, cqe);
        try testing.expectEqualSlices(u8, chunk, bytes);

        const more = cqe.flags & linux.IORING_CQE_F_BUF_MORE != 0;
        if (offset == 0 and !more) {
            // The registration fell back to whole-buffer mode: incremental
            // consumption needs kernel 6.12, and std retries without the flag.
            // Return the buffer so the receive stays armed, and skip: the
            // whole-buffer test covers that mode.
            try loop.bufferPut(&group, cqe);
            fell_back = true;
            break;
        }
        try testing.expectEqual(offset + chunk.len < payload.len, more);
        try loop.bufferPut(&group, cqe);
        offset += chunk.len;
    }

    // Cancel and reap with a deadline. The cancel's own completion and the
    // receive's `-ECANCELED` may arrive in either order or together, and on
    // the fallback path the receive may already have ended with `-ENOBUFS`,
    // in which case the cancel answers `-ENOENT` and there is nothing armed.
    const recv_tag: Tag = .{ .op = .recv, .slot = 4, .gen = 1 };
    const cancel_tag: Tag = .{ .op = .timer, .slot = 5, .gen = 1 };
    _ = try loop.cancel(cancel_tag, recv_tag, 0);
    var cancelled = false;
    var cancel_done = false;
    var spins: usize = 0;
    while ((!cancel_done or (!cancelled and !fell_back)) and spins < 8) : (spins += 1) {
        cap.n = 0;
        _ = try loop.tick(&cap, Capture.on, .{ .until = loop.now() + std.time.ns_per_s });
        for (cap.cqes[0..cap.n]) |cqe| {
            if (cqe.tag.slot == cancel_tag.slot and cqe.tag.op == cancel_tag.op) cancel_done = true;
            if (cqe.errno() == linux.E.CANCELED) cancelled = true;
        }
    }
    try testing.expect(cancel_done);
    if (!fell_back) try testing.expect(cancelled);
    if (fell_back) return error.SkipZigTest;
}

test "provided buffers: whole-buffer mode gives one completion per message" {
    var sv: [2]linux.fd_t = undefined;
    try testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM, 0, &sv)),
    );
    defer for (sv) |fd| {
        _ = linux.close(fd);
    };

    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    // `BufferGroup.init` would register incrementally, where one buffer can
    // carry several completions and a completion is a chunk. Datagrams need
    // one whole buffer per completion. The `F_BUF_MORE` assertion below only
    // bites where the kernel honors `IOU_PBUF_RING_INC` (6.12); on an older
    // kernel both registrations are whole-buffer and it passes vacuously.
    var group: BufferGroup = try initBufferGroup(
        &loop.ring.inner,
        testing.allocator,
        0,
        64,
        4,
        .{ .incremental = false },
    );

    const Capture = struct {
        const Self = @This();

        cqes: [8]Loop(Tag).Cqe = undefined,
        n: usize = 0,

        fn on(self: *Self, _: *Loop(Tag), cqe: Loop(Tag).Cqe) !void {
            if (self.n == self.cqes.len) return error.BatchFull;
            self.cqes[self.n] = cqe;
            self.n += 1;
        }
    };
    var cap: Capture = .{};

    _ = try loop.recvMultishot(.{ .op = .recv, .slot = 4, .gen = 1 }, &group, sv[1], 0);
    try loop.ring.submit();

    const sent = [_][]const u8{ "one", "two", "three" };
    for (sent) |msg| try testing.expectEqual(msg.len, linux.write(sv[0], msg.ptr, msg.len));

    var spins: usize = 0;
    while (cap.n < sent.len and spins < 8) : (spins += 1) {
        _ = try loop.tick(&cap, Capture.on, .once);
    }
    try testing.expectEqual(@as(usize, 3), cap.n);

    var found = [_]bool{ false, false, false };
    var seen = [_]bool{ false, false, false, false };
    for (cap.cqes[0..cap.n]) |cqe| {
        try testing.expect(cqe.flags & linux.IORING_CQE_F_BUFFER != 0);
        // Whole-buffer mode never retains a buffer across completions.
        try testing.expectEqual(@as(u32, 0), cqe.flags & linux.IORING_CQE_F_BUF_MORE);
        const id = cqe.bufferId().?;
        try testing.expect(!seen[id]);
        seen[id] = true;

        const bytes = try loop.bufferGet(&group, cqe);
        var matched = false;
        for (sent, 0..) |want, i| {
            if (std.mem.eql(u8, bytes, want)) {
                found[i] = true;
                matched = true;
            }
        }
        try testing.expect(matched);
        try loop.bufferPut(&group, cqe);
    }
    for (found) |yes| try testing.expect(yes);

    // Two more messages. The first takes the buffer the three above never
    // touched; the second can only complete from a buffer `put` returned, so
    // it proves the whole-buffer return re-added to the ring.
    const follow = [_][]const u8{ "again", "twice" };
    for (follow, 0..) |msg, i| {
        cap.n = 0;
        try testing.expectEqual(msg.len, linux.write(sv[0], msg.ptr, msg.len));
        spins = 0;
        while (cap.n < 1 and spins < 8) : (spins += 1) {
            _ = try loop.tick(&cap, Capture.on, .once);
        }
        try testing.expectEqual(@as(usize, 1), cap.n);
        const cqe = cap.cqes[0];
        try testing.expectEqual(@as(i32, @intCast(msg.len)), cqe.res);
        try testing.expect(cqe.flags & linux.IORING_CQE_F_BUFFER != 0);
        if (i == 1) try testing.expect(seen[cqe.bufferId().?]);
        try testing.expectEqualStrings(msg, try loop.bufferGet(&group, cqe));
        try loop.bufferPut(&group, cqe);
    }

    // The multishot is still armed and borrows the ring: cancel and reap it
    // before the unregister, as the incremental test does.
    const recv_tag: Tag = .{ .op = .recv, .slot = 4, .gen = 1 };
    cap.n = 0;
    _ = try loop.cancel(.{ .op = .timer, .slot = 5, .gen = 1 }, recv_tag, 0);
    var cancelled = false;
    spins = 0;
    while (!cancelled and spins < 8) : (spins += 1) {
        _ = try loop.tick(&cap, Capture.on, .{ .until = loop.now() + std.time.ns_per_s });
        for (cap.cqes[0..cap.n]) |cqe| {
            if (cqe.errno() == linux.E.CANCELED) cancelled = true;
        }
    }
    try testing.expect(cancelled);

    group.deinit(testing.allocator);
    loop.deinit();
}

test "the pre-dispatch hook runs once, after the enter and before any handler" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    const Order = struct {
        const Self = @This();

        log: [4]u8 = undefined,
        n: usize = 0,
        hook_cqes: u32 = 0,

        fn hook(self: *Self, _: *Loop(Tag), done: Loop(Tag).Tick) void {
            self.hook_cqes = done.cqes;
            self.log[self.n] = 'h';
            self.n += 1;
        }

        fn on(self: *Self, _: *Loop(Tag), _: Loop(Tag).Cqe) !void {
            self.log[self.n] = 'c';
            self.n += 1;
        }
    };

    // An idle pass: the hook runs even though no handler will.
    var idle: Order = .{};
    _ = try loop.tickStarting(&idle, Order.hook, Order.on, .no_wait);
    try testing.expectEqualStrings("h", idle.log[0..idle.n]);
    try testing.expectEqual(@as(u32, 0), idle.hook_cqes);

    // A pass with two completions: the hook runs once, before both handlers.
    _ = try loop.nop(.{ .op = .timer, .slot = 1, .gen = 1 });
    _ = try loop.nop(.{ .op = .timer, .slot = 2, .gen = 1 });
    var busy: Order = .{};
    _ = try loop.tickStarting(&busy, Order.hook, Order.on, .no_wait);
    try testing.expectEqualStrings("hcc", busy.log[0..busy.n]);
    // The hook sees the batch it is about to dispatch.
    try testing.expectEqual(@as(u32, 2), busy.hook_cqes);
}

test "stopDeferred keeps the rest of the queue in arrival order" {
    // The starvation this exists to prevent: a handler that cannot take more
    // deferred work this pass must leave the remainder at the head, or it
    // lands behind whatever arrives during the pass and never runs.
    var cqes: [8]linux.io_uring_cqe = undefined;
    var deferred: [8]Tag = undefined;
    var loop: Loop(Tag) = try .init(.{
        .entries = 8,
        .cqes = &cqes,
        .deferred = &deferred,
    });
    defer loop.deinit();

    const a: Tag = .{ .op = .send, .slot = 1, .gen = 1 };
    const b: Tag = .{ .op = .send, .slot = 2, .gen = 1 };
    const c: Tag = .{ .op = .send, .slot = 3, .gen = 1 };
    const arrival: Tag = .{ .op = .recv, .slot = 9, .gen = 1 };
    try loop.nextTick(a);
    try loop.nextTick(b);
    try loop.nextTick(c);

    const Order = struct {
        const Self = @This();
        seen: [4]Tag = undefined,
        served: usize = 0,
        defer_next: bool = false,

        fn on(self: *Self, l: *Loop(Tag), cqe: Loop(Tag).Cqe) !void {
            self.seen[self.served] = cqe.tag;
            self.served += 1;
            if (cqe.tag.slot == 1) {
                // A new hello parks during this pass, behind the queue, and
                // the pass ends here.
                try l.nextTick(arrival);
                l.stopDeferred();
                l.stop();
            }
        }
    };
    var app: Order = .{};

    _ = try loop.tick(&app, Order.on, .no_wait);
    // Only the head was served; everything else kept its place, with the
    // arrival from this pass at the tail.
    try testing.expectEqual(@as(usize, 1), app.served);
    try testing.expectEqual(a.slot, app.seen[0].slot);
    try testing.expectEqual(@as(usize, 3), loop.deferred_len);

    // The next pass resumes at the head, not at the arrival: b, then c, then
    // the tag that parked during the previous pass.
    _ = try loop.tick(&app, Order.on, .no_wait);
    try testing.expectEqual(@as(usize, 4), app.served);
    try testing.expectEqual(b.slot, app.seen[1].slot);
    try testing.expectEqual(c.slot, app.seen[2].slot);
    try testing.expectEqual(arrival.slot, app.seen[3].slot);
}
