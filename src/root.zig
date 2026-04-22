pub const common = @import("common.zig");
pub const cli = @import("cli.zig");
pub const fs_paths = @import("fs_paths.zig");
pub const cartridge = @import("cartridge.zig");
pub const cartridge_rtc = @import("cartridge_rtc.zig");
pub const scheduler = @import("scheduler.zig");
pub const timer = @import("timer.zig");
pub const dma = @import("dma.zig");
pub const apu = @import("apu.zig");
pub const io = @import("io.zig");
pub const ppu = @import("ppu.zig");
pub const arm7tdmi = @import("cpu/arm7tdmi.zig");
pub const arm_isa = @import("cpu/arm_isa.zig");
pub const thumb_isa = @import("cpu/thumb_isa.zig");
pub const gba = @import("gba.zig");
pub const savestate = @import("savestate.zig");

test {
    _ = common;
    _ = cli;
    _ = fs_paths;
    _ = cartridge;
    _ = cartridge_rtc;
    _ = scheduler;
    _ = timer;
    _ = dma;
    _ = apu;
    _ = io;
    _ = ppu;
    _ = arm7tdmi;
    _ = arm_isa;
    _ = thumb_isa;
    _ = gba;
    _ = savestate;
}
