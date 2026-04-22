const std = @import("std");
const common = @import("common.zig");
const gba_mod = @import("gba.zig");
const apu_mod = @import("apu.zig");
const ppu_mod = @import("ppu.zig");
const timer_mod = @import("timer.zig");
const dma_mod = @import("dma.zig");

pub const dword = common.dword;
pub const EventType = enum(u8) {
    tm0_rel,
    tm1_rel,
    tm2_rel,
    tm3_rel,
    tm0_ena,
    tm1_ena,
    tm2_ena,
    tm3_ena,
    tm0_irq,
    tm1_irq,
    tm2_irq,
    tm3_irq,
    tm0_write_l,
    tm1_write_l,
    tm2_write_l,
    tm3_write_l,
    tm0_write_h,
    tm1_write_h,
    tm2_write_h,
    tm3_write_h,
    dma0,
    dma1,
    dma2,
    dma3,
    ppu_hdraw,
    ppu_hblank,
    apu_sample,
    apu_ch1_rel,
    apu_ch2_rel,
    apu_ch3_rel,
    apu_ch4_rel,
    apu_div_tick,
    serial,

    pub const max = 33;
};

pub const Event = struct {
    time: dword,
    ty: EventType,
};

pub const Scheduler = struct {
    master: *anyopaque = undefined,
    now: dword = 0,
    event_queue: [EventType.max]Event = std.mem.zeroes([EventType.max]Event),
    n_events: u8 = 0,

    pub fn init(master: *anyopaque) Scheduler {
        return .{ .master = master };
    }

    pub fn run_mem(self: *Scheduler, cycles: u32) void {
        var end_time = self.now + cycles;
        while (self.n_events != 0 and self.event_queue[0].time < end_time) {
            const gba = self.master_gba();
            if (!gba.prefetch_halted) {
                gba.prefetcher_cycles += 1;
            }
            if (self.run_next_event() > 0) {
                end_time = self.now + cycles;
            } else if (!gba.prefetch_halted) {
                gba.prefetcher_cycles -= 1;
            }
        }
        self.now = end_time;
        while (self.n_events != 0 and self.event_queue[0].time == end_time) {
            self.master_gba().bus_lock();
            _ = self.run_next_event();
        }
    }

    pub fn run_internal(self: *Scheduler, cycles: u32) void {
        var end_time = self.now + cycles;
        while (self.n_events != 0 and self.event_queue[0].time <= end_time) {
            _ = self.run_next_event();
            if (self.now > end_time) {
                end_time = self.now;
            }
        }
        self.now = end_time;
    }

    pub fn run_next_event(self: *Scheduler) dword {
        if (self.n_events == 0) {
            return 0;
        }

        const event = self.event_queue[0];
        self.n_events -= 1;
        var i: usize = 0;
        while (i < self.n_events) : (i += 1) {
            self.event_queue[i] = self.event_queue[i + 1];
        }

        self.now = event.time;
        const gba = self.master_gba();
        switch (event.ty) {
            .tm0_rel, .tm1_rel, .tm2_rel, .tm3_rel => {
                gba.tmc.reload_timer(@intFromEnum(event.ty) - @intFromEnum(EventType.tm0_rel));
            },
            .tm0_ena, .tm1_ena, .tm2_ena, .tm3_ena => {
                gba.tmc.enable_timer(@intFromEnum(event.ty) - @intFromEnum(EventType.tm0_ena));
            },
            .tm0_irq, .tm1_irq, .tm2_irq, .tm3_irq => {
                const timer_index = @intFromEnum(event.ty) - @intFromEnum(EventType.tm0_irq);
                gba.io.regs.ifl.timer |= @as(u4, 1) << @intCast(timer_index);
            },
            .tm0_write_l, .tm1_write_l, .tm2_write_l, .tm3_write_l => {
                gba.io.timer_write_l(@intFromEnum(event.ty) - @intFromEnum(EventType.tm0_write_l));
            },
            .tm0_write_h, .tm1_write_h, .tm2_write_h, .tm3_write_h => {
                gba.io.timer_write_h(@intFromEnum(event.ty) - @intFromEnum(EventType.tm0_write_h));
            },
            .dma0, .dma1, .dma2, .dma3 => {
                gba.dmac.run(@intFromEnum(event.ty) - @intFromEnum(EventType.dma0));
            },
            .ppu_hdraw => gba.ppu.hdraw(),
            .ppu_hblank => gba.ppu.hblank(),
            .apu_sample => gba.apu.new_sample(),
            .apu_ch1_rel => gba.apu.ch1_reload(),
            .apu_ch2_rel => gba.apu.ch2_reload(),
            .apu_ch3_rel => gba.apu.ch3_reload(),
            .apu_ch4_rel => gba.apu.ch4_reload(),
            .apu_div_tick => gba.apu.div_tick(),
            .serial => gba.io.serial_transfer_complete(),
        }
        return self.now - event.time;
    }

    pub fn add_event(self: *Scheduler, ty: EventType, time: dword) void {
        if (self.n_events == EventType.max) {
            return;
        }

        var index: usize = self.n_events;
        self.event_queue[index] = .{ .time = time, .ty = ty };
        self.n_events += 1;

        while (index > 0 and self.event_queue[index].time < self.event_queue[index - 1].time) {
            const tmp = self.event_queue[index - 1];
            self.event_queue[index - 1] = self.event_queue[index];
            self.event_queue[index] = tmp;
            index -= 1;
        }
    }

    pub fn remove_event(self: *Scheduler, ty: EventType) void {
        var i: usize = 0;
        while (i < self.n_events) : (i += 1) {
            if (self.event_queue[i].ty == ty) {
                self.n_events -= 1;
                var j = i;
                while (j < self.n_events) : (j += 1) {
                    self.event_queue[j] = self.event_queue[j + 1];
                }
                return;
            }
        }
    }

    fn master_gba(self: *Scheduler) *gba_mod.Gba {
        return @ptrCast(@alignCast(self.master));
    }
};

test "scheduler add_event keeps queue sorted" {
    var scheduler = Scheduler.init(@ptrFromInt(1));
    scheduler.add_event(.dma2, 9);
    scheduler.add_event(.tm0_rel, 4);
    scheduler.add_event(.ppu_hblank, 7);
    try std.testing.expectEqual(@as(u8, 3), scheduler.n_events);
    try std.testing.expectEqual(EventType.tm0_rel, scheduler.event_queue[0].ty);
    try std.testing.expectEqual(EventType.ppu_hblank, scheduler.event_queue[1].ty);
    try std.testing.expectEqual(EventType.dma2, scheduler.event_queue[2].ty);
}

test "scheduler remove_event compacts queue" {
    var scheduler = Scheduler.init(@ptrFromInt(1));
    scheduler.add_event(.dma2, 9);
    scheduler.add_event(.tm0_rel, 4);
    scheduler.add_event(.ppu_hblank, 7);
    scheduler.remove_event(.ppu_hblank);
    try std.testing.expectEqual(@as(u8, 2), scheduler.n_events);
    try std.testing.expectEqual(EventType.tm0_rel, scheduler.event_queue[0].ty);
    try std.testing.expectEqual(EventType.dma2, scheduler.event_queue[1].ty);
}
