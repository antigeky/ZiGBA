const std = @import("std");
const common = @import("common.zig");
const scheduler = @import("scheduler.zig");
const gba_mod = @import("gba.zig");

pub const byte = common.byte;
pub const sbyte = common.sbyte;
pub const hword = common.hword;
pub const shword = common.shword;
pub const word = common.word;
pub const dword = common.dword;

pub const apu_div_period = 32768;
pub const sample_freq = 32768;
pub const sample_period = (1 << 24) / sample_freq;
pub const sample_buf_len = 1024;

pub const nrx1_len = 0b0011_1111;
pub const nrx1_duty = 0b1100_0000;
pub const nrx2_pace = 0b0000_0111;
pub const nrx2_dir = 1 << 3;
pub const nrx2_vol = 0b1111_0000;
pub const nrx4_wvlen_hi = 0b0000_0111;
pub const nrx4_len_enable = 1 << 6;
pub const nrx4_trigger = 1 << 7;
pub const nrx34_wvlen = (nrx4_wvlen_hi << 8) | 0xff;
pub const nr10_slop = 0b0000_0111;
pub const nr10_dir = 1 << 3;
pub const nr10_pace = 0b0111_0000;
pub const nr43_div = 0b0000_0111;
pub const nr43_width = 1 << 3;
pub const nr43_shift = 0b1111_0000;

const duty_cycles = [_]byte{ 0b1111_1110, 0b0111_1110, 0b0111_1000, 0b1000_0001 };

