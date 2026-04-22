const std = @import("std");
const common = @import("common.zig");
const fs_paths = @import("fs_paths.zig");
const fs_io = std.Io.Threaded.global_single_threaded.io();

pub const byte = common.byte;
pub const hword = common.hword;
pub const word = common.word;

const day_seconds = std.time.s_per_day;
const gpio_data_addr: word = 0x00c4;
const gpio_direction_addr: word = 0x00c6;
const gpio_control_addr: word = 0x00c8;
const gpio_last_addr: word = gpio_control_addr + 1;

const sio_bit: byte = 1 << 1;
const sck_bit: byte = 1 << 0;
const cs_bit: byte = 1 << 2;
const status_24_hour: byte = 0x40;
const persist_magic = [_]u8{ 'Z', 'I', 'G', 'R', 'T', 'C', '0', '1' };
const persist_version: u32 = 1;

/// État sérialisable de la RTC cartouche.
pub const RuntimeState = struct {
    present: bool = false,
    read_enabled: bool = false,
    data_port: byte = 0,
    direction_port: byte = 0,
    status: byte = status_24_hour,
    alarm_hour: byte = 0,
    alarm_minute: byte = 0,
    sio_output: bool = false,
    command: byte = 0,
    command_bits: u4 = 0,
    transfer_byte: u4 = 0,
    transfer_bit: u4 = 0,
    transfer_len: u4 = 0,
    mode: TransferMode = .idle,
    register: RtcRegister = .none,
    last_cs_high: bool = false,
    last_sck_high: bool = false,
    epoch_bias_seconds: i64 = 0,
    transfer_buffer: [7]byte = [_]byte{0} ** 7,
};

