//! wlink CLI — a thin consumer of the `wlink` library module.
//!
//! Phase 4: list, status, regs, dump, reset, halt, resume, write-reg, write-mem.

const std = @import("std");
const wlink = @import("wlink");

pub const std_options: std.Options = .{ .log_level = .info };

const Cli = struct {
    device: usize = 0,
    serial: ?[]const u8 = null,
    chip: ?wlink.RiscvChip = null,
    speed: wlink.Speed = .high,
    no_detach: bool = false,
    // flash / erase flags
    address: ?u32 = null,
    erase: bool = false,
    skip_gap: bool = false,
    no_run: bool = false,
    enable_sdi_print: bool = false,
    watch_serial: bool = false,
    method: []const u8 = "default",
    rv: bool = false,
    dap: bool = false,
    /// positionals[0] is the command; the rest are operands.
    positionals: [4][]const u8 = undefined,
    npos: usize = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [8192]u8 = undefined;
    var out_file = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    var cli = Cli{};
    // iterateAllocator works on every platform (plain iterate() is unsupported on
    // Windows, where the command line must be parsed via the allocator).
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next(); // argv0
    while (it.next()) |arg| {
        if (eql(arg, "-d") or eql(arg, "--device")) {
            cli.device = std.fmt.parseInt(usize, it.next() orelse return usageErr(out, "missing value for --device"), 10) catch
                return usageErr(out, "invalid --device value");
        } else if (eql(arg, "--serial")) {
            cli.serial = it.next() orelse return usageErr(out, "missing value for --serial");
        } else if (eql(arg, "--chip")) {
            const v = it.next() orelse return usageErr(out, "missing value for --chip");
            cli.chip = wlink.RiscvChip.fromStr(v) orelse return usageErr(out, "unknown --chip value");
        } else if (eql(arg, "--speed")) {
            const v = it.next() orelse return usageErr(out, "missing value for --speed");
            cli.speed = wlink.commands.Speed.fromStr(v) orelse return usageErr(out, "unknown --speed value");
        } else if (eql(arg, "--no-detach")) {
            cli.no_detach = true;
        } else if (eql(arg, "-a") or eql(arg, "--address")) {
            const v = it.next() orelse return usageErr(out, "missing value for --address");
            cli.address = parseNumber(v) orelse return usageErr(out, "invalid --address value");
        } else if (eql(arg, "-e") or eql(arg, "--erase")) {
            cli.erase = true;
        } else if (eql(arg, "-s") or eql(arg, "--skip-gap")) {
            cli.skip_gap = true;
        } else if (eql(arg, "-R") or eql(arg, "--no-run")) {
            cli.no_run = true;
        } else if (eql(arg, "--enable-sdi-print")) {
            cli.enable_sdi_print = true;
        } else if (eql(arg, "--watch-serial")) {
            cli.watch_serial = true;
        } else if (eql(arg, "--method")) {
            cli.method = it.next() orelse return usageErr(out, "missing value for --method");
        } else if (eql(arg, "--rv")) {
            cli.rv = true;
        } else if (eql(arg, "--dap")) {
            cli.dap = true;
        } else if (eql(arg, "-h") or eql(arg, "--help")) {
            try printHelp(out);
            return 0;
        } else {
            if (cli.npos >= cli.positionals.len) return usageErr(out, "too many arguments");
            cli.positionals[cli.npos] = arg;
            cli.npos += 1;
        }
    }

    const command = if (cli.npos > 0) cli.positionals[0] else {
        try listProbes(gpa, out);
        try out.print("\nNo command given, use --help for help.\n", .{});
        try out.print("hint: try `wlink status`.\n", .{});
        return 0;
    };

    if (eql(command, "list")) {
        try listProbes(gpa, out);
        return 0;
    }

    // Resolve --serial to a device index for commands that open a probe.
    if (cli.serial) |sn| {
        cli.device = wlink.probe.indexBySerial(sn) catch |e| {
            try out.print("Failed to resolve probe serial {s}: {t}\n", .{ sn, e });
            return 1;
        };
    }

    if (eql(command, "status")) return statusCommand(out, cli);
    if (eql(command, "regs")) return regsCommand(out, cli);
    if (eql(command, "dump")) return dumpCommand(gpa, out, cli);
    if (eql(command, "reset")) return resetCommand(out, cli);
    if (eql(command, "halt")) return haltCommand(out, cli);
    if (eql(command, "resume")) return resumeCommand(out, cli);
    if (eql(command, "write-reg")) return writeRegCommand(out, cli);
    if (eql(command, "write-mem")) return writeMemCommand(out, cli);
    if (eql(command, "flash")) return flashCommand(gpa, io, out, cli);
    if (eql(command, "erase")) return eraseCommand(out, cli);
    if (eql(command, "unprotect")) return unprotectCommand(out, cli);
    if (eql(command, "protect")) return protectCommand(out, cli);
    if (eql(command, "set-power")) return setPowerCommand(out, cli);
    if (eql(command, "mode-switch")) return modeSwitchCommand(gpa, out, cli);
    if (eql(command, "sdi-print")) return sdiPrintCommand(out, cli);
    if (eql(command, "watch-serial")) {
        wlink.serial_monitor.watchSerial(io, gpa, out) catch |e| return reportErr(out, "watch-serial", e);
        return 0;
    }

    try out.print("Unknown or not-yet-ported command: {s}\n", .{command});
    return 1;
}

