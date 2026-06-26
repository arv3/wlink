//! High-level flash operation: write a parsed `Firmware` image to an attached
//! target and (optionally) reset it to run.
//!
//! This is the library counterpart of the CLI `flash` command. The caller is
//! responsible for opening + attaching the probe (`ProbeSession`) and for any
//! pre-flash erase or post-flash detach; this routine only writes the image and
//! resets-to-run.

const std = @import("std");
const firmware = @import("firmware.zig");
const operations = @import("operations.zig");
const Error = @import("error.zig").Error;

const Firmware = firmware.Firmware;
const ProbeSession = operations.ProbeSession;

/// Progress callback: invoked with the running (written, total) byte counts for
/// the section currently being flashed. `written == total` marks the end of a
/// section.
pub const ProgressFn = *const fn (ctx: ?*anyopaque, written: usize, total: usize) void;

/// Options controlling how a `Firmware` is flashed.
pub const Options = struct {
    /// Flash address for binary images. Ignored for ELF/Intel-HEX (which carry
    /// their own section addresses). `null` uses the chip's default code-flash start.
    address: ?u32 = null,
    /// Merge sections separated by gaps <= 4096 bytes, zero-filling the gap
    /// (experimental). Ignored for binary images.
    skip_gap: bool = false,
    /// When false (default), reset the target to run after flashing. When true,
    /// leave the target halted.
    no_run: bool = false,
    /// Read each flashed region back and compare it against the written data,
    /// returning `Error.VerifyFailed` on the first mismatch.
    verify: bool = false,
    /// Optional progress callback and its opaque context.
    progress_ctx: ?*anyopaque = null,
    progress: ?ProgressFn = null,
};

/// Flash `fw` to the target behind `sess`.
///
/// `fw` is taken by pointer and the routine consumes the memory it processes:
/// for a section image it frees the sections and resets `fw.*` to an empty image,
/// so a caller's `defer fw.deinit(allocator)` stays correct (a no-op afterwards).
/// A binary image is left intact for the caller to free. `allocator` must be the
/// allocator that produced `fw`.
pub fn flashFirmware(
    sess: *ProbeSession,
    allocator: std.mem.Allocator,
    fw: *Firmware,
    opts: Options,
) firmware.ReadError!void {
    switch (fw.*) {
        .binary => |data| {
            if (opts.skip_gap) std.log.warn("Skip gap is ignored when flashing binary", .{});
            const start = opts.address orelse sess.chip_family.codeFlashStart();
            std.log.info("Flashing {d} bytes to 0x{x:0>8}", .{ data.len, start });
            try sess.writeFlash(data, start, opts.progress_ctx, opts.progress);
            if (opts.verify) try verifyRegion(sess, allocator, data, start);
        },
        .sections => |orig_secs| {
            if (opts.address != null) std.log.warn("--address is ignored when flashing ELF or ihex", .{});
            // fillTinyGap consumes the section slice; detach it from `fw` so the
            // caller's deinit doesn't double-free.
            fw.* = .{ .sections = &.{} };
            const max_gap: u32 = if (opts.skip_gap) 4096 else 0xFFFFFFFF;
            if (opts.skip_gap) std.log.warn("Skip gap is an experimental feature using a trait of wchlink!", .{});
            const secs = try firmware.fillTinyGap(allocator, orig_secs, max_gap);
            defer {
                for (secs) |s| allocator.free(s.data);
                allocator.free(secs);
            }

            var offset: u32 = 0;
            for (secs) |section| {
                const start = sess.chip_family.fixCodeFlashStart(section.address);
                std.log.info("Flashing {d} bytes to 0x{x:0>8}", .{ section.data.len, start });
                std.log.debug("offset: 0x{x:0>8}", .{offset});
                try sess.writeFlash(section.data, start - offset, opts.progress_ctx, opts.progress);
                if (opts.verify) try verifyRegion(sess, allocator, section.data, start);
                offset += ((@as(u32, @intCast(section.data.len)) + 4095) / 4096) * 4096;
            }
        },
    }

    std.log.info("Flash done", .{});
    operations.sleepMs(500);

    if (!opts.no_run) {
        std.log.info("Now reset...", .{});
        try sess.softReset();
    }
}

/// Read `expected.len` bytes back from `address` and compare against `expected`.
/// Returns `Error.VerifyFailed` (logging the first differing byte) on mismatch.
fn verifyRegion(sess: *ProbeSession, allocator: std.mem.Allocator, expected: []const u8, address: u32) firmware.ReadError!void {
    std.log.info("Verifying {d} bytes at 0x{x:0>8}", .{ expected.len, address });
    // readMemory rounds the length up to a multiple of 4, so compare the prefix.
    const got = try sess.readMemory(allocator, address, @intCast(expected.len));
    defer allocator.free(got);
    for (expected, 0..) |b, i| {
        if (got[i] != b) {
            std.log.err("Verify failed at 0x{x:0>8}: expected 0x{x:0>2}, got 0x{x:0>2}", .{
                address + @as(u32, @intCast(i)), b, got[i],
            });
            return Error.VerifyFailed;
        }
    }
    std.log.info("Verify OK", .{});
}
