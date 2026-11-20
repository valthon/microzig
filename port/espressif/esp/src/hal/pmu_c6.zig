//! ESP-IDF v5.5.1 C6 PMU setup (Apache-2.0, Espressif Systems).
//! References below are relative to components/esp_hw_support/port/esp32c6
//! unless prefixed hal/ or soc/. TRM v1.2 §§12.4.2.1–7, 12.10.1.
const microzig = @import("microzig");
const p = microzig.chip.peripherals;
const pmu = p.PMU;
const std = @import("std");
pub const idf_reference = @import("pmu_c6_idf.zig");

/// Reserved within the LP mailbox, separate from the deep-sleep test's 0xf0.
/// SRAM, not MMIO. LP firmware/loaders must leave these 16 bytes alone.
pub const milestone_address = 0x5000_3fe0;
pub inline fn milestone(byte: u8, address: usize) void {
    const record: *volatile [4]u32 = @ptrFromInt(milestone_address);
    record[1] = @intCast(address);
    record[0] = byte;
    asm volatile ("fence iorw, iorw");
}

pub const Row = struct {
    name: []const u8,
    reg: *volatile microzig.mmio.Mmio(packed struct(u32) { value: u32 }),
    mask: u32,
    value: u32,
    idf: u32,
};

/// Named fields determine the write; an independently transcribed IDF word
/// checks their encoding at compile time, including SVD bit offsets.
pub fn row(comptime device: anytype, comptime name: []const u8, comptime fields: anytype, comptime idf: u32, comptime full: bool) Row {
    const reg = &@field(device, name);
    const T = @TypeOf(reg.*).underlying_type;
    const bits = comptime blk: {
        var v: T = @bitCast(@as(u32, 0));
        var m: T = @bitCast(@as(u32, 0));
        for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field| {
            @field(v, field) = @field(fields, field);
            @field(m, field) = std.math.maxInt(@TypeOf(@field(m, field)));
        }
        const value: u32 = @bitCast(v);
        if (value != idf) @compileError("IDF PMU table mismatch: " ++ name);
        break :blk .{ .value = value, .mask = if (full) 0xffffffff else @as(u32, @bitCast(m)) };
    };
    return .{ .name = name, .reg = @ptrCast(reg), .mask = bits.mask, .value = bits.value, .idf = idf };
}

/// A bounded write plan is also the read-only probe's source. Repeated RMWs
/// use the preceding planned value; no PMU command is executed by the probe.
pub const Plan = struct {
    rows: [128]Row = undefined,
    len: usize = 0,

    pub fn add(self: *Plan, r: Row) void {
        std.debug.assert(self.len < self.rows.len);
        self.rows[self.len] = r;
        self.len += 1;
    }
    pub fn modify(self: *Plan, comptime device: anytype, comptime name: []const u8, fields: anytype, idf: u32) void {
        const reg = &@field(device, name);
        const T = @TypeOf(reg.*).underlying_type;
        var v: T = @bitCast(@as(u32, 0));
        var m: T = @bitCast(@as(u32, 0));
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field| {
            @field(v, field) = @field(fields, field);
            @field(m, field) = std.math.maxInt(@TypeOf(@field(m, field)));
        }
        const value: u32 = @bitCast(v);
        self.add(.{ .name = name, .reg = @ptrCast(reg), .mask = @bitCast(m), .value = value, .idf = idf });
    }
    pub fn write(self: *Plan, comptime device: anytype, comptime name: []const u8, fields: anytype, idf: u32) void {
        self.modify(device, name, fields, idf);
        self.rows[self.len - 1].mask = 0xffffffff;
    }
    pub fn apply(self: *const Plan, byte: u8) void {
        for (self.rows[0..self.len]) |r| {
            milestone(byte, @intFromPtr(r.reg));
            r.reg.write_raw(if (r.mask == 0xffffffff) r.value else (r.reg.raw & ~r.mask) | r.value);
        }
    }
};

pub const Calibration = struct {
    hp: u5,
    lp: u5,
    deep_dbg: u4,
    deep_lp: u5,
    idf: idf_reference.Bias,

    pub fn from_fuses(f: idf_reference.Fuses) Calibration {
        return .{
            .hp = active_dbias(f.version >= 3, f.hp, 25),
            .lp = active_dbias(f.version >= 3, f.lp, 26),
            .deep_dbg = if (f.version >= 3) @as(u4, f.deep_dbg) + 8 else 12,
            .deep_lp = if (f.version >= 3) @truncate(@as(u6, f.deep_lp) + 23) else 23,
            .idf = idf_reference.bias(f),
        };
    }

    pub fn read() Calibration {
        // hal/esp32c6/include/hal/efuse_ll.h:74–116 and efuse_hal.c:28–31.
        // BLK_VERSION_MAJOR here is the system-data version in BLOCK1,
        // not the ADC calibration version exposed by hal.efuse.items.
        const version = p.EFUSE.RD_MAC_SPI_SYS_3.raw;
        const encoding = ((version >> 30) & 3) * 100 + ((version >> 27) & 7);
        const ef = p.EFUSE.RD_MAC_SPI_SYS_2.read();
        return from_fuses(.{
            .version = encoding,
            .hp = ef.ACTIVE_HP_DBIAS,
            .lp = ef.ACTIVE_LP_DBIAS,
            .deep_dbg = ef.DSLP_LP_DBG,
            .deep_lp = ef.DSLP_LP_DBIAS,
        });
    }
};

