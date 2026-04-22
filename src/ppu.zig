const std = @import("std");
const common = @import("common.zig");
const io_mod = @import("io.zig");
const gba_mod = @import("gba.zig");

pub const byte = common.byte;
pub const hword = common.hword;
pub const shword = common.shword;
pub const word = common.word;
pub const sword = common.sword;
pub const dword = common.dword;

pub const screen_w = 240;
pub const screen_h = 160;
pub const dots_w = 308;
pub const lines_h = 228;

pub const BgTile = packed struct(hword) {
    num: u10,
    hflip: bool,
    vflip: bool,
    palette: u4,
};

pub const ObjAttr = extern struct {
    attr0: hword = 0,
    attr1: hword = 0,
    attr2: hword = 0,
    affparam: shword = 0,

    pub fn y(self: ObjAttr) byte {
        return @truncate(self.attr0);
    }

    pub fn aff(self: ObjAttr) bool {
        return common.has_bit(self.attr0, 8);
    }

    pub fn disable_double(self: ObjAttr) bool {
        return common.has_bit(self.attr0, 9);
    }

    pub fn mode(self: ObjAttr) byte {
        return @truncate((self.attr0 >> 10) & 0b11);
    }

    pub fn mosaic(self: ObjAttr) bool {
        return common.has_bit(self.attr0, 12);
    }

    pub fn palmode(self: ObjAttr) bool {
        return common.has_bit(self.attr0, 13);
    }

    pub fn shape(self: ObjAttr) byte {
        return @truncate((self.attr0 >> 14) & 0b11);
    }

    pub fn x(self: ObjAttr) hword {
        return @truncate(self.attr1 & 0x01ff);
    }

    pub fn affparamind(self: ObjAttr) byte {
        return @truncate((self.attr1 >> 9) & 0x1f);
    }

    pub fn hflip(self: ObjAttr) bool {
        return common.has_bit(self.attr1, 12);
    }

    pub fn vflip(self: ObjAttr) bool {
        return common.has_bit(self.attr1, 13);
    }

    pub fn size(self: ObjAttr) byte {
        return @truncate((self.attr1 >> 14) & 0b11);
    }

    pub fn tilenum(self: ObjAttr) hword {
        return @truncate(self.attr2 & 0x03ff);
    }

    pub fn priority(self: ObjAttr) byte {
        return @truncate((self.attr2 >> 10) & 0b11);
    }

    pub fn palette(self: ObjAttr) byte {
        return @truncate((self.attr2 >> 12) & 0x0f);
    }
};

pub const WindowIndex = enum(u2) {
    win0,
    win1,
    wout,
    wobj,
};

pub const LayerIndex = enum(u3) {
    bg0,
    bg1,
    bg2,
    bg3,
    obj,
    bd,
    max,
};

pub const EffectType = enum(u2) {
    none,
    alpha,
    binc,
    bdec,
};

const ObjDotAttr = packed struct(byte) {
    priority: u2,
    semitrans: bool,
    mosaic: bool,
    pad: u4,
};

const BgAffIntermediate = struct {
    x: sword = 0,
    y: sword = 0,
    mosx: sword = 0,
    mosy: sword = 0,
};

const ObjDimensions = struct {
    w: byte,
    h: byte,
};

const BgOrder = struct {
    ids: [4]byte = [_]byte{0} ** 4,
    priorities: [4]byte = [_]byte{0} ** 4,
    count: byte = 0,
};

const LayerStack = struct {
    values: [6]byte = [_]byte{0} ** 6,
    count: byte = 0,

    fn push(self: *LayerStack, layer: byte) void {
        std.debug.assert(self.count < self.values.len);
        self.values[self.count] = layer;
        self.count += 1;
    }
};

const transparent_color: hword = 0x8000;
const color_mask: hword = 0x7fff;
const layer_count = @intFromEnum(LayerIndex.max);
const layer_obj = @intFromEnum(LayerIndex.obj);
const layer_bd = @intFromEnum(LayerIndex.bd);
const window_wout = @intFromEnum(WindowIndex.wout);
const window_wobj = @intFromEnum(WindowIndex.wobj);
const obj_mode_semitrans: byte = 1;
const obj_mode_objwin: byte = 2;
const obj_shape_square: byte = 0;
const obj_shape_horz: byte = 1;
const obj_shape_vert: byte = 2;

const sc_layout = [_][2][2]byte{
    .{ .{ 0, 0 }, .{ 0, 0 } },
    .{ .{ 0, 1 }, .{ 0, 1 } },
    .{ .{ 0, 0 }, .{ 1, 1 } },
    .{ .{ 0, 1 }, .{ 2, 3 } },
};

const obj_layout = [_][3]byte{
    .{ 8, 8, 16 },
    .{ 16, 8, 32 },
    .{ 32, 16, 32 },
    .{ 64, 32, 64 },
};

