//! Register definitions.
//!
//! The Rust code used the `bitfield!` macro; here we use `packed struct(u32)`. Zig
//! lays packed-struct fields out LSB-first, so each field below is declared from bit 0
//! upward with explicit padding for gaps — matching the original bit positions.

const std = @import("std");

// CSR register numbers (command.regno, 16-bit). CSR: 0x0000 - 0x0fff
pub const MARCHID: u16 = 0xF12;
pub const MIMPID: u16 = 0xF13;
pub const MSTATUS: u16 = 0x300;
pub const MISA: u16 = 0x301;
pub const MTVEC: u16 = 0x305;
pub const MSCRATCH: u16 = 0x340;
pub const MEPC: u16 = 0x341;
pub const MCAUSE: u16 = 0x342;
pub const MTVAL: u16 = 0x343;
pub const DPC: u16 = 0x7b1;

// Debug interface DMI registers (8-bit addresses)
pub const DMDATA0: u8 = 0x04;
pub const DMDATA1: u8 = 0x05;
pub const DMCONTROL: u8 = 0x10;
pub const DMSTATUS: u8 = 0x11;
pub const DMHARTINFO: u8 = 0x12;
pub const DMABSTRACTCS: u8 = 0x16;
pub const DMCOMMAND: u8 = 0x17;
pub const DMABSTRACTAUTO: u8 = 0x18;
pub const DMPROGBUF0: u8 = 0x20;
pub const DMHALTSUM0: u8 = 0x40;

pub const Gpr = struct { reg: []const u8, name: []const u8, no: u16 };
pub const Csr = struct { name: []const u8, no: u16 };

pub const GPRS_RVI = [_]Gpr{
    .{ .reg = "x0", .name = "zero", .no = 0x1000 }, .{ .reg = "x1", .name = "ra", .no = 0x1001 },
    .{ .reg = "x2", .name = "sp", .no = 0x1002 },   .{ .reg = "x3", .name = "gp", .no = 0x1003 },
    .{ .reg = "x4", .name = "tp", .no = 0x1004 },   .{ .reg = "x5", .name = "t0", .no = 0x1005 },
    .{ .reg = "x6", .name = "t1", .no = 0x1006 },   .{ .reg = "x7", .name = "t2", .no = 0x1007 },
    .{ .reg = "x8", .name = "s0", .no = 0x1008 },   .{ .reg = "x9", .name = "s1", .no = 0x1009 },
    .{ .reg = "x10", .name = "a0", .no = 0x100a },  .{ .reg = "x11", .name = "a1", .no = 0x100b },
    .{ .reg = "x12", .name = "a2", .no = 0x100c },  .{ .reg = "x13", .name = "a3", .no = 0x100d },
    .{ .reg = "x14", .name = "a4", .no = 0x100e },  .{ .reg = "x15", .name = "a5", .no = 0x100f },
    .{ .reg = "x16", .name = "a6", .no = 0x1010 },  .{ .reg = "x17", .name = "a7", .no = 0x1011 },
    .{ .reg = "x18", .name = "s2", .no = 0x1012 },  .{ .reg = "x19", .name = "s3", .no = 0x1013 },
    .{ .reg = "x20", .name = "s4", .no = 0x1014 },  .{ .reg = "x21", .name = "s5", .no = 0x1015 },
    .{ .reg = "x22", .name = "s6", .no = 0x1016 },  .{ .reg = "x23", .name = "s7", .no = 0x1017 },
    .{ .reg = "x24", .name = "s8", .no = 0x1018 },  .{ .reg = "x25", .name = "s9", .no = 0x1019 },
    .{ .reg = "x26", .name = "s10", .no = 0x101a }, .{ .reg = "x27", .name = "s11", .no = 0x101b },
    .{ .reg = "x28", .name = "t3", .no = 0x101c },  .{ .reg = "x29", .name = "t4", .no = 0x101d },
    .{ .reg = "x30", .name = "t5", .no = 0x101e },  .{ .reg = "x31", .name = "t6", .no = 0x101f },
};

/// GPRs for rv32ec (16 registers).
pub const GPRS_RVE = GPRS_RVI[0..16];

pub const CSRS = [_]Csr{
    .{ .name = "marchid", .no = 0xf12 },   .{ .name = "mimpid", .no = 0xf13 },
    .{ .name = "mhartid", .no = 0xf14 },   .{ .name = "misa", .no = 0x301 },
    .{ .name = "mtvec", .no = 0x305 },     .{ .name = "mscratch", .no = 0x340 },
    .{ .name = "mepc", .no = 0x341 },      .{ .name = "mcause", .no = 0x342 },
    .{ .name = "mtval", .no = 0x343 },     .{ .name = "mstatus", .no = 0x300 },
    .{ .name = "dcsr", .no = 0x7b0 },      .{ .name = "dpc", .no = 0x7b1 },
    .{ .name = "dscratch0", .no = 0x7b2 }, .{ .name = "dscratch1", .no = 0x7b3 },
    .{ .name = "gintenr", .no = 0x800 },   .{ .name = "intsyscr", .no = 0x804 },
    .{ .name = "corecfgr", .no = 0xbc0 },
};

