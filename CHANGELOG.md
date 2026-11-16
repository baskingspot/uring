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
  and whether the tick entered or blocked. It carries no timestamps; call
  `Loop.now` when you want one.
- `Ring` wraps `std.os.linux.IoUring` with that enter and the submit
  discipline. `DEFER_TASKRUN | SINGLE_ISSUER` is the default mask. A kernel
  without `IORING_FEAT_EXT_ARG` is refused at `init`.
- `Options.time_kernel` times the enter into `Stats.kernel_ns`. Off by
  default: it is the only path that reads a clock per tick.
- `bench/` compares the loop against the equivalent hand-written loop over
  `std.os.linux.IoUring`: dispatch, idle tick, and submission prep.
