//! The probe — WCH-Link.

const std = @import("std");
const usb = @import("usb.zig");
const commands = @import("commands.zig");
const Error = @import("error.zig").Error;
const RiscvChip = @import("riscv_chip.zig").RiscvChip;

pub const VENDOR_ID: u16 = 0x1a86;
pub const PRODUCT_ID: u16 = 0x8010;

pub const ENDPOINT_OUT: u8 = 0x01;
pub const ENDPOINT_IN: u8 = 0x81;

pub const DATA_ENDPOINT_OUT: u8 = 0x02;
pub const DATA_ENDPOINT_IN: u8 = 0x82;

pub const VENDOR_ID_DAP: u16 = 0x1a86;
pub const PRODUCT_ID_DAP: u16 = 0x8012;

pub const ENDPOINT_OUT_DAP: u8 = 0x02;

/// All WCH-Link probe variants.
pub const WchLinkVariant = enum(u8) {
    /// WCH-Link-CH549, does not support CH32V00X
    ch549 = 1,
    /// WCH-LinkE-CH32V305 (default)
    e_ch32v305 = 2,
    /// WCH-LinkS-CH32V203
    s_ch32v203 = 3,
    /// WCH-LinkW-CH32V208
    w_ch32v208 = 5,

    pub fn fromU8(value: u8) Error!WchLinkVariant {
        return switch (value) {
            1 => .ch549,
            2, 0x12 => .e_ch32v305,
            3 => .s_ch32v203,
            5, 0x85 => .w_ch32v208,
            else => Error.UnknownLinkVariant,
        };
    }

    /// CH549 variant does not support mode switch; re-programming is needed.
    pub fn supportSwitchMode(self: WchLinkVariant) bool {
        return self != .ch549;
    }

    /// Only W and E variants support power output control.
    pub fn supportPowerFuncs(self: WchLinkVariant) bool {
        return self == .w_ch32v208 or self == .e_ch32v305;
    }

    /// Only the E variant supports SDI print.
    pub fn supportSdiPrint(self: WchLinkVariant) bool {
        return self == .e_ch32v305;
    }

    /// Whether this variant can debug the given chip.
    pub fn supportChip(self: WchLinkVariant, chip: RiscvChip) bool {
        return switch (self) {
            .ch549 => switch (chip) {
                .CH32V003, .CH32X035, .CH643 => false,
                else => true,
            },
            .w_ch32v208 => switch (chip) {
                .CH56X, .CH57X, .CH582, .CH59X => false,
                else => true,
            },
            else => true,
        };
    }

    pub fn name(self: WchLinkVariant) []const u8 {
        return switch (self) {
            .ch549 => "WCH-Link-CH549",
            .e_ch32v305 => "WCH-LinkE-CH32V305",
            .s_ch32v203 => "WCH-LinkS-CH32V203",
            .w_ch32v208 => "WCH-LinkW-CH32V208",
        };
    }
};

/// Probe firmware version + variant.
pub const ProbeInfo = struct {
    major_version: u8 = 0,
    minor_version: u8 = 0,
    variant: WchLinkVariant = .e_ch32v305,

    pub fn version(self: ProbeInfo) struct { u8, u8 } {
        return .{ self.major_version, self.minor_version };
    }

    /// True if firmware version >= (major, minor).
    pub fn versionAtLeast(self: ProbeInfo, major: u8, minor: u8) bool {
        if (self.major_version != major) return self.major_version > major;
        return self.minor_version >= minor;
    }

    pub fn fromPayload(bytes: []const u8) Error!ProbeInfo {
        if (bytes.len < 3) return Error.InvalidPayloadLength;
        return .{
            .major_version = bytes[0],
            .minor_version = bytes[1],
            // Variant is only available in newer firmware (4-byte payload).
            .variant = if (bytes.len == 4) try WchLinkVariant.fromU8(bytes[2]) else .ch549,
        };
    }

    pub fn format(self: ProbeInfo, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("WCH-Link v{d}.{d}(v{d}) ({s})", .{
            self.major_version,
            self.minor_version,
            @as(u16, self.major_version) * 10 + self.minor_version,
            self.variant.name(),
        });
    }
};

