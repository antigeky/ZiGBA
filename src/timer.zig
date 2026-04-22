const std = @import("std");
const common = @import("common.zig");
const scheduler = @import("scheduler.zig");
const gba_mod = @import("gba.zig");
const io_mod = @import("io.zig");
const dma_mod = @import("dma.zig");

pub const hword = common.hword;
pub const dword = common.dword;

const rates = [_]u4{ 0, 6, 8, 10 };

pub const TimerController = struct {
    master: *anyopaque = undefined,
    set_time: [4]dword = [_]dword{0} ** 4,
    counter: [4]hword = [_]hword{0} ** 4,
    ena_count: [4]hword = [_]hword{0} ** 4,
    written_cnt_h: [4]hword = [_]hword{0} ** 4,
    written_cnt_l: [4]hword = [_]hword{0} ** 4,

    pub fn init(master: *anyopaque) TimerController {
        return .{ .master = master };
    }

    pub fn update_timer_count(self: *TimerController, index: usize) void {
        const gba = self.master_gba();
        const tm = &gba.io.regs.tm[index];
        if (!tm.cnt.enable or tm.cnt.countup) {
            self.set_time[index] = gba.sched.now;
            return;
        }

        const rate = rates[tm.cnt.rate];
        self.counter[index] +%= @truncate((gba.sched.now >> rate) - (self.set_time[index] >> rate));
        self.set_time[index] = gba.sched.now;
    }

    pub fn update_timer_reload(self: *TimerController, index: usize) void {
        const gba = self.master_gba();
        gba.sched.remove_event(@enumFromInt(@intFromEnum(scheduler.EventType.tm0_rel) + index));

        const tm = &gba.io.regs.tm[index];
        if (!tm.cnt.enable or tm.cnt.countup) {
            return;
        }

        const rate = rates[tm.cnt.rate];
        const align_mask: dword = (@as(dword, 1) << rate) - 1;
        const rel_time = (self.set_time[index] + ((@as(dword, 0x1_0000) - @as(dword, self.counter[index])) << rate)) & ~align_mask;
        gba.sched.add_event(@enumFromInt(@intFromEnum(scheduler.EventType.tm0_rel) + index), rel_time);
    }

    pub fn enable_timer(self: *TimerController, index: usize) void {
        self.counter[index] = self.ena_count[index];
        self.set_time[index] = self.master_gba().sched.now;
        self.update_timer_reload(index);
    }

    pub fn reload_timer(self: *TimerController, index: usize) void {
        const gba = self.master_gba();
        self.counter[index] = gba.io.regs.tm[index].reload;
        self.set_time[index] = gba.sched.now;
        self.update_timer_reload(index);

        if (index <= 1 and @intFromBool(gba.io.regs.soundcnth.cha_timer) == index) {
            gba.apu.fifo_a_pop();
            if (gba.apu.fifo_a_size <= 16 and gba.io.regs.dma[1].cnt.start == .spec) {
                gba.dmac.dma[1].sound = true;
                gba.dmac.activate(1);
            }
        }
        if (index <= 1 and @intFromBool(gba.io.regs.soundcnth.chb_timer) == index) {
            gba.apu.fifo_b_pop();
            if (gba.apu.fifo_b_size <= 16 and gba.io.regs.dma[2].cnt.start == .spec) {
                gba.dmac.dma[2].sound = true;
                gba.dmac.activate(2);
            }
        }

        if (gba.io.regs.tm[index].cnt.irq) {
            gba.sched.add_event(@enumFromInt(@intFromEnum(scheduler.EventType.tm0_irq) + index), gba.sched.now + 3);
        }

        if (index + 1 < 4 and gba.io.regs.tm[index + 1].cnt.enable and gba.io.regs.tm[index + 1].cnt.countup) {
            self.counter[index + 1] +%= 1;
            if (self.counter[index + 1] == 0) {
                self.reload_timer(index + 1);
            }
        }
    }

    fn master_gba(self: *TimerController) *gba_mod.Gba {
        return @ptrCast(@alignCast(self.master));
    }
};