fn setPowerCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    if (cli.npos < 2) return usageErr(out, "usage: set-power <enable-3v3|disable-3v3|enable-5v|disable-5v>");
    const p = wlink.commands.SetPower.fromStr(cli.positionals[1]) orelse return usageErr(out, "invalid power option");
    wlink.probe.setPowerOutputEnabled(cli.device, p) catch |e| return reportErr(out, "set-power", e);
    return 0;
}

fn modeSwitchCommand(gpa: std.mem.Allocator, out: *std.Io.Writer, cli: Cli) !u8 {
    try listProbes(gpa, out);
    std.log.warn("This is an experimental feature, better use the WCH-LinkUtility!", .{});
    if (cli.rv == cli.dap) {
        try out.print("Please choose one mode to switch, either --rv or --dap\n", .{});
        return 2;
    }
    if (cli.dap) {
        wlink.probe.switchFromRvToDap(cli.device) catch |e| return reportErr(out, "mode-switch", e);
    } else {
        wlink.probe.switchFromDapToRv(cli.device) catch |e| return reportErr(out, "mode-switch", e);
    }
    return 0;
}

fn sdiPrintCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    if (cli.npos < 2) return usageErr(out, "usage: sdi-print <enable|disable>");
    const enable = eql(cli.positionals[1], "enable");
    if (!enable and !eql(cli.positionals[1], "disable")) return usageErr(out, "sdi-print arg must be enable|disable");

    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    if (enable) {
        std.log.info("Enabling SDI print", .{});
        sess.setSdiPrintEnabled(true) catch |e| return reportErr(out, "setSdiPrintEnabled", e);
        std.log.info("Now you can connect to the WCH-Link serial port", .{});
        // enable implies no detach (detaching would stop SDI print)
    } else {
        std.log.info("Disabling SDI print", .{});
        sess.setSdiPrintEnabled(false) catch |e| return reportErr(out, "setSdiPrintEnabled", e);
        if (!cli.no_detach) sess.detachChip() catch {};
    }
    return 0;
}

const ProgressState = struct {
    out: *std.Io.Writer,
    fn cb(ctx: ?*anyopaque, written: usize, total: usize) void {
        const self: *ProgressState = @ptrCast(@alignCast(ctx.?));
        self.out.print("\rFlashing: {d}/{d} bytes", .{ written, total }) catch {};
        self.out.flush() catch {};
    }
};