pub const Ppu = struct {
    master: *anyopaque = undefined,
    screen: [screen_h][screen_w]hword = [_][screen_w]hword{[_]hword{0} ** screen_w} ** screen_h,
    ly: byte = 0,

    layerlines: [layer_count][screen_w]hword = [_][screen_w]hword{[_]hword{0} ** screen_w} ** layer_count,
    objdotattrs: [screen_w]ObjDotAttr = [_]ObjDotAttr{@bitCast(@as(byte, 0))} ** screen_w,
    window: [screen_w]byte = [_]byte{0} ** screen_w,

    bgaffintr: [2]BgAffIntermediate = [_]BgAffIntermediate{.{}} ** 2,

    bgmos_y: byte = 0,
    bgmos_ct: i8 = -1,
    objmos_y: byte = 0,
    objmos_ct: i8 = -1,

    draw_bg: [4]bool = [_]bool{false} ** 4,
    draw_obj: bool = false,
    in_win: [2]bool = [_]bool{false} ** 2,
    obj_semitrans: bool = false,
    obj_mos: bool = false,

    obj_cycles: i32 = 0,
    frame_complete: bool = false,

    /// Crée une instance de PPU liée à son état GBA propriétaire.
    pub fn init(master: *anyopaque) Ppu {
        return .{ .master = master };
    }

    /// Rend toutes les couches de fond activées pour la ligne courante.
    pub fn render_bgs(self: *Ppu) void {
        switch (self.master_gba().io.regs.dispcnt.bg_mode) {
            0 => {
                self.render_bg_line_text(0);
                self.render_bg_line_text(1);
                self.render_bg_line_text(2);
                self.render_bg_line_text(3);
            },
            1 => {
                self.render_bg_line_text(0);
                self.render_bg_line_text(1);
                self.render_bg_line_aff(2, 1);
            },
            2 => {
                self.render_bg_line_aff(2, 2);
                self.render_bg_line_aff(3, 2);
            },
            3 => self.render_bg_line_aff(2, 3),
            4 => self.render_bg_line_aff(2, 4),
            5 => self.render_bg_line_aff(2, 5),
            else => {},
        }
    }

    /// Rend tous les objets activés pour la ligne courante.
    pub fn render_objs(self: *Ppu) void {
        const gba = self.master_gba();
        if (!gba.io.regs.dispcnt.obj_enable) {
            return;
        }

        var x: usize = 0;
        while (x < screen_w) : (x += 1) {
            self.layerlines[layer_obj][x] = transparent_color;
        }

        const obj_cycles_base: i32 = if (gba.io.regs.dispcnt.hblank_free) screen_w else dots_w;
        self.obj_cycles = obj_cycles_base * 4 - 6;

        var i: usize = 0;
        while (i < 128) : (i += 1) {
            self.render_obj_line(i);
            if (self.obj_cycles <= 0) {
                break;
            }
        }
    }

    /// Applique la couverture de WIN0 et WIN1 pour la ligne courante.
    pub fn render_windows(self: *Ppu) void {
        const gba = self.master_gba();
        if (gba.io.regs.dispcnt.win_enable == 0) {
            return;
        }

        var i: i32 = 1;
        while (i >= 0) : (i -= 1) {
            const win_index: usize = @intCast(i);
            if ((gba.io.regs.dispcnt.win_enable & common.bit(u2, win_index)) == 0 or !self.in_win[win_index]) {
                continue;
            }

            const x1 = gba.io.regs.winh[win_index].x1;
            const x2 = gba.io.regs.winh[win_index].x2;
            var x = x1;
            while (x != x2) : (x +%= 1) {
                if (x < screen_w) {
                    self.window[x] = @intCast(win_index);
                }
            }
        }
    }

    /// Compose la ligne visible dans le tampon d'image.
    pub fn draw_scanline(self: *Ppu) void {
        const gba = self.master_gba();
        var x: usize = 0;
        while (x < screen_w) : (x += 1) {
            self.layerlines[layer_bd][x] = gba.pram.h[0];
        }

        self.draw_bg = [_]bool{false} ** 4;
        self.draw_obj = false;
        self.obj_mos = false;
        self.obj_semitrans = false;

        if (gba.io.regs.dispcnt.win_enable != 0 or gba.io.regs.dispcnt.winobj_enable) {
            @memset(&self.window, window_wout);
        }

        self.render_bgs();
        self.render_objs();
        self.render_windows();

        if (gba.io.regs.bgcnt[0].mosaic) self.hmosaic_bg(0);
        if (gba.io.regs.bgcnt[1].mosaic) self.hmosaic_bg(1);
        if (gba.io.regs.bgcnt[2].mosaic) self.hmosaic_bg(2);
        if (gba.io.regs.bgcnt[3].mosaic) self.hmosaic_bg(3);
        if (self.obj_mos) self.hmosaic_obj();

        self.compose_lines();
    }

    /// Fait avancer le PPU vers la phase HDraw suivante.
    pub fn hdraw(self: *Ppu) void {
        const gba = self.master_gba();
        self.ly +%= 1;
        if (self.ly == lines_h) {
            self.ly = 0;
        }
        gba.io.regs.vcount = self.ly;
        gba.io.regs.dispstat.hblank = false;

        if (self.ly == gba.io.regs.dispstat.lyc) {
            gba.io.regs.dispstat.vcounteq = true;
            if (gba.io.regs.dispstat.vcount_irq) {
                gba.io.regs.ifl.vcounteq = true;
            }
        } else {
            gba.io.regs.dispstat.vcounteq = false;
        }

        if (self.ly == screen_h) {
            gba.io.regs.dispstat.vblank = true;
            self.vblank();
        } else if (self.ly == lines_h - 1) {
            gba.io.regs.dispstat.vblank = false;
            self.frame_complete = true;
        }

        var i: usize = 0;
        while (i < 2) : (i += 1) {
            if (self.ly == gba.io.regs.winv[i].y1) self.in_win[i] = true;
            if (self.ly == gba.io.regs.winv[i].y2) self.in_win[i] = false;
        }

        if (gba.io.regs.dma[3].cnt.start == .spec) {
            if (2 <= self.ly and self.ly < 162) {
                gba.dmac.activate(3);
            } else if (self.ly == 162) {
                gba.io.regs.dma[3].cnt.enable = false;
            }
        }

        if (self.ly < screen_h) {
            if (gba.io.regs.dispcnt.forced_blank) {
                @memset(&self.screen[self.ly], 0xffff);
            } else {
                self.draw_scanline();
            }
        }

        gba.sched.add_event(.ppu_hblank, gba.sched.now + 4 * screen_w + 44);
        gba.sched.add_event(.ppu_hdraw, gba.sched.now + 4 * dots_w);
    }

    /// Entre en VBlank et déclenche les IRQ ainsi que les démarrages DMA correspondants.
    pub fn vblank(self: *Ppu) void {
        const gba = self.master_gba();
        if (gba.io.regs.dispstat.vblank_irq) {
            gba.io.regs.ifl.vblank = true;
        }

        self.bgaffintr[0].x = @bitCast(gba.io.regs.bgaff[0].x);
        self.bgaffintr[0].y = @bitCast(gba.io.regs.bgaff[0].y);
        self.bgaffintr[1].x = @bitCast(gba.io.regs.bgaff[1].x);
        self.bgaffintr[1].y = @bitCast(gba.io.regs.bgaff[1].y);
        self.bgaffintr[0].mosx = self.bgaffintr[0].x;
        self.bgaffintr[0].mosy = self.bgaffintr[0].y;
        self.bgaffintr[1].mosx = self.bgaffintr[1].x;
        self.bgaffintr[1].mosy = self.bgaffintr[1].y;

        self.bgmos_y = 0;
        self.bgmos_ct = -1;
        self.objmos_y = 0;
        self.objmos_ct = -1;

        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (gba.io.regs.dma[i].cnt.start == .vblank) {
                gba.dmac.activate(i);
            }
        }
    }

    /// Entre en HBlank et fait progresser l'état affine et mosaïque propre à la ligne.
    pub fn hblank(self: *Ppu) void {
        const gba = self.master_gba();
        if (self.ly < screen_h) {
            self.bgaffintr[0].x +%= @as(sword, gba.io.regs.bgaff[0].pb);
            self.bgaffintr[0].y +%= @as(sword, gba.io.regs.bgaff[0].pd);
            self.bgaffintr[1].x +%= @as(sword, gba.io.regs.bgaff[1].pb);
            self.bgaffintr[1].y +%= @as(sword, gba.io.regs.bgaff[1].pd);

            self.bgmos_ct += 1;
            if (self.bgmos_ct == gba.io.regs.mosaic.bg_v) {
                self.bgmos_ct = -1;
                self.bgmos_y = self.ly + 1;
                self.bgaffintr[0].mosx = self.bgaffintr[0].x;
                self.bgaffintr[0].mosy = self.bgaffintr[0].y;
                self.bgaffintr[1].mosx = self.bgaffintr[1].x;
                self.bgaffintr[1].mosy = self.bgaffintr[1].y;
            }

            self.objmos_ct += 1;
            if (self.objmos_ct == gba.io.regs.mosaic.obj_v) {
                self.objmos_ct = -1;
                self.objmos_y = self.ly + 1;
            }

            var i: usize = 0;
            while (i < 4) : (i += 1) {
                if (gba.io.regs.dma[i].cnt.start == .hblank) {
                    gba.dmac.activate(i);
                }
            }
        }

        gba.io.regs.dispstat.hblank = true;
        if (gba.io.regs.dispstat.hblank_irq) {
            gba.io.regs.ifl.hblank = true;
        }
    }

    fn render_bg_line_text(self: *Ppu, bg: usize) void {
        const gba = self.master_gba();
        if ((gba.io.regs.dispcnt.bg_enable & common.bit(u4, bg)) == 0) {
            return;
        }
        self.draw_bg[bg] = true;

        const bgcnt = gba.io.regs.bgcnt[bg];
        const map_start = @as(word, bgcnt.tilemap_base) * 0x800;
        const tile_start = @as(word, bgcnt.tile_base) * 0x4000;

        const sy: hword = if (bgcnt.mosaic)
            (@as(hword, self.bgmos_y) +% gba.io.regs.bgtext[bg].vofs) % 512
        else
            (@as(hword, self.ly) +% gba.io.regs.bgtext[bg].vofs) % 512;
        const scy: hword = sy >> 8;
        const ty: hword = (sy >> 3) & 0x1f;
        const fy: hword = sy & 0x0007;
        const sx = gba.io.regs.bgtext[bg].hofs;
        var scx: hword = sx >> 8;
        var tx: hword = (sx >> 3) & 0x1f;
        var fx: hword = sx & 0x0007;
        const sc_row = @as(usize, @intCast(scy & 1));
        const size_index = @as(usize, bgcnt.size);
        const scs = [_]byte{
            sc_layout[size_index][sc_row][0],
            sc_layout[size_index][sc_row][1],
        };
        var map_addr = map_start + @as(word, scs[@as(usize, @intCast(scx & 1))]) * 0x800 + 32 * 2 * @as(word, ty) + 2 * @as(word, tx);
        var tile: BgTile = @bitCast(read_bg_half(gba, map_addr));

        if (bgcnt.palmode) {
            var tile_addr = tile_start + 64 * @as(word, tile.num);
            var tmpfy = fy;
            if (tile.vflip) {
                tmpfy = 7 - fy;
            }
            var row = read_bg_row_8(gba, tile_addr, tmpfy);
            if (tile.hflip) {
                row = reverse_row_8bpp(row);
            }
            row >>= @as(u6, @intCast(8 * fx));

            var x: usize = 0;
            while (x < screen_w) : (x += 1) {
                const col_ind: byte = @truncate(row & 0xff);
                self.layerlines[bg][x] = if (col_ind != 0)
                    gba.pram.h[col_ind] & color_mask
                else
                    transparent_color;

                row >>= 8;
                fx += 1;
                if (fx == 8) {
                    fx = 0;
                    tx += 1;
                    if (tx == 32) {
                        tx = 0;
                        scx += 1;
                        map_addr = map_start + @as(word, scs[@as(usize, @intCast(scx & 1))]) * 0x800 + 32 * 2 * @as(word, ty);
                    } else {
                        map_addr += 2;
                    }
                    tile = @bitCast(read_bg_half(gba, map_addr));
                    tile_addr = tile_start + 64 * @as(word, tile.num);
                    tmpfy = fy;
                    if (tile.vflip) {
                        tmpfy = 7 - fy;
                    }
                    row = read_bg_row_8(gba, tile_addr, tmpfy);
                    if (tile.hflip) {
                        row = reverse_row_8bpp(row);
                    }
                }
            }
            return;
        }

        var tile_addr = tile_start + 32 * @as(word, tile.num);
        var tmpfy = fy;
        if (tile.vflip) {
            tmpfy = 7 - fy;
        }
        var row = read_bg_row_4(gba, tile_addr, tmpfy);
        if (tile.hflip) {
            row = reverse_row_4bpp(row);
        }
        row >>= @as(u5, @intCast(4 * fx));

        var x: usize = 0;
        while (x < screen_w) : (x += 1) {
            var col_ind: byte = @truncate(row & 0x0f);
            self.layerlines[bg][x] = blk: {
                if (col_ind == 0) {
                    break :blk transparent_color;
                }
                col_ind |= @as(byte, tile.palette) << 4;
                break :blk gba.pram.h[col_ind] & color_mask;
            };

            row >>= 4;
            fx += 1;
            if (fx == 8) {
                fx = 0;
                tx += 1;
                if (tx == 32) {
                    tx = 0;
                    scx += 1;
                    map_addr = map_start + @as(word, scs[@as(usize, @intCast(scx & 1))]) * 0x800 + 32 * 2 * @as(word, ty);
                } else {
                    map_addr += 2;
                }
                tile = @bitCast(read_bg_half(gba, map_addr));
                tile_addr = tile_start + 32 * @as(word, tile.num);
                tmpfy = fy;
                if (tile.vflip) {
                    tmpfy = 7 - fy;
                }
                row = read_bg_row_4(gba, tile_addr, tmpfy);
                if (tile.hflip) {
                    row = reverse_row_4bpp(row);
                }
            }
        }
    }

    fn render_bg_line_aff(self: *Ppu, bg: usize, mode: byte) void {
        const gba = self.master_gba();
        if ((gba.io.regs.dispcnt.bg_enable & common.bit(u4, bg)) == 0) {
            return;
        }
        self.draw_bg[bg] = true;

        const bgcnt = gba.io.regs.bgcnt[bg];
        const map_start = @as(word, bgcnt.tilemap_base) * 0x800;
        const tile_start = @as(word, bgcnt.tile_base) * 0x4000;
        const bm_start: word = if (gba.io.regs.dispcnt.frame_sel) 0xa000 else 0x0000;
        const aff_index = bg - 2;

        var x0: sword = if (bgcnt.mosaic)
            self.bgaffintr[aff_index].mosx
        else
            self.bgaffintr[aff_index].x;
        var y0: sword = if (bgcnt.mosaic)
            self.bgaffintr[aff_index].mosy
        else
            self.bgaffintr[aff_index].y;
        const size_shift: u4 = @as(u4, 7) + @as(u4, bgcnt.size);
        const size: hword = @as(hword, 1) << size_shift;

        var x: usize = 0;
        while (x < screen_w) : (x += 1) {
            var sx: word = @bitCast(x0 >> 8);
            var sy: word = @bitCast(y0 >> 8);
            if (((mode < 3) and (sx >= size or sy >= size) and !bgcnt.overflow) or
                (((mode == 3) or (mode == 4)) and (sx >= screen_w or sy >= screen_h)) or
                ((mode == 5) and (sx >= 160 or sy >= 128)))
            {
                self.layerlines[bg][x] = transparent_color;
                x0 +%= @as(sword, gba.io.regs.bgaff[aff_index].pa);
                y0 +%= @as(sword, gba.io.regs.bgaff[aff_index].pc);
                continue;
            }

            var col_ind: byte = 0;
            var pal = true;
            switch (mode) {
                1, 2 => {
                    sx &= size - 1;
                    sy &= size - 1;
                    const tilex: hword = @truncate(sx >> 3);
                    const tiley: hword = @truncate(sy >> 3);
                    const finex: hword = @truncate(sx & 0x0007);
                    const finey: hword = @truncate(sy & 0x0007);
                    const tile = gba.vram.b[@as(usize, @intCast((map_start + @as(word, tiley) * (@as(word, size) >> 3) + tilex) % 0x10000))];
                    col_ind = gba.vram.b[@as(usize, @intCast((tile_start + 64 * @as(word, tile) + @as(word, finey) * 8 + finex) % 0x10000))];
                },
                3 => {
                    pal = false;
                    self.layerlines[bg][x] = gba.vram.h[@as(usize, @intCast(sy * screen_w + sx))] & color_mask;
                },
                4 => {
                    col_ind = gba.vram.b[@as(usize, @intCast(bm_start + sy * screen_w + sx))];
                },
                5 => {
                    pal = false;
                    self.layerlines[bg][x] = gba.vram.h[@as(usize, @intCast((bm_start >> 1) + sy * 160 + sx))] & color_mask;
                },
                else => {},
            }
            if (pal) {
                self.layerlines[bg][x] = if (col_ind != 0)
                    gba.pram.h[col_ind] & color_mask
                else
                    transparent_color;
            }

            x0 +%= @as(sword, gba.io.regs.bgaff[aff_index].pa);
            y0 +%= @as(sword, gba.io.regs.bgaff[aff_index].pc);
        }
    }

    fn render_obj_line(self: *Ppu, index: usize) void {
        const gba = self.master_gba();
        const obj = gba.oam.objs[index];
        const dims = dimensions_for_obj(obj) orelse return;
        var w = dims.w;
        var h = dims.h;
        if (obj.disable_double()) {
            if (obj.aff()) {
                w *%= 2;
                h *%= 2;
            } else {
                return;
            }
        }

        var yofs = self.ly -% obj.y();
        if (yofs >= h) {
            return;
        }

        if (obj.mosaic()) {
            yofs = self.objmos_y -% obj.y();
            self.obj_mos = true;
        }
        if (obj.mode() == obj_mode_semitrans) {
            self.obj_semitrans = true;
        }

        const tile_start = @as(word, obj.tilenum()) * 32;
        if (gba.io.regs.dispcnt.bg_mode > 2 and tile_start < 0x4000) {
            return;
        }

        if (obj.aff()) {
            self.render_obj_line_affine(obj, w, h, yofs, tile_start);
        } else {
            self.render_obj_line_regular(obj, w, h, yofs, tile_start);
        }
    }

    fn render_obj_line_affine(
        self: *Ppu,
        obj: ObjAttr,
        w: byte,
        h: byte,
        yofs: byte,
        tile_start: word,
    ) void {
        const gba = self.master_gba();
        self.obj_cycles -= 10 + 2 * @as(i32, w);

        var ow = w;
        var oh = h;
        if (obj.disable_double()) {
            ow /= 2;
            oh /= 2;
        }

        const aff_index = @as(usize, obj.affparamind()) * 4;
        const pa = gba.oam.objs[aff_index + 0].affparam;
        const pb = gba.oam.objs[aff_index + 1].affparam;
        const pc = gba.oam.objs[aff_index + 2].affparam;
        const pd = gba.oam.objs[aff_index + 3].affparam;

        const half_w: sword = @divTrunc(@as(sword, w), 2);
        const half_h: sword = @divTrunc(@as(sword, h), 2);
        const half_ow: sword = @divTrunc(@as(sword, ow), 2);
        const half_oh: sword = @divTrunc(@as(sword, oh), 2);
        var x0: sword = @as(sword, pa) * -half_w +
            @as(sword, pb) * (@as(sword, yofs) - half_h) +
            (half_ow << 8);
        var y0: sword = @as(sword, pc) * -half_w +
            @as(sword, pd) * (@as(sword, yofs) - half_h) +
            (half_oh << 8);

        const tile_rows_8: word = if (gba.io.regs.dispcnt.obj_mapmode) ow / 8 else 16;
        const tile_rows_4: word = if (gba.io.regs.dispcnt.obj_mapmode) ow / 8 else 32;
        const max_ty: hword = oh / 8;
        const max_tx: hword = ow / 8;

        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sx = (@as(word, obj.x()) + @as(word, @intCast(x))) % 512;
            if (sx < screen_w) {
                const ty: hword = @truncate(signed_shift_to_word(y0, 11));
                const fy: hword = @truncate(signed_shift_to_word(y0, 8) & 0x0007);
                const tx: hword = @truncate(signed_shift_to_word(x0, 11));
                const fx: hword = @truncate(signed_shift_to_word(x0, 8) & 0x0007);

                var col: hword = transparent_color;
                if (ty < max_ty and tx < max_tx) {
                    if (obj.palmode()) {
                        var tile_addr = tile_start + @as(word, ty) * 64 * tile_rows_8;
                        tile_addr += 64 * @as(word, tx) + 8 * @as(word, fy) + fx;
                        const col_ind = read_obj_byte(gba, tile_addr);
                        if (col_ind != 0) {
                            col = gba.pram.h[@as(usize, 0x100) + col_ind] & color_mask;
                        }
                    } else {
                        var tile_addr = tile_start + @as(word, ty) * 32 * tile_rows_4;
                        tile_addr += 32 * @as(word, tx) + 4 * @as(word, fy) + @as(word, fx / 2);
                        var col_ind = read_obj_byte(gba, tile_addr);
                        if ((fx & 1) != 0) {
                            col_ind >>= 4;
                        } else {
                            col_ind &= 0x0f;
                        }
                        if (col_ind != 0) {
                            col_ind |= obj.palette() << 4;
                            col = gba.pram.h[@as(usize, 0x100) + col_ind] & color_mask;
                        }
                    }
                }
                self.store_obj_pixel(obj, @intCast(sx), col);
            }

            x0 +%= @as(sword, pa);
            y0 +%= @as(sword, pc);
        }
    }

    fn render_obj_line_regular(
        self: *Ppu,
        obj: ObjAttr,
        w: byte,
        h: byte,
        yofs_in: byte,
        tile_start: word,
    ) void {
        const gba = self.master_gba();
        self.obj_cycles -= w;

        var tile_addr = tile_start;
        var yofs = yofs_in;
        if (obj.vflip()) {
            yofs = h - 1 - yofs;
        }
        const ty: byte = yofs >> 3;
        const fy: byte = yofs & 0x07;
        var fx: byte = 0;

        if (obj.palmode()) {
            tile_addr += @as(word, ty) * 64 * (if (gba.io.regs.dispcnt.obj_mapmode) w / 8 else 16);
            var row: dword = undefined;
            if (obj.hflip()) {
                tile_addr += 64 * (@as(word, w) / 8 - 1);
                row = reverse_row_8bpp(read_obj_row_8(gba, tile_addr, fy));
            } else {
                row = read_obj_row_8(gba, tile_addr, fy);
            }

            var x: usize = 0;
            while (x < w) : (x += 1) {
                const sx = (@as(word, obj.x()) + @as(word, @intCast(x))) % 512;
                if (sx < screen_w) {
                    const col_ind: byte = @truncate(row & 0xff);
                    const col: hword = if (col_ind != 0)
                        gba.pram.h[@as(usize, 0x100) + col_ind] & color_mask
                    else
                        transparent_color;
                    self.store_obj_pixel(obj, @intCast(sx), col);
                }

                row >>= 8;
                fx += 1;
                if (fx == 8 and x + 1 < w) {
                    fx = 0;
                    if (obj.hflip()) {
                        tile_addr -%= 64;
                        row = reverse_row_8bpp(read_obj_row_8(gba, tile_addr, fy));
                    } else {
                        tile_addr += 64;
                        row = read_obj_row_8(gba, tile_addr, fy);
                    }
                }
            }
            return;
        }

        tile_addr += @as(word, ty) * 32 * (if (gba.io.regs.dispcnt.obj_mapmode) w / 8 else 32);
        var row: word = undefined;
        if (obj.hflip()) {
            tile_addr += 32 * (@as(word, w) / 8 - 1);
            row = reverse_row_4bpp(read_obj_row_4(gba, tile_addr, fy));
        } else {
            row = read_obj_row_4(gba, tile_addr, fy);
        }

        var x: usize = 0;
        while (x < w) : (x += 1) {
            const sx = (@as(word, obj.x()) + @as(word, @intCast(x))) % 512;
            if (sx < screen_w) {
                var col_ind: byte = @truncate(row & 0x0f);
                const col: hword = blk: {
                    if (col_ind == 0) {
                        break :blk transparent_color;
                    }
                    col_ind |= obj.palette() << 4;
                    break :blk gba.pram.h[@as(usize, 0x100) + col_ind] & color_mask;
                };
                self.store_obj_pixel(obj, @intCast(sx), col);
            }

            row >>= 4;
            fx += 1;
            if (fx == 8 and x + 1 < w) {
                fx = 0;
                if (obj.hflip()) {
                    tile_addr -%= 32;
                    row = reverse_row_4bpp(read_obj_row_4(gba, tile_addr, fy));
                } else {
                    tile_addr += 32;
                    row = read_obj_row_4(gba, tile_addr, fy);
                }
            }
        }
    }

    fn store_obj_pixel(self: *Ppu, obj: ObjAttr, sx: usize, col: hword) void {
        const gba = self.master_gba();
        if (obj.mode() == obj_mode_objwin) {
            if (gba.io.regs.dispcnt.winobj_enable and !is_transparent(col)) {
                self.window[sx] = window_wobj;
            }
            return;
        }

        if (obj.priority() < self.objdotattrs[sx].priority or is_transparent(self.layerlines[layer_obj][sx])) {
            if (!is_transparent(col)) {
                self.draw_obj = true;
                self.layerlines[layer_obj][sx] = col;
                self.objdotattrs[sx].semitrans = obj.mode() == obj_mode_semitrans;
            }
            self.objdotattrs[sx].mosaic = obj.mosaic();
            self.objdotattrs[sx].priority = @truncate(obj.priority());
        }
    }

    fn hmosaic_bg(self: *Ppu, bg: usize) void {
        var mos_ct: i16 = -1;
        var mos_x: usize = 0;
        var x: usize = 0;
        while (x < screen_w) : (x += 1) {
            self.layerlines[bg][x] = self.layerlines[bg][mos_x];
            mos_ct += 1;
            if (mos_ct == self.master_gba().io.regs.mosaic.bg_h) {
                mos_ct = -1;
                mos_x = x + 1;
            }
        }
    }

    fn hmosaic_obj(self: *Ppu) void {
        var mos_ct: i16 = -1;
        var mos_x: usize = 0;
        var prev_mos = false;
        var x: usize = 0;
        while (x < screen_w) : (x += 1) {
            mos_ct += 1;
            if (mos_ct == self.master_gba().io.regs.mosaic.obj_h or !self.objdotattrs[x].mosaic or !prev_mos) {
                mos_ct = -1;
                mos_x = x;
                prev_mos = self.objdotattrs[x].mosaic;
            }
            self.layerlines[layer_obj][x] = self.layerlines[layer_obj][mos_x];
        }
    }

    fn compose_lines(self: *Ppu) void {
        const gba = self.master_gba();
        const order = self.sort_drawn_backgrounds();
        const effect: EffectType = @enumFromInt(gba.io.regs.bldcnt.effect);
        var eva: byte = @intCast(gba.io.regs.bldalpha.eva);
        var evb: byte = @intCast(gba.io.regs.bldalpha.evb);
        var evy: byte = @intCast(gba.io.regs.bldy.evy);
        if (eva > 16) eva = 16;
        if (evb > 16) evb = 16;
        if (evy > 16) evy = 16;

        if (effect != .none or self.obj_semitrans) {
            var x: usize = 0;
            while (x < screen_w) : (x += 1) {
                const layers = self.collect_layers(order, x, 2);
                const top_layer = layers.values[0];
                const top_color = self.layerlines[top_layer][x];
                if (top_layer == layer_obj and self.objdotattrs[x].semitrans and layers.count > 1 and
                    target_contains(gba.io.regs.bldcnt.target2, layers.values[1]))
                {
                    self.screen[self.ly][x] = blend_alpha(top_color, self.layerlines[layers.values[1]][x], eva, evb);
                    continue;
                }

                const win_enabled = gba.io.regs.dispcnt.win_enable != 0 or gba.io.regs.dispcnt.winobj_enable;
                const effects_enabled = !win_enabled or window_control(gba, self.window[x]).effects_enable;
                if (target_contains(gba.io.regs.bldcnt.target1, top_layer) and effects_enabled) {
                    self.screen[self.ly][x] = switch (effect) {
                        .none => top_color,
                        .alpha => blk: {
                            if (layers.count <= 1 or !target_contains(gba.io.regs.bldcnt.target2, layers.values[1])) {
                                break :blk top_color;
                            }
                            break :blk blend_alpha(top_color, self.layerlines[layers.values[1]][x], eva, evb);
                        },
                        .binc => brighten(top_color, evy),
                        .bdec => darken(top_color, evy),
                    };
                } else {
                    self.screen[self.ly][x] = top_color;
                }
            }
            return;
        }

        var x: usize = 0;
        while (x < screen_w) : (x += 1) {
            const layers = self.collect_layers(order, x, 1);
            self.screen[self.ly][x] = self.layerlines[layers.values[0]][x];
        }
    }

    fn sort_drawn_backgrounds(self: *Ppu) BgOrder {
        const gba = self.master_gba();
        var order = BgOrder{};
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (!self.draw_bg[i]) {
                continue;
            }
            const index = order.count;
            order.ids[index] = @intCast(i);
            order.priorities[index] = @intCast(gba.io.regs.bgcnt[i].priority);
            order.count += 1;

            var j = index;
            while (j > 0 and order.priorities[j] < order.priorities[j - 1]) {
                swap_byte(&order.ids[j], &order.ids[j - 1]);
                swap_byte(&order.priorities[j], &order.priorities[j - 1]);
                j -= 1;
            }
        }
        return order;
    }

    fn collect_layers(self: *Ppu, order: BgOrder, x: usize, visible_limit: usize) LayerStack {
        const gba = self.master_gba();
        const win_enabled = gba.io.regs.dispcnt.win_enable != 0 or gba.io.regs.dispcnt.winobj_enable;
        const win = self.window[x];
        const win_ctrl = if (win_enabled)
            window_control(gba, win)
        else
            io_mod.WinCntByte{
                .bg_enable = 0,
                .obj_enable = false,
                .effects_enable = false,
                .unused = 0,
            };

        var stack = LayerStack{};
        var put_obj = self.draw_obj and !is_transparent(self.layerlines[layer_obj][x]) and
            (!win_enabled or win_ctrl.obj_enable);

        var i: usize = 0;
        while (i < order.count and stack.count < visible_limit) : (i += 1) {
            if (put_obj and self.objdotattrs[x].priority <= order.priorities[i]) {
                put_obj = false;
                stack.push(layer_obj);
                if (stack.count == visible_limit) {
                    break;
                }
            }

            const bg = order.ids[i];
            if (!is_transparent(self.layerlines[bg][x]) and (!win_enabled or bg_enabled_in_window(win_ctrl, bg))) {
                stack.push(bg);
                if (stack.count == visible_limit) {
                    break;
                }
            }
        }

        if (put_obj and stack.count < visible_limit) {
            stack.push(layer_obj);
        }
        stack.push(layer_bd);
        return stack;
    }

    fn master_gba(self: *Ppu) *gba_mod.Gba {
        return @ptrCast(@alignCast(self.master));
    }
};

