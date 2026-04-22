const std = @import("std");
const common = @import("common.zig");
const dma_mod = @import("dma.zig");
const apu_mod = @import("apu.zig");
const scheduler = @import("scheduler.zig");
const gba_mod = @import("gba.zig");

pub const byte = common.byte;
pub const hword = common.hword;
pub const shword = common.shword;
pub const word = common.word;
pub const sword = common.sword;
pub const dword = common.dword;

pub const io_size = 0x400;

pub const DISPCNT = 0x000;
pub const DISPSTAT = 0x004;
pub const VCOUNT = 0x006;
pub const BG0CNT = 0x008;
pub const BG1CNT = 0x00a;
pub const BG2CNT = 0x00c;
pub const BG3CNT = 0x00e;
pub const BG0HOFS = 0x010;
pub const BG0VOFS = 0x012;
pub const BG1HOFS = 0x014;
pub const BG1VOFS = 0x016;
pub const BG2HOFS = 0x018;
pub const BG2VOFS = 0x01a;
pub const BG3HOFS = 0x01c;
pub const BG3VOFS = 0x01e;
pub const BG2PA = 0x020;
pub const BG2PB = 0x022;
pub const BG2PC = 0x024;
pub const BG2PD = 0x026;
pub const BG2X = 0x028;
pub const BG2Y = 0x02c;
pub const BG3PA = 0x030;
pub const BG3PB = 0x032;
pub const BG3PC = 0x034;
pub const BG3PD = 0x036;
pub const BG3X = 0x038;
pub const BG3Y = 0x03c;
pub const WIN0H = 0x040;
pub const WIN1H = 0x042;
pub const WIN0V = 0x044;
pub const WIN1V = 0x046;
pub const WININ = 0x048;
pub const WINOUT = 0x04a;
pub const MOSAIC = 0x04c;
pub const BLDCNT = 0x050;
pub const BLDALPHA = 0x052;
pub const BLDY = 0x054;
pub const SOUND1CNT_L = 0x060;
pub const SOUND1CNT_H = 0x062;
pub const SOUND1CNT_X = 0x064;
pub const SOUND2CNT_L = 0x068;
pub const SOUND2CNT_H = 0x06c;
pub const SOUND3CNT_L = 0x070;
pub const SOUND3CNT_H = 0x072;
pub const SOUND3CNT_X = 0x074;
pub const SOUND4CNT_L = 0x078;
pub const SOUND4CNT_H = 0x07c;
pub const SOUNDCNT_L = 0x080;
pub const SOUNDCNT_H = 0x082;
pub const SOUNDCNT_X = 0x084;
pub const SOUNDBIAS = 0x088;
pub const WAVERAM = 0x090;
pub const FIFO_A = 0x0a0;
pub const FIFO_B = 0x0a4;
pub const DMA0SAD = 0x0b0;
pub const DMA0DAD = 0x0b4;
pub const DMA0CNT_L = 0x0b8;
pub const DMA0CNT_H = 0x0ba;
pub const DMA1SAD = 0x0bc;
pub const DMA1DAD = 0x0c0;
pub const DMA1CNT_L = 0x0c4;
pub const DMA1CNT_H = 0x0c6;
pub const DMA2SAD = 0x0c8;
pub const DMA2DAD = 0x0cc;
pub const DMA2CNT_L = 0x0d0;
pub const DMA2CNT_H = 0x0d2;
pub const DMA3SAD = 0x0d4;
pub const DMA3DAD = 0x0d8;
pub const DMA3CNT_L = 0x0dc;
pub const DMA3CNT_H = 0x0de;
pub const TM0CNT_L = 0x100;
pub const TM0CNT_H = 0x102;
pub const TM1CNT_L = 0x104;
pub const TM1CNT_H = 0x106;
pub const TM2CNT_L = 0x108;
pub const TM2CNT_H = 0x10a;
pub const TM3CNT_L = 0x10c;
pub const TM3CNT_H = 0x10e;
pub const SIODATA32_L = 0x120;
pub const SIODATA32_H = 0x122;
pub const SIOMULTI0 = 0x120;
pub const SIOMULTI1 = 0x122;
pub const SIOMULTI2 = 0x124;
pub const SIOMULTI3 = 0x126;
pub const SIOMLT_SEND = 0x12a;
pub const SIODATA8 = 0x12a;
pub const SIOCNT = 0x128;
pub const KEYINPUT = 0x130;
pub const RCNT = 0x134;
pub const JOYCNT = 0x140;
pub const JOY_RECV = 0x150;
pub const JOY_TRANS = 0x154;
pub const JOYSTAT = 0x158;
pub const KEYCNT = 0x132;
pub const IE = 0x200;
pub const IF = 0x202;
pub const WAITCNT = 0x204;
pub const IME = 0x208;
pub const POSTFLG = 0x300;
pub const HALTCNT = 0x301;

pub const DispCnt = packed struct(hword) {
    bg_mode: u3,
    reserved: u1,
    frame_sel: bool,
    hblank_free: bool,
    obj_mapmode: bool,
    forced_blank: bool,
    bg_enable: u4,
    obj_enable: bool,
    win_enable: u2,
    winobj_enable: bool,
};

pub const DispStat = packed struct(hword) {
    vblank: bool,
    hblank: bool,
    vcounteq: bool,
    vblank_irq: bool,
    hblank_irq: bool,
    vcount_irq: bool,
    unused: u2,
    lyc: u8,
};

