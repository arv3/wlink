//! The chip DB.
//! These numbers are from the `GetCHIPID` fn in EVT code.

/// Map a chip-id (as reported by AttachChip) to a human-readable part name.
/// Returns null when the id is unknown.
pub fn chipIdToChipName(chip_id: u32) ?[]const u8 {
    return switch (chip_id & 0xFFF00000) {
        0x650_00000 => "CH565",
        0x690_00000 => "CH569",
        0x710_00000 => "CH571",
        0x730_00000 => "CH573",
        0x810_00000 => "CH581",
        0x820_00000 => "CH582",
        0x830_00000 => "CH583",
        0x840_00000 => "CH584",
        0x920_00000 => "CH592",
        0x930_00000 => "CH585",
        0x003_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x003_00500 => "CH32V003F4P6",
            0x003_10500 => "CH32V003F4U6",
            0x003_20500 => "CH32V003A4M6",
            0x003_30500 => "CH32V003J4M6",
            else => null,
        },
        // https://github.com/openwch/ch32v002_004_005_006_007/blob/main/EVT/EXAM/SRC/Peripheral/src/ch32v00X_dbgmcu.c
        0x006_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x006_00600 => "CH32V006K8U6",
            0x006_10600 => "CH32V006E8R6",
            0x006_20600 => "CH32V006F8U6",
            0x006_30600 => "CH32V006F8P6",
            else => null,
        },
        0x007_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x007_00800 => "CH32M007G8R6",
            0x007_10600 => "CH32V007E8R6",
            0x007_20600 => "CH32V007F8U6",
            else => null,
        },
        0x005_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x005_00600 => "CH32V005E6R6",
            0x005_10600 => "CH32V005F6U6",
            0x005_20600 => "CH32V005F6P6",
            0x005_30600 => "CH32V005D6U6",
            else => null,
        },
        0x002_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x002_00600 => "CH32V002F4P6",
            0x002_10600 => "CH32V002F4U6",
            0x002_20600 => "CH32V002A4M6",
            0x002_30600 => "CH32V002D4U6",
            0x002_40600 => "CH32V002J4M6",
            else => null,
        },
        0x004_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x004_00600 => "CH32V004F6P1",
            0x004_10600 => "CH32V004F6U1",
            else => null,
        },
        0x035_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x035_00601 => "CH32X035R8T6",
            0x035_10601 => "CH32X035C8T6",
            0x035_E0601 => "CH32X035F8U6",
            0x035_60601 => "CH32X035G8U6",
            0x035_B0601 => "CH32X035G8R6",
            0x035_70601 => "CH32X035F7P6",
            0x035_A0601 => "CH32X033F8P6",
            else => null,
        },
        0x103_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x103_00700 => "CH32L103C8U6",
            0x103_10700 => "CH32L103C8T6",
            0x103_A0700 => "CH32L103F8P6",
            0x103_B0700 => "CH32L103G8R6",
            0x103_20700 => "CH32L103K8U6",
            0x103_D0700 => "CH32L103F8U6",
            0x103_70700 => "CH32L103F7P6",
            else => null,
        },
        0x200_00000 => switch (chip_id) {
            0x200_04102 => "CH32F103C8T6",
            0x200_0410F => "CH32F103R8T6",
            else => null,
        },
        0x203_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x203_00500 => "CH32V203C8U6",
            0x203_10500 => "CH32V203C8T6",
            0x203_20500 => "CH32V203K8T6",
            0x203_30500 => "CH32V203C6T6",
            0x203_50500 => "CH32V203K6T6",
            0x203_60500 => "CH32V203G6U6",
            0x203_B0500 => "CH32V203G8R6",
            0x203_E0500 => "CH32V203F8U6",
            0x203_70500 => "CH32V203F6P6",
            0x203_90500 => "CH32V203F6P6",
            0x203_A0500 => "CH32V203F8P6",
            0x203_4050C => "CH32V203RBT6",
            else => null,
        },
        0x208_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x208_0050C => "CH32V208WBU6",
            0x208_1050C => "CH32V208RBT6",
            0x208_2050C => "CH32V208CBU6",
            0x208_3050C => "CH32V208GBU6",
            else => null,
        },
        0x303_00000, 0x305_00000, 0x307_00000, 0x317_00000 => switch (chip_id & 0xFFFFFF0F) {
            0x303_30504 => "CH32V303CBT6",
            0x303_20504 => "CH32V303RBT6",
            0x303_10504 => "CH32V303RCT6",
            0x303_00504 => "CH32V303VCT6",
            0x305_20508 => "CH32V305FBP6",
            0x305_00508 => "CH32V305RBT6",
            0x305_B0508 => "CH32V305GBU6",
            0x307_30508 => "CH32V307WCU6",
            0x307_20508 => "CH32V307FBP6",
            0x307_10508 => "CH32V307RCT6",
            0x307_00508 => "CH32V307VCT6",
            0x317_0B508 => "CH32V317VCT6",
            0x317_3B508 => "CH32V317WCU6",
            0x317_5B508 => "CH32V317TCU6",
            else => null,
        },
        // https://github.com/openwch/ch32h417/blob/main/EVT/EXAM/SRC/Peripheral/src/ch32h417_dbgmcu.c
        0x415_00000, 0x416_00000, 0x417_00000 => switch (chip_id & ~@as(u32, 0x0000_00F0)) {
            0x415_0050D => "CH32H415REU",
            0x416_0050D => "CH32H416RDU",
            0x417_0050D => "CH32H417QEU",
            0x417_1050D => "CH32H417MEU",
            0x417_2050D => "CH32H417WEU",
            else => null,
        },
        0x641 => switch (chip_id & 0xFFFFFF0F) {
            0x641_00500 => "CH641F",
            0x641_10500 => "CH641D",
            0x641_50500 => "CH641U",
            0x641_60500 => "CH641P",
            else => null,
        },
        0x643_00000 => switch (chip_id) {
            0x643_00601 => "CH643W",
            0x643_10601 => "CH643Q",
            0x643_30601 => "CH643L",
            0x643_40601 => "CH643U",
            else => null,
        },
        else => null,
    };
}

const std = @import("std");
const testing = std.testing;

test "ch32h41x package ids ignore variant nibble" {
    try testing.expectEqualStrings("CH32H417QEU", chipIdToChipName(0x4170_052D).?);
    try testing.expectEqualStrings("CH32H417QEU", chipIdToChipName(0x4170_050D).?);
    try testing.expectEqualStrings("CH32H417MEU", chipIdToChipName(0x4171_050D).?);
    try testing.expectEqualStrings("CH32H417WEU", chipIdToChipName(0x4172_050D).?);
    try testing.expectEqualStrings("CH32H415REU", chipIdToChipName(0x4150_050D).?);
    try testing.expectEqualStrings("CH32H416RDU", chipIdToChipName(0x4160_050D).?);
}