pub const CartridgeRtc = struct {
    present: bool = false,
    read_enabled: bool = false,
    data_port: byte = 0,
    direction_port: byte = 0,
    status: byte = status_24_hour,
    alarm_hour: byte = 0,
    alarm_minute: byte = 0,
    sio_output: bool = false,
    command: byte = 0,
    command_bits: u4 = 0,
    transfer_byte: u4 = 0,
    transfer_bit: u4 = 0,
    transfer_len: u4 = 0,
    mode: TransferMode = .idle,
    register: RtcRegister = .none,
    last_cs_high: bool = false,
    last_sck_high: bool = false,
    epoch_bias_seconds: i64 = 0,
    transfer_buffer: [7]byte = [_]byte{0} ** 7,

    pub fn detect_rom_has_rtc(rom: []const u8) bool {
        if (std.mem.indexOf(u8, rom, "SIIRTC_V") != null) {
            return true;
        }
        if (rom.len < 0xB0) {
            return false;
        }

        const game_code = rom[0xAC..0xB0];
        const known_rtc_prefixes = [_][]const u8{
            "AXV", // Pokémon Ruby
            "AXP", // Pokémon Sapphire
            "BPE", // Pokémon Emerald
            "U3I", // Boktai
            "U32", // Boktai 2
            "U33", // Boktai 3
            "BLJ", // Legendz - Yomigaeru Shiren no Shima
            "BLV", // Legendz - Sign of Nekuromu
            "BR4", // RockMan EXE 4.5 - Real Operation
            "BKA", // Sennen Kazoku
        };
        inline for (known_rtc_prefixes) |prefix| {
            if (std.mem.startsWith(u8, game_code, prefix)) {
                return true;
            }
        }
        return false;
    }

    pub fn configure_for_rom(self: *CartridgeRtc, rom: []const u8) void {
        self.* = .{};
        self.present = detect_rom_has_rtc(rom);
    }

    pub fn capture_runtime_state(self: CartridgeRtc) RuntimeState {
        return .{
            .present = self.present,
            .read_enabled = self.read_enabled,
            .data_port = self.data_port,
            .direction_port = self.direction_port,
            .status = self.status,
            .alarm_hour = self.alarm_hour,
            .alarm_minute = self.alarm_minute,
            .sio_output = self.sio_output,
            .command = self.command,
            .command_bits = self.command_bits,
            .transfer_byte = self.transfer_byte,
            .transfer_bit = self.transfer_bit,
            .transfer_len = self.transfer_len,
            .mode = self.mode,
            .register = self.register,
            .last_cs_high = self.last_cs_high,
            .last_sck_high = self.last_sck_high,
            .epoch_bias_seconds = self.epoch_bias_seconds,
            .transfer_buffer = self.transfer_buffer,
        };
    }

    pub fn apply_runtime_state(self: *CartridgeRtc, state: RuntimeState) void {
        self.present = state.present;
        self.read_enabled = state.read_enabled;
        self.data_port = state.data_port;
        self.direction_port = state.direction_port;
        self.status = state.status;
        self.alarm_hour = state.alarm_hour;
        self.alarm_minute = state.alarm_minute;
        self.sio_output = state.sio_output;
        self.command = state.command;
        self.command_bits = state.command_bits;
        self.transfer_byte = state.transfer_byte;
        self.transfer_bit = state.transfer_bit;
        self.transfer_len = state.transfer_len;
        self.mode = state.mode;
        self.register = state.register;
        self.last_cs_high = state.last_cs_high;
        self.last_sck_high = state.last_sck_high;
        self.epoch_bias_seconds = state.epoch_bias_seconds;
        self.transfer_buffer = state.transfer_buffer;
    }

    pub fn handles_addr(self: CartridgeRtc, addr: word) bool {
        if (!self.present) {
            return false;
        }
        return addr >= gpio_data_addr and addr <= gpio_last_addr;
    }

    pub fn load(self: *CartridgeRtc, path: []const u8) void {
        if (!self.present) {
            return;
        }
        var file = std.Io.Dir.cwd().openFile(fs_io, path, .{}) catch return;
        defer file.close(fs_io);

        var blob: PersistBlob = undefined;
        const got = file.readPositionalAll(fs_io, std.mem.asBytes(&blob), 0) catch return;
        if (got != @sizeOf(PersistBlob)) {
            return;
        }
        if (!std.mem.eql(u8, blob.magic[0..], persist_magic[0..])) {
            return;
        }
        if (blob.version != persist_version) {
            return;
        }

        self.status = blob.status;
        self.alarm_hour = blob.alarm_hour;
        self.alarm_minute = blob.alarm_minute;
        self.epoch_bias_seconds = blob.epoch_bias_seconds;
    }

    pub fn save(self: CartridgeRtc, path: []const u8) bool {
        if (!self.present) {
            return true;
        }
        fs_paths.ensure_dir(fs_paths.saves_dir) catch {
            return false;
        };
        const blob = PersistBlob{
            .magic = persist_magic,
            .version = persist_version,
            .status = self.status,
            .alarm_hour = self.alarm_hour,
            .alarm_minute = self.alarm_minute,
            .reserved = 0,
            .epoch_bias_seconds = self.epoch_bias_seconds,
        };
        std.Io.Dir.cwd().writeFile(fs_io, .{ .sub_path = path, .data = std.mem.asBytes(&blob) }) catch {
            return false;
        };
        return true;
    }

    pub fn read_byte(self: CartridgeRtc, addr: word) byte {
        const half = self.read_half(addr & ~@as(word, 1));
        return @truncate(half >> @as(u4, @intCast((addr & 1) * 8)));
    }

    pub fn read_half(self: CartridgeRtc, addr_raw: word) hword {
        if (!self.present) {
            return 0xffff;
        }
        const addr = addr_raw & ~@as(word, 1);
        return switch (addr) {
            gpio_data_addr => self.read_data_register(),
            gpio_direction_addr => self.direction_port,
            gpio_control_addr => @intFromBool(self.read_enabled),
            else => 0xffff,
        };
    }

    pub fn read_word(self: CartridgeRtc, addr_raw: word) word {
        const addr = addr_raw & ~@as(word, 3);
        return @as(word, self.read_half(addr)) | (@as(word, self.read_half(addr + 2)) << 16);
    }

    pub fn write_byte(self: *CartridgeRtc, addr_raw: word, value: byte) void {
        if (!self.present) {
            return;
        }
        const addr = addr_raw & ~@as(word, 1);
        var current = self.read_half(addr);
        const shift: u4 = @intCast((addr_raw & 1) * 8);
        current &= ~(@as(hword, 0xff) << shift);
        current |= @as(hword, value) << shift;
        self.write_half(addr, current);
    }

    pub fn write_half(self: *CartridgeRtc, addr_raw: word, value: hword) void {
        if (!self.present) {
            return;
        }
        const addr = addr_raw & ~@as(word, 1);
        switch (addr) {
            gpio_data_addr => self.write_data_register(@truncate(value)),
            gpio_direction_addr => self.direction_port = @truncate(value & 0b111),
            gpio_control_addr => self.read_enabled = (value & 1) != 0,
            else => {},
        }
    }

    pub fn write_word(self: *CartridgeRtc, addr_raw: word, value: word) void {
        const addr = addr_raw & ~@as(word, 3);
        self.write_half(addr, @truncate(value));
        self.write_half(addr + 2, @truncate(value >> 16));
    }

    fn read_data_register(self: CartridgeRtc) hword {
        var value: byte = self.data_port & 0b101;
        if (self.read_enabled and (self.direction_port & sio_bit) == 0 and self.sio_output) {
            value |= sio_bit;
        } else {
            value |= self.data_port & sio_bit;
        }
        return value;
    }

    fn write_data_register(self: *CartridgeRtc, value: byte) void {
        const next = value & 0b111;
        const prev_cs_high = self.last_cs_high;
        const prev_sck_high = self.last_sck_high;
        const next_cs_high = (next & cs_bit) != 0;
        const next_sck_high = (next & sck_bit) != 0;

        self.data_port = next;

        if (!prev_cs_high and next_cs_high) {
            self.begin_transfer(next_sck_high);
        } else if (prev_cs_high and !next_cs_high) {
            self.finish_transfer();
        }

        if (next_cs_high and !prev_sck_high and next_sck_high) {
            self.clock_rising_edge();
        }

        self.last_cs_high = next_cs_high;
        self.last_sck_high = next_sck_high;
    }

    fn begin_transfer(self: *CartridgeRtc, sck_high: bool) void {
        self.mode = .command;
        self.register = .none;
        self.command = 0;
        self.command_bits = 0;
        self.transfer_byte = 0;
        self.transfer_bit = 0;
        self.transfer_len = 0;
        self.sio_output = false;
        @memset(&self.transfer_buffer, 0);
        self.last_sck_high = sck_high;
    }

    fn finish_transfer(self: *CartridgeRtc) void {
        self.mode = .idle;
        self.register = .none;
        self.command = 0;
        self.command_bits = 0;
        self.transfer_byte = 0;
        self.transfer_bit = 0;
        self.transfer_len = 0;
        self.sio_output = false;
        @memset(&self.transfer_buffer, 0);
    }

    fn clock_rising_edge(self: *CartridgeRtc) void {
        switch (self.mode) {
            .idle => {},
            .command => self.shift_command_bit(),
            .write => self.shift_write_bit(),
            .read => self.shift_read_bit(),
        }
    }

    fn shift_command_bit(self: *CartridgeRtc) void {
        const input_bit: byte = @intCast((self.data_port & sio_bit) >> 1);
        self.command = (self.command << 1) | input_bit;
        self.command_bits += 1;
        if (self.command_bits == 8) {
            self.decode_command();
        }
    }

    fn shift_write_bit(self: *CartridgeRtc) void {
        const input_bit: byte = @intCast((self.data_port & sio_bit) >> 1);
        self.transfer_buffer[self.transfer_byte] |= input_bit << @as(u3, @intCast(self.transfer_bit));
        self.transfer_bit += 1;
        if (self.transfer_bit == 8) {
            self.transfer_bit = 0;
            self.transfer_byte += 1;
            if (self.transfer_byte == self.transfer_len) {
                self.commit_write_payload();
                self.mode = .idle;
            }
        }
    }

    fn shift_read_bit(self: *CartridgeRtc) void {
        if (self.transfer_byte >= self.transfer_len) {
            self.sio_output = false;
            self.mode = .idle;
            return;
        }

        self.sio_output = ((self.transfer_buffer[self.transfer_byte] >> @as(u3, @intCast(self.transfer_bit))) & 1) != 0;
        self.transfer_bit += 1;
        if (self.transfer_bit == 8) {
            self.transfer_bit = 0;
            self.transfer_byte += 1;
            if (self.transfer_byte == self.transfer_len) {
                self.mode = .idle;
            }
        }
    }

    fn decode_command(self: *CartridgeRtc) void {
        if ((self.command & 0xF0) != 0x60) {
            self.mode = .idle;
            return;
        }

        const reg_index = (self.command >> 1) & 0x7;
        const read_mode = (self.command & 1) != 0;
        self.register = switch (reg_index) {
            0 => .reset,
            1 => .status,
            2 => .datetime,
            3 => .time,
            4 => .alarm,
            else => .none,
        };

        switch (self.register) {
            .reset => {
                if (!read_mode) {
                    self.reset_device();
                }
                self.mode = .idle;
            },
            .status => self.begin_payload_transfer(read_mode, 1),
            .datetime => self.begin_payload_transfer(read_mode, 7),
            .time => self.begin_payload_transfer(read_mode, 3),
            .alarm => self.begin_payload_transfer(read_mode, 2),
            .none => self.mode = .idle,
        }
    }

    fn begin_payload_transfer(self: *CartridgeRtc, read_mode: bool, len: u4) void {
        self.transfer_byte = 0;
        self.transfer_bit = 0;
        self.transfer_len = len;
        @memset(&self.transfer_buffer, 0);
        if (read_mode) {
            self.prepare_read_payload();
            self.mode = .read;
        } else {
            self.mode = .write;
        }
    }

    fn prepare_read_payload(self: *CartridgeRtc) void {
        switch (self.register) {
            .status => self.transfer_buffer[0] = self.status,
            .datetime => {
                const datetime = self.current_datetime();
                self.transfer_buffer[0] = encode_bcd(datetime.year);
                self.transfer_buffer[1] = encode_bcd(datetime.month);
                self.transfer_buffer[2] = encode_bcd(datetime.day);
                self.transfer_buffer[3] = encode_bcd(datetime.day_of_week);
                self.transfer_buffer[4] = encode_bcd(datetime.hour);
                self.transfer_buffer[5] = encode_bcd(datetime.minute);
                self.transfer_buffer[6] = encode_bcd(datetime.second);
            },
            .time => {
                const datetime = self.current_datetime();
                self.transfer_buffer[0] = encode_bcd(datetime.hour);
                self.transfer_buffer[1] = encode_bcd(datetime.minute);
                self.transfer_buffer[2] = encode_bcd(datetime.second);
            },
            .alarm => {
                self.transfer_buffer[0] = self.alarm_hour;
                self.transfer_buffer[1] = self.alarm_minute;
            },
            else => {},
        }
    }

    fn commit_write_payload(self: *CartridgeRtc) void {
        switch (self.register) {
            .status => self.status = self.transfer_buffer[0] & (0x02 | 0x08 | 0x20 | 0x40),
            .datetime => self.apply_datetime_write(),
            .time => self.apply_time_write(),
            .alarm => {
                self.alarm_hour = self.transfer_buffer[0];
                self.alarm_minute = self.transfer_buffer[1];
            },
            else => {},
        }
    }

    fn apply_datetime_write(self: *CartridgeRtc) void {
        var datetime = DateTime{
            .year = decode_bcd(self.transfer_buffer[0]),
            .month = clamp_month(decode_bcd(self.transfer_buffer[1])),
            .day = 1,
            .day_of_week = 0,
            .hour = clamp_hour(decode_bcd(self.transfer_buffer[4])),
            .minute = clamp_minute_or_second(decode_bcd(self.transfer_buffer[5])),
            .second = clamp_minute_or_second(decode_bcd(self.transfer_buffer[6])),
        };
        const max_day = days_in_month(datetime.year, datetime.month);
        datetime.day = clamp_day(decode_bcd(self.transfer_buffer[2]), max_day);
        datetime.day_of_week = weekday_from_date(datetime.year, datetime.month, datetime.day);
        self.epoch_bias_seconds = datetime_to_epoch_seconds(datetime) - host_unix_seconds();
    }

    fn apply_time_write(self: *CartridgeRtc) void {
        var datetime = self.current_datetime();
        datetime.hour = clamp_hour(decode_bcd(self.transfer_buffer[0]));
        datetime.minute = clamp_minute_or_second(decode_bcd(self.transfer_buffer[1]));
        datetime.second = clamp_minute_or_second(decode_bcd(self.transfer_buffer[2]));
        self.epoch_bias_seconds = datetime_to_epoch_seconds(datetime) - host_unix_seconds();
    }

    fn reset_device(self: *CartridgeRtc) void {
        self.status = status_24_hour;
        self.command = 0;
        self.command_bits = 0;
        self.transfer_byte = 0;
        self.transfer_bit = 0;
        self.transfer_len = 0;
        self.mode = .idle;
        self.register = .none;
        self.sio_output = false;
        @memset(&self.transfer_buffer, 0);
    }

    fn current_datetime(self: CartridgeRtc) DateTime {
        return epoch_seconds_to_datetime(host_unix_seconds() + self.epoch_bias_seconds);
    }
};

