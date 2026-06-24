//! Firmware file formats: binary, plain-hex, Intel-HEX, ELF32.

const std = @import("std");
const Error = @import("error.zig").Error;

pub const FirmwareFormat = enum { plain_hex, intel_hex, elf, binary };

pub const Section = struct {
    /// Physical start address.
    address: u32,
    data: []u8,

    pub fn endAddress(self: Section) u32 {
        return self.address + @as(u32, @intCast(self.data.len));
    }
};

/// An abstract firmware image. Owns its memory; free with `deinit`.
pub const Firmware = union(enum) {
    binary: []u8,
    sections: []Section,

    pub fn deinit(self: *Firmware, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .binary => |b| allocator.free(b),
            .sections => |secs| {
                for (secs) |s| allocator.free(s.data);
                allocator.free(secs);
            },
        }
    }
};

/// Errors from the pure parsers (no file I/O).
pub const ReadError = Error || std.mem.Allocator.Error || error{ InvalidHex, InvalidElf, EmptyImage };

/// Read and parse a firmware file, guessing the format from extension/content.
pub fn readFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) (ReadError || std.Io.Dir.ReadFileAllocError)!Firmware {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(raw);

    const format = guessFormat(path, raw);
    std.log.info("Read {s} as {t} format", .{ path, format });
    return switch (format) {
        .plain_hex => .{ .binary = try decodeHex(allocator, raw) },
        .binary => .{ .binary = try allocator.dupe(u8, raw) },
        .intel_hex => try readIhex(allocator, raw),
        .elf => try readElf(allocator, raw),
    };
}

fn hasExt(path: []const u8, ext: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(path[dot + 1 ..], ext);
}

pub fn guessFormat(path: []const u8, raw: []const u8) FirmwareFormat {
    const exts = [_][]const u8{ "ihex", "ihe", "h86", "hex", "a43", "a90" };
    for (exts) |e| {
        if (hasExt(path, e)) return .intel_hex;
    }
    if (raw.len >= 4 and raw[0] == 0x7f and raw[1] == 'E' and raw[2] == 'L' and raw[3] == 'F') return .elf;
    if (raw.len == 0) return .binary;

    if (raw[0] == ':') {
        var ok = true;
        for (raw) |ch| {
            if (!(std.ascii.isHex(ch) or ch == ':' or ch == '\n' or ch == '\r')) {
                ok = false;
                break;
            }
        }
        if (ok) return .intel_hex;
    }
    var all_hexish = true;
    for (raw) |ch| {
        if (!(std.ascii.isHex(ch) or ch == '\n' or ch == '\r')) {
            all_hexish = false;
            break;
        }
    }
    return if (all_hexish) .plain_hex else .binary;
}

fn decodeHex(allocator: std.mem.Allocator, raw: []const u8) ReadError![]u8 {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    for (raw) |ch| {
        if (ch == '\r' or ch == '\n') continue;
        try clean.append(allocator, ch);
    }
    if (clean.items.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, clean.items.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, clean.items) catch return error.InvalidHex;
    return out;
}

// --------------------------------------------------------------------------
// Intel HEX
// --------------------------------------------------------------------------

const Builder = struct { address: u32, data: std.ArrayList(u8) };

