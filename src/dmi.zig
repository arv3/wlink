//! Access the MCU using RISC-V DMI.
//!
//! Refs: RISC-V QingKeV2 Microprocessor Debug Manual; RISC-V Debug Spec 0.13.2.
//!
//! Low-level DMI ops operate on `*WchLink`; higher-level register/memory access
//! operates on `*ProbeSession`. (Rust attached these as trait/impl methods; Zig
//! can't extend a struct across files, so they're free functions here.)

const std = @import("std");
const commands = @import("commands.zig");
const regs = @import("regs.zig");
const WchLink = @import("probe.zig").WchLink;
const ProbeSession = @import("operations.zig").ProbeSession;
const sleepMs = @import("operations.zig").sleepMs;
const errmod = @import("error.zig");
const Error = errmod.Error;
const AbstractcsCmdErr = errmod.AbstractcsCmdErr;

pub const KEY1: u32 = 0x45670123;
pub const KEY2: u32 = 0xCDEF89AB;

// --------------------------------------------------------------------------
// Low-level DMI (on *WchLink)
// --------------------------------------------------------------------------

pub fn dmiNop(p: *WchLink) Error!void {
    var b: [6]u8 = undefined;
    _ = try p.transact(commands.CMD_DMI_OP, commands.dmiNopPayload(&b));
}

pub fn dmiRead(p: *WchLink, reg: u8) Error!u32 {
    var n: u32 = 0;
    while (true) {
        var b: [6]u8 = undefined;
        const payload = try p.transact(commands.CMD_DMI_OP, commands.dmiReadPayload(&b, reg));
        const resp = try commands.DmiOpResponse.parse(payload);
        if (resp.op == 0x03 and resp.data == 0xffffffff and resp.addr == 0x7d) {
            return Error.NotAttached;
        }
        if (resp.isSuccess()) return resp.data;
        if (n > 100) return Error.Timeout;
        if (resp.isBusy()) {
            std.log.warn("dmi_read: busy, retrying", .{});
            sleepMs(10);
            n += 1;
        } else {
            return Error.DmiFailed;
        }
    }
}

pub fn dmiWrite(p: *WchLink, reg: u8, value: u32) Error!void {
    var b: [6]u8 = undefined;
    _ = try p.transact(commands.CMD_DMI_OP, commands.dmiWritePayload(&b, reg, value));
}

pub fn readDmiReg(p: *WchLink, comptime R: type) Error!R {
    return R.fromBits(try dmiRead(p, R.ADDR));
}

pub fn writeDmiReg(p: *WchLink, reg: anytype) Error!void {
    try dmiWrite(p, @TypeOf(reg).ADDR, reg.toBits());
}

// --------------------------------------------------------------------------
// Higher-level (on *ProbeSession)
// --------------------------------------------------------------------------

fn clearAbstractcsCmderr(sess: *ProbeSession) Error!void {
    var a = regs.Abstractcs.fromBits(0);
    a.cmderr = 0b111;
    try writeDmiReg(&sess.probe, a);
}

fn clearDmstatusHavereset(sess: *ProbeSession) Error!void {
    var dmcontrol = try readDmiReg(&sess.probe, regs.Dmcontrol);
    dmcontrol.ackhavereset = true;
    try writeDmiReg(&sess.probe, dmcontrol);
}

pub fn ensureMcuHalt(sess: *ProbeSession) Error!void {
    const p = &sess.probe;
    var dmstatus = try readDmiReg(p, regs.Dmstatus);
    if (dmstatus.allhalted and dmstatus.anyhalted) {
        std.log.debug("Already halted, nop", .{});
    } else {
        while (true) {
            try dmiWrite(p, 0x10, 0x80000001);
            dmstatus = try readDmiReg(p, regs.Dmstatus);
            if (dmstatus.anyhalted and dmstatus.allhalted) break;
            std.log.warn("Not halt, try send", .{});
            sleepMs(10);
        }
    }
    try dmiWrite(p, 0x10, 0x00000001);
}

pub fn ensureMcuResume(sess: *ProbeSession) Error!void {
    const p = &sess.probe;
    try clearDmstatusHavereset(sess);
    var dmstatus = try readDmiReg(p, regs.Dmstatus);
    if (dmstatus.allrunning and dmstatus.anyrunning) {
        std.log.debug("Already running, nop", .{});
        return;
    }
    try dmiWrite(p, 0x10, 0x80000001);
    try dmiWrite(p, 0x10, 0x80000001);
    try dmiWrite(p, 0x10, 0x00000001);
    try dmiWrite(p, 0x10, 0x40000001);

    dmstatus = try readDmiReg(p, regs.Dmstatus);
    if (dmstatus.allresumeack and dmstatus.anyresumeack) {
        std.log.debug("Resumed", .{});
    } else {
        std.log.warn("Resume fails", .{});
    }
}

