# wlink - WCH-Link(RV) command line tool

> **Note**
> This tool may not be ready for production use. This fork is an LLM-asssisted port to Zig 0.16.

## Feature Support

- [x] Flash firmware, support Intel HEX, ELF and raw binary format
- [x] Erase chip
- [x] Halt, resume, reset support
- [x] Read chip info
- [x] Read chip memory(flash)
- [x] Read/write chip register - very handy for debugging
- [x] Code-Protect & Code-Unprotect for supported chips
- [x] Enable or Disable 3.3V, 5V output
- [x] [SDI print](https://www.cnblogs.com/liaigu/p/17628184.html) support, requires 2.10+ firmware
- [x] [Serial port watching](https://github.com/ch32-rs/wlink/pull/36) for a smooth development experience
- [ ] ~~Windows native driver support, no need to install libusb manually (requires x86 build)~~


### Probes

Current firmware version: 2.15 (aka. v35).

> **NOTE**: If you are using newer chips like CH32V317 or CH585, be sure to use the latest firmware.

> **NOTE**: The firmware version is not the same as the version shown by WCH's toolchain. Because WCH calculates the version number by `major * 10 + minor`, so the firmware version 2.10 is actually v30 `0x020a`.

- WCH-Link [CH549] - the first version, reflash required when switching mode
- WCH-LinkE [CH32V305][CH32V307] - the recommended debug probe
- WCH-LinkW [CH32V208][CH32V208] - wireless version
- WCH-Link? [CH32V203][CH32V203]

[CH549]: https://www.wch-ic.com/products/CH549.html

### MCU

- [CH32V003]
- [CH32V103]
- [CH32V203]/[CH32V208]
- [CH32V307]
- [CH569]/CH565
- [CH573]/CH571
- [CH583]/CH582/CH581
- [CH585]/CH584
- [CH592]/CH591
- [CH643]
- [CH641]
- [CH32X035]/CH32X033
- [CH32L103]
- [CH32H417]

[CH32V003]: https://www.wch-ic.com/products/CH32V003.html
[CH32V103]: https://www.wch-ic.com/products/CH32V103.html
[CH32V203]: https://www.wch-ic.com/products/CH32V203.html
[CH32V208]: https://www.wch-ic.com/products/CH32V208.html
[CH32V307]: https://www.wch-ic.com/products/CH32V307.html
[CH32V317]: https://www.wch.cn/products/CH32V317.html
[CH32X035]: https://www.wch-ic.com/products/CH32X035.html
[CH32L103]: https://www.wch-ic.com/products/CH32L103.html
[CH569]: https://www.wch-ic.com/products/CH569.html
[CH573]: https://www.wch-ic.com/products/CH573.html
[CH583]: https://www.wch-ic.com/products/CH583.html
[CH585]: https://www.wch-ic.com/products/CH585.html
[CH592]: https://www.wch-ic.com/products/CH592.html
[CH641]: https://www.wch-ic.com/products/CH641.html
[CH643]: https://www.wch-ic.com/products/CH643.html
[CH32H417]: https://www.wch-ic.com/products/CH32H417.html

## References

- [docs/references.md](docs/references.md)
- WCH's openocd fork: <https://github.com/treideme/openocd-hacks>

## License

This project is licensed under the MIT or Apache-2.0 license, at your option.