pub const BgCnt = packed struct(hword) {
    priority: u2,
    tile_base: u2,
    unused: u2,
    mosaic: bool,
    palmode: bool,
    tilemap_base: u5,
    overflow: bool,
    size: u2,
};

pub const BgText = extern struct {
    hofs: hword = 0,
    vofs: hword = 0,
};

pub const BgAff = extern struct {
    pa: shword = 0,
    pb: shword = 0,
    pc: shword = 0,
    pd: shword = 0,
    x: sword = 0,
    y: sword = 0,
};

pub const WinH = extern struct {
    x2: byte = 0,
    x1: byte = 0,
};

pub const WinV = extern struct {
    y2: byte = 0,
    y1: byte = 0,
};

pub const WinCntByte = packed struct(byte) {
    bg_enable: u4,
    obj_enable: bool,
    effects_enable: bool,
    unused: u2,
};

pub const Mosaic = packed struct(word) {
    bg_h: u4,
    bg_v: u4,
    obj_h: u4,
    obj_v: u4,
    pad: u16,
};

pub const BldCnt = packed struct(hword) {
    target1: u6,
    effect: u2,
    target2: u6,
    unused: u2,
};

pub const BldAlpha = packed struct(hword) {
    eva: u5,
    unused1: u3,
    evb: u5,
    unused2: u3,
};

pub const BldY = packed struct(word) {
    evy: u5,
    unused: u27,
};

pub const SoundCntH = packed struct(hword) {
    gb_volume: u2,
    cha_volume: bool,
    chb_volume: bool,
    unused: u4,
    cha_ena_right: bool,
    cha_ena_left: bool,
    cha_timer: bool,
    cha_reset: bool,
    chb_ena_right: bool,
    chb_ena_left: bool,
    chb_timer: bool,
    chb_reset: bool,
};

pub const SoundBias = packed struct(word) {
    bias: u10,
    unused1: u4,
    samplerate: u2,
    unused2: u16,
};

pub const DmaCnt = packed struct(hword) {
    unused: u5,
    dadcnt: dma_mod.DmaAddressControl,
    sadcnt: dma_mod.DmaAddressControl,
    repeat: bool,
    wsize: bool,
    drq: bool,
    start: dma_mod.DmaStartTiming,
    irq: bool,
    enable: bool,
};

pub const DmaReg = extern struct {
    sad: word = 0,
    dad: word = 0,
    ct: hword = 0,
    cnt: DmaCnt = @bitCast(@as(hword, 0)),
};

pub const TimerCnt = packed struct(hword) {
    rate: u2,
    countup: bool,
    unused: u3,
    irq: bool,
    enable: bool,
    unused1: u8,
};

pub const TimerReg = extern struct {
    reload: hword = 0,
    cnt: TimerCnt = @bitCast(@as(hword, 0)),
};

pub const KeyInput = packed struct(hword) {
    a: bool,
    b: bool,
    select: bool,
    start: bool,
    right: bool,
    left: bool,
    up: bool,
    down: bool,
    r: bool,
    l: bool,
    unused: u6,
};

pub const KeyCnt = packed struct(hword) {
    keys: u10,
    unused: u4,
    irq_enable: bool,
    irq_cond: bool,
};

pub const InterruptFlags = packed struct(hword) {
    vblank: bool,
    hblank: bool,
    vcounteq: bool,
    timer: u4,
    serial: bool,
    dma: u4,
    keypad: bool,
    gamepak: bool,
    unused: u2,
};

pub const WaitCnt = packed struct(hword) {
    sram: u2,
    rom0: u2,
    rom0s: bool,
    rom1: u2,
    rom1s: bool,
    rom2: u2,
    rom2s: bool,
    phi: u2,
    unused: bool,
    prefetch: bool,
    gamepaktype: bool,
};