pub fn resetDebugModule(sess: *ProbeSession) Error!void {
    const p = &sess.probe;
    try dmiWrite(p, 0x10, 0x00000000);
    try dmiWrite(p, 0x10, 0x00000001);
    const dmcontrol = try readDmiReg(p, regs.Dmcontrol);
    if (!dmcontrol.dmactive) return Error.DmiFailed;
}

pub fn readReg(sess: *ProbeSession, regno: u16) Error!u32 {
    const p = &sess.probe;
    try clearAbstractcsCmderr(sess);

    const reg: u32 = regno;
    try dmiWrite(p, 0x04, 0x00000000); // clear Data0
    try dmiWrite(p, 0x17, 0x00220000 | (reg & 0xFFFF));

    const a = try readDmiReg(p, regs.Abstractcs);
    if (a.busy) return Error.AbstractCommandError;
    if (a.cmderr != 0) try AbstractcsCmdErr.check(a.cmderr);

    return try dmiRead(p, 0x04);
}

pub fn writeReg(sess: *ProbeSession, regno: u16, value: u32) Error!void {
    const p = &sess.probe;
    const reg: u32 = regno;
    try dmiWrite(p, 0x04, value);
    try dmiWrite(p, 0x17, 0x00230000 | (reg & 0xFFFF));

    const a = try readDmiReg(p, regs.Abstractcs);
    if (a.busy) return Error.AbstractCommandError;
    if (a.cmderr != 0) try AbstractcsCmdErr.check(a.cmderr);
}

pub fn readMem32(sess: *ProbeSession, addr: u32) Error!u32 {
    const p = &sess.probe;
    try dmiWrite(p, 0x20, 0x0002a303); // lw x6,0(x5)
    try dmiWrite(p, 0x21, 0x00100073); // ebreak
    try dmiWrite(p, 0x04, addr); // data0 <- address
    try clearAbstractcsCmderr(sess);
    try dmiWrite(p, 0x17, 0x00271005);

    const a = try readDmiReg(p, regs.Abstractcs);
    if (a.busy) return Error.AbstractCommandError;
    if (a.cmderr != 0) try AbstractcsCmdErr.check(a.cmderr);

    try dmiWrite(p, 0x17, 0x00221006); // data0 <- x6
    if (a.busy) return Error.AbstractCommandError;
    if (a.cmderr != 0) try AbstractcsCmdErr.check(a.cmderr);

    return try dmiRead(p, 0x04);
}

pub fn writeMem32(sess: *ProbeSession, addr: u32, data: u32) Error!void {
    const p = &sess.probe;
    try dmiWrite(p, 0x20, 0x0072a023); // sw x7,0(x5)
    try dmiWrite(p, 0x21, 0x00100073); // ebreak
    try dmiWrite(p, 0x04, addr); // data0 <- address
    try clearAbstractcsCmderr(sess);
    try dmiWrite(p, 0x17, 0x00231005); // x5 <- data0

    var a = try readDmiReg(p, regs.Abstractcs);
    if (a.busy) return Error.AbstractCommandError;
    if (a.cmderr != 0) try AbstractcsCmdErr.check(a.cmderr);

    try dmiWrite(p, 0x04, data); // data0 <- data
    try clearAbstractcsCmderr(sess);
    try dmiWrite(p, 0x17, 0x00271007); // x7 <- data0

    a = try readDmiReg(p, regs.Abstractcs);
    if (a.busy) return Error.AbstractCommandError;
    if (a.cmderr != 0) try AbstractcsCmdErr.check(a.cmderr);
}

pub fn writeMem8(sess: *ProbeSession, addr: u32, data: u8) Error!void {
    const p = &sess.probe;
    try dmiWrite(p, 0x20, 0x00728023); // sb x7,0(x5)
    try dmiWrite(p, 0x21, 0x00100073); // ebreak
    try dmiWrite(p, 0x04, addr);
    try clearAbstractcsCmderr(sess);
    try dmiWrite(p, 0x17, 0x00231005);

    var a = try readDmiReg(p, regs.Abstractcs);
    if (a.busy) return Error.AbstractCommandError;
    if (a.cmderr != 0) try AbstractcsCmdErr.check(a.cmderr);

    try dmiWrite(p, 0x04, @as(u32, data));
    try clearAbstractcsCmderr(sess);
    try dmiWrite(p, 0x17, 0x00271007);

    a = try readDmiReg(p, regs.Abstractcs);
    if (a.busy) return Error.AbstractCommandError;
    if (a.cmderr != 0) try AbstractcsCmdErr.check(a.cmderr);
}

