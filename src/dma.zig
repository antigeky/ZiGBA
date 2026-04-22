const std = @import("std");
const common = @import("common.zig");
const scheduler = @import("scheduler.zig");
const gba_mod = @import("gba.zig");
const cartridge = @import("cartridge.zig");

pub const byte = common.byte;
pub const hword = common.hword;
pub const word = common.word;
pub const MemoryRegion = common.MemoryRegion;

pub const DmaAddressControl = enum(u2) {
    inc,
    dec,
    fixed,
    inc_reload,
};

pub const DmaStartTiming = enum(u2) {
    imm,
    vblank,
    hblank,
    spec,
};

pub const DmaChannelState = struct {
    sptr: word = 0,
    dptr: word = 0,
    bus_val: word = 0,
    ct: hword = 0,
    sound: bool = false,
    initial: bool = false,
    waiting: bool = false,
};

/// Contrôleur DMA à quatre canaux fixes.
pub const DmaController = struct {
    master: *anyopaque = undefined,
    dma: [4]DmaChannelState = [_]DmaChannelState{.{}} ** 4,
    active_dma: u3 = 4,

    pub fn init(master: *anyopaque) DmaController {
        return .{ .master = master };
    }

    pub fn enable(self: *DmaController, index: usize) void {
        const gba = self.master_gba();
        const regs = &gba.io.regs.dma[index];
        self.dma[index].sptr = regs.sad;
        self.dma[index].dptr = regs.dad;
        if (regs.cnt.wsize) {
            self.dma[index].sptr &= ~@as(word, 0b11);
            self.dma[index].dptr &= ~@as(word, 0b11);
        } else {
            self.dma[index].sptr &= ~@as(word, 1);
            self.dma[index].dptr &= ~@as(word, 1);
        }
        self.dma[index].ct = regs.ct;
        if (index < 3) {
            self.dma[index].ct %= 0x4000;
            if (self.dma[index].ct == 0) {
                self.dma[index].ct = 0x4000;
            }
        } else if (gba.cart.eeprom_mask != 0 and !gba.cart.eeprom_size_set and (self.dma[index].sptr & gba.cart.eeprom_mask) == gba.cart.eeprom_mask) {
            if (self.dma[index].ct == 9) {
                gba.cart.set_eeprom_size(false);
            }
            if (self.dma[index].ct == 17) {
                gba.cart.set_eeprom_size(true);
            }
        }

        if (index > 0) {
            self.dma[index].sptr %= 1 << 28;
        } else {
            self.dma[index].sptr %= 1 << 27;
        }
        if (index < 3) {
            self.dma[index].dptr %= 1 << 27;
        } else {
            self.dma[index].dptr %= 1 << 28;
        }

        if (regs.cnt.start == .imm) {
            gba.sched.add_event(@enumFromInt(@intFromEnum(scheduler.EventType.dma0) + index), gba.sched.now + 2);
        }
    }

    pub fn activate(self: *DmaController, index: usize) void {
        const gba = self.master_gba();
        const regs = &gba.io.regs.dma[index];
        if (!regs.cnt.enable) {
            return;
        }

        if (regs.cnt.dadcnt == .inc_reload) {
            self.dma[index].dptr = regs.dad;
            if (regs.cnt.wsize) {
                self.dma[index].dptr &= ~@as(word, 0b11);
            } else {
                self.dma[index].dptr &= ~@as(word, 1);
            }
        }
        if (self.dma[index].sound) {
            self.dma[index].ct = 4;
        } else {
            self.dma[index].ct = regs.ct;
        }
        if (index < 3) {
            self.dma[index].ct %= 0x4000;
            if (self.dma[index].ct == 0) {
                self.dma[index].ct = 0x4000;
            }
        }

        if (index > 0) {
            self.dma[index].sptr %= 1 << 28;
        } else {
            self.dma[index].sptr %= 1 << 27;
        }
        if (index < 3) {
            self.dma[index].dptr %= 1 << 27;
        } else {
            self.dma[index].dptr %= 1 << 28;
        }

        gba.sched.add_event(@enumFromInt(@intFromEnum(scheduler.EventType.dma0) + index), gba.sched.now + 2);
    }

    pub fn run(self: *DmaController, index: usize) void {
        const gba = self.master_gba();
        if (gba.bus_locks != 0 or index > self.active_dma) {
            self.dma[index].waiting = true;
            return;
        }

        self.dma[index].initial = true;
        gba.next_prefetch_addr = 0xffff_ffff;
        gba.cpu.next_seq = false;
        while (true) {
            self.active_dma = @intCast(index);
            if (gba.io.regs.dma[index].cnt.wsize or self.dma[index].sound) {
                self.transw(index, self.dma[index].dptr, self.dma[index].sptr);
            } else {
                self.transh(index, self.dma[index].dptr, self.dma[index].sptr);
            }
            const step: word = if (gba.io.regs.dma[index].cnt.wsize) 4 else 2;
            update_addr(&self.dma[index].sptr, gba.io.regs.dma[index].cnt.sadcnt, step);
            if (!self.dma[index].sound) {
                update_addr(&self.dma[index].dptr, gba.io.regs.dma[index].cnt.dadcnt, step);
            }
            self.dma[index].initial = false;
            self.dma[index].ct -%= 1;
            if (self.dma[index].ct == 0) {
                break;
            }
        }
        gba.prefetch_halted = false;

        self.dma[index].sound = false;
        self.active_dma = 4;

        if (!gba.io.regs.dma[index].cnt.repeat) {
            gba.io.regs.dma[index].cnt.enable = false;
        }
        if (gba.io.regs.dma[index].cnt.irq) {
            gba.io.regs.ifl.dma |= @as(u4, 1) << @intCast(index);
        }

        gba.bus_unlock(4);
    }

    pub fn transh(self: *DmaController, index: usize, daddr: word, saddr: word) void {
        const gba = self.master_gba();
        gba.bus_lock();
        gba.tick_components(gba.get_waitstates(saddr, false, !self.dma[index].initial), true);
        var data = gba.bus_readh(saddr);
        if (gba.openbus or saddr < gba_mod.bios_size) {
            data = @truncate(self.dma[index].bus_val);
        } else {
            self.dma[index].bus_val = @as(word, data) * 0x00010001;
        }
        gba.cpu.bus_val = @as(word, data) * 0x00010001;
        gba.prefetch_halted = true;
        gba.tick_components(gba.get_waitstates(daddr, false, !self.dma[index].initial or (saddr & common.bit(word, 27)) != 0), true);
        gba.bus_writeh(daddr, data);
        gba.bus_unlock(@intCast(index));
    }

    pub fn transw(self: *DmaController, index: usize, daddr: word, saddr: word) void {
        const gba = self.master_gba();
        gba.bus_lock();
        gba.tick_components(gba.get_waitstates(saddr, true, !self.dma[index].initial), true);
        var data = gba.bus_readw(saddr);
        if (gba.openbus or saddr < gba_mod.bios_size) {
            data = self.dma[index].bus_val;
        } else {
            self.dma[index].bus_val = data;
        }
        gba.cpu.bus_val = data;
        gba.prefetch_halted = true;
        gba.tick_components(gba.get_waitstates(daddr, true, !self.dma[index].initial or (saddr & common.bit(word, 27)) != 0), true);
        gba.bus_writew(daddr, data);
        gba.bus_unlock(@intCast(index));
    }

    fn master_gba(self: *DmaController) *gba_mod.Gba {
        return @ptrCast(@alignCast(self.master));
    }
};