const PersistBlob = extern struct {
    magic: [8]u8,
    version: u32,
    status: byte,
    alarm_hour: byte,
    alarm_minute: byte,
    reserved: byte,
    epoch_bias_seconds: i64,
};

const TransferMode = enum(u2) {
    idle,
    command,
    read,
    write,
};

const RtcRegister = enum(u3) {
    none,
    reset,
    status,
    datetime,
    time,
    alarm,
};

const DateTime = struct {
    year: byte,
    month: byte,
    day: byte,
    day_of_week: byte,
    hour: byte,
    minute: byte,
    second: byte,
};

fn encode_bcd(value: byte) byte {
    return @as(byte, (value / 10) << 4) | @as(byte, value % 10);
}

fn decode_bcd(value: byte) byte {
    return @as(byte, (value >> 4) * 10) + (value & 0x0F);
}

fn clamp_month(value: byte) byte {
    if (value < 1) {
        return 1;
    }
    if (value > 12) {
        return 12;
    }
    return value;
}

fn clamp_day(value: byte, max_day: byte) byte {
    if (value < 1) {
        return 1;
    }
    if (value > max_day) {
        return max_day;
    }
    return value;
}

fn clamp_hour(value: byte) byte {
    if (value > 23) {
        return 23;
    }
    return value;
}

