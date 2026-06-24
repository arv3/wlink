# Porting `wlink` from Rust to Zig 0.16

Status: **COMPLETE** — all 6 phases done. Full command surface: `list`, `status`,
`regs`, `dump`, `reset`, `halt`, `resume`, `write-reg`, `write-mem`, `flash`, `erase`,
`unprotect`, `protect`, `set-power`, `mode-switch`, `sdi-print`, `watch-serial`.

Verified against a real WCH-LinkE v2.18 probe: `list`, `set-power` (toggled 3.3V),
and `watch-serial` (found/opened the probe's CDC node) all work on hardware; framing/
attach matches the reference Rust `wlink` byte-for-byte (identical 0x55 with no target
MCU connected). Firmware bin/hex/ihex/ELF32 parsing verified via unit tests + a real
.hex file. Target-requiring paths (DMI/flash) compile and mirror Rust exactly; they
need a powered target MCU for full end-to-end verification.

### Notes on the port
- **watch-serial**: the `serial` package's `list_info` has no macOS branch, so the CDC
  port is found by scanning `/dev` (cu.usbmodem* / ttyACM*) and matching the probe
  serial obtained via libusb. `configureSerialPort` works cross-platform.
- The library (`src/root.zig`) is Io-free except where files/serial require it; sleeps
  use libc `nanosleep`. Downstream Zig projects import the `wlink` module.

`wlink` is the WCH-Link RISC-V flash/debug tool (~5,300 lines of Rust). This document
is the plan for porting it to Zig 0.16, structured so the result is usable both as a
**CLI** and as a **dependency** in other Zig projects.

## Goal & constraints

- **Zig 0.16.0** (installed at `/opt/homebrew/bin/zig`).
- **USB via libusb** — the `zweiler2/libusb` Zig package, the exact same dependency
  entry already used by `occhio/tester/pcba-tester`.
- **Library-first**: a `wlink` module (`src/root.zig`) exposes the whole API; the CLI
  (`src/main.zig`) is a thin consumer of it.
- Preserve current behaviour, including the in-progress `feature/skip-gap` 4K-align
  offset logic in `main.rs`'s flash loop.

## Source → target file map

| Rust file | Zig file | Notes |
|---|---|---|
| `lib.rs` (`RiscvChip`) | `riscv_chip.zig` | `enum(u8)` + `support_*` / encoding methods |
| `error.rs` | `error.zig` | error set + `AbstractcsCmdErr` |
| `usb_device.rs` | `usb.zig` | libusb binding + `UsbDevice` (replaces `nusb`) |
| `probe.rs` | `probe.zig` | `WchLink`, `WchLinkVariant`, `transact` |
| `commands/mod.rs`, `commands/control.rs` | `commands.zig` | frame build + typed commands |
| `operations.rs` | `operations.zig` | `ProbeSession` |
| `dmi.rs` | `dmi.zig` | debug module interface |
| `regs.rs` | `regs.zig` | `packed struct(u32)` registers |
| `firmware.rs` | `firmware.zig` | ELF32 / Intel-HEX / plain-hex / binary |
| `flash_op.rs` | `flash_op.zig` | 18 flash-loader blobs (mechanical) |
| `chips.rs` | `chips.zig` | chip-id → name lookup |
| `main.rs` | `main.zig` | CLI dispatcher |
| — | `root.zig` | library entry, re-exports the public API |

## Key porting decisions

### USB: `nusb` (async) → `libusb` (sync)
The biggest change, and a simplification. Every `nusb` `.wait()` / `reader(64)` /
`writer(64)` becomes a synchronous `libusb_bulk_transfer`. Binding pattern (proven in
pcba-tester):

```zig
pub const c = @cImport({ @cInclude("libusb.h"); });
// open:  libusb_get_device_list → match desc.idVendor/idProduct → pick nth →
//        libusb_open → libusb_claim_interface(handle, 0)
// io:    libusb_bulk_transfer(handle, ep, buf, len, &transferred, timeout_ms)
// close: libusb_release_interface → libusb_close ; libusb_exit on ctx
```

The Rust `USBDeviceBackend` trait becomes a plain `UsbDevice` struct with
`readEndpoint` / `writeEndpoint` / `setTimeout`. Endpoints: cmd `0x01`/`0x81`,
data `0x02`/`0x82`. The Windows `ch375_driver` path (`libloading`) is **deferred**;
libusb+WinUSB already covers Windows.

### Trait → Zig idiom
- `Command`/`Response` traits → low-level `WchLink.transact(cmd_id, payload) ![]u8`
  (builds `[0x81, cmd, len, payload…]`, validates the `0x82`/`0x81` reply per
  `protocol.md`) + typed wrapper functions. No trait emulation.
- `regs.rs` `bitfield!` → `packed struct(u32)` (Zig fields are LSB-first, matching the
  bit positions). `DMReg` trait → a `pub const ADDR: u8` decl per struct.
- `RiscvChip` enum + `support_*()` → `enum(u8)` with methods; big-endian payload via
  `std.mem.writeInt(u32, …, .big)`.
- `Result<T, Error>` → Zig error set + explicit `allocator` threading.

### Dependency replacements
| Rust crate | Zig replacement |
|---|---|
| `nusb` | **libusb** (zweiler2 fork) |
| `object` | `std.elf` + manual ELF32 `PT_LOAD` phdr walk |
| `ihex` | hand-rolled Intel-HEX parser |
| `clap` + `clap-verbosity-flag` | hand-rolled subcommand dispatcher |
| `log` / `simplelog` | `std.log` scopes; CLI sets level |
| `indicatif` | progress callback in lib; CLI renders |
| `serialport` | `arv3/zig-serial` (deferred to Phase 6) |
| `anyhow` / `thiserror` | error set + diagnostic strings |
| `hex`, `chrono`, `nu-pretty-hex` | local helpers / `std.fmt` / `std.time` |

## Build wiring (`build.zig`)

```zig
const wlink_mod = b.addModule("wlink", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target, .optimize = optimize,
});
const libusb_dep = b.dependency("libusb", .{
    .target = target, .optimize = optimize, .@"use-rc" = true,
});
wlink_mod.addIncludePath(libusb_dep.path("libusb"));
wlink_mod.linkLibrary(libusb_dep.artifact("usb-1.0"));

const exe = b.addExecutable(.{ .name = "wlink", .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target, .optimize = optimize,
    .imports = &.{.{ .name = "wlink", .module = wlink_mod }},
})});
```

Downstream consumers: `b.dependency("wlink", .{}).module("wlink")`.

## Phases (each independently testable)

1. **Scaffold + data** — build files, `error`, `riscv_chip`, `flash_op`, `chips`.
   Checkpoint: compiles + links libusb; chip-table unit tests pass.
2. **USB + framing** — `usb`, `commands` frame codec, `probe.openNth`/`transact`/
   `GetProbeInfo`. Checkpoint: `wlink list`.
3. **Attach + info** — typed control commands, `ProbeSession.attach`, `dumpInfo`,
   `detach`. Checkpoint: `wlink status`.
4. **DMI + regs** — `regs` packed structs, `dmi` read/write, reg/mem access,
   halt/resume/reset. Checkpoint: `regs`, `dump`, `reset`.
5. **Flash pipeline** — `firmware` parsing, `writeFlash` (flash-OP + fastprogram +
   progress), `eraseFlash`, protect/unprotect, skip-gap. Checkpoint: flash round-trip.
6. **Serial extras** — SDI print, `watch_serial`, power control, mode switch.
   Checkpoint: feature parity.

## Risks to verify

- libusb 64-byte chunked reads + timeout semantics vs the Rust `read_data` loop.
- Endianness: protocol fields big-endian; `read_memory` reverses each 4-byte word.
- `std.elf` ELF32 phdr access (section-name logging is cosmetic, can be dropped).
- `packed struct(u32)` bit order — assert against known register values.
- `RiscvChip.fromStr` must reproduce clap's case-insensitive parse + the CH32H41X
  alias list.
- Preserve the `skip_gap` offset loop from `main.rs` exactly.
