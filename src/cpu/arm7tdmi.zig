const std = @import("std");
const common = @import("../common.zig");
const gba_mod = @import("../gba.zig");
const arm_isa = @import("arm_isa.zig");
const thumb_isa = @import("thumb_isa.zig");

pub const byte = common.byte;
pub const hword = common.hword;
pub const word = common.word;
pub const dword = common.dword;

pub const RegBank = enum(u3) {
    user,
    fiq,
    svc,
    abt,
    irq,
    und,
    ct,
};

pub const CpuMode = enum(u5) {
    user = 0b10000,
    fiq = 0b10001,
    irq = 0b10010,
    svc = 0b10011,
    abt = 0b10111,
    und = 0b11011,
    system = 0b11111,
};

pub const CpuInterrupt = enum(u3) {
    reset,
    und,
    swi,
    pabt,
    dabt,
    addr,
    irq,
    fiq,
};

const Registers = extern union {
    r: [16]word,
    named: extern struct {
        _r: [13]word,
        sp: word,
        lr: word,
        pc: word,
    },
};

pub const CpsrBits = packed struct(word) {
    m: CpuMode,
    t: bool,
    f: bool,
    i: bool,
    reserved: u20,
    v: bool,
    c: bool,
    z: bool,
    n: bool,
};

const Cpsr = packed union {
    w: word,
    bits: CpsrBits,
};

