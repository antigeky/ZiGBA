const std = @import("std");
const common = @import("common.zig");
const cartridge = @import("cartridge.zig");
const scheduler = @import("scheduler.zig");
const timer = @import("timer.zig");
const dma = @import("dma.zig");
const apu = @import("apu.zig");
const io = @import("io.zig");
const ppu = @import("ppu.zig");
const fs_io = std.Io.Threaded.global_single_threaded.io();
const arm7tdmi = @import("cpu/arm7tdmi.zig");

pub const byte = common.byte;
pub const hword = common.hword;
pub const word = common.word;

pub const bios_size = 0x4000;
pub const ewram_size = 0x40000;
pub const iwram_size = 0x8000;
pub const pram_size = 0x400;
pub const vram_size = 0x18000;
pub const oam_size = 0x400;

pub const GbaError = error{
    InvalidBios,
    IoFailure,
    OutOfMemory,
};

pub const Ewram = extern union {
    b: [ewram_size]byte,
    h: [ewram_size / 2]hword,
    w: [ewram_size / 4]word,
};

pub const Iwram = extern union {
    b: [iwram_size]byte,
    h: [iwram_size / 2]hword,
    w: [iwram_size / 4]word,
};

pub const Pram = extern union {
    b: [pram_size]byte,
    h: [pram_size / 2]hword,
    w: [pram_size / 4]word,
};

pub const Vram = extern union {
    b: [vram_size]byte,
    h: [vram_size / 2]hword,
    w: [vram_size / 4]word,
};

pub const Oam = extern union {
    b: [oam_size]byte,
    h: [oam_size / 2]hword,
    w: [oam_size / 4]word,
    objs: [128]ppu.ObjAttr,
};

const cart_waits = [_]i32{ 5, 4, 3, 9 };

