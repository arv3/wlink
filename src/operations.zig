//! Predefined operations for WCH-Link — the `ProbeSession`.

const std = @import("std");
const commands = @import("commands.zig");
const probe_mod = @import("probe.zig");
const WchLink = probe_mod.WchLink;
const RiscvChip = @import("riscv_chip.zig").RiscvChip;
const Error = @import("error.zig").Error;

const Speed = commands.Speed;
const ConfigChip = commands.ConfigChip;

/// Sleep helper. Uses libc (already linked via libusb) so the library stays
/// independent of the std Io instance.
pub fn sleepMs(ms: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

fn setSpeed(p: *WchLink, riscvchip: u8, speed: Speed) Error!void {
    try p.send(commands.CMD_SET_SPEED, &.{ riscvchip, @intFromEnum(speed) });
}

fn expectU8(payload: []const u8) Error!u8 {
    if (payload.len != 1) return Error.InvalidPayloadLength;
    return payload[0];
}

/// A running probe session: attach, flash, erase, inspect, etc.
pub const ProbeSession = struct {
    probe: WchLink,
    chip_family: RiscvChip,
    speed: Speed,

    /// Attach the probe to the target chip and start a session.
    pub fn attach(probe_in: WchLink, expected_chip: ?RiscvChip, speed: Speed) Error!ProbeSession {
        var probe = probe_in;
        const chip = expected_chip orelse RiscvChip.CH32V103;

        if (!probe.info.variant.supportChip(chip)) {
            std.log.err("Current WCH-Link variant doesn't support the chosen MCU, please use WCH-LinkE!", .{});
            return Error.UnsupportedChip;
        }

        var attempts: u8 = 0;
        const chip_info: commands.AttachChipResponse = while (true) {
            try setSpeed(&probe, @intFromEnum(chip), speed);
            if (probe.transact(commands.CMD_CONTROL, commands.ctl.attach_chip)) |payload| {
                break try commands.AttachChipResponse.parse(payload);
            } else |e| {
                std.log.debug("attach error {t}, retrying...", .{e});
                if (attempts >= 3) return e;
                sleepMs(100);
            }
            attempts += 1;
        };

        std.log.info("Attached chip: {f}", .{chip_info});

        if (expected_chip) |exp| {
            if (chip_info.chip_family != exp) {
                std.log.err("Attached chip type ({t}) does not match expected chip type ({t})", .{ chip_info.chip_family, exp });
                return Error.ChipMismatch;
            }
        }

        // Set speed again with the actual family when auto-detecting.
        if (expected_chip == null) {
            try setSpeed(&probe, @intFromEnum(chip_info.chip_family), speed);
        }

        try doPostInit(chip_info.chip_family, &probe);

        return ProbeSession{
            .probe = probe,
            .chip_family = chip_info.chip_family,
            .speed = speed,
        };
    }

    pub fn deinit(self: *ProbeSession) void {
        self.probe.deinit();
    }

    pub fn detachChip(self: *ProbeSession) Error!void {
        std.log.debug("Detach chip", .{});
        try self.probe.send(commands.CMD_CONTROL, commands.ctl.opt_end);
    }

    fn reattachChip(self: *ProbeSession) Error!void {
        std.log.debug("Reattach chip", .{});
        try self.detachChip();
        _ = try self.probe.transact(commands.CMD_CONTROL, commands.ctl.attach_chip);
    }

    /// Dump chip info (ESIG, flash-protect status, RAM/ROM split). Halts the MCU.
    pub fn dumpInfo(self: *ProbeSession) Error!void {
        if (self.chip_family.supportQueryInfo()) {
            const variant: commands.ESignature.Variant =
                if (self.probe.info.versionAtLeast(2, 9)) .v2 else .v1;
            const raw = try self.probe.transactRaw(commands.CMD_GET_CHIP_INFO, &.{@intFromEnum(variant)});
            const esig = try commands.ESignature.parseRaw(raw);
            std.log.info("Chip ESIG: {f}", .{esig});

            const fp = try expectU8(try self.probe.transact(commands.CMD_CONFIG_CHIP, ConfigChip.check_read_protect));
            const protected = fp == ConfigChip.FLAG_READ_PROTECTED;
            std.log.info("Flash protected: {}", .{protected});
            if (protected) {
                std.log.warn("Flash is protected, debug access is not available", .{});
            }
        }
        if (self.chip_family.supportRamRomMode()) {
            const split = try expectU8(try self.probe.transact(commands.CMD_CONTROL, commands.ctl.get_rom_ram_split));
            std.log.debug("SRAM CODE split mode: {d}", .{split});
        }
    }

    pub fn softReset(self: *ProbeSession) Error!void {
        try self.probe.send(commands.CMD_RESET, commands.Reset.soft.payload());
    }

    pub fn setSdiPrintEnabled(self: *ProbeSession, enable: bool) Error!void {
        if (!self.probe.info.variant.supportSdiPrint()) {
            std.log.err("Probe doesn't support SDI print functionality", .{});
            return Error.Custom;
        }
        if (!self.chip_family.supportSdiPrint()) {
            std.log.err("Chip doesn't support SDI print functionality", .{});
            return Error.Custom;
        }
        try self.probe.send(commands.CMD_CONTROL, commands.ctl.setSdiPrintEnabled(enable));
    }

    fn checkReadProtect(self: *ProbeSession) Error!u8 {
        return expectU8(try self.probe.transact(commands.CMD_CONFIG_CHIP, ConfigChip.check_read_protect));
    }
    fn checkReadProtectEx(self: *ProbeSession) Error!u8 {
        return expectU8(try self.probe.transact(commands.CMD_CONFIG_CHIP, ConfigChip.check_read_protect_ex));
    }

    pub fn unprotectFlash(self: *ProbeSession) Error!void {
        try self.reattachChip(); // HACK: requires a fresh attach

        var read_protected = try self.checkReadProtect();
        // Skip Unprotect when not protected: the probe firmware mass-erases the
        // option-byte page, wiping USER/Data/WRPR.
        if (read_protected == ConfigChip.FLAG_READ_PROTECTED) {
            try self.probe.send(commands.CMD_CONFIG_CHIP, ConfigChip.unprotect);
            try self.reattachChip();
            read_protected = try self.checkReadProtect();
        }
        std.log.info("Read protected: {}", .{read_protected == ConfigChip.FLAG_READ_PROTECTED});

        const write_protected = try self.checkReadProtectEx();
        if (write_protected == ConfigChip.FLAG_WRITE_PROTECTED) {
            std.log.warn("Flash is write protected!", .{});
            std.log.warn("try to unprotect...", .{});
            var buf: [8]u8 = undefined;
            try self.probe.send(commands.CMD_CONFIG_CHIP, ConfigChip.unprotectEx(0xff, &buf));
            try self.reattachChip();
            const wp = try self.checkReadProtectEx();
            std.log.info("Write protected: {}", .{wp == ConfigChip.FLAG_WRITE_PROTECTED});
        }
    }

    pub fn protectFlash(self: *ProbeSession) Error!void {
        try self.reattachChip();

        if (try self.checkReadProtect() == ConfigChip.FLAG_READ_PROTECTED) {
            std.log.warn("Flash already protected", .{});
        }
        try self.probe.send(commands.CMD_CONFIG_CHIP, ConfigChip.protect);
        try self.reattachChip();
        const rp = try self.checkReadProtect();
        std.log.info("Read protected: {}", .{rp == ConfigChip.FLAG_READ_PROTECTED});
    }

    /// Erase flash and re-attach.
    pub fn eraseFlash(self: *ProbeSession) Error!void {
        if (self.chip_family.supportFlashProtect()) {
            const ret = try self.checkReadProtect();
            if (ret == ConfigChip.FLAG_READ_PROTECTED) {
                std.log.warn("Flash is protected, unprotecting...", .{});
                try self.unprotectFlash();
            } else if (ret == ConfigChip.FLAG_READ_UNPROTECTED) {
                const wp = try self.checkReadProtectEx();
                if (wp == ConfigChip.FLAG_WRITE_PROTECTED) {
                    std.log.warn("Flash is write protected, unprotecting...", .{});
                    try self.unprotectFlash();
                } else if (wp != ConfigChip.FLAG_WRITE_UNPROTECTED) {
                    std.log.warn("Unknown flash write protect status: {d}", .{wp});
                }
            } else {
                std.log.warn("Unknown flash protect status: {d}", .{ret});
            }
        }
        try self.probe.send(commands.CMD_PROGRAM, &.{@intFromEnum(commands.Program.erase_flash)});
        _ = try self.probe.transact(commands.CMD_CONTROL, commands.ctl.attach_chip);
    }

    /// Write `data` to flash at `address` (wlink_write). `progress` is called with
    /// running (written, total) byte counts.
    pub fn writeFlash(
        self: *ProbeSession,
        data: []const u8,
        address: u32,
        progress_ctx: ?*anyopaque,
        progress: ?*const fn (ctx: ?*anyopaque, written: usize, total: usize) void,
    ) Error!void {
        const chip = self.chip_family;
        const write_pack_size = chip.writePackSize();
        const data_packet_size = chip.dataPacketSize();

        if (chip.supportFlashProtect()) try self.unprotectFlash();

        std.log.debug("Using write pack size {d} data pack size {d}", .{ write_pack_size, data_packet_size });

        var region: [8]u8 = undefined;
        try self.probe.send(commands.CMD_SET_WRITE_REGION, commands.memRegionPayload(&region, address, @intCast(data.len)));

        try self.probe.send(commands.CMD_PROGRAM, &.{@intFromEnum(commands.Program.write_flash_op)});
        const flash_op = try chip.getFlashOp();
        try self.probe.writeData(flash_op, data_packet_size);
        std.log.debug("Flash OP written", .{});

        const n = expectU8(try self.probe.transact(commands.CMD_PROGRAM, &.{@intFromEnum(commands.Program.unknown07_after_flash_op)})) catch return Error.Custom;
        if (n != 0x07) {
            std.log.err("Unknown07AfterFlashOPWritten failed (got 0x{x:0>2})", .{n});
            return Error.Custom;
        }

        try self.probe.send(commands.CMD_PROGRAM, &.{@intFromEnum(commands.Program.write_flash)});

        var written: usize = 0;
        const total = data.len;
        var off: usize = 0;
        while (off < data.len) {
            const chunk = data[off..@min(off + write_pack_size, data.len)];
            try self.probe.writeData(chunk, data_packet_size);

            var rxbuf: [4]u8 = undefined;
            try self.probe.readData(&rxbuf);
            // 41 01 01 04
            if (rxbuf[3] != 0x04) {
                std.log.err("Error while fastprogram: {x}", .{rxbuf});
                return Error.Custom;
            }
            written += chunk.len;
            if (progress) |f| f(progress_ctx, written, total);
            off += chunk.len;
        }
        std.log.debug("Fastprogram done", .{});

        try self.probe.send(commands.CMD_PROGRAM, &.{@intFromEnum(commands.Program.end)});
    }

    /// Read a continuous memory region (requires the MCU to be halted). Caller owns
    /// the returned slice. `length` is rounded up to a multiple of 4.
    pub fn readMemory(self: *ProbeSession, allocator: std.mem.Allocator, address: u32, length: u32) (Error || std.mem.Allocator.Error)![]u8 {
        var len = length;
        if (len % 4 != 0) len = (len / 4 + 1) * 4;

        var region: [8]u8 = undefined;
        try self.probe.send(commands.CMD_SET_READ_REGION, commands.memRegionPayload(&region, address, len));
        try self.probe.send(commands.CMD_PROGRAM, &.{@intFromEnum(commands.Program.read_memory)});

        const mem = try allocator.alloc(u8, len);
        errdefer allocator.free(mem);
        try self.probe.readData(mem);

        // Fix endianness: reverse each 4-byte word.
        var i: usize = 0;
        while (i + 4 <= mem.len) : (i += 4) std.mem.reverse(u8, mem[i .. i + 4]);

        if (mem.len >= 4 and mem[0] == 0xA9 and mem[1] == 0xBD and mem[2] == 0xF9 and mem[3] == 0xF3) {
            std.log.warn("A9 BD F9 F3 sequence detected!", .{});
            std.log.warn("If the chip is just put into debug mode, flash new firmware first", .{});
            std.log.warn("Or else this indicates a read to an invalid location", .{});
        }
        return mem;
    }

    /// Clear all code flash by powering off the target (WCH-LinkE only).
    pub fn eraseFlashByPowerOff(p: *WchLink, chip_family: RiscvChip) Error!void {
        if (!p.info.variant.supportPowerFuncs()) {
            std.log.err("Probe doesn't support power off erase", .{});
            return Error.Custom;
        }
        if (!chip_family.supportSpecialErase()) {
            std.log.err("Chip doesn't support power off erase", .{});
            return Error.Custom;
        }
        try setSpeed(p, @intFromEnum(chip_family), .high);
        var buf: [2]u8 = undefined;
        try p.send(commands.CMD_CONTROL, commands.eraseCodeFlashByPowerOff(chip_family, &buf));
    }

    /// Clear all code flash via the RST pin (WCH-LinkE only).
    pub fn eraseFlashByRstPin(p: *WchLink, chip_family: RiscvChip) Error!void {
        if (!p.info.variant.supportPowerFuncs()) {
            std.log.err("Probe doesn't support reset pin erase", .{});
            return Error.Custom;
        }
        if (!chip_family.supportSpecialErase()) {
            std.log.err("Chip doesn't support reset pin erase", .{});
            return Error.Custom;
        }
        try setSpeed(p, @intFromEnum(chip_family), .high);
        var buf: [2]u8 = undefined;
        try p.send(commands.CMD_CONTROL, commands.eraseCodeFlashByPinRst(chip_family, &buf));
    }
};

/// Device-specific post-attach logic.
fn doPostInit(chip: RiscvChip, p: *WchLink) Error!void {
    switch (chip) {
        .CH32V103 => {
            _ = try p.transact(commands.CMD_CONTROL, &.{0x03});
        },
        .CH32V30X, .CH8571, .CH32V003 => {
            // (commented out in the Rust source)
        },
        .CH57X, .CH582 => {
            std.log.warn("The debug interface has been opened, there is a risk of code leakage.", .{});
            std.log.warn("Please ensure that the debug interface has been closed before leaving factory!", .{});
        },
        .CH56X => {
            std.log.warn("The debug interface has been opened, there is a risk of code leakage.", .{});
            std.log.warn("Please ensure that the debug interface has been closed before leaving factory!", .{});
            const resp = try p.transact(commands.CMD_CONTROL, &.{0x04});
            std.log.debug("TODO, handle CH56X resp {x}", .{resp});
        },
        else => {},
    }
}
