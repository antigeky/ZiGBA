const std = @import("std");

pub const CliError = error{
    InvalidUsage,
};

pub const CliOptions = struct {
    rom_path: []const u8,
    boot_bios: bool = false,
};

pub fn parse_args(args: []const []const u8) CliError!CliOptions {
    var options = CliOptions{ .rom_path = "" };
    var rom_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--boot-bios")) {
            options.boot_bios = true;
            continue;
        }
        rom_path = arg;
    }

    if (rom_path == null) {
        return error.InvalidUsage;
    }
    options.rom_path = rom_path.?;
    return options;
}