fn update_addr(addr: *word, adcnt: DmaAddressControl, wsize: u32) void {
    const region = common.region_from_addr(addr.*);
    if (@intFromEnum(region) >= @intFromEnum(MemoryRegion.rom0) and @intFromEnum(region) < @intFromEnum(MemoryRegion.sram)) {
        addr.* +%= wsize;
        return;
    }

    switch (adcnt) {
        .inc, .inc_reload => addr.* +%= wsize,
        .dec => addr.* -%= wsize,
        .fixed => {},
    }
}

test "update_addr increments ROM regions regardless of control" {
    var addr: word = 0x0800_0000;
    update_addr(&addr, .dec, 4);
    try std.testing.expectEqual(@as(word, 0x0800_0004), addr);
}

test "initial dma transfer invalidates cpu prefetch sequence" {
    var gba = @import("gba.zig").Gba{};
    var cart = @import("cartridge.zig").Cartridge{};
    const bios = [_]@import("common.zig").byte{0} ** @import("gba.zig").bios_size;
    gba.init(&cart, &bios, false);

    const src_addr: word = 0x0300_0000;
    const dst_addr: word = 0x0300_0004;
    gba.bus_writew(src_addr, 0x11223344);
    gba.prefetcher_cycles = 99;
    gba.next_prefetch_addr = 0x0800_1234;
    gba.cpu.next_seq = true;

    gba.io.regs.dma[0].sad = src_addr;
    gba.io.regs.dma[0].dad = dst_addr;
    gba.io.regs.dma[0].ct = 1;
    gba.io.regs.dma[0].cnt.enable = true;
    gba.io.regs.dma[0].cnt.start = .imm;
    gba.io.regs.dma[0].cnt.wsize = true;
    gba.dmac.enable(0);
    gba.dmac.run(0);

    try std.testing.expectEqual(@as(word, 0xffff_ffff), gba.next_prefetch_addr);
    try std.testing.expect(!gba.cpu.next_seq);
    try std.testing.expectEqual(@as(word, 0x11223344), gba.bus_readw(dst_addr));
}
