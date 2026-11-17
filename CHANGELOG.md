# Changelog

All notable changes to uring are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.4.0] - 2026-11-17

### Added

- `Loop.stopDeferred`: end this pass's deferred dispatch, leaving the rest of
  the queue in place and in order. A handler that cannot take more deferred
  work this pass calls it instead of deferring the remainder again: deferring
  moves those tags behind whatever arrived during the pass, which starves them
  under a steady arrival rate. The next pass resumes at the same head.

## [0.3.0] - 2026-11-17

### Changed

- `Loop.post` is `Loop.nextTick`, and the queue and flag it feeds are named
  `deferred`: `Options.deferred`, `Loop.deferred_len`, `Cqe.deferred`,
  `Tick.deferred`, and `error.DeferredFull`. "Post" read like posting to the
  ring, which it is not: the loop synthesizes a completion for a tag and
  dispatches it next pass, with nothing submitted.

## [0.2.0] - 2026-11-16

### Added

- `Loop.tickStarting(ctx, before_dispatch, handler, wait)`: `tick` with a hook
  that runs once per pass, after the enter and before the first handler,
  receiving the pass's `Tick`. A caller whose handlers read a cached clock
  settles it there; sampling after `tick` returns leaves every handler on the
  previous pass's time, and sampling before it stamps a post-wake batch with
  the park-start time. `tick` is this with `null`, and pays nothing for it.

## [0.1.0] - 2026-11-16

### Added

- `Loop(Tag).tick`, `run`, `post`, `stop`, and the operation wrappers
  (`recv`, `send`, `recvmsg`, `sendmsg`, `acceptMultishot`, `connect`,
  `close`, `cancel`, `timeout`, `pollAdd`, `shutdown`, `nop`, and `sqe` for
  everything else). The handler is comptime and the tag is any 64-bit type.
- `Wait`: `poll` enters every pass, `no_wait` enters only when there was
  nothing to copy, `once` blocks, and `until` blocks for a deadline.
  `Wait.until` and `Ring.wait` take the deadline through `io_uring_enter`
  with `IORING_ENTER_EXT_ARG`, so a timeout costs no submitted operation.
- `Tick` reports what one pass did: completions and posted tags dispatched,
  whether the tick entered or blocked, and the tick's span (`start_ns`,
  `now_ns`). The loop samples the clock on both sides of the enter so a caller
  that measures an idle gap does not have to. `Loop.now` is that tick's
  sample.
- `Ring` wraps `std.os.linux.IoUring` with that enter and the submit
  discipline. Ring setup is `Ring.Setup`, a struct of named bits with the
  values that ride beside them (`cq_entries`, `sq_thread_cpu`,
  `sq_thread_idle`, `wq_fd`); the default is deferred completions with a
  single issuer. A kernel without `IORING_FEAT_EXT_ARG` is refused at `init`.
- `bench/` (testingx) compares the loop against the equivalent hand-written
  loop over `std.os.linux.IoUring`: a dispatch batch and an idle pass.
- The operation set is complete against `std.os.linux.IoUring`: every opcode
  it encodes has a wrapper taking the caller's tag (`read`, `write`,
  `readFixed`, `writeFixed`, `writev`, `splice`, `fsync`, `fallocate`,
  `statx`, `openat`, the `at` family, `waitid`, `epollCtl`, the socket ops,
  `sendZc`, `sendmsgZc`, `pollRemove`/`pollUpdate`, `timeoutRemove`,
  `linkTimeout`, the `*Direct` variants, and the rest).
- `Ring` covers registration: files (sparse, alloc-range, update,
  unregister), buffers, eventfd (plain and async), NAPI, and `probe` with
  `supports` for asking a kernel what it encodes.
- Provided buffers: `BufferGroup` with `recvMultishot`, `bufferGet`, and
  `bufferPut`. Operations `std` does not encode (`msg_ring`, futex, `tee`,
  `madvise`, `openat2`, personalities, restrictions) are listed in the module
  docs as not covered.