fn dimensions_for_obj(obj: ObjAttr) ?ObjDimensions {
    const size_index = @as(usize, obj.size());
    return switch (obj.shape()) {
        obj_shape_square => .{ .w = obj_layout[size_index][0], .h = obj_layout[size_index][0] },
        obj_shape_horz => .{ .w = obj_layout[size_index][2], .h = obj_layout[size_index][1] },
        obj_shape_vert => .{ .w = obj_layout[size_index][1], .h = obj_layout[size_index][2] },
        else => null,
    };
}

fn read_bg_half(gba: *gba_mod.Gba, addr: word) hword {
    return gba.vram.h[@as(usize, @intCast((addr % 0x10000) >> 1))];
}

fn read_bg_word(gba: *gba_mod.Gba, addr: word) word {
    return gba.vram.w[@as(usize, @intCast((addr % 0x10000) >> 2))];
}

fn read_bg_row_8(gba: *gba_mod.Gba, tile_addr: word, fy: hword) dword {
    const row_addr = tile_addr + 8 * @as(word, fy);
    return @as(dword, read_bg_word(gba, row_addr)) |
        (@as(dword, read_bg_word(gba, row_addr + 4)) << 32);
}

fn read_bg_row_4(gba: *gba_mod.Gba, tile_addr: word, fy: hword) word {
    return read_bg_word(gba, tile_addr + 4 * @as(word, fy));
}