pub const IoRegs = extern struct {
    dispcnt: DispCnt = @bitCast(@as(hword, 0)),
    greenswap: hword = 0,
    dispstat: DispStat = @bitCast(@as(hword, 0)),
    vcount: hword = 0,
    bgcnt: [4]BgCnt = [_]BgCnt{@bitCast(@as(hword, 0))} ** 4,
    bgtext: [4]BgText = [_]BgText{.{}} ** 4,
    bgaff: [2]BgAff = [_]BgAff{.{}} ** 2,
    winh: [2]WinH = [_]WinH{.{}} ** 2,
    winv: [2]WinV = [_]WinV{.{}} ** 2,
    winin: hword = 0,
    winout: hword = 0,
    mosaic: Mosaic = @bitCast(@as(word, 0)),
    bldcnt: BldCnt = @bitCast(@as(hword, 0)),
    bldalpha: BldAlpha = @bitCast(@as(hword, 0)),
    bldy: BldY = @bitCast(@as(word, 0)),
    unused_058: dword = 0,
    nr10: byte = 0,
    _pad_061: byte = 0,
    nr11: byte = 0,
    nr12: byte = 0,
    nr13: byte = 0,
    nr14: byte = 0,
    _pad_066_067: [2]byte = [_]byte{0} ** 2,
    nr21: byte = 0,
    nr22: byte = 0,
    _pad_06a_06b: [2]byte = [_]byte{0} ** 2,
    nr23: byte = 0,
    nr24: byte = 0,
    _pad_06e_06f: [2]byte = [_]byte{0} ** 2,
    nr30: byte = 0,
    _pad_071: byte = 0,
    nr31: byte = 0,
    nr32: byte = 0,
    nr33: byte = 0,
    nr34: byte = 0,
    _pad_076_077: [2]byte = [_]byte{0} ** 2,
    nr41: byte = 0,
    nr42: byte = 0,
    _pad_07a_07b: [2]byte = [_]byte{0} ** 2,
    nr43: byte = 0,
    nr44: byte = 0,
    _pad_07e_07f: [2]byte = [_]byte{0} ** 2,
    nr50: byte = 0,
    nr51: byte = 0,
    soundcnth: SoundCntH = @bitCast(@as(hword, 0)),
    nr52: byte = 0,
    _pad_085_087: [3]byte = [_]byte{0} ** 3,
    soundbias: SoundBias = @bitCast(@as(word, 0)),
    unused_08c: word = 0,
    waveram: [0x10]byte = [_]byte{0} ** 0x10,
    fifo_a: word = 0,
    fifo_b: word = 0,
    unused_0a8: dword = 0,
    dma: [4]DmaReg = [_]DmaReg{.{}} ** 4,
    unused_0e0_0ff: [0x20]byte = [_]byte{0} ** 0x20,
    tm: [4]TimerReg = [_]TimerReg{.{}} ** 4,
    gap_110_12f: [0x20]byte = [_]byte{0} ** 0x20,
    keyinput: KeyInput = @bitCast(@as(hword, 0x03ff)),
    keycnt: KeyCnt = @bitCast(@as(hword, 0)),
    gap_134_1ff: [0xcc]byte = [_]byte{0} ** 0xcc,
    ie: InterruptFlags = @bitCast(@as(hword, 0)),
    ifl: InterruptFlags = @bitCast(@as(hword, 0)),
    waitcnt: WaitCnt = @bitCast(@as(hword, 0)),
    gap_206_207: [2]byte = [_]byte{0} ** 2,
    ime: word = 0,
    unused_20c_2ff: [0xf4]byte = [_]byte{0} ** 0xf4,
    postflg: byte = 0,
    haltcnt: byte = 0,
    unused_302_3ff: [0xfe]byte = [_]byte{0} ** 0xfe,
};

comptime {
    std.debug.assert(@sizeOf(IoRegs) == io_size);
}

const SioMode = enum {
    normal8,
    normal32,
    multiplayer,
    uart,
    gpio,
    joybus,
};

