//! Example-local 5x7 font: columns left to right, bit 0 at top, sixth column blank.
//! `characters[i]` names `glyphs[i]`; a host capture decoder can invert this table.
const microzig = @import("microzig");
const hal = microzig.hal;
const ssd1306 = microzig.drivers.display.ssd1306;
const Datagram = hal.drivers.I2C_DatagramDevice;
const Display = ssd1306.SSD1306_Generic(.{ .mode = .i2c, .DatagramDevice = Datagram, .Digital_IO = @TypeOf(null) });

pub const Error = hal.i2c.ConfigError || hal.i2c.Error || Datagram.ConnectError || ssd1306.InputError;

pub const characters = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ =:-/";
pub const glyphs = [_][6]u8{
    .{ 0x3e, 0x51, 0x49, 0x45, 0x3e, 0 }, // 0
    .{ 0, 0x42, 0x7f, 0x40, 0, 0 }, // 1
    .{ 0x42, 0x61, 0x51, 0x49, 0x46, 0 }, // 2
    .{ 0x21, 0x41, 0x45, 0x4b, 0x31, 0 }, // 3
    .{ 0x18, 0x14, 0x12, 0x7f, 0x10, 0 }, // 4
    .{ 0x27, 0x45, 0x45, 0x45, 0x39, 0 }, // 5
    .{ 0x3c, 0x4a, 0x49, 0x49, 0x30, 0 }, // 6
    .{ 1, 0x71, 9, 5, 3, 0 }, // 7
    .{ 0x36, 0x49, 0x49, 0x49, 0x36, 0 }, // 8
    .{ 6, 0x49, 0x49, 0x29, 0x1e, 0 }, // 9
    .{ 0x7e, 0x11, 0x11, 0x11, 0x7e, 0 }, // A
    .{ 0x7f, 0x49, 0x49, 0x49, 0x36, 0 }, // B
    .{ 0x3e, 0x41, 0x41, 0x41, 0x22, 0 }, // C
    .{ 0x7f, 0x41, 0x41, 0x22, 0x1c, 0 }, // D
    .{ 0x7f, 0x49, 0x49, 0x49, 0x41, 0 }, // E
    .{ 0x7f, 9, 9, 9, 1, 0 }, // F
    .{ 0x3e, 0x41, 0x49, 0x49, 0x7a, 0 }, // G
    .{ 0x7f, 8, 8, 8, 0x7f, 0 }, // H
    .{ 0, 0x41, 0x7f, 0x41, 0, 0 }, // I
    .{ 0x20, 0x40, 0x41, 0x3f, 1, 0 }, // J
    .{ 0x7f, 8, 0x14, 0x22, 0x41, 0 }, // K
    .{ 0x7f, 0x40, 0x40, 0x40, 0x40, 0 }, // L
    .{ 0x7f, 2, 0x0c, 2, 0x7f, 0 }, // M
    .{ 0x7f, 4, 8, 0x10, 0x7f, 0 }, // N
    .{ 0x3e, 0x41, 0x41, 0x41, 0x3e, 0 }, // O
    .{ 0x7f, 9, 9, 9, 6, 0 }, // P
    .{ 0x3e, 0x41, 0x51, 0x21, 0x5e, 0 }, // Q
    .{ 0x7f, 9, 0x19, 0x29, 0x46, 0 }, // R
    .{ 0x46, 0x49, 0x49, 0x49, 0x31, 0 }, // S
    .{ 1, 1, 0x7f, 1, 1, 0 }, // T
    .{ 0x3f, 0x40, 0x40, 0x40, 0x3f, 0 }, // U
    .{ 0x1f, 0x20, 0x40, 0x20, 0x1f, 0 }, // V
    .{ 0x3f, 0x40, 0x38, 0x40, 0x3f, 0 }, // W
    .{ 0x63, 0x14, 8, 0x14, 0x63, 0 }, // X
    .{ 7, 8, 0x70, 8, 7, 0 }, // Y
    .{ 0x61, 0x51, 0x49, 0x45, 0x43, 0 }, // Z
    .{ 0, 0, 0, 0, 0, 0 }, // space
    .{ 0x14, 0x14, 0x14, 0x14, 0x14, 0 }, // =
    .{ 0, 0x36, 0x36, 0, 0, 0 }, // :
    .{ 8, 8, 8, 8, 8, 0 }, // -
    .{ 0x20, 0x10, 8, 4, 2, 0 }, // /
};

// Same window and initialization as i2c_display_ssd1306_c3_oled_042.zig.
pub const panel_x = 28; // first visible column of the 72x40 panel
pub const panel_y = 24;
var i2c0 = hal.i2c.instance.num(0);

pub fn configure() Error!void {
    // Restore routing, clock/reset, timing, filters and FIFOs after every
    // sleep return, once CPU/APB clocks have been restored.
    i2c0.connect_pins(.{ .sda = hal.gpio.num(5), .scl = hal.gpio.num(6) });
    try i2c0.apply(400_000);
}

fn display() Display {
    // Every transaction is bounded, including a disconnected or stuck panel.
    return .{ .dd = Datagram.init(i2c0, @fromBackingInt(0x3c), .from_ms(20)), .mode = {}, .dc_pin = {} };
}

pub fn init() Error!void {
    try configure();
    const d = try ssd1306.init(.i2c, display().dd, null);
    try d.set_memory_addressing_mode(.page);
    // Clear all 1024 bytes, including outside the visible window, before BOOT.
    const black: [128]u8 = @splat(0);
    for (0..8) |page| try write_page(@intCast(page), 0, &black);
}

fn write_page(page: u3, column: u7, bytes: []const u8) Error!void {
    const d = display();
    try d.set_page_start_address(page);
    try d.set_column_start_address_for_page_addressing_mode(.lower, @truncate(column));
    try d.set_column_start_address_for_page_addressing_mode(.higher, @intCast(column >> 4));
    try d.write_gdram(bytes);
}

/// One complete 72-column line per GDRAM write, always padded to twelve cells.
/// Row 0..4 maps to SSD1306 pages 3..7. Inversion includes the blank columns.
pub fn line(row: u3, text: []const u8, inverted: bool) Error!void {
    var pixels: [72]u8 = @splat(if (inverted) 0xff else 0);
    for (text[0..@min(text.len, 12)], 0..) |character, cell| {
        for (characters, glyphs) |supported, glyph| {
            if (character != supported) continue;
            for (glyph, 0..) |column, x| pixels[cell * 6 + x] = if (inverted) ~column else column;
            break;
        }
    }
    try write_page(@intCast(panel_y / 8 + @as(usize, row)), panel_x, &pixels);
}
