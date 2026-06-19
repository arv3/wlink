# Building wlink

## Native

```bash
cargo build --release
```

## Cross-compiling to Windows (from macOS / Linux)

Three Windows targets are supported. Linker settings and convenience aliases
live in [`.cargo/config.toml`](.cargo/config.toml).

| Target | Toolchain | Channel | Output |
|--------|-----------|---------|--------|
| `x86_64-pc-windows-gnu` | mingw-w64 | stable | `target/x86_64-pc-windows-gnu/release/wlink.exe` |
| `i686-pc-windows-gnu` | mingw-w64 + build-std | **nightly** | `target/i686-pc-windows-gnu/release/wlink.exe` |
| `i686-pc-windows-msvc` | cargo-xwin | stable | `target/i686-pc-windows-msvc/release/wlink.exe` |

### x86_64 Windows (GNU) — easiest

One-time setup:

```bash
brew install mingw-w64               # provides x86_64-w64-mingw32-gcc
rustup target add x86_64-pc-windows-gnu
```

Build:

```bash
cargo win64        # alias for: cargo build --release --target x86_64-pc-windows-gnu
```

### i686 / 32-bit Windows (GNU)

Homebrew's i686 mingw-w64 uses **SjLj** exception handling, while Rust's prebuilt
`i686-pc-windows-gnu` std expects **DWARF-2** unwinding. This mismatch produces
`undefined reference to _Unwind_Resume` at link time. The workaround is to rebuild
std with `panic = "abort"` (no unwinder needed), which requires nightly.

One-time setup:

```bash
brew install mingw-w64
rustup toolchain install nightly
rustup component add rust-src --toolchain nightly
rustup target add i686-pc-windows-gnu --toolchain nightly   # provides rsbegin.o/rsend.o
```

Build (the `panic=abort` rustflag is already set in `.cargo/config.toml`):

```bash
cargo +nightly win32   # alias for:
                       #   cargo build --release --target i686-pc-windows-gnu \
                       #     -Z build-std=std,panic_abort
```

Caveat: `panic = "abort"` means panics terminate the process immediately —
`std::panic::catch_unwind` will not recover. Fine for a CLI, worth knowing.

### i686 / 32-bit Windows (MSVC) — cleanest 32-bit option

Uses the MSVC ABI via [cargo-xwin](https://github.com/rust-cross/cargo-xwin),
avoiding mingw's SjLj problem. Works on stable and produces a smaller binary
(~1.3M vs ~3.4M for the GNU build).

One-time setup:

```bash
cargo install --locked cargo-xwin
rustup target add i686-pc-windows-msvc
```

Build:

```bash
cargo xwin build --release --target i686-pc-windows-msvc --xwin-arch x86
```

Notes:
- `--xwin-arch x86` is **required** — cargo-xwin downloads only `x86_64`/`aarch64`
  SDK import libs by default, so without it linking fails with
  `could not open 'kernel32.lib'`.
- The first run downloads the MSVC CRT/SDK (~30s), cached in
  `~/Library/Caches/cargo-xwin` thereafter.