fn flashCommand(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, cli: Cli) !u8 {
    if (cli.npos < 2) return usageErr(out, "usage: flash [options] <path>");
    const path = cli.positionals[1];

    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();

    sess.dumpInfo() catch |e| return reportErr(out, "dumpInfo", e);
    if (cli.erase) {
        std.log.info("Erase Flash", .{});
        sess.eraseFlash() catch |e| return reportErr(out, "eraseFlash", e);
    }

    var fw = wlink.firmware.readFromFile(gpa, io, path) catch |e| return reportErr(out, "read firmware", e);
    defer fw.deinit(gpa);

    var prog = ProgressState{ .out = out };

    switch (fw) {
        .binary => |data| {
            if (cli.skip_gap) std.log.warn("Skip gap is ignored when flashing binary", .{});
            const start = cli.address orelse sess.chip_family.codeFlashStart();
            std.log.info("Flashing {d} bytes to 0x{x:0>8}", .{ data.len, start });
            sess.writeFlash(data, start, &prog, ProgressState.cb) catch |e| return reportErr(out, "writeFlash", e);
            try out.print("\n", .{});
        },
        .sections => |orig_secs| {
            if (cli.address != null) std.log.warn("--address is ignored when flashing ELF or ihex", .{});
            // fillTinyGap consumes the section slice; detach it from `fw` so deinit
            // doesn't double-free.
            fw = .{ .sections = &.{} };
            const max_gap: u32 = if (cli.skip_gap) 4096 else 0xFFFFFFFF;
            if (cli.skip_gap) std.log.warn("Skip gap is an experimental feature using a trait of wchlink!", .{});
            const secs = wlink.firmware.fillTinyGap(gpa, orig_secs, max_gap) catch |e| return reportErr(out, "merge sections", e);
            defer {
                for (secs) |s| gpa.free(s.data);
                gpa.free(secs);
            }

            var offset: u32 = 0;
            for (secs) |section| {
                const start = sess.chip_family.fixCodeFlashStart(section.address);
                std.log.info("Flashing {d} bytes to 0x{x:0>8}", .{ section.data.len, start });
                std.log.info("offset: 0x{x:0>8}", .{offset});
                sess.writeFlash(section.data, start - offset, &prog, ProgressState.cb) catch |e| return reportErr(out, "writeFlash", e);
                try out.print("\n", .{});
                offset += ((@as(u32, @intCast(section.data.len)) + 4095) / 4096) * 4096;
            }
        },
    }

    std.log.info("Flash done", .{});
    wlink.operations.sleepMs(500);

    if (!cli.no_run) {
        std.log.info("Now reset...", .{});
        sess.softReset() catch |e| return reportErr(out, "soft reset", e);
        if (cli.enable_sdi_print) {
            sess.setSdiPrintEnabled(true) catch |e| return reportErr(out, "setSdiPrintEnabled", e);
            std.log.info("Now connect to the WCH-Link serial port to read SDI print", .{});
        }
        if (cli.watch_serial) {
            wlink.serial_monitor.watchSerial(io, gpa, out) catch |e| return reportErr(out, "watch-serial", e);
        } else {
            wlink.operations.sleepMs(500);
        }
    }

    // Detaching stops SDI print, so skip detach when SDI print was enabled.
    if (!cli.no_detach and !cli.enable_sdi_print) sess.detachChip() catch {};
    return 0;
}

fn eraseCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    if (!eql(cli.method, "default")) {
        // Special erase bypasses attach; requires --chip.
        const chip = cli.chip orelse return usageErr(out, "--chip required for a special erase");
        var probe = wlink.WchLink.openNth(cli.device) catch |e| {
            try out.print("Failed to open probe: {t}\n", .{e});
            return 1;
        };
        defer probe.deinit();
        std.log.info("Erase chip by {s}", .{cli.method});
        if (eql(cli.method, "power-off")) {
            wlink.ProbeSession.eraseFlashByPowerOff(&probe, chip) catch |e| return reportErr(out, "erase", e);
        } else if (eql(cli.method, "pin-rst")) {
            std.log.warn("Code flash erase by RST pin requires a RST pin connection", .{});
            wlink.ProbeSession.eraseFlashByRstPin(&probe, chip) catch |e| return reportErr(out, "erase", e);
        } else {
            return usageErr(out, "--method must be default|power-off|pin-rst");
        }
        return 0;
    }

    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    std.log.info("Erase Flash...", .{});
    sess.eraseFlash() catch |e| return reportErr(out, "eraseFlash", e);
    std.log.info("Erase done", .{});
    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

fn unprotectCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    std.log.info("Unprotect Flash", .{});
    sess.unprotectFlash() catch |e| return reportErr(out, "unprotectFlash", e);
    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

fn protectCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    std.log.info("Protect Flash", .{});
    sess.protectFlash() catch |e| return reportErr(out, "protectFlash", e);
    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

