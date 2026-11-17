+++
title = "uring"
+++

An io_uring completion loop for Zig: one ring, one tick, and a user_data type you define.

Zig's standard library already encodes every io_uring operation: multishot
accept, `recv_multishot` over buffer groups, registered files, `poll_add`,
`timeout`, `cancel`, `send_zc`. What it does not have is the loop around them:
when to submit, when to enter, and what runs when. This package is that loop.

It is parameterized by your tag, the value `user_data` carries home. A
completion means whatever you say it means: this library never looks inside the
tag, never closes a descriptor, never frees a byte, and never rearms an
operation. The handler is known at comptime, so every completion is a direct
call.

- [The loop](#the-loop): `Loop(Tag).tick` is one pass, publish, reap, enter, dispatch, submit, and `run`, `nextTick`, `stop`, and `now` are around it.
- [The tag](#the-tag): any 64-bit type. `Cqe` decodes it once and hands it to your handler.
- [Waiting](#waiting): `Wait.poll`, `.no_wait`, `.once`, and `.until`, and what each one costs.
- [Deadlines](#deadlines): a deadline through the enter, with no submitted operation, and `timeout` when you want the kernel to own the clock.
- [Operations](#operations): every opcode the standard library encodes, each taking your tag and returning the SQE.
- [Registered resources](#registered-resources): files, buffers, eventfds, NAPI, and the probe.
- [Provided buffers](#provided-buffers): `BufferGroup` and a multishot receive that fills ring buffers the kernel picks.
- [The ring](#the-ring): `Ring`, its setup struct, and the submit discipline that keeps the queue from filling.
- [Performance](#performance): the loop against the equivalent hand-written loop, measured.
- [Limits](#limits): what is deliberately not here.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/uring/v0.3.0.tar.gz
```

Add the module in `build.zig`:

```zig
const uring = b.dependency("uring", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("uring", uring.module("uring"));
```

`uring` builds with Zig 0.17, on Linux only, because io_uring is Linux.

## Name your tag

The tag is the one thing every caller has to decide. It is what `user_data`
carries home from the kernel, and it must be 64 bits: a packed struct of
operation, slot, and generation is the usual shape, a `*Node` works, and so
does a bare `u64`.

```zig
const Tag = packed struct(u64) {
    op: Op,        // an enum(u8) of your operations
    slot: u16,
    gen: u16,
    spare: u24 = 0,
};
```

The generation is worth the two bytes: the kernel can deliver a completion for
an operation you cancelled, and a slot that has since been reused must be able
to tell. The loop decodes nothing; comparing `cqe.tag.gen` against the
connection's current generation is the caller's job.

## Open a loop

```zig
const std = @import("std");
const uring = @import("uring");

var cqes: [64]std.os.linux.io_uring_cqe = undefined;
var loop: uring.Loop(Tag) = try .init(.{
    .entries = 256,
    .cqes = &cqes,
    .setup = .{ .single_issuer = true, .defer_taskrun = true },
});
defer loop.deinit();
```

`cqes` is the batch the loop copies completions into: the loop allocates
nothing, so the caller sizes it. `setup` is described in [the ring](#the-ring);
the two fields above are the default and the configuration the timings in
[Performance](#performance) were measured with.

## Arm an operation and tick

```zig
const buf: []u8 = ...;
_ = try loop.recv(.{ .op = .recv, .slot = 7, .gen = 1 }, fd, .{ .buffer = buf }, 0);

while (!loop.stopped) {
    const next = server.nextDeadline(loop.now());
    try loop.tick(&server, Server.onCompletion, .{ .until = next });
}
```

The handler is a function, not a callback stored in a struct:

```zig
fn onCompletion(server: *Server, loop: *uring.Loop(Tag), cqe: uring.Loop(Tag).Cqe) !void {
    if (cqe.tag.gen != server.slotGen(cqe.tag.slot)) return;  // stale
    switch (cqe.tag.op) {
        .recv => try server.onRecv(cqe),
        .send => try server.onSend(cqe),
    }
}
```

`tick` is one pass and always makes one: it does not check `stopped`, because a
shutdown that still has connections to serve needs ticks after the decision.
`run` is the convenience that reads `stopped` between passes.

# The loop

`tick(ctx, handler, wait)` does five things, in this order, every call:

1. Publish: if the submission queue holds anything, submit it. Work armed
   outside a handler is therefore never a tick late.
2. Reap: copy the ready completions into your batch.
3. Enter: only when step 2 found nothing and nothing is deferred. What kind
   of enter is `wait`; see [Waiting](#waiting).
4. Dispatch: one direct call to your handler per completion, then one per
   deferred tag. The deferred count is snapshotted before dispatch, so a
   handler that queues work cannot starve the enter.
5. Submit: publish whatever step 4 armed.

`tick` returns a `Tick`: the completion and deferred counts it dispatched,
whether it entered, whether that enter blocked, and the tick's clock span
(`start_ns`, `now_ns`). A caller whose policy depends on the pass, a
busy-poll gate, a task-work bound, reads those rather than sampling its own
clock.

`nextTick(tag)` dispatches a tag on the next pass as though a completion had
arrived, with `res` zero and `Cqe.deferred` set. Nothing is submitted and the
kernel is not involved: it is the loop's one synthetic completion. It is how a
caller parks work that the kernel did not produce, and it is bounded: the queue
is a slice you pass as `Options.deferred`, and a full queue returns
`error.DeferredFull` rather than dropping the tag.

`stop()` asks the loop to finish and `run` honors it between passes.
`now()` is the tick's sample.

# The tag

`Loop(Tag)` accepts any type that is 64 bits wide and encodes it into the
ring's `user_data` on every submission, and decodes it once per completion:

- a packed struct, the usual choice;
- a pointer, for a caller that would rather the completion carried its node;
- a bare `u64`, for a caller with its own scheme.

```zig
const Node = struct { next: ?*Node = null, kind: Kind };
var nodes: [N]Node = ...;
_ = try loop.nop(&nodes[3]);            // Loop(*Node)
```

There is no registration step and no per-tag allocation: the conversion is a
`@bitCast` (or `@intFromPtr`), and the loop's only opinion about it is that it
must be 64 bits, which is a compile error otherwise.

`Cqe` carries `tag`, `res`, `flags`, and `deferred`, plus three helpers:
`errno()` (the `linux.E` in `res`, using the standard library's decoder),
`more()` (the operation stays armed, a multishot), and `bufferId()` (which
provided buffer the kernel filled).

# Waiting

`tick` takes a `Wait`, and the four modes differ in one thing: whether the tick
enters, and whether that enter blocks.

| mode | enters | blocks | use |
|---|---|---|---|
| `.poll` | always | no | a completion queue that never empties, and deferred work behind it |
| `.no_wait` | only if nothing was ready | no | a poll window: spin here, then block |
| `.once` | yes | yes | the ordinary idle loop |
| `.until` | yes | until a deadline | a loop with a timeout to keep |

Under `DEFER_TASKRUN` only an enter runs the completions the kernel deferred,
and a full completion queue never gives the loop a reason to enter. `.poll` is
that mode: enter on every pass even when a completion is already visible. A
caller that parks ClientHellos and then watches its queue stay full needs it,
or deferred completions (a reload eventfd, a timer) wait behind the traffic.

`.until` takes an absolute monotonic deadline. A deadline already in the past
polls instead of waiting for a completion that cannot arrive first.

`SignalInterrupt` from a blocking wait is reported to the caller, because the
wait really was interrupted. `Ring.poll` absorbs it: a poll asks for no
completion and waits for nothing, so there is nothing to interrupt.

# Deadlines

There are two ways to have a deadline, and they cost different things.

The first rides the enter: `tick` with `.until` hands `io_uring_enter` a
timeout through `IORING_ENTER_EXT_ARG`. Moving the deadline costs no
submission, no cancel, and no rearm, it is an argument to the syscall the loop
was going to make anyway. This is what a loop with a timeout to keep should
use, and it is why a past deadline polls instead of asking the kernel to wait.

The second is the operation: `timeout` arms `IORING_OP_TIMEOUT` with an absolute
`kernel_timespec`, `linkTimeout` binds a timeout to the SQE before it so it
fires only if that operation has not completed, and `timeoutRemove` cancels one
by tag. Use these when the kernel must count while the loop is busy with other
operations, or when the deadline belongs to an operation rather than to the
loop.

A `Timer` that fires continuously, a pool eviction sweep, or a per-connection
idle timeout all fit the enter's deadline; the loop asks "when is the next
thing due?" once per pass. An operation timeout fits a request with a
server-imposed deadline, where the completion must arrive with that tag.

# Operations

Every opcode the standard library encodes has a wrapper. Each takes your tag in
place of a raw `user_data`, publishes when the submission queue is near full,
and returns the SQE, so every flag stays yours:

```zig
const sqe = try loop.recv(tag, fd, .{ .buffer = buf }, 0);
sqe.ioprio |= std.os.linux.IORING_RECVSEND_POLL_FIRST;
```

The set: accept (single, multishot, direct, multishot-direct), connect, bind,
listen, socket (plain, direct, direct-alloc), send, sendmsg, `sendZc`,
`sendZcFixed`, `sendmsgZc`, recv, recvmsg, `recvMultishot`, read, `readFixed`,
write, writev, `writeFixed`, close, `closeDirect`, fsync, fallocate, statx,
splice, openat, `openatDirect`, renameat, unlinkat, mkdirat, symlinkat, linkat,
waitid, `epollCtl`, timeout, `linkTimeout`, `timeoutRemove`, `pollAdd`,
`pollRemove`, `pollUpdate`, cancel, shutdown, nop, `provideBuffers`,
`removeBuffers`, and `URING_CMD` on a socket through `cmdSock`, `setsockopt`,
and `getsockopt`.

When an operation is not in that set, `sqe(tag)` hands back a blank SQE with
your tag already in `user_data`; `prep_*` on it is the same encoding the
wrappers use.

Linked operations are flags, not a wrapper: set `IOSQE_IO_LINK` on the first
SQE and the second runs only if the first succeeds.

## Registered files

An fd is a lookup per operation. Registering files once and naming them by
index removes it: pass the index where an fd goes and set `IOSQE_FIXED_FILE` on
the returned SQE.

```zig
try loop.ring.registerFiles(&.{ listener_fd, backend_fd });
const sqe = try loop.recv(tag, 0, .{ .buffer = buf }, 0);
sqe.flags |= linux.IOSQE_FIXED_FILE;
```

The `*Direct` variants take a destination index for a file the kernel creates:
`acceptDirect`, `acceptMultishotDirect`, `openatDirect`, `socketDirect`,
`socketDirectAlloc`, `closeDirect`. `IORING_FILE_INDEX_ALLOC` lets the kernel
pick, and the completion's `res` is the index it chose.

# Registered resources

`Ring` covers what the kernel lets a ring register. Registration has no tag and
no completion, so it is not on the loop:

```zig
try loop.ring.registerFiles(fds);
try loop.ring.registerFilesUpdate(offset, fds);
try loop.ring.registerFilesSparse(64);
try loop.ring.registerFileAllocRange(0, 64);
try loop.ring.unregisterFiles();

try loop.ring.registerBuffers(&.{iov});
try loop.ring.unregisterBuffers();

try loop.ring.registerEventfd(fd);        // a completion posts to `fd`
try loop.ring.registerEventfdAsync(fd);   // ... before the CQE is posted
try loop.ring.unregisterEventfd();
```

Ask the kernel what it can do rather than assuming:

```zig
const probe = try loop.ring.probe();
if (uring.Ring.supports(&probe, .SEND_ZC)) { ... }
```

The probe answers per opcode. Kernel versions differ more than the man pages
suggest: `IORING_OP_SEND_ZC` is 6.0, multishot `recv` with buffer selection is
6.0, and `IORING_OP_LINK_TIMEOUT` is 5.15.

# Provided buffers

A buffer group is a ring of buffers the kernel fills directly, so a receive
does not need a buffer chosen in advance and a multishot receive can keep
arriving into different buffers.

```zig
var group: uring.BufferGroup = try .init(&loop.ring.inner, allocator, 0, 4096, 64);
defer group.deinit(allocator);

_ = try loop.recvMultishot(tag, &group, fd, 0);

// In the handler:
const bytes = try loop.bufferGet(&group, cqe);
try process(bytes);
try loop.bufferPut(&group, cqe);
```

`bufferPut` handles incremental consumption: while the kernel sets
`IORING_CQE_F_BUF_MORE` it keeps writing at the same offset, and the buffer
returns to the ring only when the kernel is done with it.

`provideBuffers` and `removeBuffers` are the older, per-operation way, and
exist for a kernel without the buffer ring.

# The ring

`Ring` is the io_uring instance; `Loop` is the tick around it. A caller that
drives its own pass can use `Ring` alone: `submit`, `poll`, `wait`, `copyCqes`,
`sqe`, `available`, `sqPending`, `cqReady`.

Setup is a struct rather than the flag word, because the flags are unrelated
booleans plus three values that mean nothing without their bit:

```zig
.setup = .{
    .single_issuer = true,    // one thread submits
    .defer_taskrun = true,    // deferred completions run in the submit-side enter
    .cq_entries = 4096,       // IORING_SETUP_CQSIZE without a size is not expressible
    .sqpoll = true,
    .sq_thread_cpu = 3,       // IORING_SETUP_SQ_AFF without a CPU is not either
    .sq_thread_idle = 1000,
}
```

The default is `single_issuer` with `defer_taskrun`: the kernel requires the
pair, and deferred completions arriving inside the enter rather than as
interrupts is the configuration the loop's timings were measured with. Setup
fails at `init` when the kernel has no `IORING_FEAT_EXT_ARG` (5.11), because
every wait here enters with the extended argument.

The submit discipline is the loop's reason to exist beyond dispatch: a prep
that finds the submission queue full loses the operation, so `Ring.available`
is checked before each one and the queue is published with room to spare
(`Options.sq_floor`, default 8). `cancel` publishes first, because a cancel
that names an unpublished operation returns `ENOENT` and the target runs on.

# Performance

The loop is a wrapper over the ring, so the question is what the wrapper costs.
`bench/loop.zig` runs the same work twice, once through `Loop`, once through
`std.os.linux.IoUring` with the copy, enter, and dispatch written out, and the
ratio is the answer. ReleaseFast, best of five interleaved runs, on an
8-core aarch64 host:

| case | loop | hand-written | ratio |
|---|---:|---:|---:|
| 128 completions, one pass | 3202 ns | 2847 ns | 1.12 |
| idle pass (one enter) | 191 ns | 132 ns | 1.45 |

Per completion that is about 3 ns: the `Cqe` construction and the error branch
on each handler call, which a hand-written loop does not have because it does
not propagate errors. The idle pass pays two clock reads (`Tick.start_ns` and
`Tick.now_ns`), which is what lets a caller measure an idle gap without
sampling its own clock.

Run it with `just bench`; `just bench -- --filter=Batch` picks a group.

# Limits

Not here, because the standard library does not encode them: `msg_ring`, futex
operations, `tee`, `madvise`, `openat2`, `timeout_update`, and a generic
`URING_CMD` that is not a socket command. Registration for personalities,
restrictions, io-wq worker limits, `sync_cancel`, `clamp`, `pbuf_status`, and
`files_update2` is not here either. `Loop.sqe` is the door for all of them.

`uring` is Linux only and Zig 0.17 only. There is no other backend to fall back
to, and no shim for older compilers.

The loop does not own your descriptors, your buffers, or your lifetime rules.
It will not close an fd, it will not free a buffer, and it will not rearm an
operation: the kernel borrows a buffer until its completion arrives, and only
the caller knows when that has landed.
