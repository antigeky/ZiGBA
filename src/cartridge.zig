const std = @import("std");
const common = @import("common.zig");
const fs_paths = @import("fs_paths.zig");
const cartridge_rtc = @import("cartridge_rtc.zig");
const fs_io = std.Io.Threaded.global_single_threaded.io();

pub const byte = common.byte;
pub const hword = common.hword;
pub const word = common.word;
pub const dword = common.dword;

pub const CartridgeError = error{
    InvalidRom,
    OutOfMemory,
    IoFailure,
};

pub const SavType = enum {
    none,
    sram,
    flash,
    eeprom,
};

pub const FlashMode = enum {
    idle,
    id,
    erase,
    write,
    bank_sel,
};

pub const EepromState = enum {
    idle,
    brw,
    addr,
    data,
};

pub const sram_size = 1 << 15;
pub const flash_bank_size = 1 << 16;
pub const eeprom_size_s = 1 << 9;
pub const eeprom_size_l = 1 << 13;

pub const max_save_size = flash_bank_size * 2;

/// Champs du contrôleur de sauvegarde qui doivent survivre à l'enregistrement et au chargement d'une save state.
pub const RuntimeState = struct {
    sav_type: SavType = .none,
    sav_len: usize = 0,
    sav_capacity: usize = 0,
    eeprom_mask: word = 0,
    big_flash: bool = false,
    flash_code: hword = 0,
    big_eeprom: bool = false,
    eeprom_size_set: bool = false,
    eeprom_addr_len: byte = 0,
    flash: FlashState = .{},
    eeprom: EepromRuntime = .{},
    rtc: cartridge_rtc.RuntimeState = .{},
};

/// État d'exécution du séquenceur de commandes flash.
pub const FlashState = struct {
    mode: FlashMode = .idle,
    state: byte = 0,
    bank: byte = 0,
};

/// État d'exécution du séquenceur de commandes série EEPROM.
pub const EepromRuntime = struct {
    state: EepromState = .idle,
    data: dword = 0,
    addr: hword = 0,
    index: i16 = 0,
    read: bool = false,
};

