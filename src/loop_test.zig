//! The loop's tests. Every one of them runs a real ring: this library's claims
//! are about the kernel's behavior, and a mock would prove nothing about the
//! enter.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;

const Loop = @import("loop.zig").Loop;

/// A packed tag in handoff's shape: an operation, a slot, and a generation that
/// makes a stale completion detectable.
const Tag = packed struct(u64) {
    op: Op,
    slot: u16,
    gen: u16,
    spare: u24 = 0,

    const Op = enum(u8) { recv, send, timer, _ };
};

const App = struct {
    seen: [16]Tag = undefined,
    count: usize = 0,
    deferred_seen: usize = 0,
    stop_at: usize = 0,
    post_back: bool = false,

    fn onCompletion(app: *App, loop: *Loop(Tag), cqe: Loop(Tag).Cqe) !void {
        if (app.count == app.seen.len) return error.BatchFull;
        app.seen[app.count] = cqe.tag;
        app.count += 1;
        if (cqe.deferred) app.deferred_seen += 1;
        if (app.post_back and cqe.tag.op == .send) try loop.post(cqe.tag);
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
    try loop.tick(&app, App.onCompletion, .once);

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
    try loop.tick({}, struct {
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
    try loop.tick(&app, App.onCompletion, .once);

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
    try loop.tick({}, Arm.on, .once);

    var buf: [8]linux.io_uring_cqe = undefined;
    try testing.expectEqual(@as(u32, 4), try loop.ring.copyCqes(&buf));
}

test "the enter deadline ends a tick with nothing in flight" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    var app: App = .{};
    const start = loop.now();
    try loop.tick(&app, App.onCompletion, .{ .until = start + 20 * std.time.ns_per_ms });

    const elapsed = loop.now() - start;
    try testing.expect(elapsed >= 20 * std.time.ns_per_ms);
    try testing.expect(elapsed < 2 * std.time.ns_per_s);
    // The clock was refreshed after the sleep, not before it.
    try testing.expect(loop.now() > start);
}

test "post dispatches without a kernel completion, one tick later" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var ready: [4]Tag = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .ready = &ready });
    defer loop.deinit();

    const tag: Tag = .{ .op = .send, .slot = 1, .gen = 1 };
    try loop.post(tag);

    var app: App = .{};
    try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expectEqual(@as(usize, 1), app.count);
    try testing.expectEqual(@as(usize, 1), app.deferred_seen);
    try testing.expectEqual(@as(u16, 1), app.seen[0].slot);
    try testing.expectEqual(@as(u64, 0), loop.stats.cqes);
}

test "a post from a handler runs on the next tick, never inside the batch" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var ready: [4]Tag = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .ready = &ready });
    defer loop.deinit();

    _ = try loop.nop(.{ .op = .send, .slot = 5, .gen = 1 });

    var app: App = .{ .post_back = true };
    try loop.tick(&app, App.onCompletion, .once);
    // The completion was dispatched, and its handler queued one post.
    try testing.expectEqual(@as(usize, 1), app.count);
    try testing.expectEqual(@as(usize, 0), app.deferred_seen);
    try testing.expectEqual(@as(usize, 1), loop.postedLen());

    try loop.tick(&app, App.onCompletion, .no_wait);
    try testing.expectEqual(@as(usize, 2), app.count);
    try testing.expectEqual(@as(usize, 1), app.deferred_seen);
}

test "a full posted queue refuses rather than dropping" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var ready: [1]Tag = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .ready = &ready });
    defer loop.deinit();

    const tag: Tag = .{ .op = .timer, .slot = 0, .gen = 0 };
    try loop.post(tag);
    try testing.expectError(error.DeferredFull, loop.post(tag));

    var none: [0]Tag = undefined;
    var loop_none: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes, .ready = &none });
    defer loop_none.deinit();
    try testing.expectError(error.DeferredFull, loop_none.post(tag));
}

test "run ticks until a handler stops it" {
    var cqes: [8]linux.io_uring_cqe = undefined;
    var loop: Loop(Tag) = try .init(.{ .entries = 8, .cqes = &cqes });
    defer loop.deinit();

    _ = try loop.nop(.{ .op = .timer, .slot = 0, .gen = 0 });
    _ = try loop.nop(.{ .op = .timer, .slot = 1, .gen = 0 });

    var app: App = .{ .stop_at = 1 };
    try loop.run(&app, App.onCompletion, .no_wait);

    try testing.expect(loop.isStopped());
    // stop() is checked between ticks, not inside a batch: a completion that
    // arrived is work that happened, and the rest of the batch still runs.
    try testing.expectEqual(@as(usize, 2), app.count);

    try loop.tick(&app, App.onCompletion, .no_wait);
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
    try testing.expect(!loop.isStopped());
}
