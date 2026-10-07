//! TCP transport with NINJAM message framing (docs/PROTOCOL.md §1, §2).
//! Frame = 1 type byte + uint32 LE size (<= 16384) + payload.
//! Built directly on std.posix to stay stable across zig std churn.

const std = @import("std");
const builtin = @import("builtin");
const bufmod = @import("buf.zig");
const clock = @import("clock.zig");
const ws2 = std.os.windows.ws2_32;

pub const max_payload: u32 = 16384;

pub const Message = struct {
    mtype: u8,
    payload: []const u8,
};

/// What became of a message handed to `sendMessageBounded`.
///
/// The distinction between the last two is the whole point, and it is not a
/// stylistic one. The NINJAM frame is `[u8 type][u32 LE len][payload]` on a
/// TCP byte stream with **no resync marker** — no magic word, no checksum, and
/// nothing that would let a reader notice it is one byte out of step (#31
/// established exactly this). So the three states are not a gradient:
///  - `.declined` and `.sent` both leave the reader correctly framed;
///  - `.partial` does not, and cannot be undone.
pub const SendOutcome = enum {
    /// Every byte of the frame is in the socket's send buffer.
    sent,
    /// Nothing at all was written. The socket could not take the whole frame
    /// and not one byte of it reached the wire, so the stream is exactly where
    /// it was. A caller may drop a bar and frame the next one normally.
    declined,
    /// Some but not all of the frame is on the wire. The peer is now mid-frame
    /// and will consume the *next* frame's bytes as the tail of this one, then
    /// parse whatever follows as a header. This is a dead connection, not a
    /// dropped bar, and no retry can repair it.
    partial,
};

/// The session's nonblocking writer owns a short write's tail, so it can finish
/// that frame later without corrupting TCP framing or holding up the clock.
pub const WriteOutcome = enum { sent, declined, pending };

pub const Error = error{
    BadFrame,
    EndOfStream,
    ConnectionClosed,
    WriteQueueFull,
    SocketFlags,
    SocketOption,
    ConnectionRefused,
    ConnectFailed,
    BindFailed,
    ListenFailed,
    SocketOpen,
    UnknownHost,
    SocketPairFailed,
    AcceptFailed,
} || std.posix.ReadError || std.posix.PollError || std.posix.UnexpectedError || std.mem.Allocator.Error;

