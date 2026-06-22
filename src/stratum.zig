//! Stratum client -- dispatches to platform implementation.
//! Linux/Android: posix sockets + linux.getaddrinfo
//! Windows:       Winsock2
const builtin = @import("builtin");

pub usingnamespace if (builtin.os.tag == .windows)
    @import("stratum_windows.zig")
else
    @import("stratum_linux.zig");
