const std = @import("std");
const fs_paths = @import("fs_paths.zig");
const gba_mod = @import("gba.zig");
const cartridge = @import("cartridge.zig");
const fs_io = std.Io.Threaded.global_single_threaded.io();

const magic = [_]u8{ 'Z', 'i', 'G', 'B', 'A', 'S', 'T', 'T' };
const version: u32 = 2;

/// Erreurs produites lors de l'enregistrement ou de la restauration des sauvegardes d'état.
pub const SavestateError = error{
    InvalidSavestate,
    WrongRom,
    NoSavestate,
    IoFailure,
};

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    snapshot_size: u32,
    rom_hash: u64,
};

/// Charge utile de save state à taille fixe.
pub const Snapshot = struct {
    gba: gba_mod.Gba = .{},
    cart: cartridge.RuntimeState = .{},
    save_data: [cartridge.max_save_size]u8 = [_]u8{0xff} ** cartridge.max_save_size,
};

pub fn save_state(gba: *const gba_mod.Gba, cart: *const cartridge.Cartridge, path: []const u8, scratch: *Snapshot) SavestateError!void {
    fs_paths.ensure_dir(fs_paths.savestates_dir) catch return error.IoFailure;

    scratch.* = .{};
    scratch.gba = gba.*;
    scratch.cart = cart.capture_runtime_state();
    if (scratch.cart.sav_capacity > scratch.save_data.len) {
        return error.InvalidSavestate;
    }
    if (scratch.cart.sav_capacity != 0) {
        @memcpy(scratch.save_data[0..scratch.cart.sav_capacity], cart.sav_data[0..scratch.cart.sav_capacity]);
    }

    var file = std.Io.Dir.cwd().createFile(fs_io, path, .{}) catch {
        return error.IoFailure;
    };
    defer file.close(fs_io);

    const header = Header{
        .magic = magic,
        .version = version,
        .snapshot_size = @sizeOf(Snapshot),
        .rom_hash = cart.rom_hash(),
    };
    file.writeStreamingAll(fs_io, std.mem.asBytes(&header)) catch return error.IoFailure;
    file.writeStreamingAll(fs_io, std.mem.asBytes(scratch)) catch return error.IoFailure;
}

/// Charge une save state depuis «path» dans l'allocation existante de l'émulateur.
pub fn load_state(gba: *gba_mod.Gba, cart: *cartridge.Cartridge, bios: []const u8, path: []const u8, scratch: *Snapshot) SavestateError!void {
    var file = std.Io.Dir.cwd().openFile(fs_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoSavestate,
        else => return error.IoFailure,
    };
    defer file.close(fs_io);

    var header: Header = undefined;
    const header_len = file.readPositionalAll(fs_io, std.mem.asBytes(&header), 0) catch return error.IoFailure;
    if (header_len != @sizeOf(Header)) {
        return error.InvalidSavestate;
    }
    if (!std.mem.eql(u8, header.magic[0..], magic[0..])) {
        return error.InvalidSavestate;
    }
    if (header.version != version or header.snapshot_size != @sizeOf(Snapshot)) {
        return error.InvalidSavestate;
    }
    if (header.rom_hash != cart.rom_hash()) {
        return error.WrongRom;
    }

    const state_len = file.readPositionalAll(fs_io, std.mem.asBytes(scratch), @sizeOf(Header)) catch return error.IoFailure;
    if (state_len != @sizeOf(Snapshot)) {
        return error.InvalidSavestate;
    }
    if (scratch.cart.sav_capacity > scratch.save_data.len or scratch.cart.sav_capacity > cart.sav_data.len) {
        return error.InvalidSavestate;
    }

    cart.apply_runtime_state(scratch.cart, scratch.save_data[0..scratch.cart.sav_capacity]);
    gba.* = scratch.gba;
    gba.repair_runtime_references(cart, bios);
}

test "savestate path builder uses the savestates directory" {
    const allocator = std.testing.allocator;
    const path = try fs_paths.build_savestate_path(allocator, "demo.gba");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(fs_paths.savestates_dir ++ std.fs.path.sep_str ++ "demo.stt", path);
}