fn clamp_minute_or_second(value: byte) byte {
    if (value > 59) {
        return 59;
    }
    return value;
}

fn days_in_month(year_2digit: byte, month: byte) byte {
    const year: std.time.epoch.Year = @as(std.time.epoch.Year, 2000) + year_2digit;
    return std.time.epoch.getDaysInMonth(year, @enumFromInt(month));
}

fn host_unix_seconds() i64 {
    const now = std.Io.Timestamp.now(fs_io, .real);
    return @intCast(@divTrunc(now.toNanoseconds(), std.time.ns_per_s));
}

fn epoch_seconds_to_datetime(epoch_seconds: i64) DateTime {
    const clamped: u64 = if (epoch_seconds < 0) 0 else @intCast(epoch_seconds);
    const epoch = std.time.epoch.EpochSeconds{ .secs = clamped };
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const seconds = epoch.getDaySeconds();

    return .{
        .year = @truncate(year_day.year % 100),
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .day_of_week = @intCast((epoch_day.day + 4) % 7),
        .hour = seconds.getHoursIntoDay(),
        .minute = seconds.getMinutesIntoHour(),
        .second = seconds.getSecondsIntoMinute(),
    };
}

fn datetime_to_epoch_seconds(datetime: DateTime) i64 {
    const year: std.time.epoch.Year = @as(std.time.epoch.Year, 2000) + datetime.year;
    var days: i64 = 0;

    var current_year: std.time.epoch.Year = std.time.epoch.epoch_year;
    while (current_year < year) : (current_year += 1) {
        days += std.time.epoch.getDaysInYear(current_year);
    }

    var month_index: byte = 1;
    while (month_index < datetime.month) : (month_index += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(month_index));
    }

    days += datetime.day - 1;
    return days * day_seconds +
        @as(i64, datetime.hour) * std.time.s_per_hour +
        @as(i64, datetime.minute) * std.time.s_per_min +
        datetime.second;
}

