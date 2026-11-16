//! The loop against the loop you would write by hand, as testingx benchmarks.
//!
//! Every case runs the same work twice: once through `uring.Loop`, once
//! through `std.os.linux.IoUring` with the copy, enter, and dispatch written
//! out. The claim under test is that the abstraction costs nothing measurable,
//! so read the ratio between the two rows of a group, not either column.
//!
//! Each iteration is one batch: arm, submit, reap. A batch is the unit the
//! loop controls, and one operation at a time would measure the syscall.
//! Work stays under the completion queue's capacity: a burst larger than the
//! CQ measures the kernel's overflow path instead of dispatch.

const std = @import("std");
const linux = std.os.linux;
const testingx = @import("testingx");
const uring = @import("uring");

const Tag = packed struct(u64) {
    op: u8,
    slot: u16,
    gen: u16,
    spare: u24 = 0,
};

/// Held past the end of each benchmark so nothing above can be deleted.
var sink: u64 = 0;

const batch = 128;

fn onCompletion(ctx: *u64, _: *uring.Loop(Tag), cqe: uring.Loop(Tag).Cqe) !void {
    ctx.* += 1;
    sink +%= cqe.tag.slot;
}

fn armNops(ring: *uring.Ring) !void {
    for (0..batch) |i| _ = try ring.inner.nop(.{ .op = 0, .slot = @intCast(i), .gen = 0 });
}

fn reapLoop(loop: *uring.Loop(Tag), ctx: *u64) !void {
    const target = ctx.* + batch;
    while (ctx.* < target) _ = try loop.tick(ctx, onCompletion, .no_wait);
}

fn reapRaw(ring: *linux.IoUring, buf: []linux.io_uring_cqe) !void {
    var got: usize = 0;
    while (got < batch) {
        const n = try ring.copy_cqes(buf[got..], 0);
        if (n == 0) {
            _ = try ring.enter(0, 0, linux.IORING_ENTER_GETEVENTS);
            continue;
        }
        got += n;
    }
    for (buf[0..batch]) |cqe| sink +%= (@as(Tag, @bitCast(cqe.user_data))).slot;
}

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.add("Batch/loop", batchLoop);
    try b.add("Batch/raw", batchRaw);
    try b.add("Idle/loop", idleLoop);
    try b.add("Idle/raw", idleRaw);
}

/// One batch through the loop: prep, publish, reap, dispatch.
fn batchLoop(b: *testingx.B) !void {
    const cqes = try b.internal_allocator.alloc(linux.io_uring_cqe, batch);
    defer b.internal_allocator.free(cqes);
    var loop: uring.Loop(Tag) = try .init(.{ .entries = 512, .cqes = cqes });
    defer loop.deinit();
    var ctx: u64 = 0;
    defer b.keepAlive(ctx);

    while (try b.loop()) {
        for (0..batch) |i| _ = try loop.nop(.{ .op = 0, .slot = @intCast(i), .gen = 0 });
        try loop.ring.submit();
        try reapLoop(&loop, &ctx);
    }
}

/// The same batch, by hand.
fn batchRaw(b: *testingx.B) !void {
    const cqes = try b.internal_allocator.alloc(linux.io_uring_cqe, batch);
    defer b.internal_allocator.free(cqes);
    var ring = try linux.IoUring.init(512, uring.Ring.default_flags);
    defer ring.deinit();

    while (try b.loop()) {
        for (0..batch) |i| {
            _ = try ring.nop(@bitCast(Tag{ .op = 0, .slot = @intCast(i), .gen = 0 }));
        }
        _ = try ring.submit();
        try reapRaw(&ring, cqes);
    }
}

/// One idle pass: copy an empty queue and enter, which is what runs the
/// kernel's deferred completions under DEFER_TASKRUN.
fn idleLoop(b: *testingx.B) !void {
    const cqes = try b.internal_allocator.alloc(linux.io_uring_cqe, 16);
    defer b.internal_allocator.free(cqes);
    var loop: uring.Loop(Tag) = try .init(.{ .entries = 16, .cqes = cqes });
    defer loop.deinit();
    var ctx: u64 = 0;
    defer b.keepAlive(ctx);

    while (try b.loop()) _ = try loop.tick(&ctx, onCompletion, .no_wait);
}

fn idleRaw(b: *testingx.B) !void {
    const cqes = try b.internal_allocator.alloc(linux.io_uring_cqe, 16);
    defer b.internal_allocator.free(cqes);
    var ring = try linux.IoUring.init(16, uring.Ring.default_flags);
    defer ring.deinit();

    while (try b.loop()) {
        if (try ring.copy_cqes(cqes, 0) == 0) {
            _ = try ring.enter(0, 0, linux.IORING_ENTER_GETEVENTS);
        }
    }
}
