/* Linker script for the QEMU check (gdbsim-r5f562n8: 16 MB SDRAM at
   0x01000000; the program is loaded there and runs from RAM). */
ENTRY(_start)
SECTIONS {
  . = 0x01000000;
  .text   : { KEEP(*(.text.start)) *(.text*) }
  .rodata : { *(.rodata*) }
  .init_array : {
    __init_array_start = .;
    KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
    KEEP(*(.init_array))
    __init_array_end = .;
  }
  .data   : { *(.data*) }
  .bss    : { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; }
  __stack = 0x01fffff0;
}