/// État principal du matériel émulé.
pub const Gba = struct {
    cpu: arm7tdmi.Arm7Tdmi = .{},
    ppu: ppu.Ppu = .{},
    apu: apu.Apu = .{},
    dmac: dma.DmaController = .{},
    tmc: timer.TimerController = .{},
    sched: scheduler.Scheduler = .{},
    cart: *cartridge.Cartridge = undefined,
    cart_n_waits: [4]i32 = [_]i32{0} ** 4,
    cart_s_waits: [3]i32 = [_]i32{0} ** 3,
    next_prefetch_addr: word = 0xffff_ffff,
    prefetcher_cycles: i32 = 0,
    prefetch_halted: bool = false,
    bios: []const byte = &.{},
    last_bios_val: word = 0,
    ewram: Ewram = .{ .b = [_]byte{0} ** ewram_size },
    iwram: Iwram = .{ .b = [_]byte{0} ** iwram_size },
    io: io.Io = .{},
    pram: Pram = .{ .b = [_]byte{0} ** pram_size },
    vram: Vram = .{ .b = [_]byte{0} ** vram_size },
    oam: Oam = .{ .b = [_]byte{0} ** oam_size },
    halt: bool = false,
    stop: bool = false,
    bus_locks: i32 = 0,
    openbus: bool = false,

    /// Initialise la machine et raccorde les pointeurs de retour des sous-systèmes.
    pub fn init(self: *Gba, cart_ptr: *cartridge.Cartridge, bios_data: []const byte, boot_bios: bool) void {
        self.* = .{};
        self.cart = cart_ptr;
        self.cpu = arm7tdmi.Arm7Tdmi.init(self);
        self.ppu = ppu.Ppu.init(self);
        self.apu = apu.Apu.init(self);
        self.dmac = dma.DmaController.init(self);
        self.tmc = timer.TimerController.init(self);
        self.io = io.Io.init(self);
        self.sched = scheduler.Scheduler.init(self);
        self.dmac.active_dma = 4;
        self.bios = bios_data;
        self.update_cart_waits();
        self.sched.add_event(.ppu_hdraw, 0);

        if (!boot_bios) {
            self.cpu.banked_sp[@intFromEnum(arm7tdmi.RegBank.svc)] = 0x0300_7fe0;
            self.cpu.banked_sp[@intFromEnum(arm7tdmi.RegBank.irq)] = 0x0300_7fa0;
            self.cpu.set_sp(0x0300_7f00);

            self.io.regs.bgaff[0].pa = 1 << 8;
            self.io.regs.bgaff[0].pd = 1 << 8;
            self.io.regs.bgaff[1].pa = 1 << 8;
            self.io.regs.bgaff[1].pd = 1 << 8;
            self.io.regs.soundbias.bias = 0x200;

            self.last_bios_val = 0xe129_f000;
            self.cpu.set_pc(0x0800_0000);
            self.cpu.cpsr.bits.m = .system;
            self.cpu.flush();
        } else {
            self.cpu.handle_interrupt(.reset);
        }
    }

    /// Répare les pointeurs de retour des sous-systèmes après une restauration brute de save state.
    pub fn repair_runtime_references(self: *Gba, cart_ptr: *cartridge.Cartridge, bios_data: []const byte) void {
        self.cart = cart_ptr;
        self.bios = bios_data;
        self.cpu.master = self;
        self.ppu.master = self;
        self.apu.master = self;
        self.dmac.master = self;
        self.tmc.master = self;
        self.io.master = self;
        self.sched.master = self;
        self.update_cart_waits();
    }

    pub fn load_bios(allocator: std.mem.Allocator, path: []const u8) GbaError![]u8 {
        const bios_data = std.Io.Dir.cwd().readFileAlloc(fs_io, path, allocator, .limited(bios_size + 1)) catch |err| return switch (err) {
            error.FileNotFound => error.InvalidBios,
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoFailure,
        };
        errdefer allocator.free(bios_data);
        if (bios_data.len != bios_size) {
            return error.InvalidBios;
        }
        return bios_data;
    }

    pub fn update_cart_waits(self: *Gba) void {
        self.cart_n_waits[0] = cart_waits[self.io.regs.waitcnt.rom0];
        self.cart_n_waits[1] = cart_waits[self.io.regs.waitcnt.rom1];
        self.cart_n_waits[2] = cart_waits[self.io.regs.waitcnt.rom2];
        self.cart_n_waits[3] = cart_waits[self.io.regs.waitcnt.sram];
        self.cart_s_waits[0] = if (self.io.regs.waitcnt.rom0s) 2 else 3;
        self.cart_s_waits[1] = if (self.io.regs.waitcnt.rom1s) 2 else 5;
        self.cart_s_waits[2] = if (self.io.regs.waitcnt.rom2s) 2 else 9;
    }

    pub fn get_waitstates(self: *Gba, addr: word, is_word: bool, seq: bool) i32 {
        const region = addr >> 24;
        if (region < 8) {
            var waits: i32 = 1;
            if (region == @intFromEnum(common.MemoryRegion.ewram)) waits = 3;
            if (is_word and (region == @intFromEnum(common.MemoryRegion.ewram) or region == @intFromEnum(common.MemoryRegion.pram) or region == @intFromEnum(common.MemoryRegion.vram))) {
                waits += waits;
            }
            if (!self.prefetch_halted) self.prefetcher_cycles += waits;
            return waits;
        }
        if (region < 16) {
            const index = @as(usize, @intCast((region >> 1) & 0b11));
            if (index == 3) return self.cart_n_waits[3];

            const n_waits = self.cart_n_waits[index];
            const s_waits = self.cart_s_waits[index];
            var total: i32 = 0;
            if (self.io.regs.waitcnt.prefetch and @mod(self.prefetcher_cycles, s_waits) == s_waits - 1) total += 1;
            self.next_prefetch_addr = 0xffff_ffff;
            self.prefetcher_cycles = 0;
            var sequential = seq;
            if (@mod(addr, 0x20000) == 0) sequential = false;
            total += if (sequential) s_waits else n_waits;
            if (is_word) total += s_waits;
            return total;
        }
        return 1;
    }

    pub fn get_fetch_waitstates(self: *Gba, addr: word, is_word: bool, seq: bool) i32 {
        if (!self.io.regs.waitcnt.prefetch) return self.get_waitstates(addr, is_word, seq);
        const region = addr >> 24;
        const rom_addr = addr % (1 << 25);
        if (region < 8) {
            var waits: i32 = 1;
            if (region == @intFromEnum(common.MemoryRegion.ewram)) waits = 3;
            if (is_word and (region == @intFromEnum(common.MemoryRegion.ewram) or region == @intFromEnum(common.MemoryRegion.pram) or region == @intFromEnum(common.MemoryRegion.vram))) waits += waits;
            self.prefetcher_cycles += waits;
            return waits;
        }
        if (region < 16) {
            const index = @as(usize, @intCast((region >> 1) & 0b11));
            if (index == 3) return self.cart_n_waits[3];
            const n_waits = self.cart_n_waits[index];
            const s_waits = self.cart_s_waits[index];
            var total: i32 = 0;
            if (rom_addr == self.next_prefetch_addr) {
                if (is_word and self.prefetcher_cycles >= 2 * s_waits - 1) {
                    total += 1;
                    self.prefetcher_cycles -= 2 * s_waits;
                    if (self.prefetcher_cycles < 0) self.prefetcher_cycles = 0 else self.prefetcher_cycles += 1;
                    self.next_prefetch_addr +%= 4;
                } else {
                    var i: usize = 0;
                    const count: usize = if (is_word) 2 else 1;
                    while (i < count) : (i += 1) {
                        if (self.prefetcher_cycles < s_waits) {
                            total += s_waits - self.prefetcher_cycles;
                            self.prefetcher_cycles = 0;
                        } else {
                            total += 1;
                            self.prefetcher_cycles -= s_waits;
                            self.prefetcher_cycles += 1;
                        }
                        self.next_prefetch_addr +%= 2;
                    }
                }
            } else {
                self.prefetcher_cycles = 0;
                total += n_waits;
                self.next_prefetch_addr = rom_addr + 2;
                if (is_word) {
                    total += s_waits;
                    self.next_prefetch_addr +%= 2;
                }
            }
            return total;
        }
        return 1;
    }

    pub fn bus_readb(self: *Gba, addr_in: word) byte {
        self.openbus = false;
        const region = addr_in >> 24;
        const rom_addr = addr_in % (1 << 25);
        var addr = addr_in % (1 << 24);
        switch (region) {
            @intFromEnum(common.MemoryRegion.bios) => {
                if (addr < bios_size) {
                    if (self.cpu.pc_value() < bios_size) {
                        self.last_bios_val = read_le_word(self.bios, addr & ~@as(word, 3));
                        return self.bios[addr];
                    }
                    return @truncate(self.last_bios_val >> @as(u5, @intCast(8 * (addr % 4))));
                }
            },
            @intFromEnum(common.MemoryRegion.ewram) => return self.ewram.b[addr % ewram_size],
            @intFromEnum(common.MemoryRegion.iwram) => return self.iwram.b[addr % iwram_size],
            @intFromEnum(common.MemoryRegion.io) => {
                if (addr < io.io_size) return self.io.readb(addr);
            },
            @intFromEnum(common.MemoryRegion.pram) => return self.pram.b[addr % pram_size],
            @intFromEnum(common.MemoryRegion.vram) => {
                addr %= 0x20000;
                if (addr >= vram_size) addr -= 0x8000;
                return self.vram.b[addr];
            },
            @intFromEnum(common.MemoryRegion.oam) => return self.oam.b[addr % oam_size],
            @intFromEnum(common.MemoryRegion.rom0), @intFromEnum(common.MemoryRegion.rom0_ex), @intFromEnum(common.MemoryRegion.rom1), @intFromEnum(common.MemoryRegion.rom1_ex), @intFromEnum(common.MemoryRegion.rom2), @intFromEnum(common.MemoryRegion.rom2_ex) => {
                if (self.cart.has_gpio_addr(rom_addr)) return self.cart.read_gpio_byte(rom_addr);
                if (self.cart.eeprom_mask != 0 and (rom_addr & self.cart.eeprom_mask) == self.cart.eeprom_mask) return @truncate(self.cart.read_eeprom());
                if (rom_addr < self.cart.rom_size()) return self.cart.read_rom_byte(rom_addr);
                return read_rom_oob_byte(addr);
            },
            @intFromEnum(common.MemoryRegion.sram), @intFromEnum(common.MemoryRegion.sram_ex) => return self.cart.read_sram(@truncate(addr)),
            else => {},
        }
        self.openbus = true;
        return 0;
    }

    pub fn bus_readh(self: *Gba, addr_in: word) hword {
        self.openbus = false;
        const region = addr_in >> 24;
        const rom_addr = addr_in % (1 << 25);
        var addr = addr_in % (1 << 24);
        switch (region) {
            @intFromEnum(common.MemoryRegion.bios) => {
                if (addr < bios_size) {
                    if (self.cpu.pc_value() < bios_size) {
                        self.last_bios_val = read_le_word(self.bios, addr & ~@as(word, 3));
                        return read_le_half(self.bios, addr & ~@as(word, 1));
                    }
                    return @truncate(self.last_bios_val >> @as(u5, @intCast(16 * ((addr >> 1) % 2))));
                }
            },
            @intFromEnum(common.MemoryRegion.ewram) => return self.ewram.h[(addr % ewram_size) >> 1],
            @intFromEnum(common.MemoryRegion.iwram) => return self.iwram.h[(addr % iwram_size) >> 1],
            @intFromEnum(common.MemoryRegion.io) => {
                if (addr < io.io_size) return self.io.readh(addr);
            },
            @intFromEnum(common.MemoryRegion.pram) => return self.pram.h[(addr % pram_size) >> 1],
            @intFromEnum(common.MemoryRegion.vram) => {
                addr %= 0x20000;
                if (addr >= vram_size) addr -= 0x8000;
                return self.vram.h[addr >> 1];
            },
            @intFromEnum(common.MemoryRegion.oam) => return self.oam.h[(addr % oam_size) >> 1],
            @intFromEnum(common.MemoryRegion.rom0), @intFromEnum(common.MemoryRegion.rom0_ex), @intFromEnum(common.MemoryRegion.rom1), @intFromEnum(common.MemoryRegion.rom1_ex), @intFromEnum(common.MemoryRegion.rom2), @intFromEnum(common.MemoryRegion.rom2_ex) => {
                if (self.cart.has_gpio_addr(rom_addr)) return self.cart.read_gpio_half(rom_addr);
                if (self.cart.eeprom_mask != 0 and (rom_addr & self.cart.eeprom_mask) == self.cart.eeprom_mask) return self.cart.read_eeprom();
                if (rom_addr < self.cart.rom_size()) return self.cart.read_rom_half(rom_addr);
                return read_rom_oob(addr & ~@as(word, 1));
            },
            @intFromEnum(common.MemoryRegion.sram), @intFromEnum(common.MemoryRegion.sram_ex) => {
                const b = self.cart.read_sram(@truncate(addr));
                return @as(hword, b) * 0x0101;
            },
            else => {},
        }
        self.openbus = true;
        return 0;
    }

    pub fn bus_readw(self: *Gba, addr_in: word) word {
        self.openbus = false;
        const region = addr_in >> 24;
        const rom_addr = addr_in % (1 << 25);
        var addr = addr_in % (1 << 24);
        switch (region) {
            @intFromEnum(common.MemoryRegion.bios) => {
                if (addr < bios_size) {
                    if (self.cpu.pc_value() < bios_size) {
                        const data = read_le_word(self.bios, addr & ~@as(word, 3));
                        self.last_bios_val = data;
                        return data;
                    }
                    return self.last_bios_val;
                }
            },
            @intFromEnum(common.MemoryRegion.ewram) => return self.ewram.w[(addr % ewram_size) >> 2],
            @intFromEnum(common.MemoryRegion.iwram) => return self.iwram.w[(addr % iwram_size) >> 2],
            @intFromEnum(common.MemoryRegion.io) => {
                if (addr < io.io_size) return self.io.readw(addr & ~@as(word, 0b11));
            },
            @intFromEnum(common.MemoryRegion.pram) => return self.pram.w[(addr % pram_size) >> 2],
            @intFromEnum(common.MemoryRegion.vram) => {
                addr %= 0x20000;
                if (addr >= vram_size) addr -= 0x8000;
                return self.vram.w[addr >> 2];
            },
            @intFromEnum(common.MemoryRegion.oam) => return self.oam.w[(addr % oam_size) >> 2],
            @intFromEnum(common.MemoryRegion.rom0), @intFromEnum(common.MemoryRegion.rom0_ex), @intFromEnum(common.MemoryRegion.rom1), @intFromEnum(common.MemoryRegion.rom1_ex), @intFromEnum(common.MemoryRegion.rom2), @intFromEnum(common.MemoryRegion.rom2_ex) => {
                if (self.cart.has_gpio_addr(rom_addr)) return self.cart.read_gpio_word(rom_addr);
                if (self.cart.eeprom_mask != 0 and (rom_addr & self.cart.eeprom_mask) == self.cart.eeprom_mask) {
                    const dat = self.cart.read_eeprom();
                    return @as(word, dat) | (@as(word, self.cart.read_eeprom()) << 16);
                }
                if (rom_addr < self.cart.rom_size()) return self.cart.read_rom_word(rom_addr);
                return (@as(word, read_rom_oob((addr & ~@as(word, 0b11)) + 2)) << 16) | read_rom_oob(addr & ~@as(word, 0b11));
            },
            @intFromEnum(common.MemoryRegion.sram), @intFromEnum(common.MemoryRegion.sram_ex) => return @as(word, self.cart.read_sram(@truncate(addr))) * 0x0101_0101,
            else => {},
        }
        self.openbus = true;
        return 0;
    }

    pub fn bus_writeb(self: *Gba, addr_in: word, value: byte) void {
        const region = addr_in >> 24;
        const rom_addr = addr_in % (1 << 25);
        var addr = addr_in % (1 << 24);
        switch (region) {
            @intFromEnum(common.MemoryRegion.ewram) => self.ewram.b[addr % ewram_size] = value,
            @intFromEnum(common.MemoryRegion.iwram) => self.iwram.b[addr % iwram_size] = value,
            @intFromEnum(common.MemoryRegion.io) => {
                if (addr < io.io_size) self.io.writeb(addr, value);
            },
            @intFromEnum(common.MemoryRegion.pram) => self.pram.h[(addr % pram_size) >> 1] = @as(hword, value) * 0x0101,
            @intFromEnum(common.MemoryRegion.vram) => {
                addr %= 0x20000;
                if (addr >= vram_size) addr -= 0x8000;
                if (addr < 0x10000 or (addr < 0x14000 and self.io.regs.dispcnt.bg_mode >= 3)) {
                    self.vram.h[addr >> 1] = @as(hword, value) * 0x0101;
                }
            },
            @intFromEnum(common.MemoryRegion.rom0), @intFromEnum(common.MemoryRegion.rom0_ex), @intFromEnum(common.MemoryRegion.rom1), @intFromEnum(common.MemoryRegion.rom1_ex), @intFromEnum(common.MemoryRegion.rom2), @intFromEnum(common.MemoryRegion.rom2_ex) => {
                if (self.cart.has_gpio_addr(rom_addr)) {
                    self.cart.write_gpio_byte(rom_addr, value);
                } else if (self.cart.eeprom_mask != 0 and (rom_addr & self.cart.eeprom_mask) == self.cart.eeprom_mask) {
                    self.cart.write_eeprom(value);
                }
            },
            @intFromEnum(common.MemoryRegion.sram), @intFromEnum(common.MemoryRegion.sram_ex) => self.cart.write_sram(@truncate(addr), value),
            else => {},
        }
    }

    pub fn bus_writeh(self: *Gba, addr_in: word, value: hword) void {
        const region = addr_in >> 24;
        const rom_addr = addr_in % (1 << 25);
        var addr = addr_in % (1 << 24);
        switch (region) {
            @intFromEnum(common.MemoryRegion.ewram) => self.ewram.h[(addr % ewram_size) >> 1] = value,
            @intFromEnum(common.MemoryRegion.iwram) => self.iwram.h[(addr % iwram_size) >> 1] = value,
            @intFromEnum(common.MemoryRegion.io) => {
                if (addr < io.io_size) self.io.writeh(addr & ~@as(word, 1), value);
            },
            @intFromEnum(common.MemoryRegion.pram) => self.pram.h[(addr % pram_size) >> 1] = value,
            @intFromEnum(common.MemoryRegion.vram) => {
                addr %= 0x20000;
                if (addr >= vram_size) addr -= 0x8000;
                self.vram.h[addr >> 1] = value;
            },
            @intFromEnum(common.MemoryRegion.oam) => self.oam.h[(addr % oam_size) >> 1] = value,
            @intFromEnum(common.MemoryRegion.rom0), @intFromEnum(common.MemoryRegion.rom0_ex), @intFromEnum(common.MemoryRegion.rom1), @intFromEnum(common.MemoryRegion.rom1_ex), @intFromEnum(common.MemoryRegion.rom2), @intFromEnum(common.MemoryRegion.rom2_ex) => {
                if (self.cart.has_gpio_addr(rom_addr)) {
                    self.cart.write_gpio_half(rom_addr, value);
                } else if (self.cart.eeprom_mask != 0 and (rom_addr & self.cart.eeprom_mask) == self.cart.eeprom_mask) {
                    self.cart.write_eeprom(value);
                }
            },
            @intFromEnum(common.MemoryRegion.sram), @intFromEnum(common.MemoryRegion.sram_ex) => self.cart.write_sram(@truncate(addr), @truncate(value >> @as(u4, @intCast(8 * (addr & 1))))),
            else => {},
        }
    }

    pub fn bus_writew(self: *Gba, addr_in: word, value: word) void {
        const region = addr_in >> 24;
        const rom_addr = addr_in % (1 << 25);
        var addr = addr_in % (1 << 24);
        switch (region) {
            @intFromEnum(common.MemoryRegion.ewram) => self.ewram.w[(addr % ewram_size) >> 2] = value,
            @intFromEnum(common.MemoryRegion.iwram) => self.iwram.w[(addr % iwram_size) >> 2] = value,
            @intFromEnum(common.MemoryRegion.io) => {
                if (addr < io.io_size) self.io.writew(addr & ~@as(word, 0b11), value);
            },
            @intFromEnum(common.MemoryRegion.pram) => self.pram.w[(addr % pram_size) >> 2] = value,
            @intFromEnum(common.MemoryRegion.vram) => {
                addr %= 0x20000;
                if (addr >= vram_size) addr -= 0x8000;
                self.vram.w[addr >> 2] = value;
            },
            @intFromEnum(common.MemoryRegion.oam) => self.oam.w[(addr % oam_size) >> 2] = value,
            @intFromEnum(common.MemoryRegion.rom0), @intFromEnum(common.MemoryRegion.rom0_ex), @intFromEnum(common.MemoryRegion.rom1), @intFromEnum(common.MemoryRegion.rom1_ex), @intFromEnum(common.MemoryRegion.rom2), @intFromEnum(common.MemoryRegion.rom2_ex) => {
                if (self.cart.has_gpio_addr(rom_addr)) {
                    self.cart.write_gpio_word(rom_addr, value);
                } else if (self.cart.eeprom_mask != 0 and (rom_addr & self.cart.eeprom_mask) == self.cart.eeprom_mask) {
                    self.cart.write_eeprom(@truncate(value));
                    self.cart.write_eeprom(@truncate(value >> 16));
                }
            },
            @intFromEnum(common.MemoryRegion.sram), @intFromEnum(common.MemoryRegion.sram_ex) => self.cart.write_sram(@truncate(addr), @truncate(value >> @as(u5, @intCast(8 * (addr & 0b11))))),
            else => {},
        }
    }

    pub fn bus_lock(self: *Gba) void {
        self.bus_locks += 1;
    }

    pub fn bus_unlock(self: *Gba, dma_prio: usize) void {
        self.bus_locks = 0;
        var i: usize = 0;
        while (i < 4 and i < dma_prio) : (i += 1) {
            if (self.dmac.dma[i].waiting) {
                self.dmac.dma[i].waiting = false;
                if (dma_prio == 5) {
                    self.tick_components(1, false);
                    self.prefetcher_cycles += 1;
                }
                self.dmac.run(i);
                if (dma_prio == 5) {
                    self.tick_components(1, false);
                    self.prefetcher_cycles += 1;
                }
                break;
            }
        }
    }

    pub fn tick_components(self: *Gba, cycles: i32, mem: bool) void {
        if (cycles <= 0) return;
        if (mem) self.sched.run_mem(@intCast(cycles)) else self.sched.run_internal(@intCast(cycles));
    }

    pub fn step(self: *Gba) void {
        if (self.stop) return;

        while (true) {
            const pending_irq = (@as(hword, @bitCast(self.io.regs.ie)) & @as(hword, @bitCast(self.io.regs.ifl))) != 0;
            if (pending_irq) {
                if (self.halt) {
                    self.halt = false;
                    if ((self.io.regs.ime & 1) != 0 and !self.cpu.cpsr.bits.i) {
                        self.cpu.handle_interrupt(.irq);
                    }
                    return;
                }
                if ((self.io.regs.ime & 1) != 0 and !self.cpu.cpsr.bits.i) {
                    self.cpu.handle_interrupt(.irq);
                    return;
                }
            }

            if (!self.halt) {
                self.cpu.step();
                return;
            }
            if (self.ppu.frame_complete or self.apu.samples_full) {
                return;
            }
            _ = self.sched.run_next_event();
        }
    }

    pub fn update_keypad_irq(self: *Gba) void {
        const keys = ~@as(hword, @bitCast(self.io.regs.keyinput)) & 0x03ff;
        const mask = self.io.regs.keycnt.keys;
        if (self.io.regs.keycnt.irq_cond) {
            if ((keys & mask) == mask) {
                if (self.io.regs.keycnt.irq_enable) self.io.regs.ifl.keypad = true;
                self.stop = false;
            }
        } else if ((keys & mask) != 0) {
            if (self.io.regs.keycnt.irq_enable) self.io.regs.ifl.keypad = true;
            self.stop = false;
        }
    }
};

