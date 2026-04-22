const std = @import("std");
const fs_io = std.Io.Threaded.global_single_threaded.io();

/// Erreurs partagées par les utilitaires de chemins et de répertoires.
pub const PathsError = error{
    OutOfMemory,
    IoFailure,
};

pub const system_dir = "system";
pub const saves_dir = "saves";
pub const savestates_dir = "savestates";
pub const default_bios_path = system_dir ++ std.fs.path.sep_str ++ "bios.bin";

/// Retourne le nom de base de la ROM sans extension.
pub fn basename_stem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const maybe_dot = std.mem.lastIndexOfScalar(u8, base, '.');
    return base[0 .. maybe_dot orelse base.len];
}

/// Alloue un chemin de fichier de sauvegarde sous «./saves».
pub fn build_save_path(allocator: std.mem.Allocator, rom_path: []const u8) PathsError![]u8 {
    return build_leaf_path(allocator, saves_dir, rom_path, ".sav");
}

/// Alloue un chemin de persistance de l'horloge temps réel sous «./saves».
pub fn build_rtc_path(allocator: std.mem.Allocator, rom_path: []const u8) PathsError![]u8 {
    return build_leaf_path(allocator, saves_dir, rom_path, ".rtc");
}

/// Alloue un chemin de save state sous «./savestates».
pub fn build_savestate_path(allocator: std.mem.Allocator, rom_path: []const u8) PathsError![]u8 {
    return build_leaf_path(allocator, savestates_dir, rom_path, ".stt");
}

/// Alloue un nom d'affichage lisible dérivé du chemin de la ROM.
pub fn build_display_name(allocator: std.mem.Allocator, rom_path: []const u8) PathsError![]u8 {
    return try allocator.dupe(u8, basename_stem(rom_path));
}

/// Garantit qu'un répertoire relatif existe sous le répertoire de travail courant.
pub fn ensure_dir(path: []const u8) PathsError!void {
    std.Io.Dir.cwd().createDirPath(fs_io, path) catch {
        return error.IoFailure;
    };
}

fn build_leaf_path(allocator: std.mem.Allocator, dir_path: []const u8, rom_path: []const u8, extension: []const u8) PathsError![]u8 {
    const stem = basename_stem(rom_path);
    return std.mem.concat(allocator, u8, &.{ dir_path, std.fs.path.sep_str, stem, extension }) catch {
        return error.OutOfMemory;
    };
}

test "basename_stem strips the extension" {
    try std.testing.expectEqualStrings("game", basename_stem("roms/game.gba"));
}

test "build_save_path places files in saves directory" {
    const allocator = std.testing.allocator;
    const path = try build_save_path(allocator, "roms/game.gba");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(saves_dir ++ std.fs.path.sep_str ++ "game.sav", path);
}

test "build_rtc_path places files in saves directory" {
    const allocator = std.testing.allocator;
    const path = try build_rtc_path(allocator, "roms/game.gba");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(saves_dir ++ std.fs.path.sep_str ++ "game.rtc", path);
}

test "build_savestate_path places files in savestates directory" {
    const allocator = std.testing.allocator;
    const path = try build_savestate_path(allocator, "game.gba");
    defer allocator.free(path);
    try std.testing.expectEqualStrings(savestates_dir ++ std.fs.path.sep_str ++ "game.stt", path);
}