/// Internal socket layer: POSIX syscalls on unix, Winsock2 on Windows.
/// Exposes just what `Conn` and the test fixtures need — connected-stream
/// sockets, nonblocking mode, poll, read/write/send, sockopts, getaddrinfo,
/// and a connected-pair fixture (`socketpair`). Not a general socket
/// abstraction; `Fd` stays `std.posix.socket_t` (a HANDLE on Windows, which
/// is pointer-width like SOCKET) so callers keep their types.
pub const sys = switch (builtin.os.tag) {
    .windows => struct {
        /// Winsock SOCKET. ws2_32.zig does not declare a socket type;
        /// `socket_t`/`fd_t` are `HANDLE` (`*anyopaque`), same width as SOCKET.
        pub const Fd = std.posix.socket_t;
        /// INVALID_SOCKET ((SOCKET)~0) — distinct from a null SOCKET.
        pub const invalid: Fd = @ptrFromInt(std.math.maxInt(usize));
        pub fn isInvalid(fd: Fd) bool {
            return fd == invalid;
        }

        // Winsock externs — ws2_32.zig ships types/constants only, no decls,
        // so the handful of functions used here are declared directly.
        const WSADATA = extern struct {
            wVersion: c_ushort,
            wHighVersion: c_ushort,
            szDescription: [257]u8,
            szSystemStatus: [129]u8,
            iMaxSockets: c_ushort,
            iMaxUdpDg: c_ushort,
            lpVendorInfo: ?[*:0]u8,
        };
        /// Winsock error codes (winsock2.h WSAE*).
        const WSAE = struct {
            const WOULDBLOCK: i32 = 10035;
            const INPROGRESS: i32 = 10036;
            const ALREADY: i32 = 10037;
            const NETDOWN: i32 = 10050;
            const NETRESET: i32 = 10052;
            const CONNABORTED: i32 = 10053;
            const CONNRESET: i32 = 10054;
            const ISCONN: i32 = 10056;
            const NOTCONN: i32 = 10057;
            const CONNREFUSED: i32 = 10061;
        };
        extern "ws2_32" fn WSAStartup(wVersionRequested: c_ushort, lpWSAData: *WSADATA) callconv(.winapi) c_int;
        extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;

        /// WSAStartup is refcounted and safe to call repeatedly; calling it
        /// on every entry point is the cheapest correct "init once".
        pub fn ensureWsa() void {
            var d: WSADATA = undefined;
            _ = WSAStartup(0x0202, &d); // MAKEWORD(2,2)
        }

        // Winsock error → the errno-like members callers already handle.
        fn sendErr() Error {
            return switch (WSAGetLastError()) {
                WSAE.WOULDBLOCK => error.WouldBlock,
                WSAE.CONNRESET, WSAE.CONNABORTED => error.ConnectionResetByPeer,
                WSAE.NOTCONN => error.SocketUnconnected,
                else => error.ConnectionClosed,
            };
        }
        fn recvErr() Error {
            return switch (WSAGetLastError()) {
                WSAE.WOULDBLOCK => error.WouldBlock,
                WSAE.CONNRESET, WSAE.CONNABORTED, WSAE.NETRESET => error.ConnectionResetByPeer,
                WSAE.NOTCONN => error.SocketUnconnected,
                else => error.Unexpected,
            };
        }
        fn pollErr() Error {
            return switch (WSAGetLastError()) {
                WSAE.NETDOWN => error.NetworkDown,
                else => error.Unexpected,
            };
        }

        // ws2_32.zig also lacks the addrinfo layout (std.c.addrinfo on
        // Windows refers to a member this file does not declare).
        const addrinfo = extern struct {
            flags: c_int,
            family: c_int,
            socktype: c_int,
            protocol: c_int,
            addrlen: usize,
            canonname: ?[*:0]u8,
            addr: ?*ws2.sockaddr,
            next: ?*addrinfo,
        };
        const POLLFD = extern struct {
            fd: Fd,
            events: c_short,
            revents: c_short,
        };
        extern "ws2_32" fn socket(af: c_int, type_: c_int, protocol: c_int) callconv(.winapi) Fd;
        extern "ws2_32" fn closesocket(s: Fd) callconv(.winapi) c_int;
        extern "ws2_32" fn connect(s: Fd, name: *const ws2.sockaddr, namelen: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn bind(s: Fd, name: *const ws2.sockaddr, namelen: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn listen(s: Fd, backlog: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn accept(s: Fd, addr: ?*ws2.sockaddr, addrlen: ?*c_int) callconv(.winapi) Fd;
        extern "ws2_32" fn getsockname(s: Fd, name: *ws2.sockaddr, namelen: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn recv(s: Fd, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn send(s: Fd, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn shutdown(s: Fd, how: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn setsockopt(s: Fd, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn getsockopt(s: Fd, level: c_int, optname: c_int, optval: ?*anyopaque, optlen: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn ioctlsocket(s: Fd, cmd: i32, argp: *c_ulong) callconv(.winapi) c_int;
        extern "ws2_32" fn WSAPoll(fdArray: [*]POLLFD, fds: c_ulong, timeout: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn getaddrinfo(pNodeName: ?[*:0]const u8, pServiceName: ?[*:0]const u8, pHints: ?*const addrinfo, ppResult: *?*addrinfo) callconv(.winapi) c_int;
        extern "ws2_32" fn freeaddrinfo(pAddrInfo: ?*addrinfo) callconv(.winapi) void;

        const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));
        // WSAPoll event bits (winsock2.h POLL*).
        const POLLRDNORM: c_short = 0x0100;
        const POLLWRNORM: c_short = 0x0010;
        const POLLERR: c_short = 0x0001;
        const POLLHUP: c_short = 0x0002;
        const POLLNVAL: c_short = 0x0004;
        const POLLIN: c_short = POLLRDNORM;
        const POLLOUT: c_short = POLLWRNORM;

        pub fn closeFd(fd: Fd) void {
            _ = closesocket(fd);
        }

        /// Nonblocking mode via ioctlsocket(FIONBIO): Winsock has no
        /// get/set-flags split — FIONBIO is the whole story.
        pub fn setNonblocking(fd: Fd) Error!void {
            var on: c_ulong = 1;
            if (ioctlsocket(fd, FIONBIO, &on) != 0) return error.SocketFlags;
        }

        pub const PollEvents = struct { in: bool = false, out: bool = false, err: bool = false, nval: bool = false };
        pub fn pollOne(fd: Fd, want_in: bool, want_out: bool, timeout_ms: c_int) Error!PollEvents {
            var pfds = [1]POLLFD{.{
                .fd = fd,
                .events = (if (want_in) POLLIN else 0) | (if (want_out) POLLOUT else 0),
                .revents = 0,
            }};
            const n = WSAPoll(&pfds, 1, timeout_ms);
            if (n < 0) return pollErr();
            const r = pfds[0].revents;
            return .{
                .in = (r & (POLLIN | POLLHUP)) != 0,
                .out = (r & POLLOUT) != 0,
                .err = (r & (POLLERR | POLLHUP)) != 0,
                .nval = (r & POLLNVAL) != 0,
            };
        }

        /// Bytes read; error.WouldBlock/ConnectionResetByPeer are preserved
        /// for the nonblocking read loop in `fillMore`. rc==0 is EOF.
        pub fn readFd(fd: Fd, buf: []u8) Error!usize {
            const rc = recv(fd, buf.ptr, @intCast(buf.len), 0);
            if (rc == 0) return error.EndOfStream;
            if (rc < 0) return recvErr();
            return @intCast(rc);
        }

        /// send() on a saturated nonblocking socket returns WSAEWOULDBLOCK
        /// *or* a literal 0; both mean "accepted nothing".
        pub fn writeFd(fd: Fd, buf: []const u8) Error!usize {
            const rc = send(fd, buf.ptr, @intCast(buf.len), 0);
            if (rc < 0) return sendErr();
            if (rc == 0) return error.WouldBlock;
            return @intCast(rc);
        }

        /// send() never raises SIGPIPE on Windows, so send == write here.
        pub const sendFd = writeFd;

        pub fn setSockOptInt(fd: Fd, level: c_int, opt: c_int, value: i32) Error!void {
            const v: i32 = value;
            if (setsockopt(fd, level, opt, &v, @sizeOf(i32)) != 0) return error.SocketOption;
        }
        pub fn getSockOptInt(fd: Fd, level: c_int, opt: c_int) Error!i32 {
            var v: i32 = 0;
            var n: c_int = @sizeOf(i32);
            if (getsockopt(fd, level, opt, &v, &n) != 0) return error.SocketOption;
            return v;
        }

        /// Abortive close is a no-op on Windows: Winsock answers an RST by
        /// discarding bytes the peer has not read yet, so the client reads
        /// `ConnectionResetByPeer` where the tests (and posix) show
        /// `EndOfStream`. Loopback TIME_WAIT is not a real hazard at a test
        /// suite's scale, and Winsock already emits RST on a plain close when
        /// inbound data is still pending.
        pub fn lingerAbort(fd: Fd) void {
            _ = fd;
        }

        /// Winsock has no TIOCOUTQ/SO_NWRITE equivalent: report "unknown" so
        /// callers fall back to their partial-send backstop.
        pub fn sendQueueBytes(fd: Fd) ?i32 {
            _ = fd;
            return null;
        }

        /// Connect initiated: ok on success and on every "in flight"
        /// answer a blocking or nonblocking socket can give.
        pub fn connectNow(fd: Fd, name: *const anyopaque, len: u32) Error!void {
            if (connect(fd, @ptrCast(@alignCast(name)), @intCast(len)) != 0) {
                return switch (WSAGetLastError()) {
                    WSAE.WOULDBLOCK, WSAE.INPROGRESS, WSAE.ALREADY, WSAE.ISCONN => {},
                    WSAE.CONNREFUSED => error.ConnectionRefused,
                    else => error.ConnectFailed,
                };
            }
        }

        pub fn bindFd(fd: Fd, name: *const anyopaque, len: u32) Error!void {
            if (bind(fd, @ptrCast(@alignCast(name)), @intCast(len)) != 0) return error.BindFailed;
        }
        pub fn listenFd(fd: Fd, backlog: c_int) Error!void {
            if (listen(fd, backlog) != 0) return error.ListenFailed;
        }
        /// Port actually bound, for ephemeral-port fixtures. Family-agnostic:
        /// the buffer is sized for a v6 sockaddr so getsockname doesn't refuse
        /// a v6 socket the way an `in`-sized one would.
        pub fn boundPort(fd: Fd) u16 {
            var buf: [64]u8 align(8) = undefined;
            var n: c_int = buf.len;
            if (getsockname(fd, @ptrCast(&buf), &n) != 0) return 0;
            const base: *const ws2.sockaddr = @ptrCast(&buf);
            return switch (base.family) {
                ws2.AF.INET => std.mem.bigToNative(u16, @as(*const ws2.sockaddr.in, @ptrCast(&buf)).port),
                ws2.AF.INET6 => std.mem.bigToNative(u16, @as(*const ws2.sockaddr.in6, @ptrCast(&buf)).port),
                else => 0,
            };
        }
        /// Accepted fd, or null on a nonblocking EAGAIN (any failure).
        pub fn acceptFd(lfd: Fd) ?Fd {
            var ca: ws2.sockaddr.storage = std.mem.zeroes(ws2.sockaddr.storage);
            var cl: c_int = @sizeOf(@TypeOf(ca));
            const a = accept(lfd, @ptrCast(&ca), &cl);
            if (isInvalid(a)) return null;
            return a;
        }
        /// Stop the send side (FIN), keep the receive side — the fixture
        /// half-close.
        pub fn shutdownWrite(fd: Fd) void {
            _ = shutdown(fd, 1); // SD_SEND
        }

        pub fn socketInet() Error!Fd {
            return socketFam(ws2.AF.INET);
        }
        /// Fresh TCP socket of an address family (AF.INET / AF.INET6).
        pub fn socketFam(family: c_int) Error!Fd {
            const s = socket(family, ws2.SOCK.STREAM, ws2.IPPROTO.TCP);
            if (isInvalid(s)) return error.SocketOpen;
            return s;
        }

        pub const AddrInfo = struct {
            list: ?*addrinfo,
            cur: ?*addrinfo,
            pub fn next(self: *AddrInfo) ?*addrinfo {
                const c = self.cur orelse return null;
                self.cur = c.next;
                return c;
            }
            pub fn deinit(self: *AddrInfo) void {
                freeaddrinfo(self.list);
                self.list = null;
                self.cur = null;
            }
        };
        /// getaddrinfo via the narrow (ANSI) Winsock API. Hostnames here are
        /// config strings and in practice IP literals, so the ANSI entry point
        /// is adequate.
        pub fn getAddrInfo(host: []const u8, port: u16) Error!AddrInfo {
            ensureWsa();
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const al = arena.allocator();
            const hostz = al.dupeZ(u8, host) catch return error.SystemResources;
            var portbuf: [16]u8 = undefined;
            const portz = std.fmt.bufPrintZ(&portbuf, "{d}", .{port}) catch unreachable;
            var hints = std.mem.zeroes(addrinfo);
            hints.family = ws2.AF.UNSPEC;
            hints.socktype = ws2.SOCK.STREAM;
            hints.protocol = ws2.IPPROTO.TCP;
            var res: ?*addrinfo = null;
            if (getaddrinfo(hostz.ptr, portz, &hints, &res) != 0) return error.UnknownHost;
            return .{ .list = res, .cur = res };
        }
        /// Socket + nonblocking + connect initiated for one addrinfo node.
        pub fn connectNode(ai: *const addrinfo) Error!Fd {
            const sa = ai.addr orelse return error.ConnectFailed;
            const fd = socket(ai.family, ai.socktype, ai.protocol);
            if (isInvalid(fd)) return error.SocketOpen;
            errdefer closeFd(fd);
            try setNonblocking(fd);
            try connectNow(fd, sa, @intCast(ai.addrlen));
            return fd;
        }

        /// Loopback sockaddr for tests (`in` layout matches posix: family,
        /// port big-endian, addr big-endian, zero pad).
        pub fn loopbackIn(port_be: u16) ws2.sockaddr.in {
            var sa = std.mem.zeroes(ws2.sockaddr.in);
            sa.family = ws2.AF.INET;
            sa.port = port_be;
            sa.addr = std.mem.bytesToValue(u32, &[4]u8{ 127, 0, 0, 1 });
            return sa;
        }

        /// A connected pair of loopback TCP sockets — the Winsock stand-in for
        /// socketpair(2), which does not exist there. Test fixtures only.
        /// Blocking connect+accept complete synchronously on loopback, so the
        /// pair comes back blocking like the posix version does.
        pub fn socketpair() Error![2]Fd {
            ensureWsa();
            const lfd = try socketInet();
            defer closeFd(lfd);
            var sa = loopbackIn(0); // kernel chooses the port
            try bindFd(lfd, &sa, @sizeOf(@TypeOf(sa)));
            try listenFd(lfd, 1);
            sa.port = std.mem.nativeToBig(u16, boundPort(lfd));

            const cfd = try socketInet();
            errdefer closeFd(cfd);
            try connectNow(cfd, &sa, @sizeOf(@TypeOf(sa)));

            const afd = accept(lfd, null, null);
            if (isInvalid(afd)) return error.AcceptFailed;
            return .{ cfd, afd };
        }
    },
    else => struct {
        pub const Fd = std.posix.socket_t;
        pub const invalid: Fd = -1;
        pub fn isInvalid(fd: Fd) bool {
            return fd < 0;
        }
        pub fn ensureWsa() void {}

        pub fn closeFd(fd: Fd) void {
            _ = std.posix.errno(std.posix.system.close(fd));
        }
        pub fn setNonblocking(fd: Fd) Error!void {
            var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
            o.NONBLOCK = true;
            _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
        }
        pub const PollEvents = struct { in: bool = false, out: bool = false, err: bool = false, nval: bool = false };
        pub fn pollOne(fd: Fd, want_in: bool, want_out: bool, timeout_ms: c_int) Error!PollEvents {
            var pfd = [_]std.posix.pollfd{.{
                .fd = fd,
                .events = (if (want_in) std.posix.POLL.IN else 0) | (if (want_out) std.posix.POLL.OUT else 0),
                .revents = 0,
            }};
            _ = try std.posix.poll(&pfd, timeout_ms);
            const r = pfd[0].revents;
            return .{
                .in = (r & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0,
                .out = (r & std.posix.POLL.OUT) != 0,
                .err = (r & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0,
                .nval = (r & std.posix.POLL.NVAL) != 0,
            };
        }
        pub fn readFd(fd: Fd, buf: []u8) Error!usize {
            while (true) {
                const n = std.posix.system.read(fd, buf.ptr, buf.len);
                switch (std.posix.errno(n)) {
                    .SUCCESS => {
                        if (n == 0) return error.ConnectionClosed;
                        return n;
                    },
                    .AGAIN => return error.WouldBlock,
                    .INTR => continue,
                    else => return error.Unexpected,
                }
            }
        }
        pub fn writeFd(fd: Fd, buf: []const u8) Error!usize {
            while (true) {
                const n = std.posix.system.write(fd, buf.ptr, buf.len);
                switch (std.posix.errno(n)) {
                    .SUCCESS => {
                        // a 0-byte write accepted nothing — same handling as
                        // EAGAIN so write loops don't spin
                        if (n == 0) return error.WouldBlock;
                        return n;
                    },
                    .AGAIN => return error.WouldBlock,
                    .INTR => continue,
                    else => return error.ConnectionClosed,
                }
            }
        }
        /// MSG_NOSIGNAL where it exists; plain write() on macOS, which gets
        /// SIGPIPE suppression from SO_NOSIGPIPE at connect time instead.
        pub fn sendFd(fd: Fd, buf: []const u8) Error!usize {
            if (builtin.os.tag == .macos) return writeFd(fd, buf);
            while (true) {
                const n = std.posix.system.send(fd, buf.ptr, buf.len, std.posix.MSG.NOSIGNAL);
                switch (std.posix.errno(n)) {
                    .SUCCESS => {
                        if (n == 0) return error.WouldBlock;
                        return n;
                    },
                    .AGAIN => return error.WouldBlock,
                    .INTR => continue,
                    else => return error.ConnectionClosed,
                }
            }
        }
        pub fn setSockOptInt(fd: Fd, level: c_int, opt: c_int, value: i32) Error!void {
            try std.posix.setsockopt(fd, level, @intCast(opt), &std.mem.toBytes(value));
        }
        pub fn getSockOptInt(fd: Fd, level: c_int, opt: c_int) Error!i32 {
            var v: i32 = 0;
            var n: std.c.socklen_t = @sizeOf(i32);
            if (std.c.getsockopt(fd, level, @intCast(opt), &v, &n) != 0) return error.SocketOption;
            return v;
        }

        /// Abortive close (RST on close, not FIN) — test fixtures use it so a
        /// torn-down server does not park the port in TIME_WAIT.
        pub fn lingerAbort(fd: Fd) void {
            const li = std.posix.linger{ .onoff = 1, .linger = 0 };
            std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.LINGER, &std.mem.toBytes(li)) catch {};
        }

        /// Unsent bytes in the kernel send queue (Linux TIOCOUTQ / Darwin
        /// SO_NWRITE). Null where the OS cannot answer; callers then use
        /// their partial-send backstop, which measures the same thing.
        extern "c" fn ioctl(fd: std.c.fd_t, request: c_ulong, ...) c_int;
        const tiocoutq_linux = 0x5411;
        const so_nwrite_darwin = 0x1024;
        pub fn sendQueueBytes(fd: Fd) ?i32 {
            if (builtin.os.tag == .linux) {
                var v: c_int = 0;
                if (ioctl(fd, tiocoutq_linux, &v) == 0) return v;
                return null;
            } else if (builtin.os.tag == .macos) {
                var v: c_int = 0;
                var len: std.c.socklen_t = @sizeOf(c_int);
                if (std.c.getsockopt(fd, std.c.SOL.SOCKET, so_nwrite_darwin, &v, &len) == 0) return v;
                return null;
            }
            return null;
        }

        /// Connect initiated: ok on success and on every "in flight" answer
        /// a blocking or nonblocking socket can give (INTR means the kernel
        /// is still connecting; ISCONN means it already did).
        pub fn connectNow(fd: Fd, name: *const anyopaque, len: u32) Error!void {
            switch (std.posix.errno(std.posix.system.connect(fd, @ptrCast(@alignCast(name)), len))) {
                .SUCCESS, .INPROGRESS, .INTR, .ISCONN => {},
                .CONNREFUSED => return error.ConnectionRefused,
                else => return error.ConnectFailed,
            }
        }
        pub fn bindFd(fd: Fd, name: *const anyopaque, len: u32) Error!void {
            if (std.posix.errno(std.posix.system.bind(fd, @ptrCast(@alignCast(name)), len)) != .SUCCESS)
                return error.BindFailed;
        }
        pub fn listenFd(fd: Fd, backlog: c_int) Error!void {
            if (std.posix.errno(std.posix.system.listen(fd, @intCast(backlog))) != .SUCCESS)
                return error.ListenFailed;
        }
        /// Port actually bound, for ephemeral-port fixtures. Family-agnostic:
        /// the buffer is sized for a v6 sockaddr so getsockname doesn't
        /// refuse a v6 socket the way an `in`-sized one would.
        pub fn boundPort(fd: Fd) u16 {
            var buf: [64]u8 align(8) = undefined;
            var n: std.posix.socklen_t = buf.len;
            if (std.posix.system.getsockname(fd, @ptrCast(&buf), &n) != 0) return 0;
            const base: *const std.posix.sockaddr = @ptrCast(&buf);
            return switch (base.family) {
                std.posix.AF.INET => std.mem.bigToNative(u16, @as(*const std.posix.sockaddr.in, @ptrCast(&buf)).port),
                std.posix.AF.INET6 => std.mem.bigToNative(u16, @as(*const std.posix.sockaddr.in6, @ptrCast(&buf)).port),
                else => 0,
            };
        }
        pub fn acceptFd(lfd: Fd) ?Fd {
            var ca: std.posix.sockaddr = undefined;
            var cl: std.posix.socklen_t = @sizeOf(@TypeOf(ca));
            const a = std.posix.system.accept(lfd, @ptrCast(&ca), &cl);
            if (std.posix.errno(a) != .SUCCESS) return null;
            return @intCast(a);
        }
        /// Stop the send side (FIN), keep the receive side — the fixture
        /// half-close.
        pub fn shutdownWrite(fd: Fd) void {
            _ = std.posix.system.shutdown(fd, std.posix.SHUT.WR);
        }
        pub fn socketInet() Error!Fd {
            return socketFam(std.posix.AF.INET);
        }
        /// Fresh TCP socket of an address family (AF.INET / AF.INET6).
        pub fn socketFam(family: c_int) Error!Fd {
            const s = std.posix.system.socket(@intCast(family), std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
            if (std.posix.errno(s) != .SUCCESS) return error.SocketOpen;
            return @intCast(s);
        }

        pub const AddrInfo = struct {
            head: ?*std.posix.addrinfo,
            cur: ?*std.posix.addrinfo,
            pub fn next(self: *AddrInfo) ?*std.posix.addrinfo {
                const c = self.cur orelse return null;
                self.cur = c.next;
                return c;
            }
            pub fn deinit(self: *AddrInfo) void {
                if (self.head) |h| std.posix.freeaddrinfo(h);
                self.head = null;
                self.cur = null;
            }
        };
        pub fn getAddrInfo(host: []const u8, port: u16) Error!AddrInfo {
            var portbuf: [16]u8 = undefined;
            const portz = std.fmt.bufPrintZ(&portbuf, "{d}", .{port}) catch unreachable;
            var hostbuf: [256]u8 = undefined;
            if (host.len >= hostbuf.len) return error.UnknownHost;
            @memcpy(hostbuf[0..host.len], host);
            hostbuf[host.len] = 0;
            const hostz: [*:0]const u8 = @ptrCast(&hostbuf);
            const hints: std.posix.addrinfo = .{
                .flags = .{},
                .family = std.posix.AF.UNSPEC,
                .socktype = std.posix.SOCK.STREAM,
                .protocol = std.posix.IPPROTO.TCP,
                .addrlen = 0,
                .canonname = null,
                .addr = null,
                .next = null,
            };
            var res: ?*std.posix.addrinfo = null;
            const rc = std.posix.system.getaddrinfo(hostz, portz, &hints, &res);
            if (@intFromEnum(rc) != 0) return error.UnknownHost;
            return .{ .head = res, .cur = res };
        }
        pub fn connectNode(ai: *const std.posix.addrinfo) Error!Fd {
            const fd = std.posix.system.socket(@intCast(ai.family), @intCast(ai.socktype), @intCast(ai.protocol));
            if (std.posix.errno(fd) != .SUCCESS) return error.SocketOpen;
            const sfd: Fd = @intCast(fd);
            errdefer closeFd(sfd);
            try setNonblocking(sfd);
            try connectNow(sfd, ai.addr.?, ai.addrlen);
            return sfd;
        }
        pub fn loopbackIn(port_be: u16) std.posix.sockaddr.in {
            var sa = std.mem.zeroes(std.posix.sockaddr.in);
            sa.family = std.posix.AF.INET;
            sa.port = port_be;
            sa.addr = std.mem.bytesToValue(u32, &[4]u8{ 127, 0, 0, 1 });
            return sa;
        }
        /// AF_UNIX socketpair on unix; loopback TCP pair on Windows. The pair
        /// shapes differ where it matters (Darwin SO_NWRITE cannot see a unix
        /// socket's queue), so tests that measure TCP accounting use
        /// `tcpPair`-style fixtures built on `socketInet` instead.
        pub fn socketpair() Error![2]Fd {
            var fds: [2]std.posix.fd_t = undefined;
            switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
                .SUCCESS => return fds,
                else => return error.SocketPairFailed,
            }
        }
    },
};

pub const Conn = struct {
    io: std.Io = undefined,
    fd: sys.Fd = sys.invalid,

    rbuf: [65536]u8 = undefined,
    rhead: usize = 0,
    rtail: usize = 0,

    // #14: bounded storage, not a backlog of stale audio. Uploads may leave
    // only ONE in-flight frame here; small control frames queue behind its
    // mandatory tail. A control flood fails explicitly rather than growing.
    wbuf: [4 * (max_payload + 5)]u8 = undefined,
    woff: usize = 0,
    wlen: usize = 0,

    last_recv_ms: i64 = 0,
    last_send_ms: i64 = 0,

    pub fn connect(io: std.Io, host: []const u8, port: u16) !Conn {
        sys.ensureWsa();
        // fast path: dotted-quad IPv4 literal
        if (std.Io.net.Ip4Address.parse(host, port)) |ip4| {
            const sa = sockaddrIn(ip4);
            return connectSockaddr(io, std.posix.AF.INET, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
        } else |_| {}

        // fast path: IPv6 literal. The CLI strips the brackets of
        // `--host [::1]:port`, so the text arrives bare (`::1`). A `%zone`
        // scope is refused here (error.UnresolvedScope) on purpose: getaddrinfo
        // below resolves scoped forms, and duplicating if_nametoindex would be
        // a second copy of one job.
        if (std.Io.net.Ip6Address.parse(host, port)) |ip6| {
            const sa = sockaddrIn6(ip6);
            return connectSockaddr(io, std.posix.AF.INET6, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
        } else |_| {}

        // hostname: getaddrinfo (libc / Winsock). AF.UNSPEC, not AF.INET: the
        // resolver returns both families in its own preference order (RFC
        // 6724), and the loop below connects to the first entry that answers —
        // so a v6-first resolver still reaches a v4-only server by falling
        // through the refused v6 attempt, and vice versa. Taking only the
        // first entry would be happy-eyeballs by luck rather than by
        // construction.
        var infos = try sys.getAddrInfo(host, port);
        defer infos.deinit();

        // getaddrinfo can return many entries; a host has at most two families
        // that matter here, and the fixed array is a deliberate bound rather
        // than an allocation. The addrs are borrowed from the list, which
        // outlives the connect loop below.
        var cands: [16]Candidate = undefined;
        var ncands: usize = 0;
        while (infos.next()) |ai| {
            if (ai.addrlen == 0 or ai.addr == null) continue;
            if (ncands == cands.len) break;
            cands[ncands] = .{ .family = ai.family, .addr = ai.addr.?, .len = @intCast(ai.addrlen) };
            ncands += 1;
        }
        return connectCandidates(io, cands[0..ncands]);
    }

    /// One place a host may be reached: an address of a specific family, in
    /// the form `connect` accepts. `addr` is borrowed and must outlive the
    /// connect attempt.
    pub const Candidate = struct {
        family: c_int,
        addr: *const anyopaque,
        len: u32,
    };

    /// The connect loop proper, separated from where candidates come from
    /// (literals, getaddrinfo) so the fallthrough is testable without betting
    /// on the resolver's ordering of `localhost`.
    ///
    /// The property it exists to keep: **one failed candidate is not a failed
    /// host.** A v6-first resolver must still reach a v4-only server — the
    /// refused v6 connect falls through to the next entry — and a v4-only
    /// resolver reaches a v6-only one the same way. Taking the first entry and
    /// dying on it would be happy-eyeballs by luck rather than by construction.
    fn connectCandidates(io: std.Io, candidates: []const Candidate) !Conn {
        for (candidates) |c| {
            if (connectSockaddr(io, c.family, c.addr, c.len)) |conn| {
                return conn;
            } else |_| continue;
        }
        return error.UnknownHost;
    }

    pub fn closeFd(fd: sys.Fd) void {
        sys.closeFd(fd);
    }

    pub fn setNonblocking(fd: sys.Fd) Error!void {
        try sys.setNonblocking(fd);
    }

    fn sockaddrIn(ip4: std.Io.net.Ip4Address) std.posix.sockaddr.in {
        const In = std.posix.sockaddr.in;
        var sa: In = std.mem.zeroes(In);
        if (@hasField(In, "len")) sa.len = @sizeOf(In);
        sa.family = std.posix.AF.INET;
        sa.port = std.mem.nativeToBig(u16, ip4.port);
        // sockaddr stores network-order bytes in memory; bytes are already
        // in network order, so a native-endian reinterpretation is correct.
        sa.addr = @bitCast(ip4.bytes);
        return sa;
    }

    /// The IPv6 twin of `sockaddrIn`, for the literal fast path. The scoped
    /// `%zone` forms never reach here (see `connect`), so `scope_id` is the
    /// address's own interface index — 0 for every unscoped literal.
    fn sockaddrIn6(ip6: std.Io.net.Ip6Address) std.posix.sockaddr.in6 {
        const In6 = std.posix.sockaddr.in6;
        var sa: In6 = std.mem.zeroes(In6);
        if (@hasField(In6, "len")) sa.len = @sizeOf(In6);
        sa.family = std.posix.AF.INET6;
        sa.port = std.mem.nativeToBig(u16, ip6.port);
        sa.flowinfo = ip6.flow;
        sa.addr = ip6.bytes;
        sa.scope_id = ip6.interface.index;
        return sa;
    }

    /// Open a stream socket of `family`, connect it to `sa` (a `sockaddr.in`,
    /// a `sockaddr.in6`, or an addrinfo's own sockaddr — all the same bytes to
    /// `connect`), and return the non-blocking `Conn`.
    fn connectSockaddr(io: std.Io, family: c_int, sa: *const anyopaque, len: u32) !Conn {
        const fd = try sys.socketFam(family);
        errdefer sys.closeFd(fd);
        // latency-sensitive protocol: TCP_NODELAY
        sys.setSockOptInt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, 1) catch {};
        // blocking connect (like the reference client's jnetlib), then go async
        sys.connectNow(fd, sa, len) catch return error.ConnectionRefused;
        try sys.setNonblocking(fd);
        if (builtin.os.tag == .macos) {
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &std.mem.toBytes(@as(c_int, 1)));
        }
        return connected(io, fd);
    }

    fn connected(io: std.Io, fd: sys.Fd) Conn {
        return .{
            .io = io,
            .fd = fd,
            .last_recv_ms = clock.nowMs(io),
            .last_send_ms = clock.nowMs(io),
        };
    }

    pub fn close(self: *Conn) void {
        sys.closeFd(self.fd);
        self.fd = sys.invalid;
    }

    pub fn isConnected(self: *const Conn) bool {
        return !sys.isInvalid(self.fd);
    }

    /// Wait until the socket is readable or timeout_ms elapses. Returns true
    /// if readable.
    pub fn pollReadable(self: *Conn, timeout_ms: i32) !bool {
        if (sys.isInvalid(self.fd)) return error.ConnectionClosed;
        const ev = try sys.pollOne(self.fd, true, false, timeout_ms);
        return ev.in or ev.out or ev.err or ev.nval;
    }

    fn fillMore(self: *Conn) Error!void {
        if (sys.isInvalid(self.fd)) return error.ConnectionClosed;
        // compact if full
        if (self.rtail == self.rbuf.len) {
            if (self.rhead > 0) {
                const live = self.rtail - self.rhead;
                std.mem.copyForwards(u8, self.rbuf[0..live], self.rbuf[self.rhead..self.rtail]);
                self.rhead = 0;
                self.rtail = live;
            } else {
                return error.BadFrame; // >64KiB buffered and still no full frame
            }
        }
        const n = sys.readFd(self.fd, self.rbuf[self.rtail..]) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return e,
        };
        self.rtail += n;
        self.last_recv_ms = clock.nowMs(self.io);
    }

    fn ensureBuffered(self: *Conn, n: usize) Error!void {
        while (self.rtail - self.rhead < n) {
            const before = self.rtail - self.rhead;
            try self.fillMore();
            if (self.rtail - self.rhead == before) {
                // #14: even a partial inbound frame must return control to the
                // audio clock. Keep its bytes buffered until the next pass.
                return error.WouldBlock;
            }
        }
    }

    /// Read one framed message. `payload` receives a copy of the payload
    /// bytes; the returned Message points into it.
    pub fn readMessage(self: *Conn, payload: *bufmod.Buf) Error!Message {
        try self.ensureBuffered(5);
        const t = self.rbuf[self.rhead];
        var size_bytes: [4]u8 = undefined;
        @memcpy(&size_bytes, self.rbuf[self.rhead + 1 ..][0..4]);
        const size = std.mem.readInt(u32, &size_bytes, .little);
        if (t == 0xFF or size > max_payload) return error.BadFrame;
        try self.ensureBuffered(5 + @as(usize, size));
        payload.clear();
        try payload.add(self.rbuf[self.rhead + 5 ..][0..size]);
        self.rhead += 5 + @as(usize, size);
        return .{ .mtype = t, .payload = payload.items() };
    }

    fn writeAllRaw(self: *Conn, data: []const u8) Error!void {
        if (sys.isInvalid(self.fd)) return error.ConnectionClosed;
        var off: usize = 0;
        while (off < data.len) {
            const n = sys.writeFd(self.fd, data[off..]) catch |e| switch (e) {
                error.WouldBlock => {
                    _ = try sys.pollOne(self.fd, false, true, 1000);
                    continue;
                },
                else => return error.ConnectionClosed,
            };
            off += n;
        }
        self.last_send_ms = clock.nowMs(self.io);
    }

    pub fn sendMessage(self: *Conn, mtype: u8, payload: []const u8) Error!void {
        if (payload.len > max_payload) return error.BadFrame;
        var hdr: [5]u8 = undefined;
        hdr[0] = mtype;
        std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
        try self.writeAllRaw(&hdr);
        if (payload.len > 0) try self.writeAllRaw(payload);
    }

    /// #14: no polling, sleeping, or retry-on-EAGAIN on the session's write
    /// path. A partial frame remains owned here until its tail is flushed.
    /// Work is bounded by the fixed queue size, even if the peer keeps reading.
    pub fn flushWrites(self: *Conn) Error!bool {
        if (sys.isInvalid(self.fd)) return error.ConnectionClosed;
        while (self.woff < self.wlen) {
            const bytes = self.wbuf[self.woff..self.wlen];
            const n = sys.sendFd(self.fd, bytes) catch |e| switch (e) {
                error.WouldBlock => return false,
                else => return error.ConnectionClosed,
            };
            if (n == 0) return error.ConnectionClosed;
            self.woff += n;
            self.last_send_ms = clock.nowMs(self.io);
        }
        self.woff = 0;
        self.wlen = 0;
        return true;
    }

    fn appendFrame(self: *Conn, mtype: u8, payload: []const u8) Error!void {
        if (payload.len > max_payload) return error.BadFrame;
        const need = payload.len + 5;
        if (self.wlen + need > self.wbuf.len and self.woff > 0) {
            std.mem.copyForwards(u8, self.wbuf[0 .. self.wlen - self.woff], self.wbuf[self.woff..self.wlen]);
            self.wlen -= self.woff;
            self.woff = 0;
        }
        if (self.wlen + need > self.wbuf.len) return error.WriteQueueFull;
        const frame = self.wbuf[self.wlen..][0..need];
        frame[0] = mtype;
        std.mem.writeInt(u32, frame[1..5], @intCast(payload.len), .little);
        @memcpy(frame[5..], payload);
        self.wlen += need;
    }

    /// Control frames cannot be dropped, but must not block behind an upload.
    /// Preserve their order in the bounded queue and flush from the run loop.
    pub fn queueMessage(self: *Conn, mtype: u8, payload: []const u8) Error!void {
        _ = try self.flushWrites();
        try self.appendFrame(mtype, payload);
        _ = try self.flushWrites();
    }

    /// Attempt an upload once. No bytes written => decline; some written =>
    /// retain only this frame's tail and tell the caller to drop the bar.
    /// Never append another upload behind a stalled frame.
    pub fn trySendMessage(self: *Conn, mtype: u8, payload: []const u8) Error!WriteOutcome {
        if (payload.len > max_payload) return error.BadFrame;
        if (!try self.flushWrites()) return .declined;
        // This is an optimization, not an atomicity promise: Linux buffer
        // accounting and Darwin AF_UNIX queue depth can overstate the room.
        if (self.sendRoom()) |room| {
            if (room < payload.len + 5) return .declined;
        }
        try self.appendFrame(mtype, payload);
        if (try self.flushWrites()) return .sent;
        if (self.woff > 0) return .pending;
        self.wlen = 0;
        return .declined;
    }

    /// Send `data`, giving the socket at most `budget_ms` **in total** to accept
    /// it. See `SendOutcome` for what the three results mean.
    ///
    /// This exists because `writeAllRaw` cannot be used by the audio clock. The
    /// socket is non-blocking (`setNonblocking` runs right after connect), so a
    /// peer that stops reading turns `write` into EAGAIN — and `writeAllRaw`'s
    /// answer is to `poll(POLLOUT, 1000)` **in a loop, discarding the return
    /// value**. It therefore does not wait "up to a second"; it waits a second,
    /// wakes, tries again, waits another second, and so on, *forever*, until
    /// the peer reads or the connection dies. `finalizeInterval` calls `send()`
    /// inline on the interval-generation path, so that unbounded wait is a
    /// direct stall of the audio clock — measured at >5 s and still not
    /// returning, for a single 16 KiB upload against a socket with an 8 KiB
    /// buffer (see `src/kujamba_timing.zig`, #14).
    ///
    /// The partial result is reported as `.partial` and is the *only* honest
    /// answer. An earlier version of this function returned a plain `false`,
    /// with a comment claiming a torn frame was benign because "both ends frame
    /// by the declared length, so the server simply never completes that guid".
    /// That is backwards, and it is the load-bearing bug #14's own mechanism
    /// exposes. The server frames by the declared length, so it *does* complete
    /// the frame — with the next bar's bytes as its missing payload — and then
    /// parses whatever comes after as a header from mid-stream. A fresh guid does
    /// not help, because the server never sees those bytes as a guid; they are
    /// the tail of the frame before. So the first torn frame costs the rest of
    /// the session's uploads, silently and permanently — which is the dead
    /// performance this PR exists to prevent, minus the honesty of a disconnect.
    /// Measured, before this fix: a half-full socket, a 16 KiB frame, a zero
    /// budget — `false`, and 6000 bytes on the wire.
    fn writeAllBounded(self: *Conn, data: []const u8, budget_ms: i32) Error!SendOutcome {
        if (sys.isInvalid(self.fd)) return error.ConnectionClosed;
        if (data.len == 0) return .sent;
        // a deadline, not a per-attempt timeout: three brief stalls inside one
        // budget must not add up to three budgets
        const deadline_ms = clock.nowMs(self.io) + budget_ms;
        var off: usize = 0;
        while (off < data.len) {
            const n = sys.writeFd(self.fd, data[off..]) catch |e| switch (e) {
                error.WouldBlock => {
                    // bytes already accepted are bytes the peer will read, so
                    // from here on the frame is torn no matter what we do
                    if (off > 0) return .partial;
                    const left = deadline_ms - clock.nowMs(self.io);
                    if (left <= 0) return .declined;
                    _ = try sys.pollOne(self.fd, false, true, @intCast(left));
                    continue;
                },
                else => return error.ConnectionClosed,
            };
            off += n;
        }
        self.last_send_ms = clock.nowMs(self.io);
        return .sent;
    }

    /// `sendMessage` with a hard bound on how long it may wait for the peer,
    /// and with a promise the caller is allowed to rely on: **`.declined` means
    /// not one byte of this frame reached the wire.** The stream is therefore
    /// still correctly framed, and the caller may abandon whatever it was
    /// sending and carry on.
    ///
    /// Only the upload path (#14) uses this. Giving up on a bar is strictly
    /// better than stalling the audio clock behind it; every other message keeps
    /// using `sendMessage`.
    ///
    /// `budget_ms = 0` never waits at all, which is what an upload wants: it
    /// asks the socket "can you take this whole thing?" and acts on the answer
    /// instead of discovering it a second later.
    pub fn sendMessageBounded(self: *Conn, mtype: u8, payload: []const u8, budget_ms: i32) Error!SendOutcome {
        if (payload.len > max_payload) return error.BadFrame;

        // The atomicity gate. `writable()` cannot do this job: POLLOUT means
        // "at least one byte free", which is true of a socket with 6 KiB of room
        // as well as one with 6 KiB *of a 16 KiB frame's worth* still owed. Ask
        // instead whether the whole frame fits, and decline before touching the
        // wire if it does not. Nothing is raced by doing this first: the session
        // has exactly one writer for this socket, so the only thing that can
        // change between the check and the write is the queue draining (which
        // adds room) or the kernel's own autotuning shrinking the buffer (which
        // is caught as `.partial` below, not silently).
        const need = 5 + payload.len;
        if (self.sendRoom()) |room| {
            if (room < need) return .declined;
        }

        var hdr: [5]u8 = undefined;
        hdr[0] = mtype;
        std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
        switch (try self.writeAllBounded(&hdr, budget_ms)) {
            .sent => {},
            .declined => return .declined,
            .partial => return .partial,
        }
        if (payload.len == 0) return .sent;
        switch (try self.writeAllBounded(payload, budget_ms)) {
            .sent => return .sent,
            // the header is already on the wire, so these bytes are not optional
            .declined, .partial => return .partial,
        }
    }

    /// Would the socket accept *something* right now?
    ///
    /// A zero-timeout `poll`, i.e. "is the peer keeping up" asked without paying
    /// to find out. Note what it is **not**: it does not say the socket can take
    /// any particular frame. POLLOUT is set as soon as one byte is free, so a
    /// socket with a few KiB free answers true while being unable to accept a
    /// 16 KiB upload — and trusting it there is exactly what tore frames.
    /// `sendMessageBounded` asks the real question itself, so this is only a
    /// cheap pre-gate now, never the authority.
    pub fn writable(self: *Conn) bool {
        if (sys.isInvalid(self.fd)) return false;
        const ev = sys.pollOne(self.fd, false, true, 0) catch return false;
        return ev.out;
    }

    /// Bytes the kernel can accept on this socket right now, or null if this
    /// platform does not let us find out.
    ///
    /// `SO_SNDBUF` is the buffer's capacity and `TIOCOUTQ` is how much of it is
    /// still occupied, so the difference is the room. Both are needed: the
    /// capacity alone says nothing about how full the buffer is, which is the
    /// half-full case that tore frames.
    ///
    /// Null is not a licence to tear a frame. It only means the pre-check is
    /// unavailable, in which case `sendMessageBounded` falls back to the write
    /// loop and relies on `.partial` to catch a tear — a worse but still
    /// correct failure, never a silent one.
    pub fn sendRoom(self: *Conn) ?usize {
        if (sys.isInvalid(self.fd)) return null;
        const cap = sendBufBytes(self.fd) orelse return null;
        const queued = sys.sendQueueBytes(self.fd) orelse return null;
        if (queued < 0) return 0;
        const q: usize = @intCast(queued);
        if (q >= cap) return 0;
        return cap - q;
    }
};

/// `SO_SNDBUF`, i.e. the send buffer's capacity in bytes.
fn sendBufBytes(fd: sys.Fd) ?usize {
    const v = sys.getSockOptInt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF) catch return null;
    if (v <= 0) return null;
    return @intCast(v);
}

// Bytes queued for transmission and not yet freed by the peer — see
// `sys.sendQueueBytes`: TIOCOUTQ on Linux, SO_NWRITE on Darwin, null
// (→ `.partial` backstop) where the OS cannot answer, including Windows.

/// Push bytes until the kernel send queue refuses; returns the byte count
/// queued. Test fixtures use this to saturate a socket on platforms where a
/// pinned `SO_SNDBUF` cannot — Windows buffers by internal backlog, not by
/// the SNDBUF number, so on Windows saturation takes ~128 KiB of queued data
/// rather than a small pinned buffer. The bytes land in the stream: callers
/// that also read the peer must drain them first.
pub fn fillKernelSend(fd: sys.Fd) Error!usize {
    const junk: [16389]u8 = @splat(0xab);
    var total: usize = 0;
    while (true) {
        const n = sys.sendFd(fd, &junk) catch |e| switch (e) {
            error.WouldBlock => return total,
            else => return e,
        };
        total += n;
    }
}
//
// There is no one way to ask for this, and finding that out was its own
// afternoon. `TIOCOUTQ` is the obvious answer and it works on Linux — but
// Darwin does not implement it for sockets at all: both the `'t'` spelling from
// its own `<sys/ttycom.h>` and the `'f'` spelling return `ENOTSUP`, measured on
// a socketpair and on loopback TCP alike. The same number is available on
// Darwin as the `SO_NWRITE` socket option instead. So: spelled out per target
// rather than guessed, with an unknown target yielding null — which disables
// the pre-check and falls back to the `.partial` backstop, a worse but still
// safe answer.

test "framing constants" {
    try std.testing.expectEqual(@as(u32, 16384), max_payload);
}

// ---- connect tests (#23) -----------------------------------------------------
//
// These drive `Conn.connect` against a real loopback listener, because the
// failure they guard against is not expressible without a socket: the bug this
// issue fixed was an `openStreamSocket` hard-coded to AF.INET — which cannot
// even be constructed against a v6 listener — and a hints struct pinned to
// AF.INET, which returns no v6 results to iterate at all. Both are invisible
// to any test that does not actually cross a socket.

/// Reads exactly `buf.len` bytes off a blocking socket; EOF mid-read fails.
fn readExact(fd: sys.Fd, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = sys.readFd(fd, buf[got..]) catch |e| switch (e) {
            error.EndOfStream => return error.EndOfStream,
            else => return e,
        };
        got += n;
    }
}

/// A loopback listener built on the `sys` seam rather than `std.Io.net`:
/// on Windows the Io.net listener's handle is a kernel AFD endpoint, not a
/// Winsock SOCKET, so only `sys` can accept on a socket `Conn` can reach.
/// (The fixtures exercise `Conn` end-to-end, which is Winsock on Windows.)
fn loopbackListener(ip: std.Io.net.IpAddress) !sys.Fd {
    sys.ensureWsa();
    switch (ip) {
        .ip4 => |ip4| {
            const lfd = try sys.socketFam(std.posix.AF.INET);
            errdefer sys.closeFd(lfd);
            const sa = Conn.sockaddrIn(ip4);
            try sys.bindFd(lfd, &sa, @sizeOf(@TypeOf(sa)));
            try sys.listenFd(lfd, 4);
            return lfd;
        },
        .ip6 => |ip6| {
            const lfd = try sys.socketFam(std.posix.AF.INET6);
            errdefer sys.closeFd(lfd);
            const sa = Conn.sockaddrIn6(ip6);
            try sys.bindFd(lfd, &sa, @sizeOf(@TypeOf(sa)));
            try sys.listenFd(lfd, 4);
            return lfd;
        },
    }
}

/// One framed round-trip over a freshly connected `Conn`: connect to the
/// already-listening `lfd` by `host` text, then check the exchange.
fn expectRoundTrip(io: std.Io, host: []const u8, lfd: sys.Fd) !void {
    const port = sys.boundPort(lfd);
    var conn = try Conn.connect(io, host, port);
    defer conn.close();
    try assertRoundTrip(&conn, lfd);
}

/// The exchange itself: send a message from the client side and check the
/// bytes the server-side socket receives — type byte, little-endian length,
/// payload — the whole framing contract in one exchange. `lfd` must already
/// have `conn` in its backlog.
fn assertRoundTrip(conn: *Conn, lfd: sys.Fd) !void {
    // O_NONBLOCK is observable via fcntl on posix; on Windows nonblocking is
    // FIONBIO state with no query back, so the flag check is posix-only.
    if (builtin.os.tag != .windows) {
        const flags: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(conn.fd, std.c.F.GETFL, @as(c_int, 0)))));
        try std.testing.expect(flags.NONBLOCK);
    }
    try conn.sendMessage(0x41, "hello");

    // Accept *after* the client has connected and sent: the connection waits
    // in the listener's backlog and the bytes in the kernel's buffers, so the
    // whole exchange needs no second thread. The listener here is blocking.
    const cfd = sys.acceptFd(lfd) orelse return error.AcceptFailed;
    defer Conn.closeFd(cfd);

    var buf: [10]u8 = undefined;
    try readExact(cfd, &buf);
    try std.testing.expectEqual(@as(u8, 0x41), buf[0]);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, buf[1..5], .little));
    try std.testing.expectEqualStrings("hello", buf[5..10]);
}

test "connect: dotted-quad IPv4 literal round-trips a frame" {
    const lfd = try loopbackListener(.{ .ip4 = .loopback(0) });
    defer sys.closeFd(lfd);
    try expectRoundTrip(std.testing.io, "127.0.0.1", lfd);
}

test "connect: IPv6 literal round-trips a frame" {
    // The skip is for containers with IPv6 switched off at the kernel, where
    // binding ::1 fails and no test in the repo could exercise this path.
    // Everywhere this suite is expected to run — macOS, Linux and Windows CI
    // runners all answer on ::1 — this is a real assertion: `::1` must reach
    // the AF.INET6 socket.
    const lfd = loopbackListener(.{ .ip6 = .loopback(0) }) catch |e| switch (e) {
        error.BindFailed, error.SocketOpen => return error.SkipZigTest,
        else => return e,
    };
    defer sys.closeFd(lfd);
    try expectRoundTrip(std.testing.io, "::1", lfd);
}

test "connect: hostname resolves through AF.UNSPEC and falls through families" {
    // "localhost" resolves to ::1 and 127.0.0.1 in some order on both CI
    // platforms, and the resolver's order decides whether this run exercises
    // the fallthrough — so this test proves the resolution path only, and the
    // fallthrough has its own seam test below that does not depend on the
    // resolver's mood.
    const lfd = try loopbackListener(.{ .ip4 = .loopback(0) });
    defer sys.closeFd(lfd);
    try expectRoundTrip(std.testing.io, "localhost", lfd);
}

test "connect: a refused candidate falls through to the next family" {
    // The seam version of the resolver test, with the ordering problem
    // removed: the candidate list is v6-first *by construction* — a dead v6
    // port, then the live v4 listener — so the property "one failed candidate
    // is not a failed host" is exercised no matter how this machine's
    // resolver orders localhost. Mutating `connectCandidates` to break on the
    // first refused candidate fails exactly here.
    const lfd = try loopbackListener(.{ .ip4 = .loopback(0) });
    defer sys.closeFd(lfd);
    const port = sys.boundPort(lfd);

    var dead: std.posix.sockaddr.in6 = std.mem.zeroes(std.posix.sockaddr.in6);
    dead.family = std.posix.AF.INET6;
    dead.port = std.mem.nativeToBig(u16, 1); // loopback port 1: nothing listens
    dead.addr[15] = 1;
    var live: std.posix.sockaddr.in = std.mem.zeroes(std.posix.sockaddr.in);
    live.family = std.posix.AF.INET;
    live.port = std.mem.nativeToBig(u16, port);
    live.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
    const cands = [_]Conn.Candidate{
        .{ .family = std.posix.AF.INET6, .addr = @ptrCast(&dead), .len = @sizeOf(std.posix.sockaddr.in6) },
        .{ .family = std.posix.AF.INET, .addr = @ptrCast(&live), .len = @sizeOf(std.posix.sockaddr.in) },
    };
    var conn = try Conn.connectCandidates(std.testing.io, &cands);
    defer conn.close();
    try assertRoundTrip(&conn, lfd);
}

test "sockaddrIn6: builds the wire struct for a loopback literal" {
    const ip6 = try std.Io.net.Ip6Address.parse("::1", 20531);
    const sa = Conn.sockaddrIn6(ip6);
    try std.testing.expectEqual(@as(std.posix.sa_family_t, std.posix.AF.INET6), sa.family);
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 20531), sa.port);
    try std.testing.expectEqual(@as(u8, 1), sa.addr[15]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 15, sa.addr[0..15]);
    try std.testing.expectEqual(@as(u32, 0), sa.scope_id);
}

