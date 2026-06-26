//! The wlink library — public API surface for use as a Zig dependency.
//!
//! A downstream project depends on this via `build.zig.zon` and imports it as:
//!     const wlink = @import("wlink");
//!     const probe = try wlink.WchLink.openNth(allocator, 0);

const std = @import("std");

pub const errors = @import("error.zig");
pub const Error = errors.Error;
pub const AbstractcsCmdErr = errors.AbstractcsCmdErr;

pub const RiscvChip = @import("riscv_chip.zig").RiscvChip;

pub const chips = @import("chips.zig");
pub const flash_op = @import("flash_op.zig");

pub const usb = @import("usb.zig");
pub const commands = @import("commands.zig");
pub const Speed = commands.Speed;
pub const probe = @import("probe.zig");
pub const WchLink = probe.WchLink;
pub const WchLinkVariant = probe.WchLinkVariant;
pub const ProbeInfo = probe.ProbeInfo;
pub const operations = @import("operations.zig");
pub const ProbeSession = operations.ProbeSession;
pub const regs = @import("regs.zig");
pub const dmi = @import("dmi.zig");
pub const firmware = @import("firmware.zig");
pub const flash = @import("flash.zig");
pub const serial_monitor = @import("serial_monitor.zig");

test {
    // Pull in all unit tests from the modules that have them.
    std.testing.refAllDecls(@This());
    _ = @import("chips.zig");
    _ = @import("riscv_chip.zig");
    _ = @import("commands.zig");
    _ = @import("regs.zig");
    _ = @import("dmi.zig");
    _ = @import("firmware.zig");
}
