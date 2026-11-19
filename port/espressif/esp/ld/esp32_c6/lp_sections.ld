/* ESP32-C6 TRM v1.2 §§3.3, 3.7.1. Reset PC is +0x80; mtvec is 256-byte aligned.
 * Top 256 bytes: shared mailbox. Next 1024 bytes: descending stack.
 * Mirrors ESP-IDF components/ulp/ld/lp_core_riscv.ld, without LP ROM. */
ENTRY(_start)
MEMORY { LP_RAM (rwx) : ORIGIN = 0x50000000, LENGTH = 16K }
SECTIONS {
    .vectors 0x50000000 : { KEEP(*(.lp_vectors)) } > LP_RAM
    .text 0x50000080 : { KEEP(*(.lp_start)) *(.text .text.*) } > LP_RAM
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > LP_RAM
    .data : {
        microzig_data_start = .;
        *(.data .data.* .sdata .sdata.*)
        microzig_data_end = .;
    } > LP_RAM
    .bss (NOLOAD) : {
        . = ALIGN(4);
        microzig_bss_start = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(4);
        microzig_bss_end = .;
    } > LP_RAM
    __global_pointer$ = microzig_data_start + 0x800;
    __lp_stack_top = 0x50003f00;
    ASSERT(microzig_bss_end <= __lp_stack_top - 1024, "LP image overlaps stack/mailbox")
    ASSERT(SIZEOF(.vectors) == 128, "LP vectors must occupy 128 bytes")
    /DISCARD/ : { *(.eh_frame*) }
}