fn nonblockingTestPair() ![2]sys.Fd {
    const fds = try sys.socketpair();
    errdefer for (fds) |fd| Conn.closeFd(fd);
    for (fds) |fd| try Conn.setNonblocking(fd);
    try sys.setSockOptInt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, 4096);
    try sys.setSockOptInt(fds[1], std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, 4096);
    return fds;
}

/// Read up to `want` bytes off a nonblocking socket, retrying WouldBlock,
/// and return how many arrived.
fn drainSome(fd: sys.Fd, want: usize) !usize {
    var got: usize = 0;
    var tries: u32 = 0;
    var buf: [8192]u8 = undefined;
    while (got < want and tries < 100000) : (tries += 1) {
        got += sys.readFd(fd, buf[0..@min(want - got, buf.len)]) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
    }
    return got;
}

test "#14: a partial frame retains its tail ahead of control messages, without waiting" {
    const fds = try nonblockingTestPair();
    defer for (fds) |fd| Conn.closeFd(fd);
    var conn = Conn{ .io = std.testing.io, .fd = fds[0] };
    const payload = [_]u8{0x5a} ** max_payload;
    // Saturate the kernel send queue first: a pinned SO_SNDBUF does the job
    // on posix, but Windows ignores that pin and only stalls on its internal
    // backlog (~128 KiB measured) — so fill until WouldBlock either way. The
    // filler bytes are drained from the peer below, ahead of the frames.
    const prefill = try fillKernelSend(fds[0]);
    var junk_left = prefill;
    const t0 = clock.nowNs(std.testing.io);
    // Control queuing uses the same writer as uploads and deliberately bypasses
    // the advisory sendRoom gate. Force a short write to test tail ownership.
    try conn.queueMessage(0x84, &payload);
    if (builtin.os.tag == .windows) {
        // Winsock's nonblocking send() never partial-copies — it takes the
        // whole buffer or refuses it — so there is no woff>0 middle to land
        // on. The tail sits in wbuf whole, and wlen>0 is the same ownership
        // guarantee the posix branch measures as a consumed prefix.
        try std.testing.expect(conn.wlen > 0);
    } else {
        // Where a pinned buffer makes the first write partial by itself, some
        // posix kernels need the room opened a little at a time: drain filler
        // 1 KiB per pass until the kernel accepts some-but-not-all.
        var guard: u32 = 0;
        while (conn.woff == 0 and junk_left > 0 and guard < 256) : (guard += 1) {
            junk_left -= try drainSome(fds[1], @min(junk_left, 1024));
            _ = try conn.flushWrites();
        }
        try std.testing.expect(conn.woff > 0);
        try std.testing.expect(conn.woff < conn.wlen);
    }
    try conn.queueMessage(0xc0, "ping");
    try std.testing.expectEqual(WriteOutcome.declined, try conn.trySendMessage(0x83, "next bar"));
    try std.testing.expect(clock.nowNs(std.testing.io) - t0 < 500 * std.time.ns_per_ms);

    var expected: [max_payload + 5 + 9]u8 = undefined;
    expected[0] = 0x84;
    std.mem.writeInt(u32, expected[1..5], max_payload, .little);
    @memcpy(expected[5..][0..max_payload], &payload);
    expected[max_payload + 5] = 0xc0;
    std.mem.writeInt(u32, expected[max_payload + 6 ..][0..4], 4, .little);
    @memcpy(expected[max_payload + 10 ..], "ping");

    var received: [expected.len]u8 = undefined;
    var got: usize = 0;
    var junk: [8192]u8 = undefined;
    const deadline = clock.nowMs(std.testing.io) + 5000;
    while ((junk_left > 0 or got < received.len) and clock.nowMs(std.testing.io) < deadline) {
        _ = try conn.flushWrites();
        if (junk_left > 0) {
            junk_left -= sys.readFd(fds[1], junk[0..@min(junk_left, junk.len)]) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return e,
            };
        } else {
            got += sys.readFd(fds[1], received[got..]) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return e,
            };
        }
    }
    try std.testing.expectEqual(expected.len, got);
    try std.testing.expectEqualSlices(u8, &expected, &received);
    try std.testing.expect(try conn.flushWrites());
    try std.testing.expectEqual(WriteOutcome.sent, try conn.trySendMessage(0x83, "next bar"));
}

