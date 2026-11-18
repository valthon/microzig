const microzig = @import("microzig");
const rom = @import("../rom.zig").functions;
const sector_size = @import("../flash.zig").sector_size;

// TRM v1.4 sections 3.3.3.1-3.3.3.3: cache serves instructions AND data.
// SPI1 CMD.FLASH_RDID and W0.BUF0 are described in ESP32-C3.svd.
// Unlike the ROM descriptor, RDID does not depend on config_param having run.
// All cache-off helpers use scalar arguments and RAM outputs only.
pub noinline fn probe(attach: bool, raw: *u32) linksection(".ram_text") u32 {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const autoload = rom.Cache_Suspend_ICache();
    defer rom.Cache_Resume_ICache(autoload);
    if (attach) rom.esp_rom_spiflash_attach(rom.esp_rom_efuse_get_flash_gpio_info(), false);
    const spi = microzig.chip.peripherals.SPI1;
    // Do not overwrite an in-flight command. Bound both waits even if the
    // peripheral is unavailable; no flash-backed timer calls with cache off.
    var remaining: u32 = 1_000_000;
    while (spi.CMD.raw != 0) {
        remaining -= 1;
        if (remaining == 0) return 2;
    }
    spi.W0.write(.{ .BUF0 = 0 });
    spi.CMD.write(.{ .FLASH_RDID = 1 });
    remaining = 1_000_000;
    while (spi.CMD.raw != 0) {
        remaining -= 1;
        if (remaining == 0) return 2;
    }
    raw.* = spi.W0.read().BUF0;
    return 0;
}

pub noinline fn configure(id: u32, size: u32) linksection(".ram_text") u32 {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const autoload = rom.Cache_Suspend_ICache();
    const rc = rom.esp_rom_spiflash_config_param(id, size, 0x10000, sector_size, 256, 0xffff);
    rom.Cache_Resume_ICache(autoload);
    return rc;
}

pub const Operation = enum { read, write, erase };

// TRM v1.4 sections 3.3.3.1-3.3.3.3: code AND rodata share the flash
// cache. Everything between suspend/resume must stay in RAM/ROM, including
// buffers and callees. noinline prevents this body migrating into flash.
// ROM operations return their own failure/timeout status; do not add a HAL
// timer/log/panic call here, since those can fetch instructions from flash.
pub noinline fn transaction(op: Operation, address: u32, words: *[64]u32, len: i32) linksection(".ram_text") u32 {
    const cs = microzig.interrupt.enter_critical_section();
    defer cs.leave();
    const autoload = rom.Cache_Suspend_ICache();
    var rc: u32 = 0;
    if (op != .read) rc = rom.esp_rom_spiflash_unlock();
    if (rc == 0) {
        // Use branches rather than a switch/jump table in flash rodata.
        if (op == .read) {
            rc = rom.esp_rom_spiflash_read(address, words, len);
        } else if (op == .write) {
            rc = rom.esp_rom_spiflash_write(address, words, len);
        } else {
            rc = rom.esp_rom_spiflash_erase_sector(address / sector_size);
        }
    }
    if (op != .read) rom.Cache_Invalidate_ICache_All();
    rom.Cache_Resume_ICache(autoload);
    return rc;
}
