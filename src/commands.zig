//! WCH-Link command framing.
//!
//! Request:        [0x81, CMD, LEN, PAYLOAD...]
//! Success reply:  [0x82, CMD, LEN, PAYLOAD...]
//! Error reply:    [0x81, REASON, LEN, PAYLOAD...]
//! where LEN == PAYLOAD.len.
//!
//! Typed command encoders/decoders are added in later phases; this module holds the
//! generic framing used by `WchLink.transact`.

const std = @import("std");
const Error = @import("error.zig").Error;
const RiscvChip = @import("riscv_chip.zig").RiscvChip;
const chips = @import("chips.zig");

pub const REQ_HEADER: u8 = 0x81;
pub const RESP_OK: u8 = 0x82;
pub const RESP_ERR: u8 = 0x81;

/// Protocol error reason: failed to connect with the riscvchip.
pub const REASON_CONNECT_FAILED: u8 = 0x55;

/// Build a request frame into `buf` and return the populated slice.
pub fn buildFrame(buf: []u8, cmd_id: u8, payload: []const u8) []u8 {
    std.debug.assert(payload.len <= 255);
    std.debug.assert(buf.len >= payload.len + 3);
    buf[0] = REQ_HEADER;
    buf[1] = cmd_id;
    buf[2] = @intCast(payload.len);
    @memcpy(buf[3..][0..payload.len], payload);
    return buf[0 .. payload.len + 3];
}

/// Validate a raw response and return its PAYLOAD slice (a sub-slice of `raw`).
/// Returns Error.Protocol for an error reply.
pub fn parseReply(raw: []const u8) Error![]const u8 {
    if (raw.len < 3) return Error.InvalidPayload;
    const tag = raw[0];
    const len: usize = raw[2];
    if (tag == RESP_OK) {
        if (len != raw.len - 3) return Error.InvalidPayloadLength;
        return raw[3 .. 3 + len];
    } else if (tag == RESP_ERR) {
        if (len != raw.len - 3) return Error.InvalidPayloadLength;
        return Error.Protocol;
    } else {
        return Error.InvalidPayload;
    }
}

// ---------------------------------------------------------------------------
// Command IDs
// ---------------------------------------------------------------------------
pub const CMD_SET_WRITE_REGION: u8 = 0x01;
pub const CMD_PROGRAM: u8 = 0x02;
pub const CMD_SET_READ_REGION: u8 = 0x03;
pub const CMD_CONFIG_CHIP: u8 = 0x06;
pub const CMD_DMI_OP: u8 = 0x08;
pub const CMD_RESET: u8 = 0x0b;
pub const CMD_SET_SPEED: u8 = 0x0c;
pub const CMD_CONTROL: u8 = 0x0d;
pub const CMD_DISABLE_DEBUG: u8 = 0x0e;
pub const CMD_GET_CHIP_INFO: u8 = 0x11;

// ---------------------------------------------------------------------------
// Speed (0x0c)
// ---------------------------------------------------------------------------
pub const Speed = enum(u8) {
    /// 400 kHz
    low = 0x03,
    /// 4000 kHz
    medium = 0x02,
    /// 6000 kHz (default)
    high = 0x01,

    pub fn fromStr(s: []const u8) ?Speed {
        if (std.ascii.eqlIgnoreCase(s, "low")) return .low;
        if (std.ascii.eqlIgnoreCase(s, "medium")) return .medium;
        if (std.ascii.eqlIgnoreCase(s, "high")) return .high;
        return null;
    }
};

// ---------------------------------------------------------------------------
// Reset (0x0b)
// ---------------------------------------------------------------------------
pub const Reset = enum {
    /// wlink_quitreset, reset and run (the most common reset)
    soft,
    normal,
    /// wlink_chip_reset, chip reset (memory not reset)
    chip,

    pub fn payload(self: Reset) []const u8 {
        return switch (self) {
            .soft => &.{0x01},
            .normal => &.{0x03},
            .chip => &.{0x02},
        };
    }
};

// ---------------------------------------------------------------------------
// Program subcommands (0x02)
// ---------------------------------------------------------------------------
pub const Program = enum(u8) {
    erase_flash = 0x01,
    write_flash = 0x02,
    write_flash_and_verify = 0x04,
    write_flash_op = 0x05,
    prepare = 0x06,
    unknown07_after_flash_op = 0x07,
    unknown0b_after_flash_op = 0x0b,
    end = 0x08,
    read_memory = 0x0c,
};

