/* Minimal linker script for the hypervisor's ARM64 VM.
 *
 * Code is loaded at PA 0x40080000 (ELF physical load address).
 * The DTB is at 0x40000000 (RAM base), so we start code above it.
 * Stack grows downward from _stack_top.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x40080000;

    .text : {
        *(.text.boot)
        *(.text .text.*)
    }

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(8) {
        *(.data .data.*)
    }

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    /* 64 KiB stack */
    . = ALIGN(16);
    _stack_bottom = .;
    . = . + 0x10000;
    _stack_top = .;
}