/// Possède la ROM, les tampons de sauvegarde et les noms de fichiers dérivés.
///
/// L'appelant alloue via «init» et doit ensuite appeler «deinit» avec le
/// même allocateur afin d'écrire les données de sauvegarde persistantes et de libérer la mémoire.
pub const Cartridge = struct {
    rom_filename: []u8 = &.{},
    sav_filename: []u8 = &.{},
    rtc_filename: []u8 = &.{},

    rom: []u8 = &.{},

    sav_type: SavType = .none,
    sav_data: []u8 = &.{},
    sav_len: usize = 0,
    eeprom_mask: word = 0,

    big_flash: bool = false,
    flash_code: hword = 0,

    big_eeprom: bool = false,
    eeprom_size_set: bool = false,
    eeprom_addr_len: byte = 0,

    flash: FlashState = .{},
    eeprom: EepromRuntime = .{},

    rtc: cartridge_rtc.CartridgeRtc = .{},

    /// Charge la ROM et le fichier de sauvegarde existant. Aucune allocation n'a lieu après cette
    /// étape d'initialisation, sauf si l'auto-détection de la taille de l'EEPROM redimensionne plus tard le
    /// tampon de sauvegarde via «set_eeprom_size».
    pub fn init(allocator: std.mem.Allocator, rom_path: []const u8) CartridgeError!Cartridge {
        const rom = try read_file_alloc(allocator, rom_path);
        errdefer allocator.free(rom);

        var cart = Cartridge{
            .rom_filename = try allocator.dupe(u8, rom_path),
            .rom = rom,
        };
        errdefer allocator.free(cart.rom_filename);

        cart.detect_save_type();
        cart.rtc.configure_for_rom(cart.rom);

        cart.sav_filename = try build_save_path(allocator, rom_path);
        errdefer allocator.free(cart.sav_filename);

        if (cart.rtc.present) {
            cart.rtc_filename = try build_rtc_path(allocator, rom_path);
            errdefer allocator.free(cart.rtc_filename);
            cart.rtc.load(cart.rtc_filename);
        }

        cart.sav_len = save_capacity_from_type(cart);
        if (cart.sav_len != 0) {
            cart.sav_data = try allocator.alloc(u8, cart.sav_len);
            errdefer allocator.free(cart.sav_data);
            @memset(cart.sav_data, 0xff);
            if (read_file_into(cart.sav_filename, cart.sav_data) and cart.sav_type == .eeprom) {
                eeprom_reverse_bytes(std.mem.bytesAsSlice(dword, cart.sav_data));
            }
        }

        return cart;
    }

    /// Écrit la RAM de sauvegarde sur le disque et libère les tampons possédés.
    pub fn deinit(self: *Cartridge, allocator: std.mem.Allocator) void {
        if (self.sav_data.len != 0) {
            if (self.sav_type == .eeprom) {
                eeprom_reverse_bytes(std.mem.bytesAsSlice(dword, self.sav_data));
            }
            _ = write_file(self.sav_filename, self.sav_data[0..self.sav_len]);
            allocator.free(self.sav_data);
            self.sav_data = &.{};
        }
        if (self.rtc.present and self.rtc_filename.len != 0) {
            _ = self.rtc.save(self.rtc_filename);
            allocator.free(self.rtc_filename);
            self.rtc_filename = &.{};
        }

        allocator.free(self.sav_filename);
        allocator.free(self.rom_filename);
        allocator.free(self.rom);
        self.* = .{};
    }

    pub fn rom_size(self: Cartridge) usize {
        return self.rom.len;
    }

    pub fn save_size(self: Cartridge) usize {
        return self.sav_len;
    }

    /// Retourne un hachage stable de la ROM chargée pour les vérifications de compatibilité des sauvegardes d'état.
    pub fn rom_hash(self: Cartridge) u64 {
        return std.hash.Wyhash.hash(0, self.rom);
    }

    /// Capture l'état mutable sans pointeurs du contrôleur de sauvegarde.
    pub fn capture_runtime_state(self: Cartridge) RuntimeState {
        return .{
            .sav_type = self.sav_type,
            .sav_len = self.sav_len,
            .sav_capacity = self.sav_data.len,
            .eeprom_mask = self.eeprom_mask,
            .big_flash = self.big_flash,
            .flash_code = self.flash_code,
            .big_eeprom = self.big_eeprom,
            .eeprom_size_set = self.eeprom_size_set,
            .eeprom_addr_len = self.eeprom_addr_len,
            .flash = self.flash,
            .eeprom = self.eeprom,
            .rtc = self.rtc.capture_runtime_state(),
        };
    }

    /// Restaure depuis une save state l'état mutable sans pointeurs du contrôleur de sauvegarde.
    pub fn apply_runtime_state(self: *Cartridge, state: RuntimeState, save_data: []const u8) void {
        self.sav_type = state.sav_type;
        self.sav_len = state.sav_len;
        self.eeprom_mask = state.eeprom_mask;
        self.big_flash = state.big_flash;
        self.flash_code = state.flash_code;
        self.big_eeprom = state.big_eeprom;
        self.eeprom_size_set = state.eeprom_size_set;
        self.eeprom_addr_len = state.eeprom_addr_len;
        self.flash = state.flash;
        self.eeprom = state.eeprom;
        self.rtc.apply_runtime_state(state.rtc);

        const copy_len = @min(@min(state.sav_capacity, save_data.len), self.sav_data.len);
        if (copy_len != 0) {
            @memcpy(self.sav_data[0..copy_len], save_data[0..copy_len]);
        }
        if (copy_len < self.sav_data.len) {
            @memset(self.sav_data[copy_len..], 0xff);
        }
    }

    pub fn read_rom_byte(self: Cartridge, addr: word) byte {
        if (self.rom.len == 0) {
            return 0xff;
        }
        return self.rom[@as(usize, addr) % self.rom.len];
    }

    pub fn read_rom_half(self: Cartridge, addr: word) hword {
        const lo = self.read_rom_byte(addr & ~@as(word, 1));
        const hi = self.read_rom_byte((addr & ~@as(word, 1)) + 1);
        return @as(hword, lo) | (@as(hword, hi) << 8);
    }

    pub fn read_rom_word(self: Cartridge, addr: word) word {
        const a = addr & ~@as(word, 3);
        return @as(word, self.read_rom_byte(a)) |
            (@as(word, self.read_rom_byte(a + 1)) << 8) |
            (@as(word, self.read_rom_byte(a + 2)) << 16) |
            (@as(word, self.read_rom_byte(a + 3)) << 24);
    }

    pub fn has_gpio_addr(self: Cartridge, addr: word) bool {
        return self.rtc.handles_addr(addr);
    }

    pub fn read_gpio_byte(self: Cartridge, addr: word) byte {
        return self.rtc.read_byte(addr);
    }

    pub fn read_gpio_half(self: Cartridge, addr: word) hword {
        return self.rtc.read_half(addr);
    }

    pub fn read_gpio_word(self: Cartridge, addr: word) word {
        return self.rtc.read_word(addr);
    }

    pub fn write_gpio_byte(self: *Cartridge, addr: word, value: byte) void {
        self.rtc.write_byte(addr, value);
    }

    pub fn write_gpio_half(self: *Cartridge, addr: word, value: hword) void {
        self.rtc.write_half(addr, value);
    }

    pub fn write_gpio_word(self: *Cartridge, addr: word, value: word) void {
        self.rtc.write_word(addr, value);
    }

    pub fn read_sram(self: *Cartridge, addr: hword) byte {
        return switch (self.sav_type) {
            .sram => self.sav_data[@as(usize, addr) % sram_size],
            .flash => self.read_flash(addr),
            else => 0xff,
        };
    }

    pub fn write_sram(self: *Cartridge, addr: hword, value: byte) void {
        switch (self.sav_type) {
            .sram => self.sav_data[@as(usize, addr) % sram_size] = value,
            .flash => self.write_flash(addr, value),
            else => {},
        }
    }

    pub fn read_flash(self: *Cartridge, addr: hword) byte {
        if (self.flash.mode == .id) {
            return @truncate(self.flash_code >> @as(u4, @truncate((addr & 1) * 8)));
        }
        const bank_offset = @as(usize, self.flash.bank) * flash_bank_size;
        return self.sav_data[bank_offset + @as(usize, addr)];
    }

    pub fn write_flash(self: *Cartridge, addr: hword, value: byte) void {
        if (self.flash.mode == .write) {
            const bank_offset = @as(usize, self.flash.bank) * flash_bank_size;
            self.sav_data[bank_offset + @as(usize, addr)] = value;
            self.flash.mode = .idle;
            return;
        }
        if (self.flash.mode == .bank_sel) {
            self.flash.bank = value & 1;
            self.flash.mode = .idle;
            return;
        }

        switch (self.flash.state) {
            0 => {
                if (addr == 0x5555 and value == 0xaa) self.flash.state = 1;
            },
            1 => {
                if (addr == 0x2aaa and value == 0x55) self.flash.state = 2;
            },
            2 => {
                if (self.flash.mode == .erase) {
                    if (addr == 0x5555 and value == 0x10) {
                        self.flash.state = 0;
                        @memset(self.sav_data, 0xff);
                        self.flash.mode = .idle;
                        return;
                    }
                    if (value == 0x30) {
                        self.flash.state = 0;
                        const bank_offset = @as(usize, self.flash.bank) * flash_bank_size;
                        const erase_base = bank_offset + (@as(usize, addr) & 0xf000);
                        @memset(self.sav_data[erase_base .. erase_base + 0x1000], 0xff);
                        self.flash.mode = .idle;
                        return;
                    }
                }
                if (addr == 0x5555) {
                    self.flash.state = 0;
                    switch (value) {
                        0x90 => self.flash.mode = .id,
                        0xf0 => self.flash.mode = .idle,
                        0x80 => self.flash.mode = .erase,
                        0xa0 => self.flash.mode = .write,
                        0xb0 => {
                            if (self.big_flash) self.flash.mode = .bank_sel;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    /// Certaines ROM diffèrent la capacité exacte de l'EEPROM jusqu'à ce qu'un DMA utilise une
    /// longueur de transfert correspondante. Cela agrandit ou réduit le tampon de sauvegarde une seule fois.
    pub fn set_eeprom_size(self: *Cartridge, big: bool) void {
        self.big_eeprom = big;
        self.sav_len = if (big) eeprom_size_l else eeprom_size_s;
        self.eeprom_addr_len = if (big) 14 else 6;
        self.eeprom_size_set = true;
    }

    pub fn read_eeprom(self: *Cartridge) hword {
        return switch (self.eeprom.state) {
            .data => blk: {
                if (!self.eeprom.read) {
                    break :blk 0;
                }
                var data: hword = 0;
                if (self.eeprom.index >= 0) {
                    const bit_index: u6 = @intCast(63 - self.eeprom.index);
                    data = @as(hword, @intCast((self.eeprom.data >> bit_index) & 1));
                }
                self.eeprom.index += 1;
                if (self.eeprom.index == 64) {
                    self.eeprom.state = .idle;
                }
                break :blk data;
            },
            .idle => 1,
            else => 0,
        };
    }

    pub fn write_eeprom(self: *Cartridge, value: hword) void {
        switch (self.eeprom.state) {
            .idle => {
                if ((value & 1) != 0) {
                    self.eeprom.state = .brw;
                }
            },
            .brw => {
                self.eeprom.read = (value & 1) != 0;
                self.eeprom.state = .addr;
                self.eeprom.addr = 0;
                self.eeprom.index = 0;
            },
            .addr => {
                self.eeprom.addr <<= 1;
                self.eeprom.addr |= value & 1;
                self.eeprom.index += 1;
                if (self.eeprom.index == self.eeprom_addr_len) {
                    self.eeprom.addr %= 1 << 10;
                    if (self.eeprom.read) {
                        self.eeprom.data = std.mem.bytesAsSlice(dword, self.sav_data)[self.eeprom.addr];
                        self.eeprom.index = -4;
                    } else {
                        self.eeprom.data = 0;
                        self.eeprom.index = 0;
                    }
                    self.eeprom.state = .data;
                }
            },
            .data => {
                if (self.eeprom.read) {
                    return;
                }
                self.eeprom.data <<= 1;
                self.eeprom.data |= value & 1;
                self.eeprom.index += 1;
                if (self.eeprom.index == 64) {
                    std.mem.bytesAsSlice(dword, self.sav_data)[self.eeprom.addr] = self.eeprom.data;
                    self.eeprom.state = .idle;
                }
            },
        }
    }

    fn detect_save_type(self: *Cartridge) void {
        self.sav_type = .none;
        self.eeprom_mask = 0;

        var i: usize = 0;
        while (i + 10 <= self.rom.len) : (i += 4) {
            const tail = self.rom[i..];
            if (std.mem.startsWith(u8, tail, "SRAM_V")) {
                self.sav_type = .sram;
                return;
            }
            if (std.mem.startsWith(u8, tail, "EEPROM_V")) {
                self.sav_type = .eeprom;
                self.big_eeprom = true;
                self.eeprom_size_set = false;
                self.eeprom_addr_len = 14;
                self.eeprom_mask = if (self.rom.len > 0x1000000) 0x1ffff00 else 0x1000000;
                return;
            }
            if (std.mem.startsWith(u8, tail, "FLASH1M_V")) {
                self.sav_type = .flash;
                self.big_flash = true;
                self.flash_code = 0x1362;
                return;
            }
            if (std.mem.startsWith(u8, tail, "FLASH512_V") or std.mem.startsWith(u8, tail, "FLASH_V")) {
                self.sav_type = .flash;
                self.big_flash = false;
                self.flash_code = 0xd4bf;
                return;
            }
        }
    }
};

pub fn save_capacity_from_type(cart: Cartridge) usize {
    return switch (cart.sav_type) {
        .none => 0,
        .sram => sram_size,
        .flash => if (cart.big_flash) flash_bank_size * 2 else flash_bank_size,
        .eeprom => if (cart.big_eeprom) eeprom_size_l else eeprom_size_s,
    };
}

pub fn eeprom_reverse_bytes(words: []align(1) dword) void {
    for (words) |*value| {
        var x = value.*;
        x = ((x & 0xffffffff00000000) >> 32) | ((x & 0x00000000ffffffff) << 32);
        x = ((x & 0xffff0000ffff0000) >> 16) | ((x & 0x0000ffff0000ffff) << 16);
        x = ((x & 0xff00ff00ff00ff00) >> 8) | ((x & 0x00ff00ff00ff00ff) << 8);
        value.* = x;
    }
}

fn build_save_path(allocator: std.mem.Allocator, rom_path: []const u8) CartridgeError![]u8 {
    return fs_paths.build_save_path(allocator, rom_path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailure,
    };
}

fn build_rtc_path(allocator: std.mem.Allocator, rom_path: []const u8) CartridgeError![]u8 {
    return fs_paths.build_rtc_path(allocator, rom_path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailure,
    };
}

fn read_file_alloc(allocator: std.mem.Allocator, path: []const u8) CartridgeError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fs_io, path, allocator, .limited(std.math.maxInt(usize))) catch |err| switch (err) {
        error.FileNotFound => error.InvalidRom,
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailure,
    };
}

fn read_file_into(path: []const u8, buf: []u8) bool {
    var file = std.Io.Dir.cwd().openFile(fs_io, path, .{}) catch return false;
    defer file.close(fs_io);

    const got = file.readPositionalAll(fs_io, buf, 0) catch return false;

    return got > 0;
}

fn write_file(path: []const u8, data: []const u8) bool {
    fs_paths.ensure_dir(fs_paths.saves_dir) catch return false;
    std.Io.Dir.cwd().writeFile(fs_io, .{ .sub_path = path, .data = data }) catch return false;
    return true;
}

test "eeprom_reverse_bytes swaps byte order per qword" {
    var values = [_]dword{0x1122334455667788};
    eeprom_reverse_bytes(&values);
    try std.testing.expectEqual(@as(dword, 0x8877665544332211), values[0]);
}

test "build_save_path replaces extension" {
    const allocator = std.testing.allocator;
    const path = try build_save_path(allocator, "game.gba");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(fs_paths.saves_dir ++ std.fs.path.sep_str ++ "game.sav", path);
}

test "rtc detection follows the SIIRTC library signature" {
    var rom = [_]u8{0} ** 256;
    @memcpy(rom[16..27], "SIIRTC_V001");

    var cart = Cartridge{ .rom = &rom };
    cart.rtc.configure_for_rom(cart.rom);
    try std.testing.expect(cart.rtc.present);
}