pub const Io = struct {
    master: *anyopaque = undefined,
    regs: IoRegs = .{},

    pub fn init(master: *anyopaque) Io {
        var io = Io{ .master = master };
        io.regs.keyinput = @bitCast(@as(hword, 0x03ff));
        return io;
    }

    pub fn readb(self: *Io, addr: word) byte {
        const half = self.readh(addr & ~@as(word, 1));
        return if ((addr & 1) != 0) @truncate(half >> 8) else @truncate(half);
    }

    pub fn writeb(self: *Io, addr: word, data: byte) void {
        if (addr == POSTFLG) {
            self.regs.postflg = data;
            return;
        }
        if (addr == HALTCNT) {
            if ((data & common.bit(byte, 7)) != 0) {
                self.gba().stop = true;
            } else {
                self.gba().halt = true;
            }
            return;
        }

        var half: hword = 0;
        if ((addr & 1) != 0) {
            half = (@as(hword, data) << 8) | self.raw_bytes()[addr & ~@as(usize, 1)];
        } else {
            half = data | (@as(hword, self.raw_bytes()[addr | 1]) << 8);
        }
        self.writeh(addr & ~@as(word, 1), half);
    }

    pub fn readh(self: *Io, addr: word) hword {
        if (BG0HOFS <= addr and addr < SOUND1CNT_L) {
            if (addr == WININ or addr == WINOUT or addr == BLDCNT or addr == BLDALPHA) {
                return self.readh_direct(addr);
            }
            self.gba().openbus = true;
            return 0;
        }
        if (SOUNDBIAS + 4 <= addr and addr < WAVERAM) {
            self.gba().openbus = true;
            return 0;
        }
        if (FIFO_A <= addr and addr < TM0CNT_L) {
            switch (addr) {
                DMA0CNT_H, DMA1CNT_H, DMA2CNT_H, DMA3CNT_H => return self.readh_direct(addr),
                DMA0CNT_L, DMA1CNT_L, DMA2CNT_L, DMA3CNT_L => return 0,
                else => {
                    self.gba().openbus = true;
                    return 0;
                },
            }
        }
        if (TM3CNT_H < addr and addr < 0x120) {
            self.gba().openbus = true;
            return 0;
        }
        if (0x15c <= addr and addr < IE) {
            self.gba().openbus = true;
            return 0;
        }
        if (IME + 4 <= addr) {
            if (addr == POSTFLG) {
                return self.readh_direct(addr);
            }
            if (addr == 0x302) {
                return 0;
            }
            self.gba().openbus = true;
            return 0;
        }

        switch (addr) {
            SOUND1CNT_X, SOUND2CNT_H, SOUND3CNT_X => return self.readh_direct(addr) & ~@as(hword, apu_mod.nrx34_wvlen),
            SOUND3CNT_H => return self.readh_direct(addr) & 0xe000,
            SOUND4CNT_L => return self.readh_direct(addr) & 0xff00,
            SIODATA32_L, SIODATA32_H, SIOMULTI2, SIOMULTI3, SIOMLT_SEND, SIOCNT, RCNT, JOYCNT, JOY_RECV, JOY_RECV + 2, JOY_TRANS, JOY_TRANS + 2, JOYSTAT => return self.readh_sio(addr),
            0x302 => return 0,
            TM0CNT_L, TM1CNT_L, TM2CNT_L, TM3CNT_L => {
                const index = @as(usize, @intCast((addr - TM0CNT_L) / (TM1CNT_L - TM0CNT_L)));
                self.gba().tmc.update_timer_count(index);
                return self.gba().tmc.counter[index];
            },
            else => return self.readh_direct(addr),
        }
    }

    pub fn writeh(self: *Io, addr: word, data: hword) void {
        if ((addr & ~@as(word, 0b11)) == BG2X or (addr & ~@as(word, 0b11)) == BG2Y or (addr & ~@as(word, 0b11)) == BG3X or (addr & ~@as(word, 0b11)) == BG3Y or (addr & ~@as(word, 0b11)) == FIFO_A or (addr & ~@as(word, 0b11)) == FIFO_B) {
            self.writeh_direct(addr, data);
            self.writew(addr & ~@as(word, 0b11), self.readw_direct(addr & ~@as(word, 0b11)));
            return;
        }

        switch (addr) {
            DISPSTAT => {
                var dispstat_bits: hword = @bitCast(self.regs.dispstat);
                dispstat_bits &= 0b111;
                dispstat_bits |= data & ~@as(hword, 0b111);
                self.regs.dispstat = @bitCast(dispstat_bits);
            },
            BG0CNT => {
                self.regs.bgcnt[0] = @bitCast(data);
                self.regs.bgcnt[0].overflow = false;
            },
            BG1CNT => {
                self.regs.bgcnt[1] = @bitCast(data);
                self.regs.bgcnt[1].overflow = false;
            },
            WININ => {
                self.regs.winin = data;
                self.win_cnt(0).unused = 0;
                self.win_cnt(1).unused = 0;
            },
            WINOUT => {
                self.regs.winout = data;
                self.win_cnt(2).unused = 0;
                self.win_cnt(3).unused = 0;
            },
            BLDCNT => {
                self.regs.bldcnt = @bitCast(data);
                self.regs.bldcnt.unused = 0;
            },
            BLDALPHA => {
                self.regs.bldalpha = @bitCast(data);
                self.regs.bldalpha.unused1 = 0;
                self.regs.bldalpha.unused2 = 0;
            },
            SOUND1CNT_L => {
                if ((data & apu_mod.nr10_pace) == 0) self.gba().apu.ch1_sweep_pace = 0;
                self.regs.nr10 = @truncate(data & 0b0111_1111);
            },
            SOUND1CNT_H => {
                self.gba().apu.ch1_len_counter = @truncate(data & apu_mod.nrx1_len);
                self.regs.nr11 = @truncate(data & apu_mod.nrx1_duty);
                const high: byte = @truncate(data >> 8);
                if ((high & 0b1111_1000) == 0) self.gba().apu.ch1_enable = false;
                self.regs.nr12 = high;
            },
            SOUND1CNT_X => {
                self.gba().apu.ch1_wavelen = data & apu_mod.nrx34_wvlen;
                self.writeh_direct(SOUND1CNT_X, data & apu_mod.nrx34_wvlen);
                const high: byte = @truncate(data >> 8);
                if ((self.regs.nr12 & 0b1111_1000) != 0 and (high & apu_mod.nrx4_trigger) != 0) {
                    self.gba().apu.ch1_enable = true;
                    self.gba().apu.ch1_duty_index = 0;
                    self.gba().apu.ch1_env_counter = 0;
                    self.gba().apu.ch1_env_pace = self.regs.nr12 & apu_mod.nrx2_pace;
                    self.gba().apu.ch1_env_dir = (self.regs.nr12 & apu_mod.nrx2_dir) != 0;
                    self.gba().apu.ch1_volume = (self.regs.nr12 & apu_mod.nrx2_vol) >> 4;
                    self.gba().apu.ch1_sweep_pace = (self.regs.nr10 & apu_mod.nr10_pace) >> 4;
                    self.gba().apu.ch1_sweep_counter = 0;
                    self.gba().sched.remove_event(.apu_ch1_rel);
                    self.gba().apu.ch1_reload();
                }
                self.regs.nr14 |= high & apu_mod.nrx4_len_enable;
            },
            SOUND1CNT_X + 2 => {},
            SOUND2CNT_L => {
                self.gba().apu.ch2_len_counter = @truncate(data & apu_mod.nrx1_len);
                self.regs.nr21 = @truncate(data & apu_mod.nrx1_duty);
                const high: byte = @truncate(data >> 8);
                if ((high & 0b1111_1000) == 0) self.gba().apu.ch2_enable = false;
                self.regs.nr22 = high;
            },
            SOUND2CNT_L + 2 => {},
            SOUND2CNT_H => {
                self.gba().apu.ch2_wavelen = data & apu_mod.nrx34_wvlen;
                self.writeh_direct(SOUND2CNT_H, data & apu_mod.nrx34_wvlen);
                const high: byte = @truncate(data >> 8);
                if ((self.regs.nr22 & 0b1111_1000) != 0 and (high & apu_mod.nrx4_trigger) != 0) {
                    self.gba().apu.ch2_enable = true;
                    self.gba().apu.ch2_duty_index = 0;
                    self.gba().apu.ch2_env_counter = 0;
                    self.gba().apu.ch2_env_pace = self.regs.nr22 & apu_mod.nrx2_pace;
                    self.gba().apu.ch2_env_dir = (self.regs.nr22 & apu_mod.nrx2_dir) != 0;
                    self.gba().apu.ch2_volume = (self.regs.nr22 & apu_mod.nrx2_vol) >> 4;
                    self.gba().sched.remove_event(.apu_ch2_rel);
                    self.gba().apu.ch2_reload();
                }
                self.regs.nr24 |= high & apu_mod.nrx4_len_enable;
            },
            SOUND2CNT_H + 2 => {},
            SOUND3CNT_L => {
                if ((data & 0b1000_0000) == 0) self.gba().apu.ch3_enable = false;
                if ((self.regs.nr30 & common.bit(byte, 6)) != (@as(byte, @truncate(data)) & common.bit(byte, 6))) {
                    self.gba().apu.waveram_swap();
                }
                self.regs.nr30 = @truncate(data & 0b1110_0000);
            },
            SOUND3CNT_H => {
                self.gba().apu.ch3_len_counter = @truncate(data);
                self.regs.nr31 = @truncate(data);
                self.regs.nr32 = @truncate((data >> 8) & 0b1110_0000);
            },
            SOUND3CNT_X => {
                self.gba().apu.ch3_wavelen = data & apu_mod.nrx34_wvlen;
                self.writeh_direct(SOUND3CNT_X, data & apu_mod.nrx34_wvlen);
                const high: byte = @truncate(data >> 8);
                if ((self.regs.nr30 & 0b1000_0000) != 0 and (high & apu_mod.nrx4_trigger) != 0) {
                    self.gba().apu.ch3_enable = true;
                    self.gba().apu.ch3_sample_index = 0;
                    self.gba().sched.remove_event(.apu_ch3_rel);
                    self.gba().apu.ch3_reload();
                }
                self.regs.nr34 |= high & apu_mod.nrx4_len_enable;
            },
            SOUND3CNT_X + 2 => {},
            SOUND4CNT_L => {
                self.gba().apu.ch4_len_counter = @truncate(data & apu_mod.nrx1_len);
                self.regs.nr41 = @truncate(data);
                const high: byte = @truncate(data >> 8);
                if ((high & 0b1111_1000) == 0) self.gba().apu.ch4_enable = false;
                self.regs.nr42 = high;
            },
            SOUND4CNT_L + 2 => {},
            SOUND4CNT_H => {
                self.regs.nr43 = @truncate(data);
                const high: byte = @truncate(data >> 8);
                if ((self.regs.nr42 & 0b1111_1000) != 0 and (high & apu_mod.nrx4_trigger) != 0) {
                    self.gba().apu.ch4_enable = true;
                    self.gba().apu.ch4_lfsr = 0;
                    self.gba().apu.ch4_env_counter = 0;
                    self.gba().apu.ch4_env_pace = self.regs.nr42 & apu_mod.nrx2_pace;
                    self.gba().apu.ch4_env_dir = (self.regs.nr42 & apu_mod.nrx2_dir) != 0;
                    self.gba().apu.ch4_volume = (self.regs.nr42 & apu_mod.nrx2_vol) >> 4;
                    self.gba().sched.remove_event(.apu_ch4_rel);
                    self.gba().apu.ch4_reload();
                }
                self.regs.nr44 = high & apu_mod.nrx4_len_enable;
            },
            SOUND4CNT_H + 2 => {},
            SOUNDCNT_L => {
                self.regs.nr50 = @truncate(data & 0b0111_0111);
                self.regs.nr51 = @truncate(data >> 8);
            },
            SOUNDCNT_H => {
                self.regs.soundcnth = @bitCast(data);
                if (self.regs.soundcnth.cha_reset) {
                    self.regs.soundcnth.cha_reset = false;
                    self.gba().apu.fifo_a_size = 0;
                }
                if (self.regs.soundcnth.chb_reset) {
                    self.regs.soundcnth.chb_reset = false;
                    self.gba().apu.fifo_b_size = 0;
                }
                self.regs.soundcnth.unused = 0;
            },
            SOUNDCNT_X => {
                if ((data & common.bit(hword, 7)) != 0) {
                    if (self.regs.nr52 == 0) {
                        self.regs.nr52 = common.bit(byte, 7);
                        self.gba().apu.enable();
                    }
                } else {
                    self.regs.nr52 = 0;
                    self.gba().apu.disable();
                }
            },
            SOUNDCNT_X + 2 => {},
            SOUNDBIAS + 2 => {},
            DMA0CNT_H, DMA1CNT_H, DMA2CNT_H, DMA3CNT_H => {
                const index = @as(usize, @intCast((addr - DMA0CNT_H) / (DMA1CNT_H - DMA0CNT_H)));
                const prev_enable = self.regs.dma[index].cnt.enable;
                self.regs.dma[index].cnt = @bitCast(data);
                self.regs.dma[index].cnt.unused = 0;
                if (index < 3) self.regs.dma[index].cnt.drq = false;
                if (!prev_enable and self.regs.dma[index].cnt.enable) {
                    self.gba().dmac.enable(index);
                }
            },
            TM0CNT_L, TM1CNT_L, TM2CNT_L, TM3CNT_L => {
                const index = @as(usize, @intCast((addr - TM0CNT_L) / (TM1CNT_L - TM0CNT_L)));
                self.gba().tmc.written_cnt_l[index] = data;
                self.gba().sched.add_event(@enumFromInt(@intFromEnum(scheduler.EventType.tm0_write_l) + index), self.gba().sched.now + 1);
            },
            TM0CNT_H, TM1CNT_H, TM2CNT_H, TM3CNT_H => {
                const index = @as(usize, @intCast((addr - TM0CNT_H) / (TM1CNT_H - TM0CNT_H)));
                self.gba().tmc.written_cnt_h[index] = data;
                self.gba().sched.add_event(@enumFromInt(@intFromEnum(scheduler.EventType.tm0_write_h) + index), self.gba().sched.now + 1);
            },
            SIOCNT => {
                var value = data;
                self.gba().sched.remove_event(.serial);
                if ((value & common.bit(hword, 7)) != 0) {
                    if (self.serial_transfer_cycles(value)) |cycles| {
                        self.gba().sched.add_event(.serial, self.gba().sched.now + cycles);
                    } else {
                        value &= ~common.bit(hword, 7);
                        if ((value & common.bit(hword, 14)) != 0) self.regs.ifl.serial = true;
                    }
                }
                self.writeh_direct(addr, value);
            },
            KEYINPUT => {},
            KEYCNT => {
                self.regs.keycnt = @bitCast(data);
                self.gba().update_keypad_irq();
            },
            0x136, 0x142, 0x15a => {},
            IF => {
                var if_bits: hword = @bitCast(self.regs.ifl);
                if_bits &= ~data;
                self.regs.ifl = @bitCast(if_bits);
            },
            WAITCNT => {
                self.regs.waitcnt = @bitCast(data);
                self.regs.waitcnt.gamepaktype = false;
                self.gba().update_cart_waits();
                self.gba().prefetcher_cycles = 0;
                self.gba().next_prefetch_addr = 0xffff_ffff;
            },
            WAITCNT + 2 => {},
            IME + 2 => {},
            POSTFLG => {
                self.writeb(addr, @truncate(data));
                self.writeb(addr | 1, @truncate(data >> 8));
            },
            POSTFLG + 2 => {},
            else => self.writeh_direct(addr, data),
        }
    }

    pub fn readw(self: *Io, addr: word) word {
        return self.readh(addr) | (@as(word, self.readh(addr | 2)) << 16);
    }

    fn sign_extend_bg_aff(data: word) sword {
        return (@as(sword, @bitCast(data << 4))) >> 4;
    }

    pub fn writew(self: *Io, addr: word, data: word) void {
        switch (addr) {
            BG2X => {
                const value = sign_extend_bg_aff(data);
                self.regs.bgaff[0].x = value;
                self.gba().ppu.bgaffintr[0].x = value;
            },
            BG2Y => {
                const value = sign_extend_bg_aff(data);
                self.regs.bgaff[0].y = value;
                self.gba().ppu.bgaffintr[0].y = value;
            },
            BG3X => {
                const value = sign_extend_bg_aff(data);
                self.regs.bgaff[1].x = value;
                self.gba().ppu.bgaffintr[1].x = value;
            },
            BG3Y => {
                const value = sign_extend_bg_aff(data);
                self.regs.bgaff[1].y = value;
                self.gba().ppu.bgaffintr[1].y = value;
            },
            FIFO_A => self.gba().apu.fifo_a_push(data),
            FIFO_B => self.gba().apu.fifo_b_push(data),
            else => {
                self.writeh(addr, @truncate(data));
                self.writeh(addr | 2, @truncate(data >> 16));
            },
        }
    }

    pub fn timer_write_l(self: *Io, index: usize) void {
        self.regs.tm[index].reload = self.gba().tmc.written_cnt_l[index];
    }

    pub fn timer_write_h(self: *Io, index: usize) void {
        const data = self.gba().tmc.written_cnt_h[index];
        const prev_enable = self.regs.tm[index].cnt.enable;
        self.gba().tmc.update_timer_count(index);
        self.regs.tm[index].cnt = @bitCast(data);
        if (index == 0) {
            self.regs.tm[index].cnt.countup = false;
        }
        if (!prev_enable and self.regs.tm[index].cnt.enable) {
            self.gba().tmc.ena_count[index] = self.regs.tm[index].reload;
            self.gba().sched.add_event(@enumFromInt(@intFromEnum(scheduler.EventType.tm0_ena) + index), self.gba().sched.now + 1);
        } else {
            self.gba().tmc.update_timer_reload(index);
        }
    }

    pub fn serial_transfer_complete(self: *Io) void {
        var value = self.readh_direct(SIOCNT);
        value &= ~common.bit(hword, 7);
        self.writeh_direct(SIOCNT, value);
        if ((value & common.bit(hword, 14)) != 0) {
            self.regs.ifl.serial = true;
        }
    }

    fn sio_mode(self: *const Io) SioMode {
        const rcnt_mode = (self.readh_direct(RCNT) >> 14) & 0x3;
        return switch (rcnt_mode) {
            0b10 => .gpio,
            0b11 => .joybus,
            else => switch ((self.readh_direct(SIOCNT) >> 12) & 0x3) {
                0 => .normal8,
                1 => .normal32,
                2 => .multiplayer,
                else => .uart,
            },
        };
    }

    fn sio_busy_bit(self: *Io) hword {
        var i: usize = 0;
        while (i < self.gba().sched.n_events) : (i += 1) {
            if (self.gba().sched.event_queue[i].ty == .serial) {
                return common.bit(hword, 7);
            }
        }
        return 0;
    }

    fn readh_sio(self: *Io, addr: word) hword {
        const mode = self.sio_mode();
        return switch (addr) {
            SIOCNT => switch (mode) {
                //.normal8 => 0x4f8f,
                //.normal32 => 0x5f8f,
                .normal8 => 0x4f0f | self.sio_busy_bit(),
                .normal32 => 0x5f0f | self.sio_busy_bit(),
                .multiplayer => 0x6f8f,
                .uart => 0x7faf,
                .gpio => 0x4f8f,
                .joybus => 0x4f8f,
            },
            RCNT => switch (mode) {
                .normal8, .normal32 => 0x01f5,
                .multiplayer, .uart => 0x01ff,
                .gpio => 0x81ff,
                .joybus => 0xc1fc,
            },
            JOYCNT => 0x0040,
            JOY_RECV, JOY_RECV + 2, JOY_TRANS, JOY_TRANS + 2, JOYSTAT => 0,
            SIODATA32_L => switch (mode) {
                .multiplayer => 0,
                .normal8 => 0,
                .normal32 => self.readh_direct(SIODATA32_L),
                .uart, .gpio, .joybus => 0,
            },
            SIODATA32_H => switch (mode) {
                .multiplayer => 0,
                .normal8 => 0,
                .normal32 => self.readh_direct(SIODATA32_H),
                .uart, .gpio, .joybus => 0,
            },
            SIOMULTI2, SIOMULTI3 => 0,
            SIOMLT_SEND => switch (mode) {
                .multiplayer => 0xffff,
                .normal8 => 0xffff,
                .normal32 => 0xffff,
                .uart => 0,
                .gpio, .joybus => 0xffff,
            },
            else => 0,
        };
    }

    fn serial_transfer_cycles(self: *const Io, siocnt_value: hword) ?u32 {
        const rcnt_mode = (self.readh_direct(RCNT) >> 14) & 0x3;
        if (rcnt_mode != 0) {
            return null;
        }
        const mode = (siocnt_value >> 12) & 0x3;
        const per_bit: u32 = if ((siocnt_value & 0x0002) != 0) 8 else 64;
        return switch (mode) {
            0 => 9 + 8 * per_bit,
            1 => 9 + 32 * per_bit,
            2 => null,
            else => null,
        };
    }

    fn readh_direct(self: *const Io, addr: word) hword {
        const bytes: []const byte = std.mem.asBytes(&self.regs);
        const index: usize = @intCast(addr);
        return bytes[index] | (@as(hword, bytes[index + 1]) << 8);
    }

    fn writeh_direct(self: *Io, addr: word, value: hword) void {
        const bytes = self.raw_bytes();
        const index: usize = @intCast(addr);
        bytes[index] = @truncate(value);
        bytes[index + 1] = @truncate(value >> 8);
    }

    fn readw_direct(self: *const Io, addr: word) word {
        const bytes: []const byte = std.mem.asBytes(&self.regs);
        const index: usize = @intCast(addr);
        return bytes[index] |
            (@as(word, bytes[index + 1]) << 8) |
            (@as(word, bytes[index + 2]) << 16) |
            (@as(word, bytes[index + 3]) << 24);
    }

    fn raw_bytes(self: *Io) []byte {
        return std.mem.asBytes(&self.regs);
    }

    fn gba(self: *Io) *gba_mod.Gba {
        return @ptrCast(@alignCast(self.master));
    }

    fn win_cnt(self: *Io, index: usize) *WinCntByte {
        const bytes = self.raw_bytes();
        return @ptrCast(@alignCast(&bytes[WININ + index]));
    }
};

