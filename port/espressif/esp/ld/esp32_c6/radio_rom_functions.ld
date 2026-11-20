/* ESP-IDF v6.0.2 components/esp_rom/esp32c6/ld: unmodified scripts below. */

/* ---- esp32c6.rom.coexist.ld ---- */
/*
 * SPDX-FileCopyrightText: 2022 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
/* ROM function interface esp32c6.rom.coexist.ld for esp32c6
 *
 *
 * Generated from ./target/esp32c6/interface-esp32c6.yml md5sum 06c13e133e0743d09b87aba30d3e213b
 *
 * Compatible with ROM where ECO version equal or greater to 0.
 *
 * THIS FILE WAS AUTOMATICALLY GENERATED. DO NOT EDIT.
 */

/***************************************
 Group rom_coexist
 ***************************************/

/* Functions */
esp_coex_rom_version_get = 0x40000afc;
coex_bt_release = 0x40000b00;
coex_bt_request = 0x40000b04;
coex_core_ble_conn_dyn_prio_get = 0x40000b08;
/*coex_core_event_duration_get = 0x40000b0c;*/
coex_core_pti_get = 0x40000b10;
coex_core_release = 0x40000b14;
coex_core_request = 0x40000b18;
coex_core_status_get = 0x40000b1c;
/*coex_core_timer_idx_get = 0x40000b20;*/
coex_event_duration_get = 0x40000b24;
coex_hw_timer_disable = 0x40000b28;
coex_hw_timer_enable = 0x40000b2c;
coex_hw_timer_set = 0x40000b30;
coex_schm_interval_set = 0x40000b34;
coex_schm_lock = 0x40000b38;
coex_schm_unlock = 0x40000b3c;
/*coex_status_get = 0x40000b40;*/
coex_wifi_release = 0x40000b44;
esp_coex_ble_conn_dynamic_prio_get = 0x40000b48;
/* Data (.data, .bss, .rodata) */
coex_env_ptr = 0x4087ffc4;
coex_pti_tab_ptr = 0x4087ffc0;
coex_schm_env_ptr = 0x4087ffbc;
coexist_funcs = 0x4087ffb8;
g_coa_funcs_p = 0x4087ffb4;
g_coex_param_ptr = 0x4087ffb0;

/* ---- esp32c6.rom.net80211.ld ---- */
/*
 * SPDX-FileCopyrightText: 2022 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
/* ROM function interface esp32c6.rom.net80211.ld for esp32c6
 *
 *
 * Generated from ./target/esp32c6/interface-esp32c6.yml md5sum 06c13e133e0743d09b87aba30d3e213b
 *
 * Compatible with ROM where ECO version equal or greater to 0.
 *
 * THIS FILE WAS AUTOMATICALLY GENERATED. DO NOT EDIT.
 */

/***************************************
 Group rom_net80211
 ***************************************/

/* Functions */
esp_net80211_rom_version_get = 0x40000b4c;
ampdu_dispatch = 0x40000b50;
ampdu_dispatch_all = 0x40000b54;
ampdu_dispatch_as_many_as_possible = 0x40000b58;
ampdu_dispatch_movement = 0x40000b5c;
ampdu_dispatch_upto = 0x40000b60;
chm_is_at_home_channel = 0x40000b64;
/*cnx_node_is_existing = 0x40000b68;*/
/*cnx_node_search = 0x40000b6c;*/
ic_ebuf_recycle_rx = 0x40000b70;
ic_ebuf_recycle_tx = 0x40000b74;
ic_reset_rx_ba = 0x40000b78;
ieee80211_align_eb = 0x40000b7c;
/*ieee80211_ampdu_reorder = 0x40000b80;*/
ieee80211_ampdu_start_age_timer = 0x40000b84;
/*ieee80211_encap_esfbuf = 0x40000b88;*/
ieee80211_is_tx_allowed = 0x40000b8c;
ieee80211_output_pending_eb = 0x40000b90;
/*ieee80211_output_process = 0x40000b94;*/
//ieee80211_set_tx_desc = 0x40000b98;
//sta_input = 0x40000b9c;
wifi_get_macaddr = 0x40000ba0;
wifi_rf_phy_disable = 0x40000ba4;
wifi_rf_phy_enable = 0x40000ba8;
ic_ebuf_alloc = 0x40000bac;
/*ieee80211_classify = 0x40000bb0;*/
ieee80211_copy_eb_header = 0x40000bb4;
ieee80211_recycle_cache_eb = 0x40000bb8;
ieee80211_search_node = 0x40000bbc;
ieee80211_crypto_encap = 0x40000bc0;
/* ieee80211_crypto_decap = 0x40000bc4; */
ieee80211_decap = 0x40000bc8;
wifi_is_started = 0x40000bcc;
ieee80211_gettid = 0x40000bd0;
//ieee80211_encap_esfbuf_htc = 0x40000bd4;
/* Data (.data, .bss, .rodata) */
net80211_funcs = 0x4087ffac;
g_scan = 0x4087ffa8;
g_chm = 0x4087ffa4;
g_ic_ptr = 0x4087ffa0;
g_hmac_cnt_ptr = 0x4087ff9c;
g_tx_cacheq_ptr = 0x4087ff98;
s_netstack_free = 0x4087ff94;
mesh_rxcb = 0x4087ff90;
sta_rxcb = 0x4087ff8c;
g_itwt_fid = 0x4087ff88;

