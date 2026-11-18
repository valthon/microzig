const compatibility = @import("compatibility.zig");

/// ESP-IDF esp_rom_spiflash.h, esp_rom_spiflash_legacy_data_t prefix.
pub const FlashChip = extern struct {
    device_id: u32,
    chip_size: u32,
    block_size: u32,
    sector_size: u32,
    page_size: u32,
    status_mask: u32,
};

/// Microsecond delay using rom function.
pub fn delay_us(us: u32) void {
    switch (compatibility.chip) {
        .esp32_c3 => functions.ets_delay_us(us),
        .esp32_c6 => functions.ets_delay_us(us),
    }
}

pub const functions = switch (compatibility.chip) {
    .esp32_c3 => struct {
        pub extern fn ets_delay_us(us: u32) callconv(.c) void;
        pub extern fn ets_update_cpu_frequency(ticks_per_us: u32) callconv(.c) void;

        pub extern fn esp_rom_regi2c_read(block: u8, host_id: u8, reg_add: u8) callconv(.c) u8;
        pub extern fn esp_rom_regi2c_read_mask(block: u8, host_id: u8, reg_add: u8, msb: u8, lsb: u8) callconv(.c) u8;
        pub extern fn esp_rom_regi2c_write(block: u8, host_id: u8, reg_add: u8, data: u8) callconv(.c) void;
        pub extern fn esp_rom_regi2c_write_mask(block: u8, host_id: u8, reg_add: u8, msb: u8, lsb: u8, data: u8) callconv(.c) void;

        pub extern fn Cache_Enable_ICache(autoload: u32) callconv(.c) void;
        pub extern fn Cache_Suspend_ICache() callconv(.c) u32;
        pub extern fn Cache_Resume_ICache(autoload: u32) callconv(.c) void;
        pub extern fn Cache_Invalidate_ICache_All() callconv(.c) void;

        // Legacy ROM entry points: addresses and lengths are word aligned;
        // result is 0 (OK), 1 (error), or 2 (timeout).
        pub extern var rom_spiflash_legacy_data: *FlashChip;
        pub extern fn esp_rom_efuse_get_flash_gpio_info() callconv(.c) u32;
        pub extern fn esp_rom_spiflash_attach(pin_config: u32, legacy: bool) callconv(.c) void;
        pub extern fn esp_rom_spiflash_config_param(id: u32, size: u32, block: u32, sector: u32, page: u32, status_mask: u32) callconv(.c) u32;
        pub extern fn esp_rom_spiflash_read(address: u32, dest: [*]u32, len: i32) callconv(.c) u32;
        pub extern fn esp_rom_spiflash_write(address: u32, src: [*]const u32, len: i32) callconv(.c) u32;
        pub extern fn esp_rom_spiflash_erase_sector(sector: u32) callconv(.c) u32;
        pub extern fn esp_rom_spiflash_unlock() callconv(.c) u32;
    },
    // C6 ROM has flash/cache entry points, but no regi2c entry points.
    .esp32_c6 => struct {
        pub extern fn ets_delay_us(us: u32) callconv(.c) void;
        pub extern fn ets_update_cpu_frequency(ticks_per_us: u32) callconv(.c) void;

        pub extern fn Cache_Enable_ICache(autoload: u32) callconv(.c) void;
        pub extern fn Cache_Suspend_ICache() callconv(.c) u32;
        pub extern fn Cache_Resume_ICache(autoload: u32) callconv(.c) void;
        pub extern fn Cache_Invalidate_ICache_All() callconv(.c) void;

        pub extern var rom_spiflash_legacy_data: *FlashChip;
        pub extern fn esp_rom_spiflash_attach(pin_config: u32, legacy: bool) callconv(.c) void;
        pub extern fn esp_rom_spiflash_config_param(id: u32, size: u32, block: u32, sector: u32, page: u32, status_mask: u32) callconv(.c) u32;
        pub extern fn esp_rom_spiflash_read(address: u32, dest: [*]u32, len: i32) callconv(.c) u32;
        pub extern fn esp_rom_spiflash_write(address: u32, src: [*]const u32, len: i32) callconv(.c) u32;
        pub extern fn esp_rom_spiflash_erase_sector(sector: u32) callconv(.c) u32;
        pub extern fn esp_rom_spiflash_unlock() callconv(.c) u32;
    },
};