test "io regs layout stays 0x400 bytes" {
    try std.testing.expectEqual(@as(usize, io_size), @sizeOf(IoRegs));
}

test "io read masks match suite expectations" {
    var gba = gba_mod.Gba{};
    var cart = @import("cartridge.zig").Cartridge{};
    const bios = [_]byte{0} ** gba_mod.bios_size;
    gba.init(&cart, &bios, false);

    gba.io.writeh_direct(SOUND3CNT_H, 0xffff);
    gba.io.writeh_direct(SOUND4CNT_L, 0xffff);
    try std.testing.expectEqual(@as(hword, 0xe000), gba.io.readh(SOUND3CNT_H));
    try std.testing.expectEqual(@as(hword, 0xff00), gba.io.readh(SOUND4CNT_L));
    try std.testing.expectEqual(@as(hword, 0x0000), gba.io.readh(0x302));
}

test "suite sio register reads match mode defaults" {
    var gba = gba_mod.Gba{};
    var cart = @import("cartridge.zig").Cartridge{};
    const bios = [_]byte{0} ** gba_mod.bios_size;
    gba.init(&cart, &bios, false);

    gba.io.writeh_direct(SIOCNT, 0x2000);
    gba.io.writeh_direct(RCNT, 0x0000);
    try std.testing.expectEqual(@as(hword, 0x6f8f), gba.io.readh(SIOCNT));
    try std.testing.expectEqual(@as(hword, 0x01ff), gba.io.readh(RCNT));
    try std.testing.expectEqual(@as(hword, 0x0040), gba.io.readh(JOYCNT));
    try std.testing.expectEqual(@as(hword, 0x0000), gba.io.readh(SIOMULTI0));
    try std.testing.expectEqual(@as(hword, 0x0000), gba.io.readh(SIOMULTI1));
    try std.testing.expectEqual(@as(hword, 0x0000), gba.io.readh(SIOMULTI2));
    try std.testing.expectEqual(@as(hword, 0x0000), gba.io.readh(SIOMULTI3));
    try std.testing.expectEqual(@as(hword, 0xffff), gba.io.readh(SIOMLT_SEND));

    gba.io.writeh_direct(SIOCNT, 0x0000);
    gba.io.writeh_direct(RCNT, 0x0000);
    try std.testing.expectEqual(@as(hword, 0x4f8f), gba.io.readh(SIOCNT));
    try std.testing.expectEqual(@as(hword, 0x01f5), gba.io.readh(RCNT));
    try std.testing.expectEqual(@as(hword, 0xffff), gba.io.readh(SIODATA8));

    gba.io.writeh_direct(SIODATA32_L, 0xffff);
    gba.io.writeh_direct(SIODATA32_H, 0xffff);
    gba.io.writeh_direct(SIOCNT, 0x1000);
    gba.io.writeh_direct(RCNT, 0x0000);
    try std.testing.expectEqual(@as(hword, 0x5f8f), gba.io.readh(SIOCNT));
    try std.testing.expectEqual(@as(hword, 0x01f5), gba.io.readh(RCNT));
    try std.testing.expectEqual(@as(hword, 0xffff), gba.io.readh(SIODATA32_L));
    try std.testing.expectEqual(@as(hword, 0xffff), gba.io.readh(SIODATA32_H));

    gba.io.writeh_direct(SIOCNT, 0x3000);
    gba.io.writeh_direct(RCNT, 0x0000);
    try std.testing.expectEqual(@as(hword, 0x7faf), gba.io.readh(SIOCNT));
    try std.testing.expectEqual(@as(hword, 0x01ff), gba.io.readh(RCNT));
    try std.testing.expectEqual(@as(hword, 0x0000), gba.io.readh(SIODATA8));

    gba.io.writeh_direct(SIOCNT, 0x0000);
    gba.io.writeh_direct(RCNT, 0x8000);
    try std.testing.expectEqual(@as(hword, 0x4f8f), gba.io.readh(SIOCNT));
    try std.testing.expectEqual(@as(hword, 0x81ff), gba.io.readh(RCNT));
    try std.testing.expectEqual(@as(hword, 0xffff), gba.io.readh(SIODATA8));

    gba.io.writeh_direct(SIOCNT, 0x0000);
    gba.io.writeh_direct(RCNT, 0xc000);
    try std.testing.expectEqual(@as(hword, 0x4f8f), gba.io.readh(SIOCNT));
    try std.testing.expectEqual(@as(hword, 0xc1fc), gba.io.readh(RCNT));
    try std.testing.expectEqual(@as(hword, 0xffff), gba.io.readh(SIODATA8));
}

