# Changelog

All notable changes to uring are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Loop(Tag).tick`, `run`, `post`, `stop`, and the operation wrappers
  (`recv`, `send`, `recvmsg`, `sendmsg`, `acceptMultishot`, `connect`,
  `close`, `cancel`, `timeout`, `pollAdd`, `shutdown`, `nop`, and `sqe` for
  everything else). The handler is comptime and the tag is any 64-bit type.
- `Wait.until` waits on a deadline through `io_uring_enter` with
  `IORING_ENTER_EXT_ARG`: a timeout with no submitted operation.
- `Ring` wraps `std.os.linux.IoUring` with that enter and the submit
  discipline. `DEFER_TASKRUN | SINGLE_ISSUER` is the default mask.
