//! Error types for wlink.
//!
//! Rust used a single `thiserror` enum carrying payloads. Zig error sets can't carry
//! payloads, so the set below mirrors the variants and any associated data is surfaced
//! via `log` or returned alongside through dedicated channels where needed.

pub const Error = error{
    /// A catch-all with a human-readable message logged at the call site.
    Custom,
    /// libusb / transport failure.
    Usb,
    /// WCH-Link not found.
    ProbeNotFound,
    /// Device is connected but not in RV mode (likely DAP mode).
    ProbeModeNotSupported,
    /// WCH-Link variant doesn't support the chosen chip.
    UnsupportedChip,
    /// Unknown WCH-Link variant byte.
    UnknownLinkVariant,
    /// Unknown RISC-V chip byte.
    UnknownChip,
    /// Probe not attached to an MCU, or debug not enabled.
    NotAttached,
    /// Attached chip type does not match the expected chip type.
    ChipMismatch,
    /// Underlying WCH-Link protocol error (a 0x81 error reply).
    Protocol,
    /// Response payload length didn't match the declared length.
    InvalidPayloadLength,
    /// Response framing was malformed.
    InvalidPayload,
    /// DM abstract command error (see AbstractcsCmdErr for the specific cause).
    AbstractCommandError,
    /// Debug module is busy.
    Busy,
    /// DMI op reported failure.
    DmiFailed,
    /// Operation timed out.
    Timeout,
    /// Serial port error.
    Serial,
    /// I/O error (file read/write).
    Io,
    /// Windows CH375 driver error.
    Driver,
};

/// Abstract command error causes, from the `abstractcs.cmderr` field.
pub const AbstractcsCmdErr = enum(u8) {
    busy = 1,
    not_supported = 2,
    exception = 3,
    halt_or_resume = 4,
    bus = 5,
    parity = 6,
    other = 7,

    /// Returns an error if `value` indicates a failure; ok for 0.
    pub fn check(value: u8) Error!void {
        switch (value) {
            0 => return,
            1...7 => return Error.AbstractCommandError,
            else => unreachable,
        }
    }

    /// Describe the cmderr value for logging.
    pub fn describe(value: u8) []const u8 {
        return switch (value) {
            0 => "none",
            1 => "busy",
            2 => "not supported",
            3 => "exception",
            4 => "halt/resume",
            5 => "bus error",
            6 => "parity error",
            7 => "other",
            else => "unknown",
        };
    }
};