// ---------------------------------------------------------------------------
// ConfigChip (0x06)
// ---------------------------------------------------------------------------
pub const ConfigChip = struct {
    pub const FLAG_READ_PROTECTED: u8 = 0x01;
    pub const FLAG_READ_UNPROTECTED: u8 = 0x02;
    pub const FLAG_WRITE_PROTECTED: u8 = 0x11;
    pub const FLAG_WRITE_UNPROTECTED: u8 = 0x00;

    pub const check_read_protect: []const u8 = &.{0x01};
    pub const unprotect: []const u8 = &.{0x02};
    pub const protect: []const u8 = &.{0x03};
    pub const check_read_protect_ex: []const u8 = &.{0x04};

    pub fn unprotectEx(b: u8, buf: *[8]u8) []const u8 {
        buf.* = .{ 0x02, b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
        return buf;
    }
    pub fn protectEx(b: u8, buf: *[8]u8) []const u8 {
        buf.* = .{ 0x03, b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
        return buf;
    }
};

// ---------------------------------------------------------------------------
// Control subcommands (0x0d)
// ---------------------------------------------------------------------------
pub const ctl = struct {
    pub const get_probe_info: []const u8 = &.{0x01};
    pub const attach_chip: []const u8 = &.{0x02};
    pub const get_rom_ram_split: []const u8 = &.{0x04};
    pub const opt_end: []const u8 = &.{0xff};

    pub fn setSdiPrintEnabled(enable: bool) []const u8 {
        return if (enable) &.{ 0xee, 0x00 } else &.{ 0xee, 0x01 };
    }
};

/// SetPower subcommands (0x0d).
pub const SetPower = enum {
    enable_3v3,
    disable_3v3,
    enable_5v,
    disable_5v,

    pub fn payload(self: SetPower) []const u8 {
        return switch (self) {
            .enable_3v3 => &.{0x09},
            .disable_3v3 => &.{0x0A},
            .enable_5v => &.{0x0B},
            .disable_5v => &.{0x0C},
        };
    }

    pub fn fromStr(s: []const u8) ?SetPower {
        if (std.ascii.eqlIgnoreCase(s, "enable-3v3")) return .enable_3v3;
        if (std.ascii.eqlIgnoreCase(s, "disable-3v3")) return .disable_3v3;
        if (std.ascii.eqlIgnoreCase(s, "enable-5v")) return .enable_5v;
        if (std.ascii.eqlIgnoreCase(s, "disable-5v")) return .disable_5v;
        return null;
    }
};

/// EraseCodeFlash (0x0d), only on WCH-LinkE.
pub fn eraseCodeFlashByPinRst(chip: RiscvChip, buf: *[2]u8) []const u8 {
    buf.* = .{ 0x08, @intFromEnum(chip) };
    return buf;
}
pub fn eraseCodeFlashByPowerOff(chip: RiscvChip, buf: *[2]u8) []const u8 {
    buf.* = .{ 0x0f, @intFromEnum(chip) };
    return buf;
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

/// AttachChip reply (0x0d, 0x02).
pub const AttachChipResponse = struct {
    chip_family: RiscvChip,
    riscvchip: u8,
    chip_id: u32,

    pub fn parse(payload: []const u8) Error!AttachChipResponse {
        if (payload.len != 5) return Error.InvalidPayloadLength;
        return .{
            .chip_family = try RiscvChip.fromU8(payload[0]),
            .riscvchip = payload[0],
            .chip_id = std.mem.readInt(u32, payload[1..5], .big),
        };
    }

    pub fn format(self: AttachChipResponse, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.chip_id == 0) {
            try writer.print("{t}", .{self.chip_family});
        } else if (chips.chipIdToChipName(self.chip_id)) |chip_name| {
            try writer.print("{t} [{s}] (ChipID: 0x{x:0>8})", .{ self.chip_family, chip_name, self.chip_id });
        } else {
            try writer.print("{t} (ChipID: 0x{x:0>8})", .{ self.chip_family, self.chip_id });
        }
    }
};

/// Flash size and Chip UID (0x11). NOTE: does NOT use the standard framing — the
/// fields are read straight from the raw reply bytes.
pub const ESignature = struct {
    /// Non-zero-wait flash size in KB.
    flash_size_kb: u16,
    /// Raw 8 UID bytes as they appear in the reply (raw[4..12]).
    uid_raw: [8]u8,

    pub const Variant = enum(u8) { v1 = 0x09, v2 = 0x06 };

    pub fn parseRaw(raw: []const u8) Error!ESignature {
        if (raw.len < 12) return Error.InvalidPayloadLength;
        var uid: [8]u8 = undefined;
        @memcpy(&uid, raw[4..12]);
        return .{
            .flash_size_kb = std.mem.readInt(u16, raw[2..4], .big),
            .uid_raw = uid,
        };
    }

    pub fn format(self: ESignature, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        // wchisp displays each 4-byte group little-endian (reversed from the reply).
        try writer.print("FlashSize({d}KB) UID(", .{self.flash_size_kb});
        var first = true;
        for ([_]usize{ 0, 4 }) |base| {
            var k: usize = 4;
            while (k > 0) {
                k -= 1;
                if (!first) try writer.print("-", .{});
                first = false;
                try writer.print("{x:0>2}", .{self.uid_raw[base + k]});
            }
        }
        try writer.print(")", .{});
    }
};

// ---------------------------------------------------------------------------
// Memory regions (0x01 set-write, 0x03 set-read): [start_be:4][len_be:4]
// ---------------------------------------------------------------------------
pub fn memRegionPayload(buf: *[8]u8, start_addr: u32, len: u32) []const u8 {
    std.mem.writeInt(u32, buf[0..4], start_addr, .big);
    std.mem.writeInt(u32, buf[4..8], len, .big);
    return buf;
}

// ---------------------------------------------------------------------------
// DMI op (0x08): payload [addr, data_be:4, op]
// ---------------------------------------------------------------------------
pub const DMI_OP_NOP: u8 = 0;
pub const DMI_OP_READ: u8 = 1;
pub const DMI_OP_WRITE: u8 = 2;

pub fn dmiNopPayload(buf: *[6]u8) []const u8 {
    buf.* = .{ 0, 0, 0, 0, 0, DMI_OP_NOP };
    return buf;
}
pub fn dmiReadPayload(buf: *[6]u8, addr: u8) []const u8 {
    buf.* = .{ addr, 0, 0, 0, 0, DMI_OP_READ };
    return buf;
}
pub fn dmiWritePayload(buf: *[6]u8, addr: u8, data: u32) []const u8 {
    buf[0] = addr;
    std.mem.writeInt(u32, buf[1..5], data, .big);
    buf[5] = DMI_OP_WRITE;
    return buf;
}

pub const DmiOpResponse = struct {
    addr: u8,
    data: u32,
    op: u8,

    pub fn parse(payload: []const u8) Error!DmiOpResponse {
        if (payload.len != 6) return Error.InvalidPayloadLength;
        return .{
            .addr = payload[0],
            .data = std.mem.readInt(u32, payload[1..5], .big),
            .op = payload[5],
        };
    }

    pub fn isBusy(self: DmiOpResponse) bool {
        return self.op == 0x03;
    }
    pub fn isSuccess(self: DmiOpResponse) bool {
        return self.op == 0x00;
    }
    pub fn isFailed(self: DmiOpResponse) bool {
        return self.op == 0x03 or self.op == 0x02;
    }
};

const testing = std.testing;

test "dmi write payload encodes big-endian data" {
    var buf: [6]u8 = undefined;
    const p = dmiWritePayload(&buf, 0x10, 0x80000001);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x80, 0x00, 0x00, 0x01, 0x02 }, p);
}

