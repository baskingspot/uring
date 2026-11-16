//! The loop against the loop you would write by hand.
//!
//! Every case runs the same work twice: once through `uring.Loop`, once
//! through `std.os.linux.IoUring` with the copy, enter, and dispatch written
//! out. The claim under test is that the abstraction costs nothing measurable,
//! so the number to read is the ratio, not either column.
//!
//! Work stays under the completion queue's capacity and is reaped as it is
//! armed. A burst larger than the CQ measures the overflow path instead of the
//! dispatch path: the kernel stops accepting submissions until it drains.

const std = @import("std");
const linux = std.os.linux;
const uring = @import("uring");

const Tag = packed struct(u64) {
    op: u8,
    slot: u16,
    gen: u16,
    spare: u24 = 0,
};

/// Consumed at the end so nothing above can be optimized away.
var sink: u64 = 0;

fn monotonic() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn onCompletion(ctx: *u64, _: *uring.Loop(Tag), cqe: uring.Loop(Tag).Cqe) !void {
    ctx.* += 1;
    sink +%= cqe.tag.slot;
}

/// Tick until `want` more completions are dispatched to `ctx`.
fn loopReap(loop: *uring.Loop(Tag), ctx: *u64, want: usize) !void {
    const target = ctx.* + want;
    while (ctx.* < target) _ = try loop.tick(ctx, onCompletion, .no_wait);
}

/// The hand-written equivalent: copy, and enter only when the queue is empty.
fn rawReap(ring: *linux.IoUring, buf: []linux.io_uring_cqe, want: usize) !void {
    var got: usize = 0;
    while (got < want) {
        const n = try ring.copy_cqes(buf[got..], 0);
        if (n == 0) {
            _ = try ring.enter(0, 0, linux.IORING_ENTER_GETEVENTS);
            continue;
        }
        got += n;
    }
    for (buf[0..got]) |cqe| sink +%= (@as(Tag, @bitCast(cqe.user_data))).slot;
}

const Result = struct {
    name: []const u8,
    loop_ns: i64,
    raw_ns: i64,
    ops: u64,

    fn perOp(ns: i64, ops: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ops));
    }
};

fn benchDispatch(allocator: std.mem.Allocator, entries: u16, batch: usize, rounds: usize, want_loop: bool, want_raw: bool) !Result {
    const cqes = try allocator.alloc(linux.io_uring_cqe, batch);
    defer allocator.free(cqes);

    var loop_ns: i64 = 0;
    if (want_loop) {
        var loop: uring.Loop(Tag) = try .init(.{ .entries = entries, .cqes = cqes });
        defer loop.deinit();
        var ctx: u64 = 0;
        const start = monotonic();
        for (0..rounds) |_| {
            for (0..batch) |i| _ = try loop.nop(.{ .op = 0, .slot = @intCast(i), .gen = 0 });
            try loop.ring.submit();
            try loopReap(&loop, &ctx, batch);
        }
        loop_ns = monotonic() - start;
        sink +%= ctx;
    }

    var raw_ns: i64 = 0;
    if (want_raw) {
        var raw = try linux.IoUring.init(entries, uring.Ring.default_flags);
        defer raw.deinit();
        const raw_start = monotonic();
        for (0..rounds) |_| {
            for (0..batch) |i| {
                _ = try raw.nop(@bitCast(Tag{ .op = 0, .slot = @intCast(i), .gen = 0 }));
            }
            _ = try raw.submit();
            try rawReap(&raw, cqes, batch);
        }
        raw_ns = monotonic() - raw_start;
    }

    return .{ .name = "dispatch", .loop_ns = loop_ns, .raw_ns = raw_ns, .ops = rounds * batch };
}

/// An idle tick: one copy of an empty queue plus the enter that runs deferred
/// completions. Nothing is armed, so nothing can stall.
fn benchIdleTick(allocator: std.mem.Allocator, entries: u16, iterations: usize, want_loop: bool, want_raw: bool) !Result {
    const cqes = try allocator.alloc(linux.io_uring_cqe, 16);
    defer allocator.free(cqes);
    var loop_ns: i64 = 0;
    if (want_loop) {
        var loop: uring.Loop(Tag) = try .init(.{ .entries = entries, .cqes = cqes });
        defer loop.deinit();
        var ctx: u64 = 0;
        const start = monotonic();
        for (0..iterations) |_| _ = try loop.tick(&ctx, onCompletion, .no_wait);
        loop_ns = monotonic() - start;
    }

    var raw_ns: i64 = 0;
    if (want_raw) {
        var raw = try linux.IoUring.init(entries, uring.Ring.default_flags);
        defer raw.deinit();
        const raw_start = monotonic();
        for (0..iterations) |_| {
            if (try raw.copy_cqes(cqes, 0) == 0) {
                _ = try raw.enter(0, 0, linux.IORING_ENTER_GETEVENTS);
            }
        }
        raw_ns = monotonic() - raw_start;
    }
    return .{ .name = "idle tick", .loop_ns = loop_ns, .raw_ns = raw_ns, .ops = iterations };
}

