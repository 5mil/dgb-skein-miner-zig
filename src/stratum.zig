//! Stratum client -- platform dispatch via comptime imports.
//! Zig 0.16 removed top-level `pub usingnamespace`; we re-export explicitly.
const builtin = @import("builtin");
const impl    = if (builtin.os.tag == .windows)
    @import("stratum_windows.zig")
else
    @import("stratum_linux.zig");

pub const Job           = impl.Job;
pub const StratumClient = impl.StratumClient;
