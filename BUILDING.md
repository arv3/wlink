# Building wlink

wlink is built with [Zig](https://ziglang.org/) **0.16.0**. Zig ships its own C
toolchain and cross-compiles out of the box, so no external linker or MinGW setup
is required.

## Native

```bash
zig build                       # debug build -> zig-out/bin/wlink
zig build -Doptimize=ReleaseSafe
```

Run directly, passing CLI arguments after `--`:

```bash
zig build run -- --help
```

Run the library unit tests:

```bash
zig build test
```

## Cross-compiling

Pass a target triple with `-Dtarget`; Zig handles the rest. The output lands in
`zig-out/bin/`.

| Target | Command | Output |
|--------|---------|--------|
| x86_64 Windows | `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe` | `zig-out/bin/wlink.exe` |
| x86_64 Linux | `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe` | `zig-out/bin/wlink` |
| aarch64 macOS | `zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe` | `zig-out/bin/wlink` |

### Notes

- **32-bit Windows (`x86-windows`)** is not currently supported: the bundled
  libusb fork fails C-header translation on that target (`PCONTEXT` in
  `winnt.h`). Use the 64-bit build.
- Cross-compiling **to macOS from a non-macOS host** requires the macOS SDK
  (for the IOKit framework that libusb links against) and is not part of the
  normal flow — build macOS binaries on a macOS host.
- USB access on Linux needs the appropriate udev rules / permissions at runtime;
  this is independent of the build.