pub const Apu = struct {
    master: *anyopaque = undefined,

    apu_div: hword = 0,

    sample_buf: [sample_buf_len]f32 = [_]f32{0} ** sample_buf_len,
    sample_ind: usize = 0,
    samples_full: bool = false,

    ch1_enable: bool = false,
    ch1_wavelen: hword = 0,
    ch1_duty_index: byte = 0,
    ch1_env_counter: byte = 0,
    ch1_env_pace: byte = 0,
    ch1_env_dir: bool = false,
    ch1_volume: byte = 0,
    ch1_len_counter: byte = 0,
    ch1_sweep_pace: byte = 0,
    ch1_sweep_counter: byte = 0,

    ch2_enable: bool = false,
    ch2_wavelen: hword = 0,
    ch2_duty_index: byte = 0,
    ch2_env_counter: byte = 0,
    ch2_env_pace: byte = 0,
    ch2_env_dir: bool = false,
    ch2_volume: byte = 0,
    ch2_len_counter: byte = 0,

    ch3_enable: bool = false,
    ch3_wavelen: hword = 0,
    ch3_sample_index: byte = 0,
    ch3_len_counter: byte = 0,
    waveram: [0x10]byte = [_]byte{0} ** 0x10,

    ch4_enable: bool = false,
    ch4_lfsr: hword = 0,
    ch4_env_counter: byte = 0,
    ch4_env_pace: byte = 0,
    ch4_env_dir: bool = false,
    ch4_volume: byte = 0,
    ch4_len_counter: byte = 0,

    fifo_a: [32]sbyte = [_]sbyte{0} ** 32,
    fifo_b: [32]sbyte = [_]sbyte{0} ** 32,
    fifo_a_size: byte = 0,
    fifo_b_size: byte = 0,

    pub fn init(master: *anyopaque) Apu {
        return .{ .master = master };
    }

    pub fn enable(self: *Apu) void {
        const gba = self.master_gba();
        gba.sched.add_event(.apu_sample, gba.sched.now + sample_period);
        gba.sched.add_event(.apu_div_tick, gba.sched.now + apu_div_period);
    }

    pub fn disable(self: *Apu) void {
        const sched = &self.master_gba().sched;
        self.apu_div = 0;
        self.sample_ind = 0;
        sched.remove_event(.apu_sample);
        sched.remove_event(.apu_ch1_rel);
        sched.remove_event(.apu_ch2_rel);
        sched.remove_event(.apu_ch3_rel);
        sched.remove_event(.apu_ch4_rel);
        sched.remove_event(.apu_div_tick);
    }

    pub fn new_sample(self: *Apu) void {
        const gba = self.master_gba();
        var nr52: byte = 0b1000_0000;
        if (self.ch1_enable) nr52 |= 0b0000_0001;
        if (self.ch2_enable) nr52 |= 0b0000_0010;
        if (self.ch3_enable) nr52 |= 0b0000_0100;
        if (self.ch4_enable) nr52 |= 0b0000_1000;
        gba.io.regs.nr52 = nr52;

        const ch1_sample: shword = if (self.ch1_enable) self.get_sample_ch1() else 0;
        const ch2_sample: shword = if (self.ch2_enable) self.get_sample_ch2() else 0;
        const ch3_sample: shword = if (self.ch3_enable) self.get_sample_ch3() else 0;
        const ch4_sample: shword = if (self.ch4_enable) self.get_sample_ch4() else 0;

        var l_sample: shword = 0;
        var r_sample: shword = 0;
        if ((gba.io.regs.nr51 & common.bit(byte, 0)) != 0) r_sample += ch1_sample;
        if ((gba.io.regs.nr51 & common.bit(byte, 1)) != 0) r_sample += ch2_sample;
        if ((gba.io.regs.nr51 & common.bit(byte, 2)) != 0) r_sample += ch3_sample;
        if ((gba.io.regs.nr51 & common.bit(byte, 3)) != 0) r_sample += ch4_sample;
        if ((gba.io.regs.nr51 & common.bit(byte, 4)) != 0) l_sample += ch1_sample;
        if ((gba.io.regs.nr51 & common.bit(byte, 5)) != 0) l_sample += ch2_sample;
        if ((gba.io.regs.nr51 & common.bit(byte, 6)) != 0) l_sample += ch3_sample;
        if ((gba.io.regs.nr51 & common.bit(byte, 7)) != 0) l_sample += ch4_sample;

        l_sample *= @as(shword, @intCast(((gba.io.regs.nr50 & 0b0111_0000) >> 4) + 1));
        r_sample *= @as(shword, @intCast((gba.io.regs.nr50 & 0b0000_0111) + 1));
        l_sample >>= @intCast(2 - gba.io.regs.soundcnth.gb_volume);
        r_sample >>= @intCast(2 - gba.io.regs.soundcnth.gb_volume);

        var cha_sample: shword = @as(shword, self.fifo_a[0]) * 2;
        var chb_sample: shword = @as(shword, self.fifo_b[0]) * 2;
        if (gba.io.regs.soundcnth.cha_volume) cha_sample *= 2;
        if (gba.io.regs.soundcnth.chb_volume) chb_sample *= 2;
        if (gba.io.regs.soundcnth.cha_ena_left) l_sample += cha_sample;
        if (gba.io.regs.soundcnth.cha_ena_right) r_sample += cha_sample;
        if (gba.io.regs.soundcnth.chb_ena_left) l_sample += chb_sample;
        if (gba.io.regs.soundcnth.chb_ena_right) r_sample += chb_sample;

        l_sample += @as(shword, @intCast(gba.io.regs.soundbias.bias)) - 0x200;
        r_sample += @as(shword, @intCast(gba.io.regs.soundbias.bias)) - 0x200;

        l_sample = std.math.clamp(l_sample, -0x200, 0x1ff);
        r_sample = std.math.clamp(r_sample, -0x200, 0x1ff);

        self.sample_buf[self.sample_ind] = @as(f32, @floatFromInt(l_sample)) / 0x200;
        self.sample_ind += 1;
        self.sample_buf[self.sample_ind] = @as(f32, @floatFromInt(r_sample)) / 0x200;
        self.sample_ind += 1;
        if (self.sample_ind == sample_buf_len) {
            self.samples_full = true;
            self.sample_ind = 0;
        }

        gba.sched.add_event(.apu_sample, gba.sched.now + sample_period);
    }

    pub fn ch1_reload(self: *Apu) void {
        self.ch1_duty_index +%= 1;
        const next_rel = @as(dword, 2048 - self.ch1_wavelen) * 16;
        self.master_gba().sched.add_event(.apu_ch1_rel, self.master_gba().sched.now + next_rel);
    }

    pub fn ch2_reload(self: *Apu) void {
        self.ch2_duty_index +%= 1;
        const next_rel = @as(dword, 2048 - self.ch2_wavelen) * 16;
        self.master_gba().sched.add_event(.apu_ch2_rel, self.master_gba().sched.now + next_rel);
    }

    pub fn ch3_reload(self: *Apu) void {
        self.ch3_sample_index +%= 1;
        if (self.ch3_sample_index % 32 == 0 and (self.master_gba().io.regs.nr30 & common.bit(byte, 5)) != 0) {
            self.waveram_swap();
        }
        const next_rel = @as(dword, 2048 - self.ch3_wavelen) * 8;
        self.master_gba().sched.add_event(.apu_ch3_rel, self.master_gba().sched.now + next_rel);
    }

    pub fn ch4_reload(self: *Apu) void {
        const bit: hword = (~(self.ch4_lfsr ^ (self.ch4_lfsr >> 1))) & 1;
        self.ch4_lfsr = (self.ch4_lfsr & ~common.bit(hword, 15)) | (bit << 15);
        if ((self.master_gba().io.regs.nr43 & nr43_width) != 0) {
            self.ch4_lfsr = (self.ch4_lfsr & ~common.bit(hword, 7)) | (bit << 7);
        }
        self.ch4_lfsr >>= 1;

        var rate: dword = @as(dword, 2) << @intCast((self.master_gba().io.regs.nr43 & nr43_shift) >> 4);
        if ((self.master_gba().io.regs.nr43 & nr43_div) != 0) {
            rate *= self.master_gba().io.regs.nr43 & nr43_div;
        }
        self.master_gba().sched.add_event(.apu_ch4_rel, self.master_gba().sched.now + 32 * rate);
    }

    pub fn div_tick(self: *Apu) void {
        const gba = self.master_gba();
        self.apu_div +%= 1;

        if (self.apu_div % 2 == 0) {
            if ((gba.io.regs.nr14 & nrx4_len_enable) != 0) {
                self.ch1_len_counter +%= 1;
                if (self.ch1_len_counter == 64) {
                    self.ch1_len_counter = 0;
                    self.ch1_enable = false;
                    gba.sched.remove_event(.apu_ch1_rel);
                }
            }
            if ((gba.io.regs.nr24 & nrx4_len_enable) != 0) {
                self.ch2_len_counter +%= 1;
                if (self.ch2_len_counter == 64) {
                    self.ch2_len_counter = 0;
                    self.ch2_enable = false;
                    gba.sched.remove_event(.apu_ch2_rel);
                }
            }
            if ((gba.io.regs.nr34 & nrx4_len_enable) != 0) {
                self.ch3_len_counter +%= 1;
                if (self.ch3_len_counter == 0) {
                    self.ch3_enable = false;
                    gba.sched.remove_event(.apu_ch3_rel);
                }
            }
            if ((gba.io.regs.nr44 & nrx4_len_enable) != 0) {
                self.ch4_len_counter +%= 1;
                if (self.ch4_len_counter == 64) {
                    self.ch4_len_counter = 0;
                    self.ch4_enable = false;
                    gba.sched.remove_event(.apu_ch4_rel);
                }
            }
        }

        if (self.apu_div % 4 == 0) {
            self.ch1_sweep_counter +%= 1;
            if (self.ch1_sweep_pace != 0 and self.ch1_sweep_counter == self.ch1_sweep_pace) {
                self.ch1_sweep_counter = 0;
                self.ch1_sweep_pace = (gba.io.regs.nr10 & nr10_pace) >> 4;
                const del_wvlen = self.ch1_wavelen >> @intCast(gba.io.regs.nr10 & nr10_slop);
                var new_wvlen = self.ch1_wavelen;
                if ((gba.io.regs.nr10 & nr10_dir) != 0) {
                    new_wvlen -%= del_wvlen;
                } else {
                    new_wvlen +%= del_wvlen;
                    if (new_wvlen > 2047) {
                        self.ch1_enable = false;
                        gba.sched.remove_event(.apu_ch1_rel);
                    }
                }
                if ((gba.io.regs.nr10 & nr10_slop) != 0) {
                    self.ch1_wavelen = new_wvlen;
                }
            }
        }

        if (self.apu_div % 8 == 0) {
            self.step_envelope(&self.ch1_env_counter, self.ch1_env_pace, self.ch1_env_dir, &self.ch1_volume);
            self.step_envelope(&self.ch2_env_counter, self.ch2_env_pace, self.ch2_env_dir, &self.ch2_volume);
            self.step_envelope(&self.ch4_env_counter, self.ch4_env_pace, self.ch4_env_dir, &self.ch4_volume);
        }

        gba.sched.add_event(.apu_div_tick, gba.sched.now + apu_div_period);
    }

    pub fn waveram_swap(self: *Apu) void {
        const gba = self.master_gba();
        const tmp = self.waveram;
        self.waveram = gba.io.regs.waveram;
        gba.io.regs.waveram = tmp;
    }

    pub fn fifo_a_push(self: *Apu, samples: word) void {
        self.push_fifo(&self.fifo_a, &self.fifo_a_size, samples);
    }

    pub fn fifo_a_pop(self: *Apu) void {
        pop_fifo(&self.fifo_a, &self.fifo_a_size);
    }

    pub fn fifo_b_push(self: *Apu, samples: word) void {
        self.push_fifo(&self.fifo_b, &self.fifo_b_size, samples);
    }

    pub fn fifo_b_pop(self: *Apu) void {
        pop_fifo(&self.fifo_b, &self.fifo_b_size);
    }

    fn get_sample_ch1(self: *Apu) shword {
        const duty = duty_cycles[(self.master_gba().io.regs.nr11 & nrx1_duty) >> 6];
        return if ((duty & common.bit(byte, self.ch1_duty_index & 7)) != 0) self.ch1_volume else -@as(shword, self.ch1_volume);
    }

    fn get_sample_ch2(self: *Apu) shword {
        const duty = duty_cycles[(self.master_gba().io.regs.nr21 & nrx1_duty) >> 6];
        return if ((duty & common.bit(byte, self.ch2_duty_index & 7)) != 0) self.ch2_volume else -@as(shword, self.ch2_volume);
    }

    fn get_sample_ch3(self: *Apu) shword {
        const wvram_index = (self.ch3_sample_index & 0b0001_1110) >> 1;
        var sample: shword = self.waveram[wvram_index];
        if ((self.ch3_sample_index & 1) != 0) {
            sample &= 0x0f;
        } else {
            sample &= 0xf0;
            sample >>= 4;
        }
        sample = 2 * sample - 16;
        if ((self.master_gba().io.regs.nr32 & 0b1000_0000) != 0) {
            return @divTrunc(3 * sample, 4);
        }
        const out_level = (self.master_gba().io.regs.nr32 & 0b0110_0000) >> 5;
        if (out_level != 0) {
            return sample >> @intCast(out_level - 1);
        }
        return 0;
    }

    fn get_sample_ch4(self: *Apu) shword {
        return if ((self.ch4_lfsr & 1) != 0) self.ch4_volume else -@as(shword, self.ch4_volume);
    }

    fn step_envelope(_: *Apu, counter: *byte, pace: byte, dir: bool, volume: *byte) void {
        counter.* +%= 1;
        if (pace == 0 or counter.* != pace) {
            return;
        }
        counter.* = 0;
        if (dir) {
            volume.* +%= 1;
            if (volume.* == 0x10) {
                volume.* = 0x0f;
            }
        } else {
            volume.* -%= 1;
            if (volume.* == 0xff) {
                volume.* = 0x00;
            }
        }
    }

    fn push_fifo(self: *Apu, fifo: *[32]sbyte, size: *byte, samples: word) void {
        _ = self;
        var value = samples;
        var i: usize = 0;
        while (i < 4) : ({
            i += 1;
            value >>= 8;
        }) {
            if (size.* == 32) {
                size.* -= 1;
                std.mem.copyForwards(sbyte, fifo[0..size.*], fifo[1 .. size.* + 1]);
            }
            fifo[size.*] = @bitCast(@as(byte, @truncate(value & 0xff)));
            size.* += 1;
        }
    }

    fn pop_fifo(fifo: *[32]sbyte, size: *byte) void {
        if (size.* <= 1) {
            return;
        }
        size.* -= 1;
        std.mem.copyForwards(sbyte, fifo[0..size.*], fifo[1 .. size.* + 1]);
    }

    fn master_gba(self: *Apu) *gba_mod.Gba {
        return @ptrCast(@alignCast(self.master));
    }
};

test "apu fifo push keeps bounded queue" {
    var apu = Apu.init(@ptrFromInt(1));
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        apu.fifo_a_push(0x0403_0201);
    }
    try std.testing.expectEqual(@as(byte, 32), apu.fifo_a_size);
}
