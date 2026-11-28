//! Host register boundary for HAL tests.
const assert = @import("std").debug.assert;
const Mmio = @import("core").mmio.Mmio;
pub const drivers = @import("drivers");

pub const chip = struct {
    pub const peripherals = struct {
        pub const TIM2 = &tim2;
        pub const PFIC = &pfic;
        pub const RCC = &rcc;
        pub const GPIOA = &gpio_ports[0];
        pub const GPIOB = &gpio_ports[1];
        pub const GPIOC = &gpio_ports[2];
        pub const GPIOD = &gpio_ports[3];
    };
};

pub const hal = struct {
    pub const clocks = struct {
        pub var frequency: u32 = 8_000_000;

        pub fn get_freqs() struct { pclk1: u32, hclk: u32 } {
            return .{ .pclk1 = frequency, .hclk = frequency };
        }
    };
};

pub const cpu = struct {
    pub const riscv_calling_convention: @import("std").builtin.CallingConvention = .auto;
    pub const interrupt = struct {
        pub fn enable(_: enum { TIM2 }) void {}
    };
};

pub const interrupt = struct {
    pub var enabled = true;

    pub fn enter_critical_section() CriticalSection {
        const previous = enabled;
        enabled = false;
        return .{ .previous = previous };
    }

    pub const CriticalSection = struct {
        previous: bool,

        pub fn leave(section: CriticalSection) void {
            enabled = section.previous;
        }
    };
};

const Word = Mmio(u32);
const ConfigRegister = struct {
    raw: u32 = 0,
    writes: usize = 0,

    pub fn write_raw(reg: *ConfigRegister, value: u32) void {
        reg.raw = value;
        reg.writes += 1;
    }
};

const GpioPort = struct {
    CFGLR: ConfigRegister = .{},
    CFGHR: ConfigRegister = .{},
    INDR: Word = .{ .raw = 0 },
    OUTDR: Word = .{ .raw = 0 },
    BSHR: Word = .{ .raw = 0 },
    BCR: Word = .{ .raw = 0 },
};
var gpio_ports: [4]GpioPort = @splat(.{});

var rcc: struct { APB1PCENR: Word = .{ .raw = 0 } } = .{};
var pfic: struct {
    STK_CTLR: Mmio(packed struct(u32) { STE: u1, STIE: u1, STCLK: u1, STRE: u1, padding: u28 = 0 }) = .{ .raw = 0 },
    STK_CNTL: Word = .{ .raw = 0 },
    STK_CNTH: Word = .{ .raw = 0 },
} = .{};

var tim2: struct {
    CTLR1: Mmio(packed struct(u32) { CEN: u1, padding: u31 = 0 }) = .{ .raw = 0 },
    DMAINTENR: Mmio(packed struct(u32) { UIE: u1, padding: u31 = 0 }) = .{ .raw = 0 },
    PSC: Mmio(packed struct(u32) { PSC: u16, padding: u16 = 0 }) = .{ .raw = 0 },
    ATRLR: Word = .{ .raw = 0 },
    SWEVGR: UpdateEvent = .{},
    INTFR: Mmio(packed struct(u32) { UIF: u1, padding: u31 = 0 }) = .{ .raw = 0 },
    CNT: Mmio(packed struct(u32) { CNT: u16, padding: u16 = 0 }) = .{ .raw = 0 },
} = .{};

const UpdateEvent = struct {
    pub fn write(_: *UpdateEvent, event: struct { UG: u1 }) void {
        assert(!interrupt.enabled);
        assert(tim2.CTLR1.read().CEN == 0 and tim2.DMAINTENR.read().UIE == 0);
        if (event.UG == 1) {
            tim2.CNT.raw = 0;
            tim2.INTFR.raw = 1;
        }
    }
};
