//! SDI-print / serial monitor for the WCH-Link CDC port.
//!
//! Mirrors the Rust `watch_serial`: find the WCH-Link's virtual serial port and stream
//! its output. The `serial` package's `list_info` has no macOS support, so the port is
//! located by scanning /dev for the CDC node whose name carries the probe serial
//! (obtained via libusb).

const std = @import("std");
const builtin = @import("builtin");
const serial = @import("serial");
const usb = @import("usb.zig");
const Error = @import("error.zig").Error;
const probe = @import("probe.zig");

const dev_prefix = switch (builtin.os.tag) {
    .macos => "cu.usbmodem",
    .linux => "ttyACM",
    else => "ttyACM",
};

/// Find the WCH-Link CDC serial port path into `buf`; returns the path slice or null.
pub fn findPort(io: std.Io, allocator: std.mem.Allocator, buf: []u8) Error!?[]const u8 {
    // Probe serial helps disambiguate when several modems are present.
    var serial_buf: [64]u8 = undefined;
    var probe_serial: ?[]const u8 = null;
    if (usb.listDevices(allocator, null, probe.VENDOR_ID, probe.PRODUCT_ID)) |listings| {
        defer usb.freeListings(allocator, listings);
        if (listings.len > 0 and listings[0].serial.len <= serial_buf.len) {
            @memcpy(serial_buf[0..listings[0].serial.len], listings[0].serial);
            probe_serial = serial_buf[0..listings[0].serial.len];
        }
    } else |_| {}

    var dir = std.Io.Dir.cwd().openDir(io, "/dev", .{ .iterate = true }) catch return Error.Serial;
    defer dir.close(io);

    var first_len: usize = 0; // first candidate as a fallback
    var it = dir.iterate();
    while (it.next(io) catch return Error.Serial) |entry| {
        if (!std.mem.startsWith(u8, entry.name, dev_prefix)) continue;
        const full_len = 5 + entry.name.len; // "/dev/" + name
        if (full_len > buf.len) continue;

        // Exact match on probe serial wins immediately.
        if (probe_serial) |ps| {
            if (std.mem.indexOf(u8, entry.name, ps) != null) {
                return writePath(buf, entry.name);
            }
        }
        if (first_len == 0) {
            _ = writePath(buf[buf.len / 2 ..], entry.name); // stash first candidate in upper half
            first_len = full_len;
        }
    }

    if (first_len != 0) {
        const stashed = buf[buf.len / 2 ..][0..first_len];
        std.mem.copyForwards(u8, buf[0..first_len], stashed);
        return buf[0..first_len];
    }
    return null;
}

fn writePath(buf: []u8, name: []const u8) []const u8 {
    @memcpy(buf[0..5], "/dev/");
    @memcpy(buf[5 .. 5 + name.len], name);
    return buf[0 .. 5 + name.len];
}

/// Open the WCH-Link serial port and stream its output to `out` until disconnect.
pub fn watchSerial(io: std.Io, allocator: std.mem.Allocator, out: *std.Io.Writer) Error!void {
    var path_buf: [256]u8 = undefined;
    const path = (try findPort(io, allocator, &path_buf)) orelse {
        std.log.err("No WCH-Link serial port found", .{});
        return Error.Custom;
    };
    std.log.info("Opening serial port: {s}", .{path});

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return Error.Serial;
    defer file.close(io);
    serial.configureSerialPort(file, .{ .baud_rate = 115200 }) catch return Error.Serial;

    var rbuf: [4096]u8 = undefined;
    var fr = file.reader(io, &rbuf);
    const r = &fr.interface;

    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&chunk) catch |e| {
            std.log.info("serial closed: {t}", .{e});
            return;
        };
        if (n == 0) return; // EOF / disconnected
        out.writeAll(chunk[0..n]) catch return Error.Io;
        out.flush() catch return Error.Io;
    }
}