fn read_obj_byte(gba: *gba_mod.Gba, addr: word) byte {
    return gba.vram.b[@as(usize, @intCast(0x10000 + addr % 0x8000))];
}

fn read_obj_word(gba: *gba_mod.Gba, addr: word) word {
    return gba.vram.w[@as(usize, @intCast((0x10000 + addr % 0x8000) >> 2))];
}

fn read_obj_row_8(gba: *gba_mod.Gba, tile_addr: word, fy: byte) dword {
    const row_addr = tile_addr + 8 * @as(word, fy);
    return @as(dword, read_obj_word(gba, row_addr)) |
        (@as(dword, read_obj_word(gba, row_addr + 4)) << 32);
}

fn read_obj_row_4(gba: *gba_mod.Gba, tile_addr: word, fy: byte) word {
    return read_obj_word(gba, tile_addr + 4 * @as(word, fy));
}

fn reverse_row_8bpp(row: dword) dword {
    var value = row;
    value = (value & 0xffffffff00000000) >> 32 | (value & 0x00000000ffffffff) << 32;
    value = (value & 0xffff0000ffff0000) >> 16 | (value & 0x0000ffff0000ffff) << 16;
    value = (value & 0xff00ff00ff00ff00) >> 8 | (value & 0x00ff00ff00ff00ff) << 8;
    return value;
}

