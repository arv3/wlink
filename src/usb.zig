//! USB transport for the WCH-Link, backed by libusb (the zweiler2 Zig package).
//!
//! Replaces the Rust `nusb` backend. libusb is synchronous, so the async `.wait()`
//! dance from the Rust code disappears: each endpoint op is one `libusb_bulk_transfer`.

const std = @import("std");
const Error = @import("error.zig").Error;

pub const c = @cImport({
    @cInclude("libusb.h");
});

/// Translate a libusb return code into our error set. `LIBUSB_SUCCESS` is 0.
pub fn mapErr(rc: c_int) Error!void {
    if (rc == c.LIBUSB_SUCCESS) return;
    return switch (rc) {
        c.LIBUSB_ERROR_TIMEOUT => Error.Timeout,
        c.LIBUSB_ERROR_NO_DEVICE, c.LIBUSB_ERROR_NOT_FOUND => Error.ProbeNotFound,
        else => Error.Usb,
    };
}

pub fn errName(rc: c_int) []const u8 {
    return switch (rc) {
        c.LIBUSB_ERROR_IO => "I/O error",
        c.LIBUSB_ERROR_INVALID_PARAM => "invalid parameter",
        c.LIBUSB_ERROR_ACCESS => "access denied (driver/permissions)",
        c.LIBUSB_ERROR_NO_DEVICE => "no such device",
        c.LIBUSB_ERROR_NOT_FOUND => "not found",
        c.LIBUSB_ERROR_BUSY => "resource busy",
        c.LIBUSB_ERROR_TIMEOUT => "timed out",
        c.LIBUSB_ERROR_OVERFLOW => "overflow",
        c.LIBUSB_ERROR_PIPE => "pipe error",
        c.LIBUSB_ERROR_INTERRUPTED => "interrupted",
        c.LIBUSB_ERROR_NO_MEM => "out of memory",
        c.LIBUSB_ERROR_NOT_SUPPORTED => "not supported",
        else => "other error",
    };
}

fn speedName(speed: c_int) []const u8 {
    return switch (speed) {
        c.LIBUSB_SPEED_SUPER_PLUS => "USB-SS+ 10000 Mbps",
        c.LIBUSB_SPEED_SUPER => "USB-SS 5000 Mbps",
        c.LIBUSB_SPEED_HIGH => "USB-HS 480 Mbps",
        c.LIBUSB_SPEED_FULL => "USB-FS 12 Mbps",
        c.LIBUSB_SPEED_LOW => "USB-LS 1.5 Mbps",
        else => "(unknown)",
    };
}

/// An opened WCH-Link USB device.
///
/// When opened with a caller-supplied libusb context (`owns_ctx == false`), `deinit`
/// closes the device but leaves the context alone — the caller owns it. When opened
/// without one, the Device creates and owns a private context.
pub const Device = struct {
    ctx: ?*c.libusb_context,
    owns_ctx: bool,
    handle: ?*c.libusb_device_handle,
    timeout_ms: c_uint = 5000,

    pub fn deinit(self: *Device) void {
        if (self.handle) |h| {
            _ = c.libusb_release_interface(h, 0);
            c.libusb_close(h);
            self.handle = null;
        }
        if (self.owns_ctx and self.ctx != null) {
            c.libusb_exit(self.ctx);
            self.ctx = null;
        }
    }

    pub fn setTimeout(self: *Device, ms: u32) void {
        self.timeout_ms = ms;
    }

    /// Read one bulk transfer from `ep`; returns the number of bytes read.
    pub fn readEndpoint(self: *Device, ep: u8, buf: []u8) Error!usize {
        var transferred: c_int = 0;
        const rc = c.libusb_bulk_transfer(self.handle, ep, buf.ptr, @intCast(buf.len), &transferred, self.timeout_ms);
        try mapErr(rc);
        return @intCast(transferred);
    }

    /// Write `buf` to `ep`, looping until everything is sent.
    pub fn writeEndpoint(self: *Device, ep: u8, buf: []const u8) Error!void {
        var off: usize = 0;
        while (off < buf.len) {
            var transferred: c_int = 0;
            const chunk = buf[off..];
            const rc = c.libusb_bulk_transfer(self.handle, ep, @constCast(chunk.ptr), @intCast(chunk.len), &transferred, self.timeout_ms);
            try mapErr(rc);
            if (transferred == 0) return Error.Usb;
            off += @intCast(transferred);
        }
    }
};

/// Cast a caller-supplied opaque context pointer to libusb's context type. Using
/// `?*anyopaque` in the public API keeps it compatible with a context created by a
/// different module's `@cImport` of libusb (whose `libusb_context` is a distinct but
/// layout-identical opaque type).
inline fn asCtx(ctx: ?*anyopaque) ?*c.libusb_context {
    return @ptrCast(ctx);
}

