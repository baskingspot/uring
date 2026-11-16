//! Coverage of the operation set: every wrapper, called once, must arm its own
//! opcode with the caller's tag in `user_data`. Nothing here is submitted, so
//! the pointer arguments only have to exist.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;

const Loop = @import("loop.zig").Loop(Tag);

const Tag = packed struct(u64) {
    op: u8,
    slot: u16,
    gen: u16,
    spare: u24 = 0,
};

const tag: Tag = .{ .op = 3, .slot = 7, .gen = 9 };

/// The fixed-buffer wrappers take a mutable iovec, which nothing here writes.
var scratch_iov: posix.iovec = .{ .base = undefined, .len = 0 };
/// `getsockopt` needs a real destination slice: std reads its length.
var scratch_opt: [8]u8 = undefined;

fn expectOp(want: linux.IORING_OP, sqe: *linux.io_uring_sqe) !void {
    try testing.expectEqual(want, sqe.opcode);
    try testing.expectEqual(Loop.encode(tag), sqe.user_data);
}

test "every wrapper arms its own opcode with the caller's tag" {
    var cqes: [1]linux.io_uring_cqe = undefined;
    var loop: Loop = try .init(.{ .entries = 128, .cqes = &cqes });
    defer loop.deinit();

    const iov_const: posix.iovec_const = undefined;
    const msg: linux.msghdr = undefined;
    const msg_const: linux.msghdr_const = undefined;
    const statx: linux.Statx = undefined;
    const siginfo: linux.siginfo_t = undefined;
    const timespec: linux.kernel_timespec = .{ .sec = 1, .nsec = 0 };
    const path: [*:0]const u8 = "/tmp";

    try expectOp(.FSYNC, try loop.fsync(tag, 0, 0));
    var read_buf: [8]u8 = undefined;
    try expectOp(.READ, try loop.read(tag, 0, .{ .buffer = &read_buf }, 0));
    try expectOp(.WRITE, try loop.write(tag, 0, "x", 0));
    try expectOp(.SPLICE, try loop.splice(tag, 0, 0, 0, 0, 1));
    try expectOp(.READ_FIXED, try loop.readFixed(tag, 0, &scratch_iov, 0, 0));
    try expectOp(.WRITEV, try loop.writev(tag, 0, &.{iov_const}, 0));
    try expectOp(.WRITE_FIXED, try loop.writeFixed(tag, 0, &scratch_iov, 0, 0));
    try expectOp(.ACCEPT, try loop.accept(tag, 0, null, null, 0));
    try expectOp(.ACCEPT, try loop.acceptDirect(tag, 0, null, null, 0, 0));
    try expectOp(.ACCEPT, try loop.acceptMultishotDirect(tag, 0, null, null, 0));
    try expectOp(.EPOLL_CTL, try loop.epollCtl(tag, 0, 0, 0, null));
    try expectOp(.SEND_ZC, try loop.sendZc(tag, 0, "x", 0, 0));
    try expectOp(.SEND_ZC, try loop.sendZcFixed(tag, 0, "x", 0, 0, 0));
    try expectOp(.SENDMSG_ZC, try loop.sendmsgZc(tag, 0, &msg_const, 0));
    try expectOp(.OPENAT, try loop.openat(tag, 0, path, .{}, 0o600));
    try expectOp(.OPENAT, try loop.openatDirect(tag, 0, path, .{}, 0o600, 0));
    try expectOp(.CLOSE, try loop.closeDirect(tag, 0));
    try expectOp(.TIMEOUT_REMOVE, try loop.timeoutRemove(tag, tag, 0));
    try expectOp(.LINK_TIMEOUT, try loop.linkTimeout(tag, @constCast(&timespec), 0));
    try expectOp(.POLL_REMOVE, try loop.pollRemove(tag, tag));
    // An update is IORING_OP_POLL_REMOVE with IORING_POLL_UPDATE_*.
    try expectOp(.POLL_REMOVE, try loop.pollUpdate(tag, tag, tag, 0, 0));
    try expectOp(.FALLOCATE, try loop.fallocate(tag, 0, 0, 0, 1));
    try expectOp(.STATX, try loop.statx(tag, 0, "/tmp", 0, .{}, @constCast(&statx)));
    try expectOp(.RENAMEAT, try loop.renameat(tag, 0, path, 0, path, 0));
    try expectOp(.UNLINKAT, try loop.unlinkat(tag, 0, path, 0));
    try expectOp(.MKDIRAT, try loop.mkdirat(tag, 0, path, 0o700));
    try expectOp(.SYMLINKAT, try loop.symlinkat(tag, path, 0, path));
    try expectOp(.LINKAT, try loop.linkat(tag, 0, path, 0, path, 0));
    try expectOp(.WAITID, try loop.waitid(tag, .ALL, 0, @constCast(&siginfo), 0, 0));
    try expectOp(.SOCKET, try loop.socket(tag, 2, 1, 0, 0));
    try expectOp(.SOCKET, try loop.socketDirect(tag, 2, 1, 0, 0, 0));
    try expectOp(.SOCKET, try loop.socketDirectAlloc(tag, 2, 1, 0, 0));
    try expectOp(.BIND, try loop.bind(tag, 0, undefined, 0, 0));
    try expectOp(.LISTEN, try loop.listen(tag, 0, 128, 0));
    try expectOp(.URING_CMD, try loop.cmdSock(tag, .SETSOCKOPT, 0, 0, 0, 0, 0));
    try expectOp(.URING_CMD, try loop.setsockopt(tag, 0, 0, 0, "x"));
    try expectOp(.URING_CMD, try loop.getsockopt(tag, 0, 0, 0, &scratch_opt));
    try expectOp(.PROVIDE_BUFFERS, try loop.provideBuffers(tag, undefined, 0, 1, 0, 0));
    try expectOp(.REMOVE_BUFFERS, try loop.removeBuffers(tag, 1, 0));

    // The send/receive family that predates this file.
    try expectOp(.NOP, try loop.nop(tag));
    try expectOp(.RECV, try loop.recv(tag, 0, .{ .buffer = undefined }, 0));
    try expectOp(.SEND, try loop.send(tag, 0, "x", 0));
    try expectOp(.RECVMSG, try loop.recvmsg(tag, 0, @constCast(&msg), 0));
    try expectOp(.SENDMSG, try loop.sendmsg(tag, 0, &msg_const, 0));
    try expectOp(.CONNECT, try loop.connect(tag, 0, undefined, 0));
    try expectOp(.CLOSE, try loop.close(tag, 0));
    try expectOp(.TIMEOUT, try loop.timeout(tag, @constCast(&timespec), 0, 0));
    try expectOp(.POLL_ADD, try loop.pollAdd(tag, 0, 0));
    try expectOp(.SHUTDOWN, try loop.shutdown(tag, 0, 0));
    try expectOp(.ASYNC_CANCEL, try loop.cancel(tag, tag, 0));
}
