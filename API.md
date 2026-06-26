# wlink — Zig Module API

`wlink` is a WCH-Link RISC-V flash/debug library (and CLI) for WCH's RISC-V MCUs
(CH32V, CH56X, CH57X, CH58X, CH59X, CH32L103, CH32X035, CH641, CH643, …). The library
talks to the probe over USB via **libusb** and exposes a small synchronous API.

This document describes the public API of the `wlink` Zig module (`src/root.zig`).

## Using as a dependency

`build.zig.zon`:

```zig
.dependencies = .{
    .wlink = .{
        .url = "git+https://github.com/<you>/wlink#<commit>",
        // .hash = "...",  // filled by `zig fetch --save`
    },
},
```

`build.zig`:

```zig
const wlink_dep = b.dependency("wlink", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("wlink", wlink_dep.module("wlink"));
```

The module links libusb and the `serial` package itself; downstream code does not need
to wire those up.

```zig
const wlink = @import("wlink");
```

> **libc / Io.** The library links libc (via libusb) and sleeps with `nanosleep`, so it
> does not need a `std.Io` instance for probe operations. Only file and serial helpers
> (`firmware.readFromFile`, `serial_monitor.*`) take an `io: std.Io`.

### Sharing a libusb context

By default each open/list call creates and owns a private libusb context. To share an
existing context (e.g. one your app already created), pass it to the `*Ctx` variants.
The context parameter is `?*anyopaque` so it accepts a `*libusb_context` from **any**
module's libusb `@cImport` (the opaque types are distinct but layout-identical); `null`
means "create a private context". A caller-supplied context is **not** freed by the
library — you keep ownership.

```zig
// `my_ctx` is your `*c.libusb_context` (your own @cImport). It coerces to ?*anyopaque.
var probe = try wlink.WchLink.openNthCtx(my_ctx, 0);
var sess = try wlink.ProbeSession.attach(probe, null, .high);
defer sess.deinit(); // closes the device; leaves my_ctx alone

const listings = try wlink.usb.listDevices(gpa, my_ctx, wlink.probe.VENDOR_ID, wlink.probe.PRODUCT_ID);
defer wlink.usb.freeListings(gpa, listings);
```

## Quick start

```zig
const std = @import("std");
const wlink = @import("wlink");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    // Open probe #0, attach to the target (auto-detect family), 6 MHz.
    var probe = try wlink.WchLink.openNth(0);
    var sess = try wlink.ProbeSession.attach(probe, null, .high);
    defer sess.deinit();

    try sess.dumpInfo();

    // Flash an ELF/ihex/bin file and reset-to-run.
    var fw = try wlink.firmware.readFromFile(gpa, init.io, "firmware.elf");
    defer fw.deinit(gpa);
    try wlink.flash.flashFirmware(&sess, gpa, &fw, .{}); // .no_run / .skip_gap / progress opt-in

    try sess.detachChip();
    return 0;
}
```

## Conventions