test "#14: the control queue is bounded even while the peer never drains" {
    const fds = try nonblockingTestPair();
    defer for (fds) |fd| Conn.closeFd(fd);
    var conn = Conn{ .io = std.testing.io, .fd = fds[0] };
    const payload = [_]u8{0x5a} ** max_payload;
    // Saturate the kernel queue so the wbuf has to carry the frames — on
    // Windows the SNDBUF pin above is advisory and this is the only way to
    // get the socket to refuse bytes.
    _ = try fillKernelSend(fds[0]);
    var full = false;
    for (0..8) |_| {
        conn.queueMessage(0xc0, &payload) catch |e| {
            try std.testing.expectEqual(error.WriteQueueFull, e);
            full = true;
            break;
        };
    }
    try std.testing.expect(full);
    try std.testing.expect(conn.wlen <= conn.wbuf.len);
}

test "#14: an incomplete incoming frame yields and resumes from buffered bytes" {
    const fds = try nonblockingTestPair();
    defer for (fds) |fd| Conn.closeFd(fd);
    var conn = Conn{ .io = std.testing.io, .fd = fds[1] };
    var payload = bufmod.Buf.init(std.testing.allocator);
    defer payload.deinit();
    const first = "\xc0\x06\x00\x00\x00abc";
    try std.testing.expectEqual(first.len, try sys.writeFd(fds[0], first));
    const t0 = clock.nowNs(std.testing.io);
    try std.testing.expectError(error.WouldBlock, conn.readMessage(&payload));
    try std.testing.expect(clock.nowNs(std.testing.io) - t0 < 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 3), try sys.writeFd(fds[0], "def"));
    const msg = try conn.readMessage(&payload);
    try std.testing.expectEqual(@as(u8, 0xc0), msg.mtype);
    try std.testing.expectEqualStrings("abcdef", msg.payload);
}