/// Open + attach. On failure prints and returns the error; otherwise returns the session.
fn attach(out: *std.Io.Writer, cli: Cli) !wlink.ProbeSession {
    const probe = wlink.WchLink.openNth(cli.device) catch |e| {
        try out.print("Failed to open probe: {t}\n", .{e});
        return e;
    };
    return wlink.ProbeSession.attach(probe, cli.chip, cli.speed) catch |e| {
        try out.print("Failed to attach: {t}\n", .{e});
        var p = probe;
        p.deinit();
        return e;
    };
}

fn statusCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    sess.dumpInfo() catch |e| return reportErr(out, "dumpInfo", e);
    wlink.dmi.dumpCoreCsrs(&sess) catch |e| return reportErr(out, "dumpCoreCsrs", e);
    wlink.dmi.dumpDmi(&sess) catch |e| return reportErr(out, "dumpDmi", e);
    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

fn regsCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    wlink.dmi.dumpRegs(&sess, out) catch |e| return reportErr(out, "dumpRegs", e);
    wlink.dmi.dumpPmpCsrs(&sess) catch |e| return reportErr(out, "dumpPmpCsrs", e);
    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

fn dumpCommand(gpa: std.mem.Allocator, out: *std.Io.Writer, cli: Cli) !u8 {
    if (cli.npos < 3) return usageErr(out, "usage: dump <address> <length>");
    const address = parseNumber(cli.positionals[1]) orelse return usageErr(out, "invalid address");
    const length = parseNumber(cli.positionals[2]) orelse return usageErr(out, "invalid length");

    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();

    const mem = sess.readMemory(gpa, address, length) catch |e| return reportErr(out, "readMemory", e);
    defer gpa.free(mem);
    try hexdump(out, mem, address);

    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

fn resetCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    const mode = if (cli.npos > 1) cli.positionals[1] else "quit";
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    var detach = !cli.no_detach;

    if (eql(mode, "quit")) {
        sess.probe.send(wlink.commands.CMD_RESET, wlink.commands.Reset.soft.payload()) catch |e| return reportErr(out, "reset", e);
    } else if (eql(mode, "run")) {
        wlink.dmi.ensureMcuResume(&sess) catch |e| return reportErr(out, "resume", e);
    } else if (eql(mode, "halt")) {
        wlink.dmi.ensureMcuHalt(&sess) catch |e| return reportErr(out, "halt", e);
        detach = false;
    } else if (eql(mode, "dm")) {
        wlink.dmi.resetDebugModule(&sess) catch |e| return reportErr(out, "reset-dm", e);
        detach = false;
    } else {
        return usageErr(out, "reset mode must be quit|run|halt|dm");
    }
    wlink.operations.sleepMs(300);
    if (detach) sess.detachChip() catch {};
    return 0;
}

fn haltCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    wlink.dmi.resetDebugModule(&sess) catch |e| return reportErr(out, "reset-dm", e);
    wlink.dmi.ensureMcuHalt(&sess) catch |e| return reportErr(out, "halt", e);
    // detach would resume the MCU, so skip it.
    return 0;
}

fn resumeCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    wlink.dmi.ensureMcuResume(&sess) catch |e| return reportErr(out, "resume", e);
    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

fn writeRegCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    if (cli.npos < 3) return usageErr(out, "usage: write-reg <reg> <value>");
    const reg = parseNumber(cli.positionals[1]) orelse return usageErr(out, "invalid reg");
    const value = parseNumber(cli.positionals[2]) orelse return usageErr(out, "invalid value");
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    wlink.dmi.writeReg(&sess, @intCast(reg & 0xFFFF), value) catch |e| return reportErr(out, "writeReg", e);
    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

fn writeMemCommand(out: *std.Io.Writer, cli: Cli) !u8 {
    if (cli.npos < 3) return usageErr(out, "usage: write-mem <address> <value>");
    const address = parseNumber(cli.positionals[1]) orelse return usageErr(out, "invalid address");
    const value = parseNumber(cli.positionals[2]) orelse return usageErr(out, "invalid value");
    var sess = attach(out, cli) catch return 1;
    defer sess.deinit();
    wlink.dmi.writeMem32(&sess, address, value) catch |e| return reportErr(out, "writeMem32", e);
    if (!cli.no_detach) sess.detachChip() catch {};
    return 0;
}

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

