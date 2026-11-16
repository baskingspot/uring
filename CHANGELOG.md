# Changelog

All notable changes to uring are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
  discipline. `DEFER_TASKRUN | SINGLE_ISSUER` is the default mask. A kernel
  without `IORING_FEAT_EXT_ARG` is refused at `init`.
- `bench/` compares the loop against the equivalent hand-written loop over
  `std.os.linux.IoUring`: dispatch, idle tick, and submission prep.