- **Errors:** all fallible calls return `wlink.Error!T` (see [Errors](#error)). Functions
  that allocate also return `std.mem.Allocator.Error`; file/serial functions add their
  own I/O error sets.
- **Ownership:** any function returning a slice documents who frees it. `[]Listing`,
  `Firmware`, and `readMemory` results are caller-owned.
- **Lifetimes:** `WchLink.transact`/`transactRaw` return a slice into the probe's
  internal buffer — valid only until the next `transact*` call. Copy if you need it
  later.

---

## Top-level re-exports (`wlink`)

| Symbol | Kind | Notes |
|---|---|---|
| `Error` | error set | aggregate error type ([Errors](#error)) |
| `AbstractcsCmdErr` | enum | DM abstract-command error cause |
| `RiscvChip` | enum(u8) | chip family + per-family behaviour |
| `Speed` | enum(u8) | probe clock speed (`= commands.Speed`) |
| `WchLink` | struct | the probe handle |
| `WchLinkVariant` | enum(u8) | probe hardware variant |
| `ProbeInfo` | struct | probe firmware version + variant |
| `ProbeSession` | struct | an attached debug/flash session |
| `chips` | namespace | chip-id → name lookup |
| `flash_op` | namespace | per-family RAM flash-loader blobs |
| `commands` | namespace | command framing + typed commands |
| `probe` | namespace | probe constants + free functions |
| `usb` | namespace | libusb transport |
| `operations` | namespace | `ProbeSession` + helpers |
| `dmi` | namespace | RISC-V debug-module access |
| `regs` | namespace | register numbers + bitfield structs |
| `firmware` | namespace | firmware file parsing |
| `flash` | namespace | high-level flash operation |
| `serial_monitor` | namespace | SDI-print / serial monitor |

---

## `WchLink` — the probe

```zig
pub const WchLink = struct {
    device: usb.Device,
    info: ProbeInfo,
    // internal reply buffer
};
```

| Function | Signature | Description |
|---|---|---|
| `openNth` | `(nth: usize) Error!WchLink` | Open the nth WCH-Link in RV mode (private libusb context). Returns `error.ProbeModeNotSupported` if the device is only present in DAP mode. Reads `info` on open. |
| `openNthCtx` | `(ctx: ?*anyopaque, nth: usize) Error!WchLink` | As `openNth`, but uses a caller-supplied libusb context (`null` = create one). The caller keeps ownership of a supplied context. |
| `deinit` | `(*WchLink) void` | Release the interface and close the device. |
| `transact` | `(*WchLink, cmd_id: u8, payload: []const u8) Error![]const u8` | Send a command frame, return the reply **payload** (validates framing; `error.Protocol` on a 0x81 error reply). Slice valid until the next call. |
| `transactRaw` | `(*WchLink, cmd_id: u8, payload: []const u8) Error![]const u8` | As `transact` but returns the full raw reply (for non-standard replies like ESignature). |
| `send` | `(*WchLink, cmd_id: u8, payload: []const u8) Error!void` | `transact` discarding the payload. |
| `writeData` | `(*WchLink, buf: []const u8, packet_len: usize) Error!void` | Write to the data-out endpoint in `packet_len` packets (last padded with 0xff). `packet_len` ≤ 256. |
| `writeDataWithProgress` | `(*WchLink, buf, packet_len, ctx: ?*anyopaque, cb: ?ProgressFn) Error!void` | As above with a per-packet callback. |
| `readData` | `(*WchLink, buf: []u8) Error!void` | Read exactly `buf.len` bytes from the data-in endpoint. |
| `getProbeInfo` | `(*WchLink) Error!ProbeInfo` | Query firmware version/variant (0x0d 0x01). |
| `setPower` | `(*WchLink, cmd: commands.SetPower) Error!void` | Toggle power output on an already-open probe (WCH-LinkE/W only). |
| `enable3v3` / `disable3v3` / `enable5v` / `disable5v` | `(*WchLink) Error!void` | Shortcuts for `setPower`. |

`pub const ProgressFn = *const fn (ctx: ?*anyopaque, nbytes: usize) void;`

### Free functions (`wlink.probe`)

| Function | Signature | Description |
|---|---|---|
| `indexBySerial` | `(serial: []const u8) Error!usize` | Resolve a WCH-Link serial number to the index used by `WchLink.openNth`. `Error.ProbeNotFound` if none matches. |
| `switchFromRvToDap` | `(nth: usize) Error!void` | Switch the nth probe RV → DAP mode. |
| `switchFromDapToRv` | `(nth: usize) Error!void` | Switch the nth probe DAP → RV mode. |
| `setPowerOutputEnabled` | `(nth: usize, cmd: commands.SetPower) Error!void` | Toggle 3.3 V / 5 V output (WCH-LinkE/W only). |

Each has a `*Ctx` variant taking a leading `ctx: ?*anyopaque` (shared libusb context):
`indexBySerialCtx`, `switchFromRvToDapCtx`, `switchFromDapToRvCtx`,
`setPowerOutputEnabledCtx`.

```zig
const nth = try wlink.probe.indexBySerial("FABC8F067FEE");
var probe = try wlink.WchLink.openNth(nth);
```

### Constants (`wlink.probe`)

`VENDOR_ID` 0x1a86, `PRODUCT_ID` 0x8010, `ENDPOINT_OUT/IN` 0x01/0x81,
`DATA_ENDPOINT_OUT/IN` 0x02/0x82, `VENDOR_ID_DAP`/`PRODUCT_ID_DAP` 0x1a86/0x8012,
`ENDPOINT_OUT_DAP` 0x02.

### `WchLinkVariant`

`ch549`, `e_ch32v305` (default), `s_ch32v203`, `w_ch32v208`. Methods:
`fromU8`, `supportSwitchMode`, `supportPowerFuncs`, `supportSdiPrint`,
`supportChip(RiscvChip)`, `name() []const u8`.

### `ProbeInfo`

```zig
pub const ProbeInfo = struct {
    major_version: u8,
    minor_version: u8,
    variant: WchLinkVariant,
};
```

`version() struct{u8,u8}`, `versionAtLeast(major, minor) bool`,
`fromPayload([]const u8) Error!ProbeInfo`, `format` (use `"{f}"`).

---

## `ProbeSession` — attached session (`wlink.ProbeSession`)

```zig
pub const ProbeSession = struct {
    probe: WchLink,
    chip_family: RiscvChip,
    speed: Speed,
};
```

| Function | Signature | Description |
|---|---|---|
| `attach` | `(probe: WchLink, expected_chip: ?RiscvChip, speed: Speed) Error!ProbeSession` | Set speed, attach (4 retries), verify family if `expected_chip` is given, run per-family post-init. Takes ownership of `probe`. |
| `deinit` | `(*ProbeSession) void` | Close the underlying probe. |
| `detachChip` | `(*ProbeSession) Error!void` | Detach (0x0d 0xff). |
| `dumpInfo` | `(*ProbeSession) Error!void` | Log ESIG, flash-protect status, RAM/ROM split. Halts the MCU. |
| `softReset` | `(*ProbeSession) Error!void` | Quit-reset and run. |
| `setSdiPrintEnabled` | `(*ProbeSession, enable: bool) Error!void` | Toggle SDI virtual-serial print (probe + chip must support it). |
| `unprotectFlash` | `(*ProbeSession) Error!void` | Remove read/write protection. |
| `protectFlash` | `(*ProbeSession) Error!void` | Enable read protection. |
| `eraseFlash` | `(*ProbeSession) Error!void` | Erase code flash (unprotecting first if needed) and re-attach. |
| `writeFlash` | `(*ProbeSession, data: []const u8, address: u32, progress_ctx: ?*anyopaque, progress: ?*const fn(ctx, written, total) void) Error!void` | Upload the RAM flash-loader and fast-program `data`. |
| `readMemory` | `(*ProbeSession, allocator, address: u32, length: u32) (Error \|\| Allocator.Error)![]u8` | Read a region (rounded up to 4 bytes); caller owns the result. Requires a halted MCU. |
| `eraseFlashByPowerOff` | `(p: *WchLink, chip_family: RiscvChip) Error!void` | Special erase by powering off the target (WCH-LinkE only; bypasses attach). |
| `eraseFlashByRstPin` | `(p: *WchLink, chip_family: RiscvChip) Error!void` | Special erase via the RST pin (WCH-LinkE only). |

Helper: `wlink.operations.sleepMs(ms: u64) void`.

---

## `dmi` — RISC-V debug module (`wlink.dmi`)

Low-level ops operate on `*WchLink`; higher-level register/memory access on
`*ProbeSession`.

| Function | Signature |
|---|---|
| `dmiNop` | `(*WchLink) Error!void` |
| `dmiRead` | `(*WchLink, reg: u8) Error!u32` (retries while busy) |
| `dmiWrite` | `(*WchLink, reg: u8, value: u32) Error!void` |
| `readDmiReg` | `(*WchLink, comptime R: type) Error!R` (R from `regs`) |
| `writeDmiReg` | `(*WchLink, reg: anytype) Error!void` |
| `ensureMcuHalt` | `(*ProbeSession) Error!void` |
| `ensureMcuResume` | `(*ProbeSession) Error!void` |
| `resetDebugModule` | `(*ProbeSession) Error!void` |
| `readReg` | `(*ProbeSession, regno: u16) Error!u32` |
| `writeReg` | `(*ProbeSession, regno: u16, value: u32) Error!void` |
| `readMem32` | `(*ProbeSession, addr: u32) Error!u32` |
| `writeMem32` | `(*ProbeSession, addr: u32, data: u32) Error!void` |
| `writeMem8` | `(*ProbeSession, addr: u32, data: u8) Error!void` |
| `dumpCoreCsrs` | `(*ProbeSession) Error!void` (logs misa/marchid) |
| `dumpRegs` | `(*ProbeSession, w: *std.Io.Writer) Error!void` |
| `dumpPmpCsrs` | `(*ProbeSession) Error!void` |
| `dumpDmi` | `(*ProbeSession) Error!void` |
| `parseMarchid` | `(marchid: u32, buf: []u8) []const u8` |
| `parseMisa` | `(misa: u32, buf: []u8) []const u8` |

Constants: `KEY1`, `KEY2`.

---

## `regs` — registers (`wlink.regs`)

- **CSR numbers:** `MARCHID`, `MIMPID`, `MSTATUS`, `MISA`, `MTVEC`, `MSCRATCH`, `MEPC`,
  `MCAUSE`, `MTVAL`, `DPC`.
- **DMI addresses:** `DMDATA0/1`, `DMCONTROL`, `DMSTATUS`, `DMHARTINFO`, `DMABSTRACTCS`,
  `DMCOMMAND`, `DMABSTRACTAUTO`, `DMPROGBUF0`, `DMHALTSUM0`.
- **Tables:** `GPRS_RVI`, `GPRS_RVE`, `CSRS`, `PMP_CSRS` (arrays of `Gpr`/`Csr`).
- **Bitfield registers** (each `packed struct(u32)` with `ADDR`, `fromBits(u32)`,
  `toBits() u32`): `Dmcontrol`, `Dmstatus`, `Hartinfo`, `Abstractcs`, `Command`.

```zig
const st = try wlink.dmi.readDmiReg(&sess.probe, wlink.regs.Dmstatus);
if (st.allhalted) { ... }
```

---

## `firmware` — file parsing (`wlink.firmware`)

```zig
pub const FirmwareFormat = enum { plain_hex, intel_hex, elf, binary };
pub const Section = struct { address: u32, data: []u8, pub fn endAddress() u32 };
pub const Firmware = union(enum) {
    binary: []u8,
    sections: []Section,
    pub fn deinit(*Firmware, allocator) void,  // frees owned memory
};
```

| Function | Signature | Description |
|---|---|---|
| `readFromFile` | `(allocator, io: std.Io, path: []const u8) (ReadError \|\| std.Io.Dir.ReadFileAllocError)!Firmware` | Read + parse, guessing the format. |
| `guessFormat` | `(path, raw) FirmwareFormat` | Guess by extension/content. |
| `readIhex` | `(allocator, text: []const u8) ReadError!Firmware` | Parse Intel-HEX. |
| `readElf` | `(allocator, elf: []const u8) ReadError!Firmware` | Parse ELF32 `PT_LOAD` segments by physical address. |
| `fillTinyGap` | `(allocator, sections: []Section, max_tiny_gap: u32) ReadError![]Section` | Merge sections ≤ `max_tiny_gap` apart (zero-filling). **Consumes** `sections`. |

`ReadError = Error || Allocator.Error || error{ InvalidHex, InvalidElf, EmptyImage }`.

---

## `flash` — high-level flash operation (`wlink.flash`)

Writes a parsed `Firmware` to an attached target and optionally resets it to run.
The caller still owns probe open/attach, pre-flash erase, and post-flash detach;
this only writes the image and resets-to-run.

```zig
pub const ProgressFn = *const fn (ctx: ?*anyopaque, written: usize, total: usize) void;
pub const Options = struct {
    address: ?u32 = null,          // binary only; null = chip default code-flash start
    skip_gap: bool = false,        // merge sections ≤ 4096 B apart (ELF/ihex only)
    no_run: bool = false,          // leave target halted instead of reset-to-run
    progress_ctx: ?*anyopaque = null,
    progress: ?ProgressFn = null,  // called with (written, total); written==total ends a section
};
```

| Function | Signature | Description |
|---|---|---|
| `flashFirmware` | `(sess: *ProbeSession, allocator, fw: *Firmware, opts: Options) firmware.ReadError!void` | Flash `fw`, then reset-to-run unless `opts.no_run`. |

**Ownership:** `fw` is passed by pointer. For a section image the routine consumes
the sections and resets `fw.*` to an empty image, so the caller's
`defer fw.deinit(allocator)` stays correct. A binary image is left intact for the
caller to free. `allocator` must be the one that produced `fw`.

---

## `serial_monitor` — SDI-print / serial (`wlink.serial_monitor`)

| Function | Signature | Description |
|---|---|---|
| `findPort` | `(io: std.Io, allocator, buf: []u8) Error!?[]const u8` | Locate the WCH-Link CDC node (matches probe serial; scans `/dev` on macOS). |
| `watchSerial` | `(io: std.Io, allocator, out: *std.Io.Writer) Error!void` | Open the port at 115200 and stream to `out` until disconnect. |

---

## `commands` — framing + typed commands (`wlink.commands`)

Generic framing:

| Function | Signature | Description |
|---|---|---|
| `buildFrame` | `(buf: []u8, cmd_id: u8, payload: []const u8) []u8` | Build `[0x81, cmd, len, payload…]`. |
| `parseReply` | `(raw: []const u8) Error![]const u8` | Validate a reply and return its payload. |

Command IDs: `CMD_SET_WRITE_REGION` 0x01, `CMD_PROGRAM` 0x02, `CMD_SET_READ_REGION`
0x03, `CMD_CONFIG_CHIP` 0x06, `CMD_DMI_OP` 0x08, `CMD_RESET` 0x0b, `CMD_SET_SPEED` 0x0c,
`CMD_CONTROL` 0x0d, `CMD_DISABLE_DEBUG` 0x0e, `CMD_GET_CHIP_INFO` 0x11.

Framing bytes: `REQ_HEADER`, `RESP_OK`, `RESP_ERR`, `REASON_CONNECT_FAILED` (0x55).

Types & helpers:

- `Speed` enum(u8): `low` 0x03, `medium` 0x02, `high` 0x01; `fromStr`.
- `Reset` enum: `soft`, `normal`, `chip`; `payload()`.
- `Program` enum(u8): `erase_flash`, `write_flash`, `write_flash_and_verify`,
  `write_flash_op`, `prepare`, `unknown07_after_flash_op`, `unknown0b_after_flash_op`,
  `end`, `read_memory`.
- `ConfigChip`: flag consts (`FLAG_READ_PROTECTED`, …) + payload consts
  (`check_read_protect`, `unprotect`, `protect`, `check_read_protect_ex`) +
  `unprotectEx(b, *[8]u8)`, `protectEx(b, *[8]u8)`.
- `ctl`: control-subcommand payloads (`get_probe_info`, `attach_chip`,
  `get_rom_ram_split`, `opt_end`) + `setSdiPrintEnabled(bool)`.
- `SetPower` enum: `enable_3v3`, `disable_3v3`, `enable_5v`, `disable_5v`; `payload()`,
  `fromStr`.
- `eraseCodeFlashByPinRst(chip, *[2]u8)`, `eraseCodeFlashByPowerOff(chip, *[2]u8)`.
- `memRegionPayload(*[8]u8, start_addr, len)`.
- DMI: `DMI_OP_NOP/READ/WRITE`, `dmiNopPayload`, `dmiReadPayload`, `dmiWritePayload`.

Responses:

- `AttachChipResponse { chip_family, riscvchip, chip_id }` — `parse`, `format`.
- `ESignature { flash_size_kb, uid_raw: [8]u8 }` + `Variant { v1, v2 }` — `parseRaw`,
  `format`.
- `DmiOpResponse { addr, data, op }` — `parse`, `isBusy`, `isSuccess`, `isFailed`.

---

## `usb` — libusb transport (`wlink.usb`)

```zig
pub const c = @cImport({ @cInclude("libusb.h"); }); // raw libusb bindings
pub const Device = struct {
    pub fn deinit(*Device) void;
    pub fn setTimeout(*Device, ms: u32) void;
    pub fn readEndpoint(*Device, ep: u8, buf: []u8) Error!usize;
    pub fn writeEndpoint(*Device, ep: u8, buf: []const u8) Error!void;
};
pub const Listing = struct { index: usize, vid: u16, pid: u16, serial: []const u8, speed: []const u8 };
```

| Function | Signature | Description |
|---|---|---|
| `openNth` | `(ctx: ?*anyopaque, vid: u16, pid: u16, nth: usize) Error!Device` | Open + claim interface 0 of the nth match. `ctx` null = private context. |
| `listDevices` | `(allocator, ctx: ?*anyopaque, vid, pid) (Error \|\| Allocator.Error)![]Listing` | Enumerate matches (serials read via `libusb_get_device_string`, no open). `ctx` null = private context. |
| `indexBySerial` | `(ctx: ?*anyopaque, vid, pid, serial: []const u8) Error!usize` | Resolve a serial to the 0-based `openNth` index. `ctx` null = private context. |
| `freeListings` | `(allocator, listings: []Listing) void` | Free a `listDevices` result. |
| `mapErr` | `(rc: c_int) Error!void` | Map a libusb return code to `Error`. |
| `errName` | `(rc: c_int) []const u8` | Human-readable libusb error. |

---

## `RiscvChip` (`wlink.RiscvChip`)

`enum(u8)` whose value is the protocol `riscvchip` byte. Variants include `CH32V103`,
`CH57X`, `CH56X`, `CH32V20X`, `CH32V30X`, `CH582`, `CH32V003`, `CH8571`, `CH59X`,
`CH643`, `CH32X035`, `CH32L103`, `CH564`, `CH645`, `CH641`, `CH585`, `CH32V00X`,
`CH32V317`, `CH32F10X`, `CH32F20X`, `CH32H41X`.

| Method | Signature |
|---|---|
| `fromU8` | `(u8) Error!RiscvChip` |
| `fromStr` | `([]const u8) ?RiscvChip` (case-insensitive, with aliases) |
| `supportFlashProtect` / `supportRamRomMode` / `supportQueryInfo` / `supportDisableDebug` / `supportSpecialErase` / `supportSdiPrint` / `isRv32e` | `(RiscvChip) bool` |
| `getFlashOp` | `(RiscvChip) Error![]const u8` |
| `dataPacketSize` | `(RiscvChip) usize` |
| `codeFlashStart` | `(RiscvChip) u32` |
| `fixCodeFlashStart` | `(RiscvChip, start_address: u32) u32` |
| `writePackSize` | `(RiscvChip) u32` |

Other helpers: `wlink.chips.chipIdToChipName(chip_id: u32) ?[]const u8`;
`wlink.flash_op.<FAMILY>` (RAM flash-loader byte arrays, e.g. `flash_op.CH32V307`).

---

## <a name="error"></a>Errors (`wlink.Error`)

```zig
pub const Error = error{
    Custom, Usb, ProbeNotFound, ProbeModeNotSupported, UnsupportedChip,
    UnknownLinkVariant, UnknownChip, NotAttached, ChipMismatch, Protocol,
    InvalidPayloadLength, InvalidPayload, AbstractCommandError, Busy,
    DmiFailed, Timeout, Serial, Io, Driver,
};
```

`AbstractcsCmdErr` enum(u8) (`busy`, `not_supported`, `exception`, `halt_or_resume`,
`bus`, `parity`, `other`) with `check(value: u8) Error!void` and
`describe(value: u8) []const u8`.

Because Zig error sets can't carry payloads, contextual detail (the offending byte, the
specific protocol reason, etc.) is emitted via `std.log` at the call site.