// pmu_param.c:418–466: nonzero calibrated code + 2, saturated at 31.
fn active_dbias(modern: bool, code: u5, fallback: u5) u5 {
    return if (modern and code != 0) code +| 2 else fallback;
}
comptime {
    std.debug.assert(active_dbias(false, 31, 25) == 25);
    std.debug.assert(active_dbias(true, 0, 26) == 26);
    std.debug.assert(active_dbias(true, 1, 25) == 3);
    std.debug.assert(active_dbias(true, 30, 25) == 31);
}

// pmu_init.c:48–100,114–132. Order is power, clock, digital, analog, retention.
// pmu_param.c:26–324 supplies HP defaults; §§12.4.2.3–7 describe fields.
const init_defaults = [_]Row{
    // pmu_param.c:26; TRM §12.4.2.4.
    row(pmu, "HP_ACTIVE_DIG_POWER", .{ .HP_ACTIVE_PD_HP_CPU_PD_EN = 0x0, .HP_ACTIVE_VDD_SPI_PD_EN = 0x0, .HP_ACTIVE_PD_HP_WIFI_PD_EN = 0x0 }, 0x0, true),
    // pmu_param.c:26; TRM §12.4.2.3.
    row(pmu, "HP_ACTIVE_HP_CK_POWER", .{ .HP_ACTIVE_I2C_ISO_EN = 0x0, .HP_ACTIVE_I2C_RETENTION = 0x0, .HP_ACTIVE_XPD_BB_I2C = 0x1, .HP_ACTIVE_XPD_BBPLL_I2C = 0x1, .HP_ACTIVE_XPD_BBPLL = 0x1 }, 0x70000000, true),
    // pmu_param.c:26; TRM §12.4.2.3.
    row(pmu, "HP_ACTIVE_XTAL", .{ .HP_ACTIVE_XPD_XTAL = 0x1 }, 0x80000000, false),
    // pmu_param.c:103; TRM §12.4.2.5.
    row(pmu, "HP_ACTIVE_ICG_HP_FUNC", .{ .HP_ACTIVE_DIG_ICG_FUNC_EN = 0xffffffff }, 0xffffffff, true),
    // pmu_param.c:103; TRM §12.4.2.5.
    row(pmu, "HP_ACTIVE_ICG_HP_APB", .{ .HP_ACTIVE_DIG_ICG_APB_EN = 0xffffffff }, 0xffffffff, true),
    // pmu_param.c:103; TRM §12.4.2.5.
    row(pmu, "HP_ACTIVE_ICG_MODEM", .{ .HP_ACTIVE_DIG_ICG_MODEM_CODE = 0x2 }, 0x80000000, false),
    // pmu_param.c:103; TRM §12.4.2.5.
    row(pmu, "HP_ACTIVE_SYSCLK", .{ .HP_ACTIVE_DIG_SYS_CLK_NO_DIV = 0x0, .HP_ACTIVE_ICG_SYS_CLOCK_EN = 0x1, .HP_ACTIVE_SYS_CLK_SLP_SEL = 0x0, .HP_ACTIVE_ICG_SLP_SEL = 0x0, .HP_ACTIVE_DIG_SYS_CLK_SEL = 0x0 }, 0x8000000, false),
    // pmu_param.c:159; TRM §12.4.2.7.
    row(pmu, "HP_ACTIVE_HP_SYS_CNTL", .{ .HP_ACTIVE_UART_WAKEUP_EN = 0x0, .HP_ACTIVE_LP_PAD_HOLD_ALL = 0x0, .HP_ACTIVE_HP_PAD_HOLD_ALL = 0x0, .HP_ACTIVE_DIG_PAD_SLP_SEL = 0x0, .HP_ACTIVE_DIG_PAUSE_WDT = 0x0, .HP_ACTIVE_DIG_CPU_STALL = 0x0 }, 0x0, false),
    // pmu_param.c:203; TRM §12.4.2.3.
    row(pmu, "HP_ACTIVE_BIAS", .{ .HP_ACTIVE_XPD_BIAS = 0x1, .HP_ACTIVE_DBG_ATTEN = 0x0, .HP_ACTIVE_PD_CUR = 0x0, .SLEEP = 0x0 }, 0x2000000, false),
    // pmu_param.c:203; TRM §12.4.2.3.
    row(pmu, "HP_ACTIVE_HP_REGULATOR0", .{ .HP_ACTIVE_HP_REGULATOR_SLP_MEM_XPD = 0x0, .HP_ACTIVE_HP_REGULATOR_SLP_LOGIC_XPD = 0x0, .HP_ACTIVE_HP_REGULATOR_XPD = 0x1, .HP_ACTIVE_HP_REGULATOR_SLP_MEM_DBIAS = 0x0, .HP_ACTIVE_HP_REGULATOR_SLP_LOGIC_DBIAS = 0x0, .HP_ACTIVE_HP_REGULATOR_DBIAS = 0x19 }, 0xc8040000, false),
    // pmu_param.c:203; TRM §12.4.2.3.
    row(pmu, "HP_ACTIVE_HP_REGULATOR1", .{ .HP_ACTIVE_HP_REGULATOR_DRV_B = 0x0 }, 0x0, false),
    // pmu_param.c:280; TRM §12.4.2.6.
    row(pmu, "HP_ACTIVE_BACKUP", .{ .HP_SLEEP2ACTIVE_BACKUP_MODEM_CLK_CODE = 0x2, .HP_MODEM2ACTIVE_BACKUP_MODEM_CLK_CODE = 0x2, .HP_MODEM2ACTIVE_BACKUP_CLK_SEL = 0x1, .HP_MODEM2ACTIVE_BACKUP_MODE = 0x2 }, 0x10100a0, true),
    // pmu_param.c:280; TRM §12.4.2.6.
    row(pmu, "HP_ACTIVE_BACKUP_CLK", .{ .HP_ACTIVE_BACKUP_ICG_FUNC_EN = 0xffffffff }, 0xffffffff, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "IMM_MODEM_ICG", .{ .UPDATE_DIG_ICG_MODEM_EN = 0x1 }, 0x80000000, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "IMM_SLEEP_SYSCLK", .{ .UPDATE_DIG_ICG_SWITCH = 0x1 }, 0x10000000, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "SLP_WAKEUP_CNTL3", .{ .SLEEP_PRT_SEL = 0x2 }, 0x20000, false),
    // pmu_param.c:48; TRM §12.4.2.4.
    row(pmu, "HP_MODEM_DIG_POWER", .{ .HP_MODEM_PD_HP_CPU_PD_EN = 0x1, .HP_MODEM_VDD_SPI_PD_EN = 0x0, .HP_MODEM_PD_HP_WIFI_PD_EN = 0x0 }, 0x20000000, true),
    // pmu_param.c:48; TRM §12.4.2.3.
    row(pmu, "HP_MODEM_HP_CK_POWER", .{ .HP_MODEM_I2C_ISO_EN = 0x0, .HP_MODEM_I2C_RETENTION = 0x0, .HP_MODEM_XPD_BB_I2C = 0x1, .HP_MODEM_XPD_BBPLL_I2C = 0x1, .HP_MODEM_XPD_BBPLL = 0x1 }, 0x70000000, true),
    // pmu_param.c:48; TRM §12.4.2.3.
    row(pmu, "HP_MODEM_XTAL", .{ .HP_MODEM_XPD_XTAL = 0x1 }, 0x80000000, false),
    // pmu_param.c:118; TRM §12.4.2.5.
    row(pmu, "HP_MODEM_ICG_HP_FUNC", .{ .HP_MODEM_DIG_ICG_FUNC_EN = 0x100000 }, 0x100000, true),
    // pmu_param.c:118; TRM §12.4.2.5.
    row(pmu, "HP_MODEM_ICG_HP_APB", .{ .HP_MODEM_DIG_ICG_APB_EN = 0x200 }, 0x200, true),
    // pmu_param.c:118; TRM §12.4.2.5.
    row(pmu, "HP_MODEM_ICG_MODEM", .{ .HP_MODEM_DIG_ICG_MODEM_CODE = 0x1 }, 0x40000000, false),
    // pmu_param.c:118; TRM §12.4.2.5.
    row(pmu, "HP_MODEM_SYSCLK", .{ .HP_MODEM_DIG_SYS_CLK_NO_DIV = 0x0, .HP_MODEM_ICG_SYS_CLOCK_EN = 0x1, .HP_MODEM_SYS_CLK_SLP_SEL = 0x1, .HP_MODEM_ICG_SLP_SEL = 0x1, .HP_MODEM_DIG_SYS_CLK_SEL = 0x1 }, 0x78000000, false),
    // pmu_param.c:170; TRM §12.4.2.7.
    row(pmu, "HP_MODEM_HP_SYS_CNTL", .{ .HP_MODEM_UART_WAKEUP_EN = 0x1, .HP_MODEM_LP_PAD_HOLD_ALL = 0x0, .HP_MODEM_HP_PAD_HOLD_ALL = 0x0, .HP_MODEM_DIG_PAD_SLP_SEL = 0x0, .HP_MODEM_DIG_PAUSE_WDT = 0x1, .HP_MODEM_DIG_CPU_STALL = 0x1 }, 0x31000000, false),
    // pmu_param.c:227; TRM §12.4.2.3.
    row(pmu, "HP_MODEM_BIAS", .{ .HP_MODEM_XPD_BIAS = 0x0, .HP_MODEM_DBG_ATTEN = 0x0, .HP_MODEM_PD_CUR = 0x0, .SLEEP = 0x0 }, 0x0, false),
    // pmu_param.c:227; TRM §12.4.2.3.
    row(pmu, "HP_MODEM_HP_REGULATOR0", .{ .HP_MODEM_HP_REGULATOR_SLP_MEM_XPD = 0x0, .HP_MODEM_HP_REGULATOR_SLP_LOGIC_XPD = 0x0, .HP_MODEM_HP_REGULATOR_XPD = 0x1, .HP_MODEM_HP_REGULATOR_SLP_MEM_DBIAS = 0x0, .HP_MODEM_HP_REGULATOR_SLP_LOGIC_DBIAS = 0x0, .HP_MODEM_HP_REGULATOR_DBIAS = 0x19 }, 0xc8040000, false),
    // pmu_param.c:227; TRM §12.4.2.3.
    row(pmu, "HP_MODEM_HP_REGULATOR1", .{ .HP_MODEM_HP_REGULATOR_DRV_B = 0x0 }, 0x0, false),
    // pmu_param.c:297; TRM §12.4.2.6.
    row(pmu, "HP_MODEM_BACKUP", .{ .HP_SLEEP2MODEM_BACKUP_MODEM_CLK_CODE = 0x1, .HP_SLEEP2MODEM_BACKUP_MODE = 0x1 }, 0x100010, true),
    // pmu_param.c:297; TRM §12.4.2.6.
    row(pmu, "HP_MODEM_BACKUP_CLK", .{ .HP_MODEM_BACKUP_ICG_FUNC_EN = 0xffffffff }, 0xffffffff, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "IMM_MODEM_ICG", .{ .UPDATE_DIG_ICG_MODEM_EN = 0x1 }, 0x80000000, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "IMM_SLEEP_SYSCLK", .{ .UPDATE_DIG_ICG_SWITCH = 0x1 }, 0x10000000, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "SLP_WAKEUP_CNTL3", .{ .SLEEP_PRT_SEL = 0x2 }, 0x20000, false),
    // pmu_param.c:70; TRM §12.4.2.4.
    row(pmu, "HP_SLEEP_DIG_POWER", .{ .HP_SLEEP_PD_HP_CPU_PD_EN = 0x0, .HP_SLEEP_VDD_SPI_PD_EN = 0x1, .HP_SLEEP_PD_HP_WIFI_PD_EN = 0x1 }, 0x8200000, true),
    // pmu_param.c:70; TRM §12.4.2.3.
    row(pmu, "HP_SLEEP_HP_CK_POWER", .{ .HP_SLEEP_I2C_ISO_EN = 0x1, .HP_SLEEP_I2C_RETENTION = 0x1, .HP_SLEEP_XPD_BB_I2C = 0x1, .HP_SLEEP_XPD_BBPLL_I2C = 0x0, .HP_SLEEP_XPD_BBPLL = 0x0 }, 0x1c000000, true),
    // pmu_param.c:70; TRM §12.4.2.3.
    row(pmu, "HP_SLEEP_XTAL", .{ .HP_SLEEP_XPD_XTAL = 0x0 }, 0x0, false),
    // pmu_param.c:133; TRM §12.4.2.5.
    row(pmu, "HP_SLEEP_ICG_HP_FUNC", .{ .HP_SLEEP_DIG_ICG_FUNC_EN = 0x0 }, 0x0, true),
    // pmu_param.c:133; TRM §12.4.2.5.
    row(pmu, "HP_SLEEP_ICG_HP_APB", .{ .HP_SLEEP_DIG_ICG_APB_EN = 0x0 }, 0x0, true),
    // pmu_param.c:133; TRM §12.4.2.5.
    row(pmu, "HP_SLEEP_ICG_MODEM", .{ .HP_SLEEP_DIG_ICG_MODEM_CODE = 0x0 }, 0x0, false),
    // pmu_param.c:133; TRM §12.4.2.5.
    row(pmu, "HP_SLEEP_SYSCLK", .{ .HP_SLEEP_DIG_SYS_CLK_NO_DIV = 0x0, .HP_SLEEP_ICG_SYS_CLOCK_EN = 0x0, .HP_SLEEP_SYS_CLK_SLP_SEL = 0x1, .HP_SLEEP_ICG_SLP_SEL = 0x1, .HP_SLEEP_DIG_SYS_CLK_SEL = 0x0 }, 0x30000000, false),
    // pmu_param.c:181; TRM §12.4.2.7.
    row(pmu, "HP_SLEEP_HP_SYS_CNTL", .{ .HP_SLEEP_UART_WAKEUP_EN = 0x1, .HP_SLEEP_LP_PAD_HOLD_ALL = 0x0, .HP_SLEEP_HP_PAD_HOLD_ALL = 0x0, .HP_SLEEP_DIG_PAD_SLP_SEL = 0x1, .HP_SLEEP_DIG_PAUSE_WDT = 0x1, .HP_SLEEP_DIG_CPU_STALL = 0x1 }, 0x39000000, false),
    // pmu_param.c:247; TRM §12.4.2.3.
    row(pmu, "HP_SLEEP_BIAS", .{ .HP_SLEEP_XPD_BIAS = 0x0, .HP_SLEEP_DBG_ATTEN = 0x0, .HP_SLEEP_PD_CUR = 0x0, .SLEEP = 0x0 }, 0x0, false),
    // pmu_param.c:247; TRM §12.4.2.3.
    row(pmu, "HP_SLEEP_HP_REGULATOR0", .{ .HP_SLEEP_HP_REGULATOR_SLP_MEM_XPD = 0x0, .HP_SLEEP_HP_REGULATOR_SLP_LOGIC_XPD = 0x0, .HP_SLEEP_HP_REGULATOR_XPD = 0x1, .HP_SLEEP_HP_REGULATOR_SLP_MEM_DBIAS = 0x0, .HP_SLEEP_HP_REGULATOR_SLP_LOGIC_DBIAS = 0x0, .HP_SLEEP_HP_REGULATOR_DBIAS = 0x1 }, 0x8040000, false),
    // pmu_param.c:247; TRM §12.4.2.3.
    row(pmu, "HP_SLEEP_HP_REGULATOR1", .{ .HP_SLEEP_HP_REGULATOR_DRV_B = 0x0 }, 0x0, false),
    // pmu_param.c:309; TRM §12.4.2.6.
    row(pmu, "HP_SLEEP_BACKUP", .{ .HP_ACTIVE2SLEEP_BACKUP_MODEM_CLK_CODE = 0x2, .HP_MODEM2SLEEP_BACKUP_MODE = 0x5, .HP_ACTIVE2SLEEP_BACKUP_MODE = 0x4 }, 0x12800200, true),
    // pmu_param.c:309; TRM §12.4.2.6.
    row(pmu, "HP_SLEEP_BACKUP_CLK", .{ .HP_SLEEP_BACKUP_ICG_FUNC_EN = 0xffffffff }, 0xffffffff, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "IMM_MODEM_ICG", .{ .UPDATE_DIG_ICG_MODEM_EN = 0x1 }, 0x80000000, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "IMM_SLEEP_SYSCLK", .{ .UPDATE_DIG_ICG_SWITCH = 0x1 }, 0x10000000, true),
    // pmu_init.c:96–100; TRM §12.4.2.5.
    row(pmu, "SLP_WAKEUP_CNTL3", .{ .SLEEP_PRT_SEL = 0x2 }, 0x20000, false),
    // pmu_param.c:339; TRM §12.4.2.4.
    row(pmu, "HP_SLEEP_LP_DIG_POWER", .{ .HP_SLEEP_LP_MEM_DSLP = 0x0, .HP_SLEEP_PD_LP_PERI_PD_EN = 0x0 }, 0x0, true),
    // pmu_param.c:339; TRM §12.4.2.3.
    row(pmu, "HP_SLEEP_LP_CK_POWER", .{ .HP_SLEEP_XPD_XTAL32K = 0x1, .HP_SLEEP_XPD_RC32K = 0x1, .HP_SLEEP_XPD_FOSC_CLK = 0x1, .HP_SLEEP_PD_OSC_CLK = 0x0 }, 0x70000000, true),
    // pmu_param.c:339; TRM §12.4.2.3.
    row(pmu, "LP_SLEEP_XTAL", .{ .LP_SLEEP_XPD_XTAL = 0x0 }, 0x0, false),
    // pmu_param.c:378; TRM §12.4.2.3.
    row(pmu, "LP_SLEEP_BIAS", .{ .LP_SLEEP_XPD_BIAS = 0x0, .LP_SLEEP_DBG_ATTEN = 0x0, .LP_SLEEP_PD_CUR = 0x0, .SLEEP = 0x0 }, 0x0, false),
    // pmu_param.c:378; TRM §12.4.2.3.
    row(pmu, "HP_SLEEP_LP_REGULATOR0", .{ .HP_SLEEP_LP_REGULATOR_SLP_XPD = 0x0, .HP_SLEEP_LP_REGULATOR_XPD = 0x1, .HP_SLEEP_LP_REGULATOR_SLP_DBIAS = 0x0, .HP_SLEEP_LP_REGULATOR_DBIAS = 0x1a }, 0xd0400000, false),
    // pmu_param.c:378; TRM §12.4.2.3.
    row(pmu, "HP_SLEEP_LP_REGULATOR1", .{ .HP_SLEEP_LP_REGULATOR_DRV_B = 0x0 }, 0x0, false),
    // pmu_param.c:352; TRM §12.4.2.4.
    row(pmu, "LP_SLEEP_LP_DIG_POWER", .{ .LP_SLEEP_LP_MEM_DSLP = 0x1, .LP_SLEEP_PD_LP_PERI_PD_EN = 0x0 }, 0x40000000, true),
    // pmu_param.c:352; TRM §12.4.2.3.
    row(pmu, "LP_SLEEP_LP_CK_POWER", .{ .LP_SLEEP_XPD_XTAL32K = 0x0, .LP_SLEEP_XPD_RC32K = 0x0, .LP_SLEEP_XPD_FOSC_CLK = 0x0, .LP_SLEEP_PD_OSC_CLK = 0x0 }, 0x0, true),
    // pmu_param.c:352; TRM §12.4.2.3.
    row(pmu, "LP_SLEEP_XTAL", .{ .LP_SLEEP_XPD_XTAL = 0x0 }, 0x0, false),
    // pmu_param.c:390; TRM §12.4.2.3.
    row(pmu, "LP_SLEEP_BIAS", .{ .LP_SLEEP_XPD_BIAS = 0x0, .LP_SLEEP_DBG_ATTEN = 0x0, .LP_SLEEP_PD_CUR = 0x1, .SLEEP = 0x1 }, 0xc0000000, false),
    // pmu_param.c:390; TRM §12.4.2.3.
    row(pmu, "LP_SLEEP_LP_REGULATOR0", .{ .LP_SLEEP_LP_REGULATOR_SLP_XPD = 0x0, .LP_SLEEP_LP_REGULATOR_XPD = 0x1, .LP_SLEEP_LP_REGULATOR_SLP_DBIAS = 0x0, .LP_SLEEP_LP_REGULATOR_DBIAS = 0xc }, 0x60400000, false),
    // pmu_param.c:390; TRM §12.4.2.3.
    row(pmu, "LP_SLEEP_LP_REGULATOR1", .{ .LP_SLEEP_LP_REGULATOR_DRV_B = 0x0 }, 0x0, false),
};