/* ---- esp32c6.rom.phy.ld ---- */
/*
 * SPDX-FileCopyrightText: 2022 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
/* ROM function interface esp32c6.rom.phy.ld for esp32c6
 *
 *
 * Generated from ./target/esp32c6/interface-esp32c6.yml md5sum 06c13e133e0743d09b87aba30d3e213b
 *
 * Compatible with ROM where ECO version equal or greater to 0.
 *
 * THIS FILE WAS AUTOMATICALLY GENERATED. DO NOT EDIT.
 */

/***************************************
 Group rom_phy
 ***************************************/

/* Functions */
phy_param_addr = 0x40001104;
phy_get_romfuncs = 0x40001108;
chip761_phyrom_version = 0x4000110c;
chip761_phyrom_version_num = 0x40001110;
get_rc_dout = 0x40001114;
rc_cal = 0x40001118;
rom_enter_critical_phy = 0x4000111c;
rom_exit_critical_phy = 0x40001120;
rom_set_chan_cal_interp = 0x40001124;
rom_loopback_mode_en = 0x40001128;
rom_bb_bss_cbw40 = 0x4000112c;
abs_temp = 0x40001130;
get_data_sat = 0x40001134;
phy_byte_to_word = 0x40001138;
set_chan_reg = 0x4000113c;
i2c_master_reset = 0x40001140;
rom_set_chan_freq_sw_start = 0x40001144;
freq_module_resetn = 0x40001148;
freq_chan_en_sw = 0x4000114c;
write_chan_freq = 0x40001150;
get_freq_mem_param = 0x40001154;
get_freq_mem_addr = 0x40001158;
bt_txpwr_freq = 0x4000115c;
wr_rf_freq_mem = 0x40001160;
read_rf_freq_mem = 0x40001164;
freq_i2c_mem_write = 0x40001168;
freq_num_get_data = 0x4000116c;
freq_i2c_num_addr = 0x40001170;
freq_i2c_write_set = 0x40001174;
pll_dac_mem_update = 0x40001178;
pll_cap_mem_update = 0x4000117c;
get_rf_freq_cap = 0x40001180;
get_rf_freq_init = 0x40001184;
phy_en_hw_set_freq = 0x40001188;
phy_dis_hw_set_freq = 0x4000118c;
rom_pwdet_sar2_init = 0x40001190;
rom_en_pwdet = 0x40001194;
rom_get_sar_sig_ref = 0x40001198;
rom_pwdet_tone_start = 0x4000119c;
rom_pwdet_wait_idle = 0x400011a0;
rom_read_sar_dout = 0x400011a4;
get_tone_sar_dout = 0x400011a8;
get_fm_sar_dout = 0x400011ac;
txtone_linear_pwr = 0x400011b0;
linear_to_db = 0x400011b4;
get_power_db = 0x400011b8;
meas_tone_pwr_db = 0x400011bc;
pkdet_vol_start = 0x400011c0;
read_sar2_code = 0x400011c4;
get_sar2_vol = 0x400011c8;
get_pll_vol = 0x400011cc;
tx_pwctrl_bg_init = 0x400011d0;
phy_pwdet_always_en = 0x400011d4;
phy_pwdet_onetime_en = 0x400011d8;
esp_tx_state_out_rom = 0x400011dc;
ant_dft_cfg_rom = 0x400011e0;
ant_wifitx_cfg_rom = 0x400011e4;
ant_wifirx_cfg_rom = 0x400011e8;
ant_bttx_cfg_rom = 0x400011ec;
ant_btrx_cfg_rom = 0x400011f0;
phy_chan_dump_cfg_rom = 0x400011f4;
phy_enable_low_rate = 0x400011f8;
phy_disable_low_rate = 0x400011fc;
phy_is_low_rate_enabled = 0x40001200;
phy_dig_reg_backup_rom = 0x40001204;
phy_chan_filt_set_rom = 0x40001208;
phy_rx11blr_cfg = 0x4000120c;
set_cca_rom = 0x40001210;
set_rx_sense_rom = 0x40001214;
rx_gain_force_rom = 0x40001218;
rom_rfpll_set_freq = 0x4000121c;
mhz2ieee = 0x40001220;
chan_to_freq = 0x40001224;
restart_cal = 0x40001228;
write_rfpll_sdm = 0x4000122c;
wait_rfpll_cal_end = 0x40001230;
set_rf_freq_offset = 0x40001234;
set_rfpll_freq = 0x40001238;
set_channel_rfpll_freq = 0x4000123c;
rfpll_cap_correct = 0x40001240;
rfpll_cap_init_cal = 0x40001244;
write_pll_cap = 0x40001248;
read_pll_cap = 0x4000124c;
chip_v7_set_chan_ana = 0x40001250;
freq_set_reg = 0x40001254;
gen_rx_gain_table = 0x40001258;
bt_txdc_cal = 0x4000125c;
bt_txiq_cal = 0x40001260;
txiq_cal_init = 0x40001264;
txdc_cal_init = 0x40001268;
txdc_cal = 0x4000126c;
txiq_get_mis_pwr = 0x40001270;
txiq_cover = 0x40001274;
rfcal_txiq = 0x40001278;
get_power_atten = 0x4000127c;
pwdet_ref_code = 0x40001280;
pwdet_code_cal = 0x40001284;
rfcal_txcap = 0x40001288;
tx_cap_init = 0x4000128c;
rfcal_pwrctrl = 0x40001290;
tx_pwctrl_init_cal = 0x40001294;
tx_pwctrl_init = 0x40001298;
bt_tx_pwctrl_init = 0x4000129c;
rom_i2c_enter_critical = 0x400012a0;
rom_i2c_exit_critical = 0x400012a4;
rom_get_i2c_read_mask = 0x400012a8;
rom_get_i2c_mst0_mask = 0x400012ac;
rom_get_i2c_hostid = 0x400012b0;
rom_chip_i2c_readReg_org = 0x400012b4;
rom_chip_i2c_readReg = 0x400012b8;
rom_chip_i2c_writeReg = 0x400012c0;
rom_set_txcap_reg = 0x400012d0;
i2c_paral_set_mst0 = 0x400012d4;
i2c_paral_set_read = 0x400012d8;
i2c_paral_read = 0x400012dc;
i2c_paral_write = 0x400012e0;
i2c_paral_write_num = 0x400012e4;
i2c_paral_write_mask = 0x400012e8;
i2c_sar2_init_code = 0x400012ec;
rom_pbus_force_mode = 0x400012f0;
rom_pbus_rd_addr = 0x400012f4;
rom_pbus_rd_shift = 0x400012f8;
rom_pbus_force_test = 0x400012fc;
rom_pbus_rd = 0x40001300;
rom_pbus_set_rxgain = 0x40001304;
rom_pbus_xpd_rx_off = 0x40001308;
rom_pbus_xpd_rx_on = 0x4000130c;
rom_pbus_xpd_tx_off = 0x40001310;
rom_pbus_xpd_tx_on = 0x40001314;
rom_set_loopback_gain = 0x40001318;
rom_txcal_debuge_mode = 0x4000131c;
pbus_debugmode = 0x40001320;
pbus_workmode = 0x40001324;
pbus_set_dco = 0x40001328;
txcal_work_mode = 0x4000132c;
rom_start_tx_tone_step = 0x40001330;
rom_stop_tx_tone = 0x40001334;
disable_agc = 0x40001338;
enable_agc = 0x4000133c;
phy_disable_cca = 0x40001340;
phy_enable_cca = 0x40001344;
write_gain_mem = 0x40001348;
bb_bss_cbw40_dig = 0x4000134c;
cbw2040_cfg = 0x40001350;
mac_tx_chan_offset = 0x40001354;
tx_paon_set = 0x40001358;
pwdet_reg_init = 0x4000135c;
i2cmst_reg_init = 0x40001360;
bt_gain_offset = 0x40001364;
fe_reg_init = 0x40001368;
mac_enable_bb = 0x4000136c;
bb_wdg_cfg = 0x40001370;
fe_txrx_reset = 0x40001374;
set_rx_comp = 0x40001378;
agc_reg_init = 0x4000137c;
bb_reg_init = 0x40001380;
open_i2c_xpd = 0x40001384;
txiq_set_reg = 0x40001388;
rxiq_set_reg = 0x4000138c;
set_txclk_en = 0x40001390;
set_rxclk_en = 0x40001394;
bb_wdg_test_en = 0x40001398;
noise_floor_auto_set = 0x4000139c;
read_hw_noisefloor = 0x400013a0;
iq_corr_enable = 0x400013a4;
wifi_agc_sat_gain = 0x400013a8;
phy_bbpll_cal = 0x400013ac;
phy_ant_init = 0x400013b0;
phy_set_bbfreq_init = 0x400013b4;
wifi_fbw_sel = 0x400013b8;
bt_filter_reg = 0x400013bc;
phy_rx_sense_set = 0x400013c0;
tx_state_set = 0x400013c4;
phy_close_pa = 0x400013c8;
phy_freq_correct = 0x400013cc;
set_pbus_reg = 0x400013d0;
wifi_rifs_mode_en = 0x400013d4;
nrx_freq_set = 0x400013d8;
fe_adc_on = 0x400013dc;
phy_force_pwr_index = 0x400013e0;
rom_iq_est_enable = 0x400013e4;
rom_iq_est_disable = 0x400013e8;
rom_bb_gain_index = 0x400013ec;
rom_rfrx_gain_index = 0x400013f0;
dc_iq_est = 0x400013f4;
set_cal_rxdc = 0x400013f8;
rxiq_get_mis = 0x400013fc;
rxiq_cover_mg_mp = 0x40001400;
rfcal_rxiq = 0x40001404;
get_rfcal_rxiq_data = 0x40001408;
get_dco_comp = 0x4000140c;
pbus_rx_dco_cal = 0x40001410;
rxdc_est_min = 0x40001414;
pbus_rx_dco_cal_1step = 0x40001418;
set_lb_txiq = 0x4000141c;
set_rx_gain_cal_iq = 0x40001420;
set_rx_gain_cal_dc = 0x40001424;
spur_reg_write_one_tone = 0x40001428;
spur_cal = 0x4000142c;
spur_coef_cfg = 0x40001430;
tsens_power_up = 0x40001434;
tsens_read_init = 0x40001438;
code_to_temp = 0x4000143c;
tsens_index_to_dac = 0x40001440;
tsens_index_to_offset = 0x40001444;
tsens_dac_cal = 0x40001448;
tsens_code_read = 0x4000144c;
tsens_temp_read = 0x40001450;
temp_to_power = 0x40001454;
get_temp_init = 0x40001458;
txbbgain_to_index = 0x4000145c;
index_to_txbbgain = 0x40001460;
bt_index_to_bb = 0x40001464;
bt_bb_to_index = 0x40001468;
bt_get_tx_gain = 0x4000146c;
dig_gain_check = 0x40001470;
wifi_get_tx_gain = 0x40001474;
wifi_11g_rate_chg = 0x40001478;
bt_chan_pwr_interp = 0x4000147c;
get_rate_fcc_index = 0x40001480;
get_chan_target_power = 0x40001484;
get_tx_gain_value = 0x40001488;
wifi_get_target_power = 0x4000148c;
/* Data (.data, .bss, .rodata) */
phy_param_rom = 0x4087fce8;