fn weekday_from_date(year: byte, month: byte, day: byte) byte {
    const datetime = DateTime{
        .year = year,
        .month = month,
        .day = day,
        .day_of_week = 0,
        .hour = 0,
        .minute = 0,
        .second = 0,
    };
    return epoch_seconds_to_datetime(datetime_to_epoch_seconds(datetime)).day_of_week;
}

fn begin_transaction(rtc: *CartridgeRtc) void {
    rtc.write_half(gpio_data_addr, sck_bit);
    rtc.write_half(gpio_data_addr, sck_bit | cs_bit);
    rtc.write_half(gpio_direction_addr, 0b111);
}

fn end_transaction(rtc: *CartridgeRtc) void {
    rtc.write_half(gpio_data_addr, sck_bit);
    rtc.write_half(gpio_data_addr, sck_bit);
}

fn write_command(rtc: *CartridgeRtc, command: byte) void {
    var i: u4 = 0;
    while (i < 8) : (i += 1) {
        const bit = (command >> @as(u3, @intCast(7 - i))) & 1;
        const port: hword = (@as(hword, bit) << 1) | cs_bit;
        rtc.write_half(gpio_data_addr, port);
        rtc.write_half(gpio_data_addr, port);
        rtc.write_half(gpio_data_addr, port);
        rtc.write_half(gpio_data_addr, port | sck_bit);
    }
}