/// PMP CSRs, QingKeV4 only.
pub const PMP_CSRS = [_]Csr{
    .{ .name = "pmpcfg0", .no = 0x3A0 },  .{ .name = "pmpaddr0", .no = 0x3B0 },
    .{ .name = "pmpaddr1", .no = 0x3B1 }, .{ .name = "pmpaddr2", .no = 0x3B2 },
    .{ .name = "pmpaddr3", .no = 0x3B3 },
};

/// Debug Module Control, 0x10.
pub const Dmcontrol = packed struct(u32) {
    dmactive: bool, // 0
    ndmreset: bool, // 1
    _rsvd2: u27 = 0, // 2..28
    ackhavereset: bool, // 29
    resumereq: bool, // 30
    haltreq: bool, // 31

    pub const ADDR: u8 = 0x10;
    pub fn fromBits(v: u32) Dmcontrol {
        return @bitCast(v);
    }
    pub fn toBits(self: Dmcontrol) u32 {
        return @bitCast(self);
    }
};

/// Debug Module Status, 0x11.
pub const Dmstatus = packed struct(u32) {
    version: u4, // 0..3
    _rsvd4: u3 = 0, // 4..6
    authenticated: bool, // 7
    anyhalted: bool, // 8
    allhalted: bool, // 9
    anyrunning: bool, // 10
    allrunning: bool, // 11
    anyunavail: bool, // 12
    allunavail: bool, // 13
    _rsvd14: u2 = 0, // 14..15
    anyresumeack: bool, // 16
    allresumeack: bool, // 17
    anyhavereset: bool, // 18
    allhavereset: bool, // 19
    _rsvd20: u12 = 0, // 20..31

    pub const ADDR: u8 = 0x11;
    pub fn fromBits(v: u32) Dmstatus {
        return @bitCast(v);
    }
    pub fn toBits(self: Dmstatus) u32 {
        return @bitCast(self);
    }
};

/// Hart information register, 0x12.
pub const Hartinfo = packed struct(u32) {
    dataaddr: u12, // 0..11
    datasize: u4, // 12..15
    dataaccess: bool, // 16
    _rsvd17: u3 = 0, // 17..19
    nscratch: u4, // 20..23
    _rsvd24: u8 = 0, // 24..31

    pub const ADDR: u8 = 0x12;
    pub fn fromBits(v: u32) Hartinfo {
        return @bitCast(v);
    }
    pub fn toBits(self: Hartinfo) u32 {
        return @bitCast(self);
    }
};

/// Abstract command status register, 0x16.
pub const Abstractcs = packed struct(u32) {
    datacount: u4, // 0..3
    _rsvd4: u4 = 0, // 4..7
    cmderr: u3, // 8..10
    _rsvd11: u1 = 0, // 11
    busy: bool, // 12
    _rsvd13: u11 = 0, // 13..23
    progbufsize: u5, // 24..28
    _rsvd29: u3 = 0, // 29..31

    pub const ADDR: u8 = 0x16;
    pub fn fromBits(v: u32) Abstractcs {
        return @bitCast(v);
    }
    pub fn toBits(self: Abstractcs) u32 {
        return @bitCast(self);
    }
};

/// Abstract command register, 0x17.
pub const Command = packed struct(u32) {
    regno: u16, // 0..15
    write: bool, // 16
    transfer: bool, // 17
    postexec: bool, // 18
    aarpostincrement: bool, // 19
    aarsize: u3, // 20..22
    _rsvd23: u1 = 0, // 23
    cmdtype: u8, // 24..31

    pub const ADDR: u8 = 0x17;
    pub fn fromBits(v: u32) Command {
        return @bitCast(v);
    }
    pub fn toBits(self: Command) u32 {
        return @bitCast(self);
    }
};

const testing = std.testing;

test "Dmcontrol bit positions" {
    try testing.expectEqual(@as(u32, 1 << 0), (Dmcontrol{ .dmactive = true, .ndmreset = false, .ackhavereset = false, .resumereq = false, .haltreq = false }).toBits());
    try testing.expectEqual(@as(u32, 1 << 31), (Dmcontrol{ .dmactive = false, .ndmreset = false, .ackhavereset = false, .resumereq = false, .haltreq = true }).toBits());
    try testing.expectEqual(@as(u32, 0x8000_0001), (Dmcontrol{ .dmactive = true, .ndmreset = false, .ackhavereset = false, .resumereq = false, .haltreq = true }).toBits());
}

test "Dmstatus decodes halted bits" {
    const s = Dmstatus.fromBits((1 << 9) | (1 << 8) | 0x2); // allhalted+anyhalted, version 2
    try testing.expect(s.allhalted and s.anyhalted);
    try testing.expectEqual(@as(u4, 2), s.version);
}

test "Abstractcs cmderr field" {
    const a = Abstractcs.fromBits(0x700 | (1 << 12)); // cmderr=7, busy
    try testing.expectEqual(@as(u3, 7), a.cmderr);
    try testing.expect(a.busy);
}
