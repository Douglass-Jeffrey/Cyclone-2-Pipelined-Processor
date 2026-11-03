/* Code: the 8 KB the I-cache preloads.  Data: from 0x10000 in the separate data
   space; .data/.rodata get their values from __data_init (generated, last in .text). */
ENTRY(_start)
MEMORY
{
  CODE (rx)  : ORIGIN = 0x00000, LENGTH = 8K
  DATA (rw)  : ORIGIN = 0x10000, LENGTH = 0x2E000
}
SECTIONS
{
  .text : {
    KEEP(*(.text.start))
    *(.text .text.*)
    KEEP(*(.datainit))
  } > CODE
  .data : {
    __data_start = .;
    *(.srodata .srodata.*) *(.rodata .rodata.*)
    *(.sdata .sdata.*) *(.data .data.*)
    . = ALIGN(4);
    __data_end = .;
  } > DATA
  .bss (NOLOAD) : {
    *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > DATA
  /DISCARD/ : { *(.comment) *(.eh_frame*) *(.note*) *(.riscv.attributes) }
}
