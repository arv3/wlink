//! Currently supported RISC-V chip series/family and per-family behaviour.

const std = @import("std");
const flash_op = @import("flash_op.zig");
const Error = @import("error.zig").Error;

/// RISC-V chip family, value is the `riscvchip` byte used by the probe protocol.
pub const RiscvChip = enum(u8) {
    /// CH32V103 RISC-V3A series
    CH32V103 = 0x01,
    /// CH571/CH573 RISC-V3A BLE 4.2 series
    CH57X = 0x02,
    /// CH565/CH569 RISC-V3A series
    CH56X = 0x03,
    /// CH32V20X RISC-V4B/V4C series
    CH32V20X = 0x05,
    /// CH32V30X RISC-V4C/V4F series, the same as type 5
    CH32V30X = 0x06,
    /// CH583/CH582/CH581 RISC-V4A BLE 5.3 series (use CH582 as the common one)
    CH582 = 0x07,
    /// CH32V003 RISC-V2A series
    CH32V003 = 0x09,
    /// RISC-V EC controller, undocumented.
    CH8571 = 0x0A,
    /// CH59x RISC-V4C BLE 5.4 series, fallback as CH58X
    CH59X = 0x0B,
    /// CH643 RISC-V4C series, RGB Display Driver MCU
    CH643 = 0x0C,
    /// CH32X035 RISC-V4C USB-PD series, fallback as CH643
    CH32X035 = 0x0D,
    /// CH32L103 RISC-V4C low power series, USB-PD
    CH32L103 = 0x0E,
    /// CH564 RISC-V4J series
    CH564 = 0x0F,
    /// CH645, CH653, RISC-V4C
    CH645 = 0x46,
    /// CH641 RISC-V2A series, USB-PD, fallback as CH32V003
    CH641 = 0x49,
    /// CH585/CH584 RISC-V3C series, BLE 5.4, NFC, USB HS, fallback as CH582
    CH585 = 0x4B,
    /// CH32V002/4/5/6/7, CH32M007
    CH32V00X = 0x4E,
    /// CH32V317 RISC-V4 series
    CH32V317 = 0x86,
    // Cortex-M chips
    CH32F10X = 0x04,
    CH32F20X = 0x08,
    /// CH32H415/CH32H416/CH32H417 RISC-V5F+RISC-V3F series
    CH32H41X = 0xC6,

    /// Parse the `riscvchip` byte returned by the probe.
    pub fn fromU8(value: u8) Error!RiscvChip {
        return switch (value) {
            0x01 => .CH32V103,
            0x02 => .CH57X,
            0x03 => .CH56X,
            0x05 => .CH32V20X,
            0x06 => .CH32V30X,
            0x07 => .CH582,
            0x09 => .CH32V003,
            0x0A => .CH8571,
            0x0B => .CH59X,
            0x0C => .CH643,
            0x0D => .CH32X035,
            0x0E => .CH32L103,
            0x49 => .CH641,
            0x4B => .CH585,
            0x0F => .CH564,
            0x4E => .CH32V00X,
            0x46 => .CH645,
            0x86 => .CH32V317,
            0x04 => .CH32F10X,
            0x08 => .CH32F20X,
            0xC6 => .CH32H41X,
            else => Error.UnknownChip,
        };
    }

    /// Parse a chip family from a user-supplied name (case-insensitive), reproducing
    /// the clap `ValueEnum::from_str` aliases. Returns null on an unknown name; the
    /// CH56X/CH58X ambiguous cases log a warning and resolve to the common variant.
    pub fn fromStr(input: []const u8) ?RiscvChip {
        var buf: [32]u8 = undefined;
        if (input.len > buf.len) return null;
        const s = std.ascii.upperString(buf[0..input.len], input);

        const eq = std.mem.eql;
        if (eq(u8, s, "CH32V103")) return .CH32V103;
        if (eq(u8, s, "CH32V20X") or eq(u8, s, "CH32V203") or eq(u8, s, "CH32V208")) return .CH32V20X;
        if (eq(u8, s, "CH32V30X") or eq(u8, s, "CH32V303") or eq(u8, s, "CH32V305") or eq(u8, s, "CH32V307")) return .CH32V30X;
        if (eq(u8, s, "CH32V317")) return .CH32V317;
        if (eq(u8, s, "CH32V003")) return .CH32V003;
        if (eq(u8, s, "CH32L103")) return .CH32L103;
        if (eq(u8, s, "CH32X0") or eq(u8, s, "CH32X03X") or eq(u8, s, "CH32X033") or eq(u8, s, "CH32X034") or eq(u8, s, "CH32X035")) return .CH32X035;
        if (eq(u8, s, "CH32V00X") or eq(u8, s, "CH32V002") or eq(u8, s, "CH32V004") or eq(u8, s, "CH32V005") or eq(u8, s, "CH32V006") or eq(u8, s, "CH32V007") or eq(u8, s, "CH32M007")) return .CH32V00X;
        if (eq(u8, s, "CH565") or eq(u8, s, "CH569")) return .CH56X;
        if (eq(u8, s, "CH57X") or eq(u8, s, "CH571") or eq(u8, s, "CH573")) return .CH57X;
        if (eq(u8, s, "CH581") or eq(u8, s, "CH582") or eq(u8, s, "CH583")) return .CH582;
        if (eq(u8, s, "CH584") or eq(u8, s, "CH585")) return .CH585;
        if (eq(u8, s, "CH564")) return .CH564;
        if (eq(u8, s, "CH59X") or eq(u8, s, "CH591") or eq(u8, s, "CH592")) return .CH59X;
        if (eq(u8, s, "CH641")) return .CH641;
        if (eq(u8, s, "CH643")) return .CH643;
        if (eq(u8, s, "CH645") or eq(u8, s, "CH653")) return .CH645;
        if (eq(u8, s, "CH8571")) return .CH8571;
        if (eq(u8, s, "CH56X")) {
            std.log.warn("Ambiguous chip family, assume CH569. use either CH564, CH565 or CH569 instead", .{});
            return .CH56X;
        }
        if (eq(u8, s, "CH58X")) {
            std.log.warn("Ambiguous chip family, assume CH582. use either CH582 or CH585 instead", .{});
            return .CH582;
        }
        if (eq(u8, s, "CH32H41X") or eq(u8, s, "CH32H415") or eq(u8, s, "CH32H415REU") or
            eq(u8, s, "CH32H415REU6") or eq(u8, s, "CH32H416") or eq(u8, s, "CH32H416RDU") or
            eq(u8, s, "CH32H416RDU6") or eq(u8, s, "CH32H417") or eq(u8, s, "CH32H417QEU") or
            eq(u8, s, "CH32H417QEU6") or eq(u8, s, "CH32H417MEU") or eq(u8, s, "CH32H417MEU6") or
            eq(u8, s, "CH32H417WEU") or eq(u8, s, "CH32H417WEU6")) return .CH32H41X;
        return null;
    }

    /// Support flash protect commands, and info query commands.
    pub fn supportFlashProtect(self: RiscvChip) bool {
        return switch (self) {
            .CH32V103, .CH32V20X, .CH32V30X, .CH32V003, .CH32V00X, .CH32L103, .CH32X035, .CH641, .CH645, .CH32V317, .CH32H41X => true,
            else => false,
        };
    }

    /// CH32V208xB, CH32V307, CH32V303RCT6/VCT6.
    pub fn supportRamRomMode(self: RiscvChip) bool {
        return switch (self) {
            .CH32V20X, .CH32V30X, .CH32V317 => true,
            else => false,
        };
    }

    /// Support config registers, query info (UID, etc).
    pub fn supportQueryInfo(self: RiscvChip) bool {
        return switch (self) {
            .CH57X, .CH56X, .CH582, .CH585, .CH59X => false,
            else => true,
        };
    }

    /// Very unsafe. Disables the chip's debug interface (command 810e0101).
    pub fn supportDisableDebug(self: RiscvChip) bool {
        return switch (self) {
            .CH57X, .CH56X, .CH582, .CH585, .CH59X => true,
            else => false,
        };
    }

    /// Erase code flash by RST pin or power-off.
    pub fn supportSpecialErase(self: RiscvChip) bool {
        return switch (self) {
            .CH57X, .CH56X, .CH582, .CH585, .CH59X => false,
            else => true,
        };
    }

    pub fn supportSdiPrint(self: RiscvChip) bool {
        return switch (self) {
            .CH32V003, .CH645, .CH32V00X, .CH32V103, .CH32V20X, .CH32V30X, .CH32X035, .CH32L103, .CH643, .CH641, .CH32V317 => true,
            else => false,
        };
    }

    pub fn isRv32e(self: RiscvChip) bool {
        return switch (self) {
            .CH32V003, .CH641, .CH32V00X => true,
            else => false,
        };
    }

    /// Per-family RAM flash-loader program.
    pub fn getFlashOp(self: RiscvChip) Error![]const u8 {
        return switch (self) {
            .CH32V003, .CH641 => &flash_op.CH32V003,
            .CH32V103 => &flash_op.CH32V103,
            .CH32V20X, .CH32V30X => &flash_op.CH32V307,
            .CH56X => &flash_op.CH569,
            .CH57X => &flash_op.CH573,
            .CH582, .CH59X, .CH585 => &flash_op.CH583,
            .CH8571 => &flash_op.OP8571,
            .CH32X035, .CH643 => &flash_op.CH643,
            .CH32L103 => &flash_op.CH32L103,
            .CH564 => &flash_op.CH564,
            .CH32V00X => &flash_op.CH32V00X,
            .CH645 => &flash_op.CH645,
            .CH32V317 => &flash_op.CH32V317,
            .CH32H41X => &flash_op.CH32H417,
            .CH32F10X, .CH32F20X => Error.UnsupportedChip,
        };
    }

    /// Packet data length of the data endpoint.
    pub fn dataPacketSize(self: RiscvChip) usize {
        return switch (self) {
            .CH32V103 => 128,
            .CH32V003, .CH641 => 64,
            else => 256,
        };
    }

    pub fn codeFlashStart(self: RiscvChip) u32 {
        return switch (self) {
            .CH56X, .CH57X, .CH582, .CH585, .CH59X, .CH8571 => 0x0000_0000,
            else => 0x0800_0000,
        };
    }

    /// The same as wch-openocd-riscv.
    pub fn fixCodeFlashStart(self: RiscvChip, start_address: u32) u32 {
        const addr = self.codeFlashStart() + start_address;
        return if (addr >= 0x10000000) addr - 0x08000000 else addr;
    }

    /// Pack size for fastprogram.
    pub fn writePackSize(self: RiscvChip) u32 {
        return switch (self) {
            .CH32V003, .CH641, .CH32V00X => 1024,
            else => 4096,
        };
    }
};

const testing = std.testing;

test "ch32h41x supports flash protect commands" {
    try testing.expect(RiscvChip.CH32H41X.supportFlashProtect());
}

test "ch32h41x aliases match openwch packages" {
    const aliases = [_][]const u8{
        "CH32H41X",       "CH32H415",       "CH32H415REU", "CH32H415REU6",
        "CH32H416",       "CH32H416RDU",    "CH32H416RDU6", "CH32H417",
        "CH32H417QEU",    "CH32H417QEU6",   "CH32H417MEU", "CH32H417MEU6",
        "CH32H417WEU",    "CH32H417WEU6",
    };
    for (aliases) |alias| {
        try testing.expectEqual(RiscvChip.CH32H41X, RiscvChip.fromStr(alias).?);
    }
}

test "fromStr is case insensitive" {
    try testing.expectEqual(RiscvChip.CH32V003, RiscvChip.fromStr("ch32v003").?);
    try testing.expectEqual(RiscvChip.CH32V30X, RiscvChip.fromStr("CH32V307").?);
    try testing.expectEqual(@as(?RiscvChip, null), RiscvChip.fromStr("nonsense"));
}