test "suite sio timing matches source expectations" {
    var gba = gba_mod.Gba{};
    var cart = @import("cartridge.zig").Cartridge{};
    const bios = [_]byte{0} ** gba_mod.bios_size;
    gba.init(&cart, &bios, false);

    const serial_delay = struct {
        fn get(gba_ptr: *gba_mod.Gba) ?u64 {
            var i: usize = 0;
            while (i < gba_ptr.sched.n_events) : (i += 1) {
                if (gba_ptr.sched.event_queue[i].ty == .serial) {
                    return gba_ptr.sched.event_queue[i].time - gba_ptr.sched.now;
                }
            }
            return null;
        }
    }.get;

    gba.io.writeh(SIOCNT, 0x4001 | 0x0080);
    try std.testing.expectEqual(@as(?u64, 0x209), serial_delay(&gba));
    gba.sched.remove_event(.serial);

    gba.io.writeh(SIOCNT, 0x4003 | 0x0080);
    try std.testing.expectEqual(@as(?u64, 0x049), serial_delay(&gba));
    gba.sched.remove_event(.serial);

    gba.io.writeh(SIOCNT, 0x5001 | 0x0080);
    try std.testing.expectEqual(@as(?u64, 0x809), serial_delay(&gba));
    gba.sched.remove_event(.serial);

    gba.io.writeh(SIOCNT, 0x5003 | 0x0080);
    try std.testing.expectEqual(@as(?u64, 0x109), serial_delay(&gba));
    gba.sched.remove_event(.serial);

    gba.io.writeh(SIOCNT, 0x2000 | 0x0080 | 0x0000);
    try std.testing.expectEqual(@as(?u64, null), serial_delay(&gba));

    gba.io.writeh(SIOCNT, 0x2000 | 0x0080 | 0x0001);
    try std.testing.expectEqual(@as(?u64, null), serial_delay(&gba));

    gba.io.writeh(SIOCNT, 0x2000 | 0x0080 | 0x0002);
    try std.testing.expectEqual(@as(?u64, null), serial_delay(&gba));

    gba.io.writeh(SIOCNT, 0x2000 | 0x0080 | 0x0003);
    try std.testing.expectEqual(@as(?u64, null), serial_delay(&gba));
}
