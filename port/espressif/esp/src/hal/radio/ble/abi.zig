//! ESP-IDF v5.5.1 components/bt/controller/esp32c6 and porting/transport.
//! Keep this ABI paired with esp-wifi-sys revision 7623c8d; not IDF v6.
const c = @import("esp-wifi-driver");
pub const Config = c.esp_bt_controller_config_t;
pub const Mbuf = extern struct {
    data: [*]u8,
    flags: u8,
    pkthdr_len: u8,
    len: u16,
    pool: ?*anyopaque,
    next: ?*Mbuf,
};
pub const PacketHeader = extern struct { len: u16, flags: u16, next: ?*anyopaque };
pub extern fn esp_register_ext_funcs(*const ExtFuncs) c_int;
pub extern fn esp_register_npl_funcs(*const anyopaque) c_int;
pub extern fn ble_osi_coex_funcs_register(*const CoexFuncs) c_int;
pub extern fn esp_ble_register_bb_funcs() c_int;
pub extern fn r_ble_controller_init(*Config) c_int;
pub extern fn r_ble_controller_enable(u8) c_int;
pub extern fn r_esp_ble_ll_set_public_addr([*]const u8) c_int;
pub extern fn r_esp_ble_msys_init(u16, u16, u16, u16, u8) c_int;
pub extern fn r_ble_hci_trans_cfg_hs(*const fn ([*]u8, ?*anyopaque) callconv(.c) c_int, ?*anyopaque, *const fn (*Mbuf, ?*anyopaque) callconv(.c) c_int, ?*anyopaque) void;
pub extern fn r_ble_hci_trans_buf_alloc(c_int) ?[*]u8;
pub extern fn r_ble_hci_trans_buf_free([*]u8) void;
pub extern fn r_ble_hci_trans_hs_cmd_tx([*]u8) c_int;
pub extern fn r_ble_hci_trans_hs_acl_tx(*Mbuf) c_int;
pub extern fn r_os_msys_get_pkthdr(u16, u16) ?*Mbuf;
pub extern fn r_os_mbuf_append(*Mbuf, [*]const u8, u16) c_int;
pub extern fn r_os_mbuf_copydata(*const Mbuf, c_int, c_int, [*]u8) c_int;
pub extern fn r_os_mbuf_free_chain(*Mbuf) c_int;
pub extern fn base_stack_initEnv() c_int;
pub extern fn conn_stack_initEnv() c_int;
pub extern fn adv_stack_initEnv() c_int;
pub extern fn extAdv_stack_initEnv() c_int;
pub extern fn sync_stack_initEnv() c_int;
pub extern fn base_stack_enable() c_int;
pub extern fn conn_stack_enable() c_int;
pub extern fn adv_stack_enable() c_int;
pub extern fn extAdv_stack_enable() c_int;
pub extern fn sync_stack_enable() c_int;
pub extern fn bt_bb_v2_init_cmplx(u32) void;
pub extern fn r_filter_duplicate_mode_disable(u32) void;
pub extern fn r_filter_duplicate_mode_enable(u32) void;
pub extern fn r_filter_duplicate_set_ring_list_max_num(u32) void;

pub const ExtFuncs = extern struct {
    version: u32 = 0x20250415,
    intr_alloc: *const fn (c_int, c_int, *const fn (?*anyopaque) callconv(.c) void, ?*anyopaque, *?*anyopaque) callconv(.c) c_int,
    intr_free: *const fn (*?*anyopaque) callconv(.c) c_int,
    malloc: *const fn (usize) callconv(.c) ?*anyopaque,
    free: *const fn (?*anyopaque) callconv(.c) void,
    task_create: *const fn (?*anyopaque, [*c]const u8, u32, ?*anyopaque, u32, ?*anyopaque, u32) callconv(.c) c_int,
    task_delete: *const fn (?*anyopaque) callconv(.c) void,
    assert: *const fn (u32, [*:0]const u8, u32, u32) callconv(.c) void,
    random: *const fn () callconv(.c) u32,
    ecc_key: *const fn ([*]u8, [*]u8) callconv(.c) c_int,
    ecc_dh: *const fn ([*]const u8, [*]const u8, [*]const u8, [*]u8) callconv(.c) c_int,
    reset_modem: *const fn (u8, u8) callconv(.c) void,
    magic: u32 = 0xa5a5a5a5,
};
pub const CoexFuncs = extern struct {
    magic: u32 = 0xfadebead,
    version: u32 = 0x00010006,
    wifi_sleep: ?*const fn (bool) callconv(.c) void = null,
    priority: ?*const fn (*bool, *bool) callconv(.c) c_int = null,
    set: *const fn (u32, u32) callconv(.c) void,
    clear: *const fn (u32, u32) callconv(.c) void,
};