test "attach response parses family and id" {
    const r = try AttachChipResponse.parse(&.{ 0x06, 0x30, 0x70, 0x05, 0x08 });
    try testing.expectEqual(RiscvChip.CH32V30X, r.chip_family);
    try testing.expectEqual(@as(u32, 0x30700508), r.chip_id);
}

test "esignature uid byte order matches wchisp" {
    // raw reply: [82 11 ffff 0020 aeb4abcd 16c6bc45 ...] -> flash 0xffff? use the doc example
    const raw = [_]u8{ 0x82, 0x11, 0x00, 0x20, 0xae, 0xb4, 0xab, 0xcd, 0x16, 0xc6, 0xbc, 0x45 };
    const e = try ESignature.parseRaw(&raw);
    try testing.expectEqual(@as(u16, 0x0020), e.flash_size_kb);
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try e.format(&w);
    try testing.expectEqualStrings("FlashSize(32KB) UID(cd-ab-b4-ae-45-bc-c6-16)", w.buffered());
}

test "buildFrame encodes header and length" {
    var buf: [16]u8 = undefined;
    const f = buildFrame(&buf, 0x0d, &.{0x01});
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x0d, 0x01, 0x01 }, f);
}

test "parseReply extracts payload" {
    const raw = [_]u8{ 0x82, 0x0d, 0x03, 0x02, 0x09, 0x02 };
    const p = try parseReply(&raw);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x09, 0x02 }, p);
}

test "parseReply flags protocol error" {
    const raw = [_]u8{ 0x81, 0x55, 0x01, 0x00 };
    try testing.expectError(Error.Protocol, parseReply(&raw));
}

test "parseReply rejects bad length" {
    const raw = [_]u8{ 0x82, 0x0d, 0x05, 0x00 };
    try testing.expectError(Error.InvalidPayloadLength, parseReply(&raw));
}
