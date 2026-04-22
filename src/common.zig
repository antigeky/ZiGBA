const std = @import("std");

pub const byte = u8;
pub const sbyte = i8;
pub const hword = u16;
pub const shword = i16;
pub const word = u32;
pub const sword = i32;
pub const dword = u64;
pub const sdword = i64;

pub const MemoryRegion = enum(u8) {
    bios,
    unused,
    ewram,
    iwram,
    io,
    pram,
    vram,
    oam,
    rom0,
    rom0_ex,
    rom1,
    rom1_ex,
    rom2,
    rom2_ex,
    sram,
    sram_ex,
};

pub inline fn region_from_addr(addr: word) MemoryRegion {
    return @enumFromInt((addr >> 24) & 0x0f);
}

pub inline fn bit(comptime T: type, index: anytype) T {
    return @as(T, 1) << @intCast(index);
}

pub inline fn has_bit(value: anytype, index: anytype) bool {
    const T = @TypeOf(value);
    return (value & bit(T, index)) != 0;
}

pub inline fn rot_right32(value: word, shift: u5) word {
    return std.math.rotr(word, value, shift);
}

pub inline fn sign_extend(comptime Src: type, comptime Dst: type, value: Src) Dst {
    return @as(Dst, @intCast(@as(std.meta.Int(.signed, @bitSizeOf(Src)), @bitCast(value))));
}

pub inline fn bool_to_u1(value: bool) u1 {
    return if (value) 1 else 0;
}

test "sign_extend handles negative hword" {
    try std.testing.expectEqual(@as(i32, -1), sign_extend(u16, i32, 0xffff));
}
