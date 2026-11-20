/* Host runner for the unmodified ESP-IDF v5.5.1 PMU implementation.
 * MMIO points at host RAM; eFuse reads are supplied by the fixture inputs. */
#include <stdio.h>
#include <string.h>
#include "esp_private/esp_pmu.h"
#define PMU_instance unused_rom_context
#include IDF_PMU_INIT
#undef PMU_instance

uint32_t get_dslp_dbg(void);
uint32_t get_dslp_lp_dbias(void);
uint32_t fuse_version, fuse_hp, fuse_lp, fuse_dbg, fuse_deep_lp;
static pmu_dev_t regs;
static pmu_hal_context_t hal = { .dev = &regs };
static pmu_sleep_machine_constant_t mc = PMU_SLEEP_MC_DEFAULT();
static pmu_context_t ctx = { .hal = &hal, .mc = &mc };
pmu_context_t *PMU_instance(void) { return &ctx; }
static void word(const char *name, uint32_t mask, uint32_t value) {
    printf("%s %08x %08x\n", name, mask, value & mask);
}
static void init_words(void) {
    const char *modes[] = { "HP_ACTIVE", "HP_MODEM", "HP_SLEEP" };
    char name[80];
    for (pmu_hp_mode_t m = PMU_MODE_HP_ACTIVE; m < PMU_MODE_HP_MAX; ++m) {
        pmu_hp_system_analog_param_t a;
        pmu_hp_system_param_t param = { .analog = &a };
        pmu_hp_system_param_default(m, &param);
        pmu_hp_system_init(&ctx, m, &param);
#define HP_WORD(suffix, member) do { snprintf(name, sizeof name, "%s_%s", modes[m], suffix); word(name, 0xffffffff, regs.hp_sys[m].member); } while (0)
        HP_WORD("DIG_POWER", dig_power.val);
        HP_WORD("HP_CK_POWER", clk_power.val);
        HP_WORD("XTAL", xtal.val);
        HP_WORD("ICG_HP_FUNC", icg_func);
        HP_WORD("ICG_HP_APB", icg_apb);
        HP_WORD("ICG_MODEM", icg_modem.val);
        HP_WORD("SYSCLK", sysclk.val);
        HP_WORD("HP_SYS_CNTL", syscntl.val);
        HP_WORD("BIAS", bias.val);
        HP_WORD("HP_REGULATOR0", regulator0.val);
        HP_WORD("HP_REGULATOR1", regulator1.val);
        HP_WORD("BACKUP", backup.val);
        HP_WORD("BACKUP_CLK", backup_clk);
        word("IMM_MODEM_ICG", 0xffffffff, regs.imm.modem_icg.val);
        word("IMM_SLEEP_SYSCLK", 0xffffffff, regs.imm.sleep_sysclk.val);
        word("SLP_WAKEUP_CNTL3", 0xffffffff, regs.wakeup.cntl3.val);
#undef HP_WORD
    }
    for (pmu_lp_mode_t m = PMU_MODE_LP_ACTIVE; m < PMU_MODE_LP_MAX; ++m) {
        pmu_lp_system_analog_param_t a;
        pmu_lp_system_param_t param = { .analog = &a };
        pmu_lp_system_param_default(m, &param);
        pmu_lp_system_init(&ctx, m, &param);
        const char *prefix = m == PMU_MODE_LP_ACTIVE ? "HP_SLEEP" : "LP_SLEEP";
#define LP_WORD(suffix, member) do { snprintf(name, sizeof name, "%s_%s", prefix, suffix); word(name, 0xffffffff, regs.lp_sys[m].member); } while (0)
        LP_WORD("LP_DIG_POWER", dig_power.val);
        LP_WORD("LP_CK_POWER", clk_power.val);
        word("LP_SLEEP_XTAL", 0xffffffff, regs.lp_sys[PMU_MODE_LP_SLEEP].xtal.val);
        word("LP_SLEEP_BIAS", 0xffffffff, regs.lp_sys[PMU_MODE_LP_SLEEP].bias.val);
        LP_WORD("LP_REGULATOR0", regulator0.val);
        LP_WORD("LP_REGULATOR1", regulator1.val);
#undef LP_WORD
    }
}
int main(int argc, char **argv) {
    if (argc != 10) return 2;
    fuse_version = strtoul(argv[1], 0, 0);
    fuse_hp = strtoul(argv[2], 0, 0);
    fuse_lp = strtoul(argv[3], 0, 0);
    fuse_dbg = strtoul(argv[4], 0, 0);
    fuse_deep_lp = strtoul(argv[5], 0, 0);
    uint32_t slow = strtoul(argv[6], 0, 0), fast = strtoul(argv[7], 0, 0);
    bool deep = atoi(argv[8]), xtal_off = atoi(argv[9]);
    printf("BIAS %u %u %u %u\n", get_act_hp_dbias(), get_act_lp_dbias(), get_dslp_dbg(), get_dslp_lp_dbias() & 31);
    puts("INIT");
    init_words();
    puts("SLEEP");
    memset(&regs, 0, sizeof regs);
    // sleep_modes.c:1262–1265,2573–2628, timer-only default domains.
    uint32_t flags = PMU_SLEEP_PD_MODEM |
        (deep ? PMU_SLEEP_PD_TOP | PMU_SLEEP_PD_CPU | PMU_SLEEP_PD_HP_AON |
                PMU_SLEEP_PD_VDDSDIO | PMU_SLEEP_PD_LP_PERIPH : 0) |
        ((deep || xtal_off) ? PMU_SLEEP_PD_XTAL | PMU_SLEEP_PD_RC_FAST |
                             PMU_SLEEP_PD_XTAL32K | PMU_SLEEP_PD_RC32K : 0);
    pmu_sleep_config_t config;
    uint32_t adjustment = pmu_sleep_calculate_hw_wait_time(flags, 0, slow, fast);
    pmu_sleep_config_default(&config, flags, 0, adjustment, 0, slow, fast, deep);
    pmu_sleep_init(&config, deep);
#define W(name, mask, member) word(name, mask, regs.member)
    W("HP_SLEEP_DIG_POWER", 0xefe00000, hp_sys[2].dig_power.val);
    W("HP_SLEEP_HP_CK_POWER", 0xffffffff, hp_sys[2].clk_power.val);
    W("HP_SLEEP_XTAL", 0x80000000, hp_sys[2].xtal.val);
    W("HP_SLEEP_LP_DIG_POWER", 0xffffffff, lp_sys[0].dig_power.val);
    W("HP_SLEEP_LP_CK_POWER", 0xffffffff, lp_sys[0].clk_power.val);
    W("LP_SLEEP_LP_DIG_POWER", 0xffffffff, lp_sys[1].dig_power.val);
    W("LP_SLEEP_LP_CK_POWER", 0xffffffff, lp_sys[1].clk_power.val);
    W("LP_SLEEP_XTAL", 0x80000000, lp_sys[1].xtal.val);
    W("HP_SLEEP_SYSCLK", 0x08000000, hp_sys[2].sysclk.val);
    W("HP_SLEEP_ICG_HP_FUNC", 0xffffffff, hp_sys[2].icg_func);
    if (!deep) W("HP_SLEEP_HP_SYS_CNTL", 0x08000000, hp_sys[2].syscntl.val);
    W("HP_SLEEP_BIAS", 0xfc000000, hp_sys[2].bias.val);
    W("HP_SLEEP_HP_REGULATOR0", 0xf8040000, hp_sys[2].regulator0.val);
    W("HP_SLEEP_HP_REGULATOR1", 0xffffff00, hp_sys[2].regulator1.val);
    W("LP_SLEEP_BIAS", 0xfc000000, lp_sys[1].bias.val);
    W("LP_SLEEP_LP_REGULATOR0", 0xffe00000, lp_sys[1].regulator0.val);
    W("LP_SLEEP_LP_REGULATOR1", 0xf0000000, lp_sys[1].regulator1.val);
    W("SLP_WAKEUP_CNTL3", 0x0000ffff, wakeup.cntl3.val);
    W("SLP_WAKEUP_CNTL7", 0xffff0000, wakeup.cntl7.val);
    W("SLP_WAKEUP_CNTL5", 0xff0fffff, wakeup.cntl5.val);
    W("POWER_WAIT_TIMER0", 0xffffc000, power.wait_timer0.val);
    W("POWER_WAIT_TIMER1", 0xffff0000, power.wait_timer1.val);
    W("POWER_CK_WAIT_CNTL", 0xffffffff, power.clk_wait.val);
    return 0;
}
