pub const ets_timer = opaque {};
pub const OSI_FUNCS_TIME_BLOCKING = 0xffffffff;
pub const options = struct {
    pub const hal = struct {
        pub const radio = struct {
            pub const radios = struct {
                pub fn coexistence() bool {
                    return true;
                }
            };
        };
        pub const rtos = struct {
            pub const tick_freq = struct {
                pub fn to_us() u32 {
                    return 1_000_000 / 100;
                }
            };
            pub const priority_bits = 4;
            pub const cpu_interrupt = struct {
                pub fn set_pending(pending: bool) void {
                    if (pending) yield_requests += 1;
                }
            };
        };
    };
};
pub const cpu = struct {
    pub const csr = struct {
        pub const mscratch = struct {
            pub fn read_raw() usize {
                return 1;
            }
        };
    };
};
pub const interrupt = struct {
    pub fn enter_critical_section() noreturn {
        unreachable;
    }
};
pub var yield_requests: usize = 0;
pub var bitmap: u32 = 0;
pub fn coex_schm_status_bit_set(kind: u32, bits: u32) void {
    if (kind == 1) bitmap |= bits;
}
pub fn coex_schm_status_bit_clear(kind: u32, bits: u32) void {
    if (kind == 1) bitmap &= ~bits;
}
