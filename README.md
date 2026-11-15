# uring

An io_uring completion loop for Zig: one ring, one tick, and a user_data type you define.

This project is incubating. It is unstable, its API will change, and it is not ready to depend on.

Zig's standard library already encodes every io_uring operation: multishot
accept, `recv_multishot` over buffer groups, registered files, `poll_add`,
`timeout`, `cancel`, `send_zc`. What it does not have is the loop around them —
when to submit, when to enter, and what runs when.

`uring` is that loop, and only that loop. It is parameterized by your tag, the
value `user_data` carries home, so a completion means whatever you say it means.
The handler is known at comptime, which makes every completion a direct call.
Nothing allocates after `init`, and the loop never closes a descriptor, never
frees a byte, and never rearms an operation.

```zig
const std = @import("std");
const uring = @import("uring");

const Tag = packed struct(u64) { op: u8, slot: u16, gen: u16, spare: u24 };

var cqes: [64]std.os.linux.io_uring_cqe = undefined;
var loop: uring.Loop(Tag) = try .init(.{ .cqes = &cqes });
defer loop.deinit();

_ = try loop.recv(.{ .op = 1, .slot = 7, .gen = 1 }, fd, .{ .buffer = buf }, 0);

// One pass per call. The deadline is the caller's, computed from the loop's
// clock every tick, because a moving deadline is application state.
while (!loop.isStopped()) {
    const next = server.nextDeadline(loop.now());
    try loop.tick(&server, Server.onCompletion, .{ .until = next });
}
```

A program with no deadlines of its own calls `run` instead, which ticks until
`stop`.

Deadlines ride the enter, not an operation: `io_uring_enter` takes a timeout
through `IORING_ENTER_EXT_ARG`, so moving a deadline costs no submission and no
cancel. An `IORING_OP_TIMEOUT` is still available for a deadline the loop
cannot own.

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/uring
```

```zig
const uring = b.dependency("uring", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("uring", uring.module("uring"));
```

Zig 0.17. Linux only, because io_uring is Linux.

## Work on it

`nix develop` provides the toolchain, and `just ci` runs what CI runs.

## License

MIT. See `LICENSE`.
