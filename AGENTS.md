# AGENTS.md

Working notes for AI coding agents in baskingspot/uring.

## What this is

An io_uring completion loop for Zig: one ring, one tick, and a user_data type you define. It is incubating: unstable, with no promises about its API.

## Environment

Zig 0.17, the current stable. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig, `ziglint`, and the base tools, and nothing comes from the system PATH. The justfile is the command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before you commit.

Zig 0.17 only, and it stays that way. The encoding layer is
`std.os.linux.IoUring`, whose API moved between 0.16 and 0.17, and the library
exists to delete scaffolding from a 0.17 consumer. A 0.16 shim would be a
second io_uring surface to keep honest for nobody.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt` and lint with `ziglint`. `just fmt` and `just lint` run both.
- A dependency a user does not need is lazy. Call `b.lazyDependency`, and put every use that needs a value inside `if (dep) |d| { ... }`. The first configure pass returns null, and the build runner fetches the package after it. An unwrap outside that block panics, and it reads as a broken build script. A warm `zig-pkg` hides this, so check with `rm -rf zig-pkg .zig-cache && zig build test`.
- This repo's GitHub settings come from `baskingspot/.github`, with `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## The loop's contract

The tag is the caller's, and the loop never interprets it. That is the whole
design, and it is what to protect in review: no field in `Loop` may mean
"connection", no handler may be called indirectly, and no path may allocate.

Two things this loop must never do, both learned the hard way in handoff:

- Hand a zero timeout to `io_uring_enter`. The kernel reads a zero timeout as
  no timeout, so a deadline in the past becomes an infinite sleep. A passed
  deadline polls instead.
- Reap before submitting. Work armed outside a handler is otherwise a tick
  late, and a caller bursts ops before its first tick.

`sq_floor` exists for the same family of reason: a prep that finds the
submission queue full loses the operation, so the loop publishes early instead
of at the edge.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, run `release-prep.py VERSION` in the repo, with the script from
`baskingspot/.github`, review the diff, commit it signed, push, then
`gh workflow run release.yml -f version=X.Y.Z`. The prep moves the Unreleased
section into a dated heading, sets `.version` in `build.zig.zon`, and points the
install command at the tag. The workflow changes no files and creates no commit,
and it refuses a version the changelog does not carry. Do not tag by hand.