pub fn readIhex(allocator: std.mem.Allocator, text: []const u8) ReadError!Firmware {
    var builders: std.ArrayList(Builder) = .empty;
    errdefer {
        for (builders.items) |*b| b.data.deinit(allocator);
        builders.deinit(allocator);
    }

    var base_address: u32 = 0;
    var last_end: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (line[0] != ':') return error.InvalidHex;
        if (line.len < 11) return error.InvalidHex;

        const byte_count = parseHexByte(line[1..3]) orelse return error.InvalidHex;
        const addr16 = (parseHexU16(line[3..7])) orelse return error.InvalidHex;
        const rectype = parseHexByte(line[7..9]) orelse return error.InvalidHex;
        const data_hex = line[9 .. 9 + @as(usize, byte_count) * 2];
        if (line.len < 9 + @as(usize, byte_count) * 2) return error.InvalidHex;

        switch (rectype) {
            0x00 => { // data
                const start = base_address + addr16;
                var value: [256]u8 = undefined;
                _ = std.fmt.hexToBytes(value[0..byte_count], data_hex) catch return error.InvalidHex;
                const bytes = value[0..byte_count];

                if (builders.items.len > 0 and start == last_end) {
                    try builders.items[builders.items.len - 1].data.appendSlice(allocator, bytes);
                } else {
                    var b = Builder{ .address = start, .data = .empty };
                    try b.data.appendSlice(allocator, bytes);
                    try builders.append(allocator, b);
                }
                last_end = start + byte_count;
            },
            0x02 => { // extended segment address
                base_address = @as(u32, (parseHexU16(data_hex) orelse return error.InvalidHex)) * 16;
            },
            0x04 => { // extended linear address
                base_address = @as(u32, (parseHexU16(data_hex) orelse return error.InvalidHex)) << 16;
            },
            else => {}, // start addr / eof: ignore
        }
    }

    const secs = try allocator.alloc(Section, builders.items.len);
    errdefer allocator.free(secs);
    for (builders.items, 0..) |*b, i| {
        secs[i] = .{ .address = b.address, .data = try b.data.toOwnedSlice(allocator) };
    }
    builders.deinit(allocator);
    return .{ .sections = secs };
}

fn parseHexByte(s: []const u8) ?u8 {
    if (s.len != 2) return null;
    return std.fmt.parseInt(u8, s, 16) catch null;
}
fn parseHexU16(s: []const u8) ?u16 {
    if (s.len != 4) return null;
    return std.fmt.parseInt(u16, s, 16) catch null;
}

// --------------------------------------------------------------------------
// ELF32 (loadable PT_LOAD segments only)
// --------------------------------------------------------------------------

pub fn readElf(allocator: std.mem.Allocator, elf: []const u8) ReadError!Firmware {
    if (elf.len < 52) return error.InvalidElf;
    if (!(elf[0] == 0x7f and elf[1] == 'E' and elf[2] == 'L' and elf[3] == 'F')) return error.InvalidElf;
    if (elf[4] != 1) return error.InvalidElf; // EI_CLASS: 1 = ELF32
    const endian: std.builtin.Endian = if (elf[5] == 2) .big else .little;

    const e_phoff = std.mem.readInt(u32, elf[28..32], endian);
    const e_phentsize = std.mem.readInt(u16, elf[42..44], endian);
    const e_phnum = std.mem.readInt(u16, elf[44..46], endian);

    var secs: std.ArrayList(Section) = .empty;
    errdefer {
        for (secs.items) |s| allocator.free(s.data);
        secs.deinit(allocator);
    }

    const PT_LOAD: u32 = 1;
    var i: u16 = 0;
    while (i < e_phnum) : (i += 1) {
        const off = e_phoff + @as(u32, i) * e_phentsize;
        if (off + 32 > elf.len) return error.InvalidElf;
        const ph = elf[off..];
        const p_type = std.mem.readInt(u32, ph[0..4], endian);
        const p_offset = std.mem.readInt(u32, ph[4..8], endian);
        const p_paddr = std.mem.readInt(u32, ph[12..16], endian);
        const p_filesz = std.mem.readInt(u32, ph[16..20], endian);

        if (p_type != PT_LOAD or p_filesz == 0) continue;
        if (p_offset + p_filesz > elf.len) return error.InvalidElf;

        std.log.debug("Loadable segment paddr 0x{x:0>8} size 0x{x}", .{ p_paddr, p_filesz });
        const data = try allocator.dupe(u8, elf[p_offset .. p_offset + p_filesz]);
        errdefer allocator.free(data);
        try secs.append(allocator, .{ .address = p_paddr, .data = data });
    }

    if (secs.items.len == 0) return error.EmptyImage;
    std.log.debug("found {d} sections", .{secs.items.len});
    return .{ .sections = try secs.toOwnedSlice(allocator) };
}

// --------------------------------------------------------------------------
// Section merging
// --------------------------------------------------------------------------

fn lessThanAddr(_: void, a: Section, b: Section) bool {
    return a.address < b.address;
}