fn write_data(rtc: *CartridgeRtc, value: byte) void {
    var i: u4 = 0;
    while (i < 8) : (i += 1) {
        const bit = (value >> @as(u3, @intCast(i))) & 1;
        const port: hword = (@as(hword, bit) << 1) | cs_bit;
        rtc.write_half(gpio_data_addr, port);
        rtc.write_half(gpio_data_addr, port);
        rtc.write_half(gpio_data_addr, port);
        rtc.write_half(gpio_data_addr, port | sck_bit);
    }
}

fn read_data(rtc: *CartridgeRtc) byte {
    rtc.write_half(gpio_control_addr, 1);
    rtc.write_half(gpio_direction_addr, 0b101);
    var value: byte = 0;
    var i: u4 = 0;
    while (i < 8) : (i += 1) {
        rtc.write_half(gpio_data_addr, cs_bit);
        rtc.write_half(gpio_data_addr, cs_bit);
        rtc.write_half(gpio_data_addr, cs_bit);
        rtc.write_half(gpio_data_addr, cs_bit);
        rtc.write_half(gpio_data_addr, cs_bit);
        rtc.write_half(gpio_data_addr, cs_bit | sck_bit);
        const bit = @as(byte, @intCast((rtc.read_half(gpio_data_addr) & sio_bit) >> 1));
        value = (value >> 1) | (bit << 7);
    }
    return value;
}

test "detect_rom_has_rtc finds the Pokémon RTC library signature" {
    var rom = [_]u8{0} ** 256;
    @memcpy(rom[32..43], "SIIRTC_V001");
    try std.testing.expect(CartridgeRtc.detect_rom_has_rtc(&rom));
}

test "gpio status read returns the default 24-hour flag" {
    var rtc = CartridgeRtc{};
    rtc.present = true;
    rtc.read_enabled = true;

    begin_transaction(&rtc);
    write_command(&rtc, 0x63);
    const value = read_data(&rtc);
    end_transaction(&rtc);

    try std.testing.expectEqual(@as(byte, status_24_hour), value);
}

test "gpio status write updates the emulated RTC status register" {
    var rtc = CartridgeRtc{};
    rtc.present = true;

    begin_transaction(&rtc);
    write_command(&rtc, 0x62);
    write_data(&rtc, 0x6A);
    end_transaction(&rtc);

    begin_transaction(&rtc);
    write_command(&rtc, 0x63);
    const value = read_data(&rtc);
    end_transaction(&rtc);

    try std.testing.expectEqual(@as(byte, 0x6A), value);
}