fn reverse_row_4bpp(row: word) word {
    var value = row;
    value = (value & 0xffff0000) >> 16 | (value & 0x0000ffff) << 16;
    value = (value & 0xff00ff00) >> 8 | (value & 0x00ff00ff) << 8;
    value = (value & 0xf0f0f0f0) >> 4 | (value & 0x0f0f0f0f) << 4;
    return value;
}

fn is_transparent(color: hword) bool {
    return (color & transparent_color) != 0;
}

fn layer_mask(layer: byte) hword {
    return @as(hword, 1) << @as(u4, @intCast(layer));
}

fn target_contains(target: u6, layer: byte) bool {
    return (@as(hword, target) & layer_mask(layer)) != 0;
}

fn bg_enabled_in_window(win_ctrl: io_mod.WinCntByte, bg: byte) bool {
    return (win_ctrl.bg_enable & common.bit(u4, bg)) != 0;
}

fn window_control(gba: *gba_mod.Gba, index: byte) io_mod.WinCntByte {
    const regs_bytes = std.mem.asBytes(&gba.io.regs);
    return @as(*const io_mod.WinCntByte, @ptrCast(@alignCast(&regs_bytes[io_mod.WININ + index]))).*;
}

fn blend_alpha(color1: hword, color2: hword, eva: byte, evb: byte) hword {
    var r = (@as(u16, eva) * @as(u16, color1 & 0x001f) + @as(u16, evb) * @as(u16, color2 & 0x001f)) / 16;
    var g = (@as(u16, eva) * @as(u16, (color1 >> 5) & 0x001f) + @as(u16, evb) * @as(u16, (color2 >> 5) & 0x001f)) / 16;
    var b = (@as(u16, eva) * @as(u16, (color1 >> 10) & 0x001f) + @as(u16, evb) * @as(u16, (color2 >> 10) & 0x001f)) / 16;
    if (r > 31) r = 31;
    if (g > 31) g = 31;
    if (b > 31) b = 31;
    return (@as(hword, @intCast(b)) << 10) | (@as(hword, @intCast(g)) << 5) | @as(hword, @intCast(r));
}