pub const Arm7Tdmi = struct {
    master: *anyopaque = undefined,
    regs: Registers = .{ .r = [_]word{0} ** 16 },
    cpsr: Cpsr = .{ .w = 0 },
    spsr: word = 0,
    banked_r8_12: [2][5]word = [_][5]word{[_]word{0} ** 5} ** 2,
    banked_sp: [@intFromEnum(RegBank.ct)]word = [_]word{0} ** @intFromEnum(RegBank.ct),
    banked_lr: [@intFromEnum(RegBank.ct)]word = [_]word{0} ** @intFromEnum(RegBank.ct),
    banked_spsr: [@intFromEnum(RegBank.ct)]word = [_]word{0} ** @intFromEnum(RegBank.ct),
    cur_instr: arm_isa.ArmInstr = .{ .w = 0 },
    next_instr: arm_isa.ArmInstr = .{ .w = 0 },
    cur_instr_addr: word = 0,
    bus_val: word = 0,
    next_seq: bool = false,

    pub fn init(master: *anyopaque) Arm7Tdmi {
        return .{ .master = master };
    }

    pub fn step(self: *Arm7Tdmi) void {
        arm_isa.exec_instr(self);
    }

    pub fn fetch_instr(self: *Arm7Tdmi) void {
        self.cur_instr = self.next_instr;
        if (self.cpsr.bits.t) {
            self.next_instr = thumb_isa.thumb_lookup[self.fetchh(self.pc_value(), self.next_seq)];
            self.set_pc(self.pc_value() + 2);
            self.cur_instr_addr +%= 2;
        } else {
            self.next_instr.w = self.fetchw(self.pc_value(), self.next_seq);
            self.set_pc(self.pc_value() + 4);
            self.cur_instr_addr +%= 4;
        }
        self.next_seq = true;
    }

    pub fn flush(self: *Arm7Tdmi) void {
        if (self.cpsr.bits.t) {
            self.set_pc(self.pc_value() & ~@as(word, 1));
            self.cur_instr_addr = self.pc_value();
            self.cur_instr = thumb_isa.thumb_lookup[self.fetchh(self.pc_value(), false)];
            self.set_pc(self.pc_value() + 2);
            self.next_instr = thumb_isa.thumb_lookup[self.fetchh(self.pc_value(), true)];
            self.set_pc(self.pc_value() + 2);
        } else {
            self.set_pc(self.pc_value() & ~@as(word, 0b11));
            self.cur_instr_addr = self.pc_value();
            self.cur_instr.w = self.fetchw(self.pc_value(), false);
            self.set_pc(self.pc_value() + 4);
            self.next_instr.w = self.fetchw(self.pc_value(), true);
            self.set_pc(self.pc_value() + 4);
        }
        self.next_seq = true;
    }

    pub fn update_mode(self: *Arm7Tdmi, old: CpuMode) void {
        const old_bank = get_bank(old);
        self.banked_sp[@intFromEnum(old_bank)] = self.sp_value();
        self.banked_lr[@intFromEnum(old_bank)] = self.lr_value();
        self.banked_spsr[@intFromEnum(old_bank)] = self.spsr;
        const new_bank = get_bank(self.cpsr.bits.m);
        self.set_sp(self.banked_sp[@intFromEnum(new_bank)]);
        self.set_lr(self.banked_lr[@intFromEnum(new_bank)]);
        self.spsr = self.banked_spsr[@intFromEnum(new_bank)];

        if (old == .fiq and self.cpsr.bits.m != .fiq) {
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                self.banked_r8_12[1][i] = self.regs.r[8 + i];
                self.regs.r[8 + i] = self.banked_r8_12[0][i];
            }
        }
        if (old != .fiq and self.cpsr.bits.m == .fiq) {
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                self.banked_r8_12[0][i] = self.regs.r[8 + i];
                self.regs.r[8 + i] = self.banked_r8_12[1][i];
            }
        }
    }

    pub fn handle_interrupt(self: *Arm7Tdmi, intr: CpuInterrupt) void {
        const old = self.cpsr.bits.m;
        const spsr = self.cpsr.w;
        self.cpsr.bits.m = switch (intr) {
            .reset, .swi, .addr => .svc,
            .pabt, .dabt => .abt,
            .und => .und,
            .irq => .irq,
            .fiq => .fiq,
        };
        self.update_mode(old);
        self.spsr = spsr;
        self.set_lr(self.pc_value());
        if (self.cpsr.bits.t) {
            if (intr == .swi or intr == .und) self.set_lr(self.lr_value() -% 2);
        } else {
            self.set_lr(self.lr_value() -% 4);
        }
        self.fetch_instr();
        self.cpsr.bits.t = false;
        self.cpsr.bits.i = true;
        self.set_pc(@as(word, 4) * @as(word, @intFromEnum(intr)));
        self.flush();
    }

    pub fn readb(self: *Arm7Tdmi, addr: word, sign_extend: bool) word {
        const gba = self.master_gba();
        gba.tick_components(gba.get_waitstates(addr, false, false), true);
        var data: word = gba.bus_readb(addr);
        if (gba.openbus) data = @as(word, @truncate(@as(byte, @truncate(self.bus_val))));
        if (sign_extend) data = @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(data))))));
        self.bus_val = data;
        gba.bus_unlock(5);
        return data;
    }

    pub fn readh(self: *Arm7Tdmi, addr: word, sign_extend: bool) word {
        const gba = self.master_gba();
        gba.tick_components(gba.get_waitstates(addr, false, false), true);
        var data: word = gba.bus_readh(addr);
        if (gba.openbus) data = @as(word, @truncate(@as(hword, @truncate(self.bus_val))));
        if ((addr & 1) != 0) {
            if (sign_extend) {
                data = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(data)))) >> 8));
            } else {
                data = (data >> 8) | (data << 24);
            }
        } else if (sign_extend) {
            data = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(data))))));
        }
        self.bus_val = data;
        gba.bus_unlock(5);
        return data;
    }

    pub fn readw(self: *Arm7Tdmi, addr: word) word {
        const gba = self.master_gba();
        gba.tick_components(gba.get_waitstates(addr, true, false), true);
        var data = gba.bus_readw(addr);
        if (gba.openbus) data = self.bus_val;
        if ((addr & 0b11) != 0) {
            data = std.math.rotr(word, data, @as(u5, @intCast(8 * (addr & 0b11))));
        }
        self.bus_val = data;
        gba.bus_unlock(5);
        return data;
    }

    pub fn readm(self: *Arm7Tdmi, addr: word, index: usize) word {
        const gba = self.master_gba();
        gba.tick_components(gba.get_waitstates(addr + 4 * @as(word, @intCast(index)), true, index != 0), true);
        var data = gba.bus_readw(addr + 4 * @as(word, @intCast(index)));
        if (gba.openbus) data = self.bus_val else self.bus_val = data;
        gba.bus_unlock(5);
        return data;
    }

    pub fn writeb(self: *Arm7Tdmi, addr: word, value: byte) void {
        const gba = self.master_gba();
        gba.tick_components(gba.get_waitstates(addr, false, false), true);
        gba.bus_writeb(addr, value);
        gba.bus_unlock(5);
    }

    pub fn writeh(self: *Arm7Tdmi, addr: word, value: hword) void {
        const gba = self.master_gba();
        gba.tick_components(gba.get_waitstates(addr, false, false), true);
        gba.bus_writeh(addr, value);
        gba.bus_unlock(5);
    }

    pub fn writew(self: *Arm7Tdmi, addr: word, value: word) void {
        const gba = self.master_gba();
        gba.tick_components(gba.get_waitstates(addr, true, false), true);
        gba.bus_writew(addr, value);
        gba.bus_unlock(5);
    }

    pub fn writem(self: *Arm7Tdmi, addr: word, index: usize, value: word) void {
        const gba = self.master_gba();
        gba.tick_components(gba.get_waitstates(addr + 4 * @as(word, @intCast(index)), true, index != 0), true);
        gba.bus_writew(addr + 4 * @as(word, @intCast(index)), value);
        gba.bus_unlock(5);
    }

    pub fn fetchh(self: *Arm7Tdmi, addr: word, seq: bool) hword {
        const gba = self.master_gba();
        gba.tick_components(gba.get_fetch_waitstates(addr, false, seq), true);
        var data: word = gba.bus_readh(addr);
        if (gba.openbus) {
            data = self.bus_val;
        } else {
            const region = addr >> 24;
            if (region == @intFromEnum(common.MemoryRegion.bios) or region == @intFromEnum(common.MemoryRegion.iwram) or region == @intFromEnum(common.MemoryRegion.oam)) {
                self.bus_val &= @as(word, 0x0000ffff) << @as(u5, @intCast(16 * ((~addr) & 1)));
                self.bus_val |= data << @as(u5, @intCast(16 * (addr & 1)));
            } else {
                self.bus_val = data * 0x00010001;
            }
        }
        gba.bus_unlock(5);
        return @truncate(data);
    }

    pub fn fetchw(self: *Arm7Tdmi, addr: word, seq: bool) word {
        const gba = self.master_gba();
        gba.tick_components(gba.get_fetch_waitstates(addr, true, seq), true);
        var data = gba.bus_readw(addr);
        if (gba.openbus) data = self.bus_val else self.bus_val = data;
        gba.bus_unlock(5);
        return data;
    }

    pub fn swapb(self: *Arm7Tdmi, addr: word, value: byte) byte {
        const gba = self.master_gba();
        gba.bus_lock();
        gba.tick_components(gba.get_waitstates(addr, false, false), true);
        var data: word = gba.bus_readb(addr);
        if (gba.openbus) data = @as(word, @truncate(@as(byte, @truncate(self.bus_val))));
        self.bus_val = data;
        self.internal_cycle(1);
        gba.tick_components(gba.get_waitstates(addr, false, false), true);
        gba.bus_writeb(addr, value);
        gba.bus_unlock(5);
        return @truncate(data);
    }

    pub fn swapw(self: *Arm7Tdmi, addr: word, value: word) word {
        const gba = self.master_gba();
        gba.bus_lock();
        gba.tick_components(gba.get_waitstates(addr, true, false), true);
        var data = gba.bus_readw(addr);
        if (gba.openbus) data = self.bus_val;
        if ((addr & 0b11) != 0) {
            data = std.math.rotr(word, data, @as(u5, @intCast(8 * (addr & 0b11))));
        }
        self.bus_val = data;
        self.internal_cycle(1);
        gba.tick_components(gba.get_waitstates(addr, true, false), true);
        gba.bus_writew(addr, value);
        gba.bus_unlock(5);
        return data;
    }

    pub fn internal_cycle(self: *Arm7Tdmi, cycles: u32) void {
        const gba = self.master_gba();
        gba.tick_components(@intCast(cycles), false);
        gba.prefetcher_cycles += @intCast(cycles);
        if (self.pc_value() >= 0x0800_0000) {
            self.next_seq = gba.io.regs.waitcnt.prefetch;
        }
    }

    pub fn pc_value(self: *Arm7Tdmi) word {
        return self.regs.named.pc;
    }

    pub fn sp_value(self: *Arm7Tdmi) word {
        return self.regs.named.sp;
    }

    pub fn lr_value(self: *Arm7Tdmi) word {
        return self.regs.named.lr;
    }

    pub fn set_pc(self: *Arm7Tdmi, value: word) void {
        self.regs.named.pc = value;
    }

    pub fn set_sp(self: *Arm7Tdmi, value: word) void {
        self.regs.named.sp = value;
    }

    pub fn set_lr(self: *Arm7Tdmi, value: word) void {
        self.regs.named.lr = value;
    }

    fn master_gba(self: *Arm7Tdmi) *gba_mod.Gba {
        return @ptrCast(@alignCast(self.master));
    }
};

pub fn get_bank(mode: CpuMode) RegBank {
    return switch (@intFromEnum(mode)) {
        @intFromEnum(CpuMode.user) => .user,
        @intFromEnum(CpuMode.fiq) => .fiq,
        @intFromEnum(CpuMode.irq) => .irq,
        @intFromEnum(CpuMode.svc) => .svc,
        @intFromEnum(CpuMode.abt) => .abt,
        @intFromEnum(CpuMode.und) => .und,
        @intFromEnum(CpuMode.system) => .user,
        else => .user,
    };
}

test "get_bank maps system to user bank" {
    try std.testing.expectEqual(RegBank.user, get_bank(.system));
}