/// Abstraction of the WchLink probe interface.
pub const WchLink = struct {
    device: usb.Device,
    info: ProbeInfo = .{},
    /// Scratch buffer for command replies; a `transact` result points into this.
    in_buf: [64]u8 = undefined,

    /// Open the nth WCH-Link in RV mode, creating a private libusb context.
    /// If the device is found only in DAP mode, returns Error.ProbeModeNotSupported.
    pub fn openNth(nth: usize) Error!WchLink {
        return openNthCtx(null, nth);
    }

    /// Like `openNth`, but uses a caller-supplied libusb context (`null` = create one).
    /// Pass a `*libusb_context` from any module's libusb `@cImport` (it coerces to
    /// `?*anyopaque`); the caller retains ownership of a supplied context.
    pub fn openNthCtx(ctx: ?*anyopaque, nth: usize) Error!WchLink {
        const device = usb.openNth(ctx, VENDOR_ID, PRODUCT_ID, nth) catch |e| {
            // Detect whether it is in DAP mode instead.
            if (usb.openNth(ctx, VENDOR_ID_DAP, PRODUCT_ID_DAP, nth)) |dap| {
                var d = dap;
                d.deinit();
                return Error.ProbeModeNotSupported;
            } else |_| {}
            return e;
        };
        var this = WchLink{ .device = device };
        this.info = try this.getProbeInfo();
        std.log.info("Connected to {f}", .{this.info});
        return this;
    }

    pub fn deinit(self: *WchLink) void {
        self.device.deinit();
    }

    /// Send a command and return the full raw reply (valid until the next transact).
    /// Used by commands whose reply does not follow the standard framing (ESignature).
    pub fn transactRaw(self: *WchLink, cmd_id: u8, payload: []const u8) Error![]const u8 {
        var out: [64]u8 = undefined;
        const frame = commands.buildFrame(&out, cmd_id, payload);
        try self.device.writeEndpoint(ENDPOINT_OUT, frame);
        const n = try self.device.readEndpoint(ENDPOINT_IN, &self.in_buf);
        return self.in_buf[0..n];
    }

    /// Send a command and return the reply PAYLOAD (valid until the next transact).
    pub fn transact(self: *WchLink, cmd_id: u8, payload: []const u8) Error![]const u8 {
        return commands.parseReply(try self.transactRaw(cmd_id, payload));
    }

    /// Send a command and discard the reply payload (still validates framing/errors).
    pub fn send(self: *WchLink, cmd_id: u8, payload: []const u8) Error!void {
        _ = try self.transact(cmd_id, payload);
    }

    pub const ProgressFn = *const fn (ctx: ?*anyopaque, nbytes: usize) void;

    /// Write `buf` to the data-out endpoint in `packet_len` packets, padding the final
    /// short packet with 0xff. `packet_len` must be <= 256.
    pub fn writeData(self: *WchLink, buf: []const u8, packet_len: usize) Error!void {
        return self.writeDataWithProgress(buf, packet_len, null, null);
    }

    pub fn writeDataWithProgress(self: *WchLink, buf: []const u8, packet_len: usize, ctx: ?*anyopaque, cb: ?ProgressFn) Error!void {
        std.debug.assert(packet_len <= 256);
        var pkt: [256]u8 = undefined;
        var off: usize = 0;
        while (off < buf.len) {
            const take = @min(packet_len, buf.len - off);
            if (cb) |f| f(ctx, take);
            @memcpy(pkt[0..take], buf[off .. off + take]);
            if (take < packet_len) @memset(pkt[take..packet_len], 0xff);
            try self.device.writeEndpoint(DATA_ENDPOINT_OUT, pkt[0..packet_len]);
            off += take;
        }
    }

    /// Read exactly `buf.len` bytes from the data-in endpoint (64-byte packets).
    pub fn readData(self: *WchLink, buf: []u8) Error!void {
        var got: usize = 0;
        while (got < buf.len) {
            const want = @min(@as(usize, 64), buf.len - got);
            const n = try self.device.readEndpoint(DATA_ENDPOINT_IN, buf[got..][0..want]);
            if (n == 0) return Error.InvalidPayloadLength;
            got += n;
        }
    }

    /// GetProbeInfo (0x0d, 0x01).
    pub fn getProbeInfo(self: *WchLink) Error!ProbeInfo {
        const payload = try self.transact(0x0d, &.{0x01});
        return ProbeInfo.fromPayload(payload);
    }
};

/// Resolve a WCH-Link serial number to the index used by `WchLink.openNth`.
pub fn indexBySerial(serial: []const u8) Error!usize {
    return indexBySerialCtx(null, serial);
}
pub fn indexBySerialCtx(ctx: ?*anyopaque, serial: []const u8) Error!usize {
    return usb.indexBySerial(ctx, VENDOR_ID, PRODUCT_ID, serial);
}

/// Switch the nth probe from RV mode to DAP mode.
pub fn switchFromRvToDap(nth: usize) Error!void {
    return switchFromRvToDapCtx(null, nth);
}
pub fn switchFromRvToDapCtx(ctx: ?*anyopaque, nth: usize) Error!void {
    var p = try WchLink.openNthCtx(ctx, nth);
    defer p.deinit();
    if (p.info.variant.supportSwitchMode()) {
        std.log.info("Switch mode for WCH-LinkRV", .{});
        _ = p.transact(0xff, &.{0x41}) catch {};
    } else {
        std.log.err("Cannot switch mode for WCH-LinkRV: not supported", .{});
        return Error.Custom;
    }
}

/// Switch the nth probe from DAP mode to RV mode.
pub fn switchFromDapToRv(nth: usize) Error!void {
    return switchFromDapToRvCtx(null, nth);
}
pub fn switchFromDapToRvCtx(ctx: ?*anyopaque, nth: usize) Error!void {
    var dev = try usb.openNth(ctx, VENDOR_ID_DAP, PRODUCT_ID_DAP, nth);
    defer dev.deinit();
    std.log.info("Switch mode WCH-LinkDAP {x:0>4}:{x:0>4} #{d}", .{ VENDOR_ID_DAP, PRODUCT_ID_DAP, nth });
    const buf = [_]u8{ 0x81, 0xff, 0x01, 0x52 };
    dev.writeEndpoint(ENDPOINT_OUT_DAP, &buf) catch {};
}

/// Enable/disable the probe's power output (WCH-LinkE/W only).
pub fn setPowerOutputEnabled(nth: usize, cmd: commands.SetPower) Error!void {
    return setPowerOutputEnabledCtx(null, nth, cmd);
}
pub fn setPowerOutputEnabledCtx(ctx: ?*anyopaque, nth: usize, cmd: commands.SetPower) Error!void {
    var p = try WchLink.openNthCtx(ctx, nth);
    defer p.deinit();
    if (!p.info.variant.supportPowerFuncs()) {
        std.log.err("Probe doesn't support power control", .{});
        return Error.Custom;
    }
    try p.send(commands.CMD_CONTROL, cmd.payload());
    switch (cmd) {
        .enable_3v3 => std.log.info("Enable 3.3V Output", .{}),
        .disable_3v3 => std.log.info("Disable 3.3V Output", .{}),
        .enable_5v => std.log.info("Enable 5V Output", .{}),
        .disable_5v => std.log.info("Disable 5V Output", .{}),
    }
}