fn listProbes(gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    const rv = try wlink.usb.listDevices(gpa, null, wlink.probe.VENDOR_ID, wlink.probe.PRODUCT_ID);
    defer wlink.usb.freeListings(gpa, rv);
    for (rv) |d| {
        try out.print("<WCH-Link#{d}> ID {x:0>4}:{x:0>4} Serial {s} ({s}) (RV mode)\n", .{ d.index, d.vid, d.pid, d.serial, d.speed });
    }
    const dap = try wlink.usb.listDevices(gpa, null, wlink.probe.VENDOR_ID_DAP, wlink.probe.PRODUCT_ID_DAP);
    defer wlink.usb.freeListings(gpa, dap);
    for (dap) |d| {
        try out.print("<WCH-Link#{d}> ID {x:0>4}:{x:0>4} Serial {s} ({s}) (DAP mode)\n", .{ d.index, d.vid, d.pid, d.serial, d.speed });
    }
    if (rv.len == 0 and dap.len == 0) try out.print("No WCH-Link probes found.\n", .{});
}

fn hexdump(out: *std.Io.Writer, data: []const u8, base: u32) !void {
    var off: usize = 0;
    while (off < data.len) : (off += 16) {
        const row = data[off..@min(off + 16, data.len)];
        try out.print("{x:0>8}: ", .{base + @as(u32, @intCast(off))});
        for (0..16) |i| {
            if (i < row.len) try out.print("{x:0>2} ", .{row[i]}) else try out.print("   ", .{});
        }
        try out.print(" |", .{});
        for (row) |b| try out.print("{c}", .{if (b >= 0x20 and b < 0x7f) b else '.'});
        try out.print("|\n", .{});
    }
}

fn parseNumber(s: []const u8) ?u32 {
    var buf: [64]u8 = undefined;
    if (s.len > buf.len) return null;
    var n: usize = 0;
    for (s) |ch| {
        if (ch == '_') continue;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    const t = buf[0..n];
    if (std.mem.startsWith(u8, t, "0x")) return std.fmt.parseInt(u32, t[2..], 16) catch null;
    if (std.mem.startsWith(u8, t, "0b")) return std.fmt.parseInt(u32, t[2..], 2) catch null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print(
        \\wlink (Zig port)
        \\
        \\USAGE: wlink [options] <command> [args]
        \\
        \\OPTIONS:
        \\  -d, --device <N>   Device index (default 0)
        \\      --serial <S>   Select probe by serial number (overrides --device)
        \\      --chip <NAME>  Expected chip family (e.g. CH32V307)
        \\      --speed <S>    low | medium | high (default high)
        \\      --no-detach    Do not detach the chip after the operation
        \\
        \\COMMANDS:
        \\  list                     List connected WCH-Link probes
        \\  status                   Attach and dump chip info + CSRs + DMI
        \\  regs                     Dump GPRs and CSRs
        \\  dump <addr> <len>        Dump a memory region
        \\  reset [quit|run|halt|dm] Reset the MCU (default quit)
        \\  halt                     Halt the MCU
        \\  resume                   Resume the MCU
        \\  write-reg <reg> <val>    Write a register
        \\  write-mem <addr> <val>   Write a memory word
        \\  flash [opts] <path>      Flash firmware (bin/hex/ihex/elf)
        \\  erase [--method M]       Erase flash (M: default|power-off|pin-rst)
        \\  unprotect                Unlock flash
        \\  protect                  Protect flash
        \\  set-power <opt>          enable-3v3|disable-3v3|enable-5v|disable-5v
        \\  mode-switch --rv|--dap   Switch probe between RV and DAP modes
        \\  sdi-print <enable|disable>  Toggle SDI virtual serial print
        \\  watch-serial             Stream the WCH-Link virtual serial port
        \\
        \\FLASH OPTIONS:
        \\  -a, --address <A>      Flash address (binary only)
        \\  -e, --erase            Erase before flashing
        \\  -s, --skip-gap         Skip gaps between sections (experimental)
        \\  -R, --no-run           Do not reset & run after flashing
        \\      --enable-sdi-print Enable SDI print after reset
        \\      --watch-serial     Stream the serial port after reset
        \\
    , .{});
}

fn usageErr(out: *std.Io.Writer, msg: []const u8) !u8 {
    try out.print("error: {s}\n", .{msg});
    return 2;
}

fn reportErr(out: *std.Io.Writer, what: []const u8, e: anyerror) !u8 {
    try out.print("{s} failed: {t}\n", .{ what, e });
    return 1;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