/// Merge sections separated by a gap <= max_tiny_gap (zero-filling the gap). Consumes
/// `sections` (frees its data and the slice) and returns a newly allocated set.
pub fn fillTinyGap(allocator: std.mem.Allocator, sections: []Section, max_tiny_gap: u32) ReadError![]Section {
    std.debug.assert(sections.len > 0);
    std.mem.sort(Section, sections, {}, lessThanAddr);

    var merged: std.ArrayList(Builder) = .empty;
    errdefer {
        for (merged.items) |*b| b.data.deinit(allocator);
        merged.deinit(allocator);
    }

    var cur = Builder{ .address = sections[0].address, .data = .empty };
    try cur.data.appendSlice(allocator, sections[0].data);

    for (sections[1..]) |sect| {
        const cur_end = cur.address + @as(u32, @intCast(cur.data.items.len));
        if (sect.address < cur_end) {
            // overlap / address overflow
            for (sections) |s| allocator.free(s.data);
            allocator.free(sections);
            cur.data.deinit(allocator);
            return error.InvalidElf;
        }
        const gap = sect.address - cur_end;
        if (gap > max_tiny_gap) {
            try merged.append(allocator, cur);
            cur = Builder{ .address = sect.address, .data = .empty };
            try cur.data.appendSlice(allocator, sect.data);
        } else {
            try cur.data.appendNTimes(allocator, 0, gap);
            try cur.data.appendSlice(allocator, sect.data);
        }
    }
    try merged.append(allocator, cur);

    // Free the inputs now that everything is copied.
    for (sections) |s| allocator.free(s.data);
    allocator.free(sections);

    const out = try allocator.alloc(Section, merged.items.len);
    for (merged.items, 0..) |*b, i| {
        out[i] = .{ .address = b.address, .data = try b.data.toOwnedSlice(allocator) };
    }
    merged.deinit(allocator);
    return out;
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

const testing = std.testing;

test "ihex parses contiguous data records" {
    const text =
        ":10000000000102030405060708090A0B0C0D0E0F78\n" ++
        ":00000001FF\n";
    var fw = try readIhex(testing.allocator, text);
    defer fw.deinit(testing.allocator);
    try testing.expect(fw == .sections);
    try testing.expectEqual(@as(usize, 1), fw.sections.len);
    try testing.expectEqual(@as(u32, 0), fw.sections[0].address);
    try testing.expectEqual(@as(usize, 16), fw.sections[0].data.len);
    try testing.expectEqual(@as(u8, 0x0F), fw.sections[0].data[15]);
}

test "readElf extracts PT_LOAD segments by physical address" {
    var buf: [88]u8 = @splat(0);
    // ELF32 LE header
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 1; // EI_CLASS = ELF32
    buf[5] = 1; // EI_DATA = little-endian
    std.mem.writeInt(u32, buf[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, buf[42..44], 32, .little); // e_phentsize
    std.mem.writeInt(u16, buf[44..46], 1, .little); // e_phnum
    // Program header at offset 52
    const ph = buf[52..];
    std.mem.writeInt(u32, ph[0..4], 1, .little); // p_type = PT_LOAD
    std.mem.writeInt(u32, ph[4..8], 84, .little); // p_offset
    std.mem.writeInt(u32, ph[12..16], 0x08000000, .little); // p_paddr
    std.mem.writeInt(u32, ph[16..20], 4, .little); // p_filesz
    // payload at offset 84
    @memcpy(buf[84..88], &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD });

    var fw = try readElf(testing.allocator, &buf);
    defer fw.deinit(testing.allocator);
    try testing.expect(fw == .sections);
    try testing.expectEqual(@as(usize, 1), fw.sections.len);
    try testing.expectEqual(@as(u32, 0x08000000), fw.sections[0].address);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC, 0xDD }, fw.sections[0].data);
}

test "fillTinyGap merges small gaps and splits large ones" {
    const a = try testing.allocator.dupe(u8, &.{ 1, 2 });
    const b = try testing.allocator.dupe(u8, &.{ 3, 4 });
    const secs = try testing.allocator.alloc(Section, 2);
    secs[0] = .{ .address = 0, .data = a };
    secs[1] = .{ .address = 4, .data = b }; // gap of 2 (4 - 2)
    const merged = try fillTinyGap(testing.allocator, secs, 4096);
    defer {
        for (merged) |s| testing.allocator.free(s.data);
        testing.allocator.free(merged);
    }
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 0, 0, 3, 4 }, merged[0].data);
}