/// Submission prep only: building the SQE and handing it to the queue, with
/// the syscall outside the measurement.
fn benchPrep(allocator: std.mem.Allocator, entries: u16, batch: usize, rounds: usize, want_loop: bool, want_raw: bool) !Result {
    const cqes = try allocator.alloc(linux.io_uring_cqe, batch);
    defer allocator.free(cqes);

    var loop_ns: i64 = 0;
    if (want_loop) {
        var loop: uring.Loop(Tag) = try .init(.{ .entries = entries, .cqes = cqes });
        defer loop.deinit();
        var ctx: u64 = 0;
        for (0..rounds) |_| {
            const start = monotonic();
            for (0..batch) |i| _ = try loop.nop(.{ .op = 0, .slot = @intCast(i), .gen = 0 });
            loop_ns += monotonic() - start;
            try loop.ring.submit();
            try loopReap(&loop, &ctx, batch);
        }
        sink +%= ctx;
    }

    var raw_ns: i64 = 0;
    if (want_raw) {
        var raw = try linux.IoUring.init(entries, uring.Ring.default_flags);
        defer raw.deinit();
        for (0..rounds) |_| {
            const start = monotonic();
            for (0..batch) |i| {
                _ = try raw.nop(@bitCast(Tag{ .op = 0, .slot = @intCast(i), .gen = 0 }));
            }
            raw_ns += monotonic() - start;
            _ = try raw.submit();
            try rawReap(&raw, cqes, batch);
        }
    }
    return .{ .name = "prep", .loop_ns = loop_ns, .raw_ns = raw_ns, .ops = rounds * batch };
}

fn arg(args: std.process.Args, i: usize) ?[]const u8 {
    if (i >= args.vector.len) return null;
    return std.mem.span(args.vector[i]);
}

/// The loop's clock, in isolation: three reads per tick is a design choice
/// only if a read is cheap.
fn benchClock(iterations: usize) Result {
    var acc: i64 = 0;
    const start = monotonic();
    for (0..iterations) |_| acc +%= monotonic();
    const elapsed = monotonic() - start;
    sink +%= @as(u64, @bitCast(acc));
    return .{ .name = "clock", .loop_ns = elapsed, .raw_ns = 0, .ops = iterations };
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;
    const case = arg(init.args, 1) orelse "all";
    const side = arg(init.args, 2) orelse "both";
    const want_loop = !std.mem.eql(u8, side, "raw");
    const want_raw = !std.mem.eql(u8, side, "loop");

    std.debug.print(
        "\nsizeof: Loop={d} Ring={d} Cqe={d}  (std ring alone {d})\n",
        .{
            @sizeOf(uring.Loop(Tag)),
            @sizeOf(uring.Ring),
            @sizeOf(uring.Loop(Tag).Cqe),
            @sizeOf(linux.IoUring),
        },
    );
    std.debug.print("{s: <10} {s: >11} {s: >11} {s: >7}\n", .{ "case", "loop ns/op", "raw ns/op", "ratio" });

    const repetitions = 5;
    var best_dispatch: ?Result = null;
    var best_idle: ?Result = null;
    var best_prep: ?Result = null;
    var round: usize = 0;
    while (round < repetitions) : (round += 1) {
        // Interleaved, so a frequency shift lands on every case.
        if (std.mem.eql(u8, case, "all") or std.mem.eql(u8, case, "dispatch")) {
            const r = try benchDispatch(allocator, 512, 128, 2000, want_loop, want_raw);
            if (best_dispatch == null or r.loop_ns < best_dispatch.?.loop_ns) best_dispatch = r;
        }
        if (std.mem.eql(u8, case, "all") or std.mem.eql(u8, case, "idle")) {
            const r = try benchIdleTick(allocator, 16, 100_000, want_loop, want_raw);
            if (best_idle == null or r.loop_ns < best_idle.?.loop_ns) best_idle = r;
        }
        if (std.mem.eql(u8, case, "clock")) {
            const r = benchClock(1_000_000);
            if (best_prep == null) best_prep = r;
        }
        if (std.mem.eql(u8, case, "all") or std.mem.eql(u8, case, "prep")) {
            const r = try benchPrep(allocator, 512, 128, 2000, want_loop, want_raw);
            if (best_prep == null or r.loop_ns < best_prep.?.loop_ns) best_prep = r;
        }
    }
    for ([_]?Result{ best_dispatch, best_idle, best_prep }) |maybe| {
        const r = maybe orelse continue;
        const lp = Result.perOp(r.loop_ns, r.ops);
        const rp = Result.perOp(r.raw_ns, r.ops);
        if (want_loop and want_raw) {
            std.debug.print("{s: <10} {d: >11.1} {d: >11.1} {d: >7.3}\n", .{ r.name, lp, rp, lp / rp });
        } else {
            std.debug.print("{s: <10} {d: >11.1}\n", .{ r.name, if (want_loop) lp else rp });
        }
    }
    std.debug.print("sink={d}\n", .{sink});
}