fn read_rom_oob(addr: word) hword {
    return @truncate((addr >> 1) & 0xffff);
}

fn read_rom_oob_byte(addr: word) byte {
    const half = read_rom_oob(addr & ~@as(word, 1));
    return @truncate(half >> @as(u4, @intCast(8 * (addr & 1))));
}

fn read_le_half(bytes: []const byte, addr: word) hword {
    const a: usize = @intCast(addr);
    return bytes[a] | (@as(hword, bytes[a + 1]) << 8);
}

fn read_le_word(bytes: []const byte, addr: word) word {
    const a: usize = @intCast(addr);
    return bytes[a] |
        (@as(word, bytes[a + 1]) << 8) |
        (@as(word, bytes[a + 2]) << 16) |
        (@as(word, bytes[a + 3]) << 24);
}

test "read_rom_oob matches open-bus pattern" {
    try std.testing.expectEqual(@as(hword, 0x0012), read_rom_oob(0x24));
}

test "read_rom_oob_byte matches odd and even byte lanes" {
    try std.testing.expectEqual(@as(byte, 0x00), read_rom_oob_byte(0x800));
    try std.testing.expectEqual(@as(byte, 0x04), read_rom_oob_byte(0x801));
}

test "halt wakes when an enabled irq becomes pending" {
    var gba: Gba = .{};
    var cart = @import("cartridge.zig").Cartridge{};
    const bios = [_]byte{0} ** bios_size;
    gba.init(&cart, &bios, false);

    gba.halt = true;
    gba.io.regs.ie.vblank = true;
    gba.io.regs.ifl.vblank = true;
    gba.cpu.cpsr.bits.i = true;
    gba.io.regs.ime = 0;

    gba.step();
    try std.testing.expect(!gba.halt);
}

test "halt dispatches irq when ime is enabled" {
    var gba: Gba = .{};
    var cart = @import("cartridge.zig").Cartridge{};
    const bios = [_]byte{0} ** bios_size;
    gba.init(&cart, &bios, false);

    gba.halt = true;
    gba.io.regs.ie.vblank = true;
    gba.io.regs.ifl.vblank = true;
    gba.io.regs.ime = 1;
    gba.cpu.cpsr.bits.i = false;
    const old_pc = gba.cpu.pc_value();

    gba.step();
    try std.testing.expect(!gba.halt);
    try std.testing.expect(gba.cpu.pc_value() != old_pc);
}