/// Open the first device matching (vid, pid) and, when `serial` is non-null, that
/// exact serial number. Devices whose serial cannot be read are skipped when a
/// serial is requested.
///
/// If `ctx` is non-null it is used and left owned by the caller; if null, a private
/// libusb context is created and owned by the returned Device.
pub fn open(ctx: ?*anyopaque, vid: u16, pid: u16, serial: ?[]const u8) Error!Device {
    const owns_ctx = ctx == null;
    var use_ctx: ?*c.libusb_context = asCtx(ctx);
    if (owns_ctx) {
        if (c.libusb_init(&use_ctx) != c.LIBUSB_SUCCESS) return Error.Usb;
    }
    errdefer if (owns_ctx) c.libusb_exit(use_ctx);

    var list: [*c]?*c.libusb_device = undefined;
    const n = c.libusb_get_device_list(use_ctx, &list);
    if (n < 0) return Error.Usb;
    defer c.libusb_free_device_list(list, 1);

    const count: usize = @intCast(n);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const dev = list[i];
        var desc: c.libusb_device_descriptor = undefined;
        if (c.libusb_get_device_descriptor(dev, &desc) != 0) continue;
        if (desc.idVendor != vid or desc.idProduct != pid) continue;

        if (serial) |want| {
            var buf: [256]u8 = undefined;
            const dev_serial = serialInto(dev, &desc, &buf) orelse continue;
            if (!std.mem.eql(u8, dev_serial, want)) continue;
        }

        var handle: ?*c.libusb_device_handle = null;
        const rc_open = c.libusb_open(dev, &handle);
        if (rc_open != c.LIBUSB_SUCCESS) {
            std.log.err("Failed to open USB device: {s}", .{errName(rc_open)});
            return Error.Usb;
        }
        errdefer c.libusb_close(handle);

        const rc_claim = c.libusb_claim_interface(handle, 0);
        if (rc_claim != c.LIBUSB_SUCCESS) {
            std.log.err("Failed to claim interface: {s}", .{errName(rc_claim)});
            return Error.Usb;
        }
        return Device{ .ctx = use_ctx, .owns_ctx = owns_ctx, .handle = handle };
    }
    return Error.ProbeNotFound;
}

/// A device listing entry. `serial` is owned by the caller's allocator.
pub const Listing = struct {
    index: usize,
    vid: u16,
    pid: u16,
    serial: []const u8,
    speed: []const u8,
};

/// Enumerate devices matching (vid, pid). Caller owns the returned slice and each
/// entry's `serial`; free with `freeListings`.
///
/// If `ctx` is non-null it is used (and left owned by the caller); if null, a private
/// libusb context is created and torn down for the duration of the call.
pub fn listDevices(allocator: std.mem.Allocator, ctx: ?*anyopaque, vid: u16, pid: u16) (Error || std.mem.Allocator.Error)![]Listing {
    const owns_ctx = ctx == null;
    var use_ctx: ?*c.libusb_context = asCtx(ctx);
    if (owns_ctx) {
        if (c.libusb_init(&use_ctx) != c.LIBUSB_SUCCESS) return Error.Usb;
    }
    defer if (owns_ctx) c.libusb_exit(use_ctx);

    var list: [*c]?*c.libusb_device = undefined;
    const n = c.libusb_get_device_list(use_ctx, &list);
    if (n < 0) return Error.Usb;
    defer c.libusb_free_device_list(list, 1);

    var out: std.ArrayList(Listing) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item.serial);
        out.deinit(allocator);
    }

    const count: usize = @intCast(n);
    var idx: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const dev = list[i];
        var desc: c.libusb_device_descriptor = undefined;
        if (c.libusb_get_device_descriptor(dev, &desc) != 0) continue;
        if (desc.idVendor != vid or desc.idProduct != pid) continue;

        const serial = readSerial(allocator, dev, &desc) catch try allocator.dupe(u8, "N/A");
        try out.append(allocator, .{
            .index = idx,
            .vid = desc.idVendor,
            .pid = desc.idProduct,
            .serial = serial,
            .speed = speedName(c.libusb_get_device_speed(dev)),
        });
        idx += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeListings(allocator: std.mem.Allocator, listings: []Listing) void {
    for (listings) |item| allocator.free(item.serial);
    allocator.free(listings);
}

/// Read a device serial into `buf` without opening the device, using the zweiler2
/// fork's `libusb_get_device_string` extension. The return value is the byte count
/// including the NUL terminator, so the string is `buf[0..rc-1]`. Returns null if the
/// device has no serial or the read fails.
fn serialInto(dev: ?*c.libusb_device, desc: *const c.libusb_device_descriptor, buf: []u8) ?[]const u8 {
    if (desc.iSerialNumber == 0) return null;
    const rc = c.libusb_get_device_string(dev, c.LIBUSB_DEVICE_STRING_SERIAL_NUMBER, buf.ptr, @intCast(buf.len));
    if (rc <= 1) return null; // <0 error, or 1 = empty string (just NUL)
    return buf[0 .. @as(usize, @intCast(rc)) - 1];
}

fn readSerial(allocator: std.mem.Allocator, dev: ?*c.libusb_device, desc: *const c.libusb_device_descriptor) ![]const u8 {
    var buf: [256]u8 = undefined;
    const s = serialInto(dev, desc, &buf) orelse return error.NoSerial;
    return allocator.dupe(u8, s);
}