/* ---- esp32c6.rom.pp.ld ---- */
/*
 * SPDX-FileCopyrightText: 2022-2024 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */
/* ROM function interface esp32c6.rom.pp.ld for esp32c6
 *
 *
 * Generated from ./target/esp32c6/interface-esp32c6.yml md5sum 06c13e133e0743d09b87aba30d3e213b
 *
 * Compatible with ROM where ECO version equal or greater to 0.
 *
 * THIS FILE WAS AUTOMATICALLY GENERATED. DO NOT EDIT.
 */

/***************************************
 Group rom_pp
 ***************************************/

/* Functions */
esp_pp_rom_version_get = 0x40000bd8;
ppCalTxopRTSThreshold = 0x40000bdc;
RC_GetBlockAckTime = 0x40000be0;
ebuf_list_remove = 0x40000be4;
//esf_buf_alloc = 0x40000be8;
//esf_buf_alloc_dynamic = 0x40000bec;
//esf_buf_recycle = 0x40000bf0;
GetAccess = 0x40000bf4;
hal_mac_is_low_rate_enabled = 0x40000bf8;
hal_mac_tx_get_blockack = 0x40000bfc;
//hal_mac_tx_set_ppdu = 0x40000c00;
ic_get_trc = 0x40000c04;
//ic_mac_deinit = 0x40000c08;
/* ic_mac_init = 0x40000c0c; */
ic_interface_enabled = 0x40000c10;
is_lmac_idle = 0x40000c14;
/*lmacAdjustTimestamp = 0x40000c18;*/
lmacDiscardAgedMSDU = 0x40000c1c;
/*lmacDiscardMSDU = 0x40000c20;*/
/*lmacEndFrameExchangeSequence = 0x40000c24;*/
lmacIsIdle = 0x40000c28;
lmacIsLongFrame = 0x40000c2c;
/*lmacMSDUAged = 0x40000c30;*/
lmacPostTxComplete = 0x40000c34;
lmacProcessAllTxTimeout = 0x40000c38;
lmacProcessCollisions = 0x40000c3c;
//lmacProcessRxSucData = 0x40000c40;
lmacReachLongLimit = 0x40000c44;
lmacReachShortLimit = 0x40000c48;
lmacRecycleMPDU = 0x40000c4c;
lmacRxDone = 0x40000c50;
//lmacSetTxFrame = 0x40000c54;
//lmacTxDone = 0x40000c58;
//lmacTxFrame = 0x40000c5c;
mac_tx_set_duration = 0x40000c60;
//mac_tx_set_plcp0 = 0x40000c64;
//mac_tx_set_plcp1 = 0x40000c68;
mac_tx_set_plcp2 = 0x40000c6c;
/* pm_check_state = 0x40000c70; */
/* pm_disable_dream_timer = 0x40000c74; */
pm_disable_sleep_delay_timer = 0x40000c78;
/*pm_dream = 0x40000c7c;*/
pm_mac_wakeup = 0x40000c80;
pm_mac_sleep = 0x40000c84;
//pm_enable_active_timer = 0x40000c88;
pm_enable_sleep_delay_timer = 0x40000c8c;
pm_local_tsf_process = 0x40000c90;
//pm_set_beacon_filter = 0x40000c94;
/*pm_is_in_wifi_slice_threshold = 0x40000c98;*/
pm_is_waked = 0x40000c9c;
//pm_keep_alive = 0x40000ca0;
/* pm_on_beacon_rx = 0x40000ca4; */
pm_on_data_rx = 0x40000ca8;
//pm_on_tbtt = 0x40000cac;
/* pm_parse_beacon = 0x40000cb0; */
//pm_process_tim = 0x40000cb4;
//pm_rx_beacon_process = 0x40000cb8;
/* pm_rx_data_process = 0x40000cbc; */
//pm_sleep = 0x40000cc0;
pm_sleep_for = 0x40000cc4;
//pm_tbtt_process = 0x40000cc8;
ppAMPDU2Normal = 0x40000ccc;
/* ppAssembleAMPDU = 0x40000cd0; */
ppCalFrameTimes = 0x40000cd4;
ppCalSubFrameLength = 0x40000cd8;
//ppCalTxAMPDULength = 0x40000cdc;
ppCheckTxAMPDUlength = 0x40000ce0;
ppDequeueRxq_Locked = 0x40000ce4;
ppDequeueTxQ = 0x40000ce8;
ppEmptyDelimiterLength = 0x40000cec;
ppEnqueueRxq = 0x40000cf0;
ppEnqueueTxDone = 0x40000cf4;
ppGetTxframe = 0x40000cf8;
//ppMapTxQueue = 0x40000cfc;
//ppProcTxSecFrame = 0x40000d00;
ppProcessRxPktHdr = 0x40000d04;
//ppProcessTxQ = 0x40000d08;
ppRecordBarRRC = 0x40000d0c;
ppRecycleAmpdu = 0x40000d10;
ppRecycleRxPkt = 0x40000d14;
//ppResortTxAMPDU = 0x40000d18;
ppResumeTxAMPDU = 0x40000d1c;
/*ppRxFragmentProc = 0x40000d20;*/
//ppRxPkt = 0x40000d24;
//ppRxProtoProc = 0x40000d28;
ppSearchTxQueue = 0x40000d2c;
ppSearchTxframe = 0x40000d30;
ppSelectNextQueue = 0x40000d34;
ppSubFromAMPDU = 0x40000d38;
//ppTask = 0x40000d3c;
//ppTxPkt = 0x40000d40;
ppTxProtoProc = 0x40000d44;
ppTxqUpdateBitmap = 0x40000d48;
/*pp_coex_tx_request = 0x40000d4c;*/
pp_hdrsize = 0x40000d50;
pp_post = 0x40000d54;
pp_process_hmac_waiting_txq = 0x40000d58;
rcGetAmpduSched = 0x40000d5c;
rcUpdateRxDone = 0x40000d60;
rc_get_trc = 0x40000d64;
rc_get_trc_by_index = 0x40000d68;
rcAmpduLowerRate = 0x40000d6c;
rcampduuprate = 0x40000d70;
rcClearCurAMPDUSched = 0x40000d74;
rcClearCurSched = 0x40000d78;
rcClearCurStat = 0x40000d7c;
/*rcGetSched = 0x40000d80;*/
rcLowerSched = 0x40000d84;
rcSetTxAmpduLimit = 0x40000d88;
rcTxUpdatePer = 0x40000d8c;
rcUpdateAckSnr = 0x40000d90;
/*rcUpdateRate = 0x40000d94;*/
/*rcUpdateTxDone = 0x40000d98;*/
/*rcUpdateTxDoneAmpdu2 = 0x40000d9c;*/
rcUpSched = 0x40000da0;
rssi_margin = 0x40000da4;
rx11NRate2AMPDULimit = 0x40000da8;
TRC_AMPDU_PER_DOWN_THRESHOLD = 0x40000dac;
TRC_AMPDU_PER_UP_THRESHOLD = 0x40000db0;
trc_calc_duration = 0x40000db4;
trc_isTxAmpduOperational = 0x40000db8;
trc_onAmpduOp = 0x40000dbc;
TRC_PER_IS_GOOD = 0x40000dc0;
trc_SetTxAmpduState = 0x40000dc4;
trc_tid_isTxAmpduOperational = 0x40000dc8;
trcAmpduSetState = 0x40000dcc;
//wDevCheckBlockError = 0x40000dd0;
/*wDev_AppendRxBlocks = 0x40000dd4;*/
wDev_DiscardFrame = 0x40000dd8;
wDev_GetNoiseFloor = 0x40000ddc;
wDev_IndicateAmpdu = 0x40000de0;
//wDev_IndicateFrame = 0x40000de4;
wdev_mac_reg_load = 0x40000de8;
wdev_mac_reg_store = 0x40000dec;
wdev_mac_special_reg_load = 0x40000df0;
wdev_mac_special_reg_store = 0x40000df4;
wdev_mac_wakeup = 0x40000df8;
wdev_mac_sleep = 0x40000dfc;
hal_mac_is_dma_enable = 0x40000e00;
//wDev_ProcessFiq = 0x40000e04;
//wDev_ProcessRxSucData = 0x40000e08;
//wdevProcessRxSucDataAll = 0x40000e0c;
wdev_csi_len_align = 0x40000e10;
ppDequeueTxDone_Locked = 0x40000e14;
//ppProcTxDone = 0x40000e18;
//pm_tx_data_done_process = 0x40000e1c;
config_is_cache_tx_buf_enabled = 0x40000e20;
//ppMapWaitTxq = 0x40000e24;
ppProcessWaitingQueue = 0x40000e28;
ppDisableQueue = 0x40000e2c;
pm_allow_tx = 0x40000e30;
//wdev_is_data_in_rxlist = 0x40000e34;
ppProcTxCallback = 0x40000e38;
//mac_tx_set_hesig = 0x40000e3c;
ppCalPreFecPaddingFactor = 0x40000e40;
//mac_tx_set_tb = 0x40000e44;
//mac_tx_set_mplen = 0x40000e48;
hal_get_tsf_timer = 0x40000e4c;
ppTxPktForceWaked = 0x40000e50;
lmacProcessLongFrameSuccess = 0x40000e54;
lmacProcessShortFrameSuccess = 0x40000e58;
//lmacDiscardFrameExchangeSequence = 0x40000e5c;
lmacProcessTBSuccess = 0x40000e60;
/*lmacProcessTxSuccess = 0x40000e64;*/
lmacProcessAckTimeout = 0x40000e68;
//lmacProcessTxComplete = 0x40000e6c;
//ppRemoveHTC = 0x40000e70;
get_estimated_batime = 0x40000e74;
is_use_muedca = 0x40000e78;
//hal_mac_tx_clr_mplen = 0x40000e7c;
//hal_mac_get_txq_state = 0x40000e80;
hal_mac_clr_txq_state = 0x40000e84;
hal_mac_get_txq_complete = 0x40000e88;
ht_get_min_subframe_len = 0x40000e8c;
rx11ACRate2AMPDULimit = 0x40000e90;
pwr_hal_clear_intr_status = 0x40000e94;
pwr_hal_clear_mac_modem_beacon_miss_intr_filter = 0x40000e98;
pwr_hal_clear_mac_modem_rx_beacon_info = 0x40000e9c;
pwr_hal_clear_mac_modem_rx_beacon_miss_counter = 0x40000ea0;
pwr_hal_clear_mac_modem_rx_beacon_sleep_counter = 0x40000ea4;
pwr_hal_clear_mac_modem_state_wakeup_protect_signal = 0x40000ea8;
pwr_hal_get_intr_raw_signal = 0x40000eac;
pwr_hal_get_intr_status = 0x40000eb0;
pwr_hal_get_mac_modem_beacon_miss_limit_exceeded_status = 0x40000eb4;
pwr_hal_get_mac_modem_rx_beacon_location_state = 0x40000eb8;
pwr_hal_get_mac_modem_rx_beacon_valid_state = 0x40000ebc;
pwr_hal_get_mac_modem_state_sleep_limit_exceeded_status = 0x40000ec0;
pwr_hal_set_beacon_filter_abort_disable = 0x40000ec4;
pwr_hal_set_beacon_filter_abort_enable = 0x40000ec8;
pwr_hal_set_beacon_filter_abort_length = 0x40000ecc;
//pwr_hal_set_beacon_filter_broadcast_wakeup_disable = 0x40000ed0;
//pwr_hal_set_beacon_filter_broadcast_wakeup_enable = 0x40000ed4;
pwr_hal_set_beacon_filter_disable = 0x40000ed8;
pwr_hal_set_beacon_filter_enable = 0x40000edc;
pwr_hal_set_beacon_filter_force_dump_disable = 0x40000ee0;
pwr_hal_set_beacon_filter_force_dump_enable = 0x40000ee4;
pwr_hal_set_beacon_filter_force_dump_limit = 0x40000ee8;
pwr_hal_set_beacon_filter_force_sync_disable = 0x40000eec;
pwr_hal_set_beacon_filter_force_sync_enable = 0x40000ef0;
pwr_hal_set_beacon_filter_force_sync_limit = 0x40000ef4;
pwr_hal_set_beacon_filter_frame_crc_state = 0x40000ef8;
pwr_hal_set_beacon_filter_soc_wakeup_and_intr_disable = 0x40000efc;
pwr_hal_set_beacon_filter_soc_wakeup_and_intr_enable = 0x40000f00;
pwr_hal_set_beacon_filter_unicast_wakeup_disable = 0x40000f04;
pwr_hal_set_beacon_filter_unicast_wakeup_enable = 0x40000f08;
pwr_hal_set_lpclk_cycle_time = 0x40000f0c;
pwr_hal_set_lpclk_sync_disable = 0x40000f10;
pwr_hal_set_lpclk_sync_enable = 0x40000f14;
pwr_hal_set_mac_modem_beacon_miss_intr_disable = 0x40000f18;
pwr_hal_set_mac_modem_beacon_miss_intr_enable = 0x40000f1c;
pwr_hal_set_mac_modem_beacon_miss_limit = 0x40000f20;
pwr_hal_set_mac_modem_beacon_miss_limit_exceeded_wakeup_disable = 0x40000f24;
pwr_hal_set_mac_modem_beacon_miss_limit_exceeded_wakeup_enable = 0x40000f28;
pwr_hal_set_mac_modem_beacon_miss_timeout = 0x40000f2c;
pwr_hal_set_mac_modem_state_sleep_limit = 0x40000f30;
pwr_hal_set_mac_modem_state_sleep_limit_exceeded_wakeup_disable = 0x40000f34;
pwr_hal_set_mac_modem_state_sleep_limit_exceeded_wakeup_enable = 0x40000f38;
pwr_hal_set_mac_modem_state_wakeup_protect_disable = 0x40000f3c;
pwr_hal_set_mac_modem_state_wakeup_protect_early_time = 0x40000f40;
pwr_hal_set_mac_modem_state_wakeup_protect_enable = 0x40000f44;
pwr_hal_set_mac_modem_tbtt_auto_period_disable = 0x40000f48;
pwr_hal_set_mac_modem_tbtt_auto_period_enable = 0x40000f4c;
pwr_hal_set_mac_modem_tbtt_auto_period_interval = 0x40000f50;
pwr_hal_set_modem_state_interface = 0x40000f54;
hal_tsf_clear_soc_wakeup_request = 0x40000f58;
tsf_hal_clear_mac_modem_rf_power_state = 0x40000f5c;
tsf_hal_clear_soc_wakeup_request = 0x40000f60;
tsf_hal_get_counter_value = 0x40000f64;
tsf_hal_get_mac_modem_rf_power_state = 0x40000f68;
tsf_hal_get_tbtt_interval = 0x40000f6c;
tsf_hal_get_time = 0x40000f70;
tsf_hal_get_timer_target = 0x40000f74;
tsf_hal_is_tsf_enabled = 0x40000f78;
tsf_hal_map_tbtt_target_to_rx_frame = 0x40000f7c;
tsf_hal_map_tsf_to_bssid = 0x40000f80;
tsf_hal_set_counter_value = 0x40000f84;
tsf_hal_set_modem_wakeup_early_time = 0x40000f88;
tsf_hal_set_rx_beacon_abort_tsf_time_deviation_sync_disable = 0x40000f8c;
tsf_hal_set_rx_beacon_abort_tsf_time_deviation_sync_enable = 0x40000f90;
tsf_hal_set_rx_beacon_fail_tsf_time_deviation_sync_disable = 0x40000f94;
tsf_hal_set_rx_beacon_fail_tsf_time_deviation_sync_enable = 0x40000f98;
tsf_hal_set_rx_beacon_success_tsf_time_deviation_sync_disable = 0x40000f9c;
tsf_hal_set_rx_beacon_success_tsf_time_deviation_sync_enable = 0x40000fa0;
tsf_hal_set_tbtt_disable = 0x40000fa4;
tsf_hal_set_tbtt_early_time = 0x40000fa8;
tsf_hal_set_tbtt_enable = 0x40000fac;
tsf_hal_set_tbtt_interval = 0x40000fb0;
tsf_hal_set_tbtt_intr_disable = 0x40000fb4;
tsf_hal_set_tbtt_intr_enable = 0x40000fb8;
tsf_hal_set_tbtt_modem_wakeup_disable = 0x40000fbc;
tsf_hal_set_tbtt_modem_wakeup_enable = 0x40000fc0;
tsf_hal_set_tbtt_rf_ctrl_disable = 0x40000fc4;
tsf_hal_set_tbtt_rf_ctrl_enable = 0x40000fc8;
tsf_hal_set_tbtt_rf_ctrl_wait_cycles = 0x40000fcc;
tsf_hal_set_tbtt_soc_wakeup_disable = 0x40000fd0;
tsf_hal_set_tbtt_soc_wakeup_enable = 0x40000fd4;
/*tsf_hal_set_tbtt_start_time = 0x40000fd8;*/
tsf_hal_set_time = 0x40000fdc;
tsf_hal_set_timer_disable = 0x40000fe0;
tsf_hal_set_timer_enable = 0x40000fe4;
tsf_hal_set_timer_intr_disable = 0x40000fe8;
tsf_hal_set_timer_intr_enable = 0x40000fec;
tsf_hal_set_timer_modem_wakeup_disable = 0x40000ff0;
tsf_hal_set_timer_modem_wakeup_enable = 0x40000ff4;
tsf_hal_set_timer_rf_ctrl_disable = 0x40000ff8;
tsf_hal_set_timer_rf_ctrl_enable = 0x40000ffc;
tsf_hal_set_timer_rf_ctrl_wait_cycles = 0x40001000;
tsf_hal_set_timer_soc_wakeup_disable = 0x40001004;
tsf_hal_set_timer_soc_wakeup_enable = 0x40001008;
tsf_hal_set_timer_target = 0x4000100c;
tsf_hal_set_tsf_disable = 0x40001010;
tsf_hal_set_tsf_enable = 0x40001014;
tsf_hal_set_tsf_time_deviation = 0x40001018;
tsf_hal_set_tsf_time_deviation_sync_disable = 0x4000101c;
tsf_hal_set_tsf_time_deviation_sync_enable = 0x40001020;
tsf_hal_unmap_tbtt_target_to_rx_frame = 0x40001024;
//ppSelectTxFormat = 0x40001028;
//ppCertSetRate = 0x4000102c;
//ppHEAMPDU2Normal = 0x40001030;
//ppCalTxHEAMPDULength = 0x40001034;
//ppCalTxHESMPDULength = 0x40001038;
//rcGetRate = 0x4000103c;
rcGetDCMMaxRate = 0x40001040;
//rcGetSMPDURate = 0x40001044;
ppDirectRecycleAmpdu = 0x40001048;
//ppCheckTxHEAMPDUlength = 0x4000104c;
//rx11AXRate2AMPDULimit = 0x40001050;
//ppRegressAmpdu = 0x40001054;
//ppCalDeliNum = 0x40001058;
ppAdd2AMPDUTail = 0x4000105c;
esp_test_disable_tx_statistics = 0x40001060;
esp_test_enable_tx_statistics = 0x40001064;
esp_test_clr_tx_statistics = 0x40001068;
esp_test_get_tx_statistics = 0x4000106c;
esp_test_clr_tx_tb_statistics = 0x40001070;
esp_test_get_tx_tb_statistics = 0x40001074;
test_tx_fail_statistics = 0x40001078;
//test_tx_succ_statistics = 0x4000107c;
//esp_test_tx_process_complete = 0x40001080;
//esp_test_tx_process_txq_state = 0x40001084;
esp_test_tx_enab_statistics = 0x40001088;
esp_test_tx_tb_complete = 0x4000108c;
esp_test_tx_count_retry = 0x40001090;
esp_test_tx_count_collision = 0x40001094;
esp_test_tx_count_timeout = 0x40001098;
hal_enable_tx_statistics = 0x4000109c;
test_rx_process_complete_noeb = 0x400010a0;
test_rx_process_complete_retry = 0x400010a4;
esp_test_rx_process_complete = 0x400010a8;
esp_test_clr_rx_statistics = 0x400010ac;
esp_test_get_rx_statistics = 0x400010b0;
test_free_rx_statistics = 0x400010b4;
esp_test_set_rx_error_occurs = 0x400010b8;
esp_test_get_rx_error_occurs = 0x400010bc;
esp_test_clr_rx_error_occurs = 0x400010c0;
esp_test_disable_rx_statistics = 0x400010c4;
esp_test_enable_rx_statistics = 0x400010c8;
hal_enable_rx_statistics = 0x400010cc;
get_user_num = 0x400010d0;
mumimo_spatial_cfg_get_nsts = 0x400010d4;
mumimo_spatial_cfg_get_nsts_tot = 0x400010d8;
test_mumimo_get_heltf_num = 0x400010dc;
test_mimo_update_user_info = 0x400010e0;
test_parse_rx_mu_mimo = 0x400010e4;
test_nonmimo_update_user_info = 0x400010e8;
test_parse_rx_mu_nonmimo = 0x400010ec;
esp_test_rx_parse_mu = 0x400010f0;
esp_test_get_rx_mu_statistics = 0x400010f4;
esp_test_clr_rx_mu_statistics = 0x400010f8;
esp_test_enable_rx_mu_statistics = 0x400010fc;
esp_test_disable_rx_mu_statistics = 0x40001100;
/* Data (.data, .bss, .rodata) */
our_instances_ptr = 0x4004ffe0;
pTxRx = 0x4087ff80;
lmacConfMib_ptr = 0x4087ff7c;
our_wait_eb = 0x4087ff78;
our_tx_eb = 0x4087ff74;
pp_wdev_funcs = 0x4087ff70;
g_osi_funcs_p = 0x4087ff6c;
wDevCtrl_ptr = 0x4087ff68;
g_wdev_last_desc_reset_ptr = 0x4004ffdc;
wDevMacSleep_ptr = 0x4087ff64;
g_lmac_cnt_ptr = 0x4087ff60;
our_controls_ptr = 0x4004ffd8;
pp_sig_cnt_ptr = 0x4087ff5c;
g_eb_list_desc_ptr = 0x4087ff58;
s_fragment_ptr = 0x4087ff54;
if_ctrl_ptr = 0x4087ff50;
g_intr_lock_mux = 0x4087ff4c;
g_wifi_global_lock = 0x4087ff48;
s_wifi_queue = 0x4087ff44;
pp_task_hdl = 0x4087ff40;
s_pp_task_create_sem = 0x4087ff3c;
s_pp_task_del_sem = 0x4087ff38;
g_wifi_menuconfig_ptr = 0x4087ff34;
xphyQueue = 0x4087ff30;
ap_no_lr_ptr = 0x4087ff2c;
rc11BSchedTbl_ptr = 0x4087ff28;
rc11NSchedTbl_ptr = 0x4087ff24;
rcLoRaSchedTbl_ptr = 0x4087ff20;
BasicOFDMSched_ptr = 0x4087ff1c;
trc_ctl_ptr = 0x4087ff18;
g_pm_cnt_ptr = 0x4087ff14;
g_pm_ptr = 0x4087ff10;
g_pm_cfg_ptr = 0x4087ff0c;
g_esp_mesh_quick_funcs_ptr = 0x4087ff08;
g_txop_queue_status_ptr = 0x4087ff04;
g_mac_sleep_en_ptr = 0x4087ff00;
g_mesh_is_root_ptr = 0x4087fefc;
g_mesh_topology_ptr = 0x4087fef8;
g_mesh_init_ps_type_ptr = 0x4087fef4;
g_mesh_is_started_ptr = 0x4087fef0;
g_config_func = 0x4087feec;
g_net80211_tx_func = 0x4087fee8;
g_timer_func = 0x4087fee4;
s_michael_mic_failure_cb = 0x4087fee0;
wifi_sta_rx_probe_req = 0x4087fedc;
g_tx_done_cb_func = 0x4087fed8;
g_per_conn_trc = 0x4087fe8c;
s_encap_amsdu_func = 0x4087fe88;
rx_beacon_count = 0x4087fe84;
rx_beacon_sw_parse = 0x4087fe80;
rx_beacon_hw_parse = 0x4087fe7c;
rx_beacon_tim_count = 0x4087fe78;
rx_beacon_tim_udata = 0x4087fe74;
rx_beacon_tim_udata_bitmap = 0x4087fe70;
rx_beacon_tim_bdata = 0x4087fe6c;
rx_beacon_tim_bdata_bitmapctl = 0x4087fe68;
rx_beacon_tim_bdata_bitmap_trans = 0x4087fe64;
rx_beacon_tim_bdata_bitmap_mbssid_self = 0x4087fe60;
rx_beacon_tim_bdata_bitmap_mbssid_other = 0x4087fe5c;
rx_beacon_dtim_tim = 0x4087fe58;
rx_beacon_dtim_tim_mcast = 0x4087fe54;
amdpu_delay_time_ms = 0x4087fd08;
ampdu_delay_packet = 0x4087fd04;
ampdu_delay = 0x4087fe51;
first_ampdu = 0x4087fe50;
s_ht_ampdu_density_us = 0x4087fd02;
s_ht_ampdu_density = 0x4087fd01;
s_running_phy_type = 0x4087fd00;
complete_ena_tb_seqno = 0x4087fe4c;
complete_ena_tb_final = 0x4087fe48;
complete_ena_tb_count = 0x4087fe44;
s_itwt_state = 0x4087fe40;
g_dbg_interp_tsf = 0x4087fe3c;
g_dbg_interp_tsf_end = 0x4087fe38;
g_dbg_closrf_tsf = 0x4087fe34;
g_dbg_closrf_idx = 0x4087fe30;
g_dbg_closrf_blk = 0x4087fe2c;
s_he_min_len_bytes = 0x4087fdf0;
s_he_dcm_min_len_bytes = 0x4087fdd0;
s_mplen_low_bitmap = 0x4087fdc0;
s_mplen_high_bitmap = 0x4087fdb0;
s_mplen_vi_bitmap = 0x4087fdac;
s_mplen_bk_bitmap = 0x4087fda8;
esp_wifi_cert_tx_mcs = 0x4087fcfc;
esp_wifi_cert_tx_bcc = 0x4087fcf8;
//esp_wifi_cert_tx_ltf = 0x4087fcf4;
//esp_wifi_cert_tx_gi = 0x4087fcf0;
esp_wifi_cert_tx_nss = 0x4087fcec;
esp_test_tx_statistics_aci_bitmap = 0x4087fda4;
esp_test_tx_statistics = 0x4087fd94;
esp_test_tx_tb_statistics = 0x4087fd84;
esp_test_tx_fail_statistics = 0x4087fd24;
esp_test_rx_statistics = 0x4087fd1c;
esp_test_rx_mu_statistics = 0x4087fd18;
esp_test_mu_print_ru_allocation = 0x4087fd14;
sigb_ru_allocation_user_num = 0x4004ffc8;
sigb_common_ru_allocation = 0x4004ff38;
mu_mimo_special_cfg_user_num_2 = 0x4004fee8;
mu_mimo_special_cfg_user_num_3 = 0x4004fe80;
mu_mimo_special_cfg_user_num_4 = 0x4004fe28;
mu_mimo_special_cfg_user_num_5 = 0x4004fdf0;
mu_mimo_special_cfg_user_num_6 = 0x4004fdd0;
mu_mimo_special_cfg_user_num_7 = 0x4004fdc0;
mu_mimo_special_cfg_user_num_8 = 0x4004fdb8;
esp_test_rx_error_occurs = 0x4087fd10;
g_pp_tx_pkt_num = 0x4087fd0c;
he_max_apep_length = 0x4004fd40;