// --------------------------------------------------------------------------
// Dumps
// --------------------------------------------------------------------------

pub fn dumpCoreCsrs(sess: *ProbeSession) Error!void {
    const misa = try readReg(sess, regs.MISA);
    var buf: [40]u8 = undefined;
    std.log.info("RISC-V ISA(misa): {s}", .{parseMisa(misa, &buf)});

    const marchid = try readReg(sess, regs.MARCHID);
    var mbuf: [16]u8 = undefined;
    std.log.info("RISC-V arch(marchid): {s}", .{parseMarchid(marchid, &mbuf)});
}

pub fn dumpRegs(sess: *ProbeSession, w: *std.Io.Writer) Error!void {
    const dpc = try readReg(sess, regs.DPC);
    w.print("dpc(pc):   0x{x:0>8}\n", .{dpc}) catch return Error.Io;

    const gprs = if (sess.chip_family.isRv32e()) regs.GPRS_RVE else regs.GPRS_RVI[0..];
    for (gprs) |g| {
        const val = try readReg(sess, g.no);
        w.print("{s:<4}{s:>5}: 0x{x:0>8}\n", .{ g.reg, g.name, val }) catch return Error.Io;
    }
    for (regs.CSRS) |csr| {
        const val = try readReg(sess, csr.no);
        w.print("{s:<9}: 0x{x:0>8}\n", .{ csr.name, val }) catch return Error.Io;
    }
}

pub fn dumpPmpCsrs(sess: *ProbeSession) Error!void {
    for (regs.PMP_CSRS) |csr| {
        const val = try readReg(sess, csr.no);
        std.log.debug("{s}: 0x{x:0>8}", .{ csr.name, val });
    }
}

pub fn dumpDmi(sess: *ProbeSession) Error!void {
    std.log.warn("The halt status may be incorrect because detaching might resume the MCU", .{});
    const p = &sess.probe;
    std.log.info("dmstatus:  0x{x:0>8}", .{(try readDmiReg(p, regs.Dmstatus)).toBits()});
    std.log.info("dmcontrol: 0x{x:0>8}", .{(try readDmiReg(p, regs.Dmcontrol)).toBits()});
    std.log.info("hartinfo:  0x{x:0>8}", .{(try readDmiReg(p, regs.Hartinfo)).toBits()});
    std.log.info("abstractcs:0x{x:0>8}", .{(try readDmiReg(p, regs.Abstractcs)).toBits()});
    std.log.info("haltsum0:  0x{x:0>8}", .{try dmiRead(p, 0x40)});
}

// --------------------------------------------------------------------------
// Parsers
// --------------------------------------------------------------------------

/// Parse marchid into a string like "WCH-V4B"; returns "(none)" for 0.
pub fn parseMarchid(marchid: u32, buf: []u8) []const u8 {
    if (marchid == 0) return "(none)";
    return std.fmt.bufPrint(buf, "{c}{c}{c}-{c}{c}{c}", .{
        @as(u8, @intCast(((marchid >> 26) & 0x1F) + 64)),
        @as(u8, @intCast(((marchid >> 21) & 0x1F) + 64)),
        @as(u8, @intCast(((marchid >> 16) & 0x1F) + 64)),
        @as(u8, @intCast(((marchid >> 10) & 0x1F) + 64)),
        @as(u8, @intCast(((marchid >> 5) & 0x1F) + '0')),
        @as(u8, @intCast((marchid & 0x1F) + 64)),
    }) catch "(err)";
}

/// Parse misa into a string like "RV32IMAC"; returns "(none)" if MXL is invalid.
pub fn parseMisa(misa: u32, buf: []u8) []const u8 {
    const mxl = (misa >> 30) & 0x3;
    const prefix: []const u8 = switch (mxl) {
        1 => "RV32",
        2 => "RV64",
        3 => "RV128",
        else => return "(none)",
    };
    @memcpy(buf[0..prefix.len], prefix);
    var len: usize = prefix.len;
    var i: u5 = 0;
    while (i < 26) : (i += 1) {
        if ((misa >> i) & 1 == 1) {
            if (len < buf.len) {
                buf[len] = 'A' + @as(u8, i);
                len += 1;
            }
        }
    }
    return buf[0..len];
}

const testing = std.testing;

test "parseMisa decodes RV32IMAC" {
    var buf: [40]u8 = undefined;
    // RV32 (mxl=1<<30) with I(8) M(12) A(0) C(2)
    const misa: u32 = (1 << 30) | (1 << 8) | (1 << 12) | (1 << 0) | (1 << 2);
    try testing.expectEqualStrings("RV32ACIM", parseMisa(misa, &buf));
}