comptime {
    // All init defaults are checked against IDF's own parameter and LL code,
    // including repeated writes to LP_SLEEP_BIAS during LP initialization.
    std.debug.assert(init_defaults.len == idf_reference.init_words.len);
    for (init_defaults, idf_reference.init_words) |r, expected| {
        std.debug.assert(std.mem.eql(u8, r.name, expected.name));
        std.debug.assert(r.value == expected.value & r.mask);
    }
}

pub fn init_plan(cal: Calibration) Plan {
    var plan: Plan = .{};
    for (init_defaults, 0..) |default, i| {
        var r = default;
        r.idf = idf_reference.init_words[i].value & r.mask;
        if (std.mem.eql(u8, r.name, "HP_ACTIVE_HP_REGULATOR0") or std.mem.eql(u8, r.name, "HP_MODEM_HP_REGULATOR0")) {
            r.value = (r.value & 0x07ff_ffff) | (@as(u32, cal.hp) << 27);
            r.idf = 0x00040000 | (@as(u32, cal.idf.hp) * 0x08000000);
        }
        if (std.mem.eql(u8, r.name, "HP_SLEEP_LP_REGULATOR0")) {
            r.value = (r.value & 0x07ff_ffff) | (@as(u32, cal.lp) << 27);
            r.idf = 0x00400000 | (@as(u32, cal.idf.lp) * 0x08000000);
        }
        plan.add(r);
    }
    // pmu_init.c:135–167. Only FORCE bits: leave masks and memory PU intact.
    plan.add(row(pmu, "POWER_PD_TOP_CNTL", .{ .FORCE_TOP_PU = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_TOP_CNTL", .{ .FORCE_TOP_NO_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_TOP_CNTL", .{ .FORCE_TOP_NO_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_TOP_CNTL", .{ .FORCE_TOP_PD = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_TOP_CNTL", .{ .FORCE_TOP_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_TOP_CNTL", .{ .FORCE_TOP_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPAON_CNTL", .{ .FORCE_HP_AON_PU = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPAON_CNTL", .{ .FORCE_HP_AON_NO_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPAON_CNTL", .{ .FORCE_HP_AON_NO_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPAON_CNTL", .{ .FORCE_HP_AON_PD = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPAON_CNTL", .{ .FORCE_HP_AON_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPAON_CNTL", .{ .FORCE_HP_AON_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPCPU_CNTL", .{ .FORCE_HP_CPU_PU = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPCPU_CNTL", .{ .FORCE_HP_CPU_NO_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPCPU_CNTL", .{ .FORCE_HP_CPU_NO_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPCPU_CNTL", .{ .FORCE_HP_CPU_PD = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPCPU_CNTL", .{ .FORCE_HP_CPU_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPCPU_CNTL", .{ .FORCE_HP_CPU_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPWIFI_CNTL", .{ .FORCE_HP_WIFI_PU = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPWIFI_CNTL", .{ .FORCE_HP_WIFI_NO_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPWIFI_CNTL", .{ .FORCE_HP_WIFI_NO_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPWIFI_CNTL", .{ .FORCE_HP_WIFI_PD = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPWIFI_CNTL", .{ .FORCE_HP_WIFI_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_HPWIFI_CNTL", .{ .FORCE_HP_WIFI_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_MEM_CNTL", .{ .FORCE_HP_MEM_NO_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_LPPERI_CNTL", .{ .FORCE_LP_PERI_PU = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_LPPERI_CNTL", .{ .FORCE_LP_PERI_NO_RESET = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_LPPERI_CNTL", .{ .FORCE_LP_PERI_NO_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_LPPERI_CNTL", .{ .FORCE_LP_PERI_PD = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_LPPERI_CNTL", .{ .FORCE_LP_PERI_ISO = 0 }, 0, false));
    plan.add(row(pmu, "POWER_PD_LPPERI_CNTL", .{ .FORCE_LP_PERI_RESET = 0 }, 0, false));
    return plan;
}

pub const SleepDomains = idf_reference.SleepDomains;

pub fn sleep_plan(cal: Calibration, periods: @import("clocks/sleep_c6.zig").Periods, deep: bool, domains: SleepDomains) error{UnsupportedClock}!Plan {
    return sleep_plan_for_clock(cal, periods, deep, p.LP_CLKRST.LP_CLK_CONF.read().FAST_CLK_SEL != 0, domains);
}

/// Pure plan construction, also exercised on the host with generated registers.
pub fn sleep_plan_for_clock(cal: Calibration, periods: @import("clocks/sleep_c6.zig").Periods, deep: bool, lp_fast_xtal: bool, domains: SleepDomains) error{UnsupportedClock}!Plan {
    var plan: Plan = .{};
    const keep_xtal = !deep and !domains.power_down_xtal;
    // TRM §§8.2.4.2,12.4.2.3,12.4.2.5: HP-state waits use LP_FAST.
    // Never reproduce IDF's post-copy xpd_xtal assignment (pmu_sleep.c:273).
    if (!keep_xtal and lp_fast_xtal) return error.UnsupportedClock;
    const keep_fast = domains.lp_core or keep_xtal;
    const xtal32k = keep_xtal or domains.slow_source == 1;
    const rc32k = keep_xtal or domains.slow_source == 2;
    // pmu_sleep.c:285–297; pmu_param.h:272–319.
    // IDF sleep_modes.c:1262–1265,2573–2628: deep drops flash and LP
    // peripherals/oscillators unless a selected wake source requires them.
    plan.modify(pmu, "HP_SLEEP_DIG_POWER", .{
        .HP_SLEEP_VDD_SPI_PD_EN = @intFromBool(deep),
        .HP_SLEEP_HP_MEM_DSLP = @as(u1, 0),
        .HP_SLEEP_PD_HP_MEM_PD_EN = @as(u4, 0),
        .HP_SLEEP_PD_HP_WIFI_PD_EN = @as(u1, 1),
        .HP_SLEEP_PD_HP_CPU_PD_EN = @intFromBool(deep),
        .HP_SLEEP_PD_HP_AON_PD_EN = @intFromBool(deep),
        .HP_SLEEP_PD_TOP_PD_EN = @intFromBool(deep),
    }, idf_reference.sleep_word("HP_SLEEP_DIG_POWER", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.add(row(pmu, "HP_SLEEP_HP_CK_POWER", .{ .HP_SLEEP_I2C_ISO_EN = 1, .HP_SLEEP_I2C_RETENTION = 1, .HP_SLEEP_XPD_BB_I2C = 0, .HP_SLEEP_XPD_BBPLL_I2C = 0, .HP_SLEEP_XPD_BBPLL = 0 }, 0x0c000000, true));
    plan.modify(pmu, "HP_SLEEP_XTAL", .{ .HP_SLEEP_XPD_XTAL = @intFromBool(keep_xtal) }, idf_reference.sleep_word("HP_SLEEP_XTAL", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.add(row(pmu, "HP_SLEEP_LP_DIG_POWER", .{ .HP_SLEEP_LP_MEM_DSLP = 0, .HP_SLEEP_PD_LP_PERI_PD_EN = 0 }, 0, true));
    plan.write(pmu, "HP_SLEEP_LP_CK_POWER", .{ .HP_SLEEP_XPD_XTAL32K = @intFromBool(xtal32k), .HP_SLEEP_XPD_RC32K = @intFromBool(rc32k), .HP_SLEEP_XPD_FOSC_CLK = @as(u1, 1), .HP_SLEEP_PD_OSC_CLK = @as(u1, 0) }, idf_reference.sleep_word("HP_SLEEP_LP_CK_POWER", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.write(pmu, "LP_SLEEP_LP_DIG_POWER", .{ .LP_SLEEP_LP_MEM_DSLP = @as(u1, 1), .LP_SLEEP_PD_LP_PERI_PD_EN = @intFromBool(deep and !domains.lp_core) }, idf_reference.sleep_word("LP_SLEEP_LP_DIG_POWER", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.write(pmu, "LP_SLEEP_LP_CK_POWER", .{ .LP_SLEEP_XPD_XTAL32K = @intFromBool(xtal32k), .LP_SLEEP_XPD_RC32K = @intFromBool(rc32k), .LP_SLEEP_XPD_FOSC_CLK = @intFromBool(keep_fast), .LP_SLEEP_PD_OSC_CLK = @as(u1, 0) }, idf_reference.sleep_word("LP_SLEEP_LP_CK_POWER", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.modify(pmu, "LP_SLEEP_XTAL", .{ .LP_SLEEP_XPD_XTAL = @intFromBool(keep_xtal) }, idf_reference.sleep_word("LP_SLEEP_XTAL", cal.idf, periods.slow, periods.fast, deep, domains).value);
    // pmu_sleep.c:299–306; no peripheral retention and clk_flags=0.
    plan.modify(pmu, "HP_SLEEP_SYSCLK", .{ .HP_SLEEP_ICG_SYS_CLOCK_EN = @as(u1, 0) }, idf_reference.sleep_word("HP_SLEEP_SYSCLK", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.add(row(pmu, "HP_SLEEP_ICG_HP_FUNC", .{ .HP_SLEEP_DIG_ICG_FUNC_EN = 0 }, 0, true));
    if (!deep) plan.modify(pmu, "HP_SLEEP_HP_SYS_CNTL", .{ .HP_SLEEP_DIG_PAD_SLP_SEL = @as(u1, 1) }, idf_reference.sleep_word("HP_SLEEP_HP_SYS_CNTL", cal.idf, periods.slow, periods.fast, deep, domains).value);
    // pmu_sleep.c:244–279,308–326; pmu_param.h:349–399.
    // XTAL-kept light sleep selects active biases, not the 0.6/0.7 V codes.
    plan.modify(pmu, "HP_SLEEP_BIAS", .{ .HP_SLEEP_DBG_ATTEN = @as(u4, 0), .HP_SLEEP_PD_CUR = @intFromBool(!keep_xtal), .SLEEP = @intFromBool(!keep_xtal) }, idf_reference.sleep_word("HP_SLEEP_BIAS", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.modify(pmu, "HP_SLEEP_HP_REGULATOR0", .{ .HP_SLEEP_HP_REGULATOR_XPD = @intFromBool(!deep), .HP_SLEEP_HP_REGULATOR_DBIAS = if (!deep and keep_fast) cal.hp else if (deep) @as(u5, 0) else @as(u5, 1) }, idf_reference.sleep_word("HP_SLEEP_HP_REGULATOR0", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.add(row(pmu, "HP_SLEEP_HP_REGULATOR1", .{ .HP_SLEEP_HP_REGULATOR_DRV_B = 0 }, 0, false));
    plan.modify(pmu, "LP_SLEEP_BIAS", .{ .LP_SLEEP_DBG_ATTEN = if (deep) cal.deep_dbg else @as(u4, 0), .LP_SLEEP_PD_CUR = @intFromBool(!keep_xtal), .SLEEP = @intFromBool(!keep_xtal) }, idf_reference.sleep_word("LP_SLEEP_BIAS", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.modify(pmu, "LP_SLEEP_LP_REGULATOR0", .{ .LP_SLEEP_LP_REGULATOR_SLP_XPD = @as(u1, 0), .LP_SLEEP_LP_REGULATOR_XPD = @as(u1, 1), .LP_SLEEP_LP_REGULATOR_SLP_DBIAS = @as(u4, 0), .LP_SLEEP_LP_REGULATOR_DBIAS = if (deep) cal.deep_lp else if (keep_fast) cal.lp else @as(u5, 12) }, idf_reference.sleep_word("LP_SLEEP_LP_REGULATOR0", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.add(row(pmu, "LP_SLEEP_LP_REGULATOR1", .{ .LP_SLEEP_LP_REGULATOR_DRV_B = 0 }, 0, false));
    // pmu_sleep.c:196–215,328–342; pmu_param.h:461–490.
    // rtc_time_us_to_slowclk truncates Q13.19 division. TRM §12.4.2.5:
    // HP states use LP_FAST, LP_SLEEP uses LP_SLOW. XTAL-off requires RC_FAST.
    const cycles = @import("clocks/sleep_c6.zig").Periods.cycles;
    const min = cycles(periods.slow, 450);
    const lp_analog = cycles(periods.slow, if (deep) 500 else 154);
    const hp_analog = cycles(periods.fast, 154);
    const power = cycles(periods.fast, 2);
    const pll = cycles(periods.fast, 50);
    // pmu_sleep.c:209–212: XTAL-off startup is timed by RC_FAST.
    const xtal = cycles(if (keep_xtal) periods.slow else periods.fast, 250);
    // No modem wake source; adjustment equals HW wait (relative timer armed
    // after setup). IDF's remaining modem interval is 278+124+450+70 us.
    // pmu_sleep.c:201–204: adjustment - hw_wait cancels for this
    // raw-tick profile. PMU_SLEEP_MC_DEFAULT (pmu_param.h:463–483):
    const regdma_m2a_us = 278;
    const system_dfs_up_us = 124;
    const lp_min_sleep_us = 450;
    const regdma_rf_on_us = 70;
    const modem = cycles(periods.fast, regdma_m2a_us + system_dfs_up_us + lp_min_sleep_us + regdma_rf_on_us);
    if (min > 255 or lp_analog > 255 or hp_analog > 65535 or power > 127 or pll > 65535 or xtal > 65535 or modem > 0xfffff)
        return error.UnsupportedClock;
    plan.modify(pmu, "SLP_WAKEUP_CNTL3", .{ .HP_MIN_SLP_VAL = @as(u8, @intCast(min)), .LP_MIN_SLP_VAL = @as(u8, @intCast(min)) }, idf_reference.sleep_word("SLP_WAKEUP_CNTL3", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.modify(pmu, "SLP_WAKEUP_CNTL7", .{ .ANA_WAIT_TARGET = @as(u16, @intCast(hp_analog)) }, idf_reference.sleep_word("SLP_WAKEUP_CNTL7", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.modify(pmu, "SLP_WAKEUP_CNTL5", .{ .LP_ANA_WAIT_TARGET = @as(u8, @intCast(lp_analog)), .MODEM_WAIT_TARGET = @as(u20, @intCast(modem)) }, idf_reference.sleep_word("SLP_WAKEUP_CNTL5", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.modify(pmu, "POWER_WAIT_TIMER0", .{ .DG_HP_POWERUP_TIMER = @as(u9, @intCast(power)), .DG_HP_WAIT_TIMER = @as(u9, @intCast(power)) }, idf_reference.sleep_word("POWER_WAIT_TIMER0", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.modify(pmu, "POWER_WAIT_TIMER1", .{ .DG_LP_POWERUP_TIMER = @as(u7, @intCast(power)), .DG_LP_WAIT_TIMER = @as(u9, @intCast(power)) }, idf_reference.sleep_word("POWER_WAIT_TIMER1", cal.idf, periods.slow, periods.fast, deep, domains).value);
    plan.modify(pmu, "POWER_CK_WAIT_CNTL", .{ .WAIT_XTL_STABLE = @as(u16, @intCast(xtal)), .WAIT_PLL_STABLE = @as(u16, @intCast(pll)) }, idf_reference.sleep_word("POWER_CK_WAIT_CNTL", cal.idf, periods.slow, periods.fast, deep, domains).value);
    return plan;
}

comptime {
    // Independent reference arithmetic for 150 kHz slow / 20 MHz fast.
    // IDF pmu_sleep.c:196–215 and pmu_param.h:461–490.
    const cycles = @import("clocks/sleep_c6.zig").Periods.cycles;
    std.debug.assert(cycles(3495253, 450) == 67);
    std.debug.assert(cycles(3495253, 154) == 23);
    std.debug.assert(cycles(26214, 154) == 3080);
    std.debug.assert(cycles(26214, 2) == 40);
    std.debug.assert(cycles(26214, 50) == 1000);
}