fn brighten(color: hword, evy: byte) hword {
    const r0: u16 = color & 0x001f;
    const g0: u16 = (color >> 5) & 0x001f;
    const b0: u16 = (color >> 10) & 0x001f;
    const r = r0 + (31 - r0) * evy / 16;
    const g = g0 + (31 - g0) * evy / 16;
    const b = b0 + (31 - b0) * evy / 16;
    return (@as(hword, @intCast(b)) << 10) | (@as(hword, @intCast(g)) << 5) | @as(hword, @intCast(r));
}

fn darken(color: hword, evy: byte) hword {
    const r0: u16 = color & 0x001f;
    const g0: u16 = (color >> 5) & 0x001f;
    const b0: u16 = (color >> 10) & 0x001f;
    const r = r0 - r0 * evy / 16;
    const g = g0 - g0 * evy / 16;
    const b = b0 - b0 * evy / 16;
    return (@as(hword, @intCast(b)) << 10) | (@as(hword, @intCast(g)) << 5) | @as(hword, @intCast(r));
}

fn signed_shift_to_word(value: sword, shift: u5) word {
    return @bitCast(value >> shift);
}

fn signed_to_word(value: shword) word {
    return @bitCast(@as(sword, value));
}

fn swap_byte(a: *byte, b: *byte) void {
    const tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

test "obj attr accessors decode fields" {
    const obj = ObjAttr{
        .attr0 = 0xafe5,
        .attr1 = 0xf756,
        .attr2 = 0xb955,
    };

    try std.testing.expectEqual(@as(byte, 0xe5), obj.y());
    try std.testing.expect(obj.aff());
    try std.testing.expect(obj.disable_double());
    try std.testing.expectEqual(@as(byte, 3), obj.mode());
    try std.testing.expect(!obj.mosaic());
    try std.testing.expect(obj.palmode());
    try std.testing.expectEqual(@as(byte, 2), obj.shape());
    try std.testing.expectEqual(@as(hword, 0x156), obj.x());
    try std.testing.expectEqual(@as(byte, 27), obj.affparamind());
    try std.testing.expect(obj.hflip());
    try std.testing.expect(obj.vflip());
    try std.testing.expectEqual(@as(byte, 3), obj.size());
    try std.testing.expectEqual(@as(hword, 0x155), obj.tilenum());
    try std.testing.expectEqual(@as(byte, 2), obj.priority());
    try std.testing.expectEqual(@as(byte, 0xb), obj.palette());
}

test "reverse_row_4bpp mirrors nibbles" {
    try std.testing.expectEqual(@as(word, 0x76543210), reverse_row_4bpp(0x01234567));
}

test "reverse_row_8bpp mirrors bytes" {
    try std.testing.expectEqual(@as(dword, 0x7766554433221100), reverse_row_8bpp(0x0011223344556677));
}

test "blend_alpha clamps to gba component range" {
    try std.testing.expectEqual(@as(hword, 0x001f), blend_alpha(0x001f, 0x001f, 16, 16));
}
