OUTPUT_ARCH( "riscv" )

ENTRY( main )

PHDRS {
    block PT_LOAD FLAGS(7);   /* RWX */
}

SECTIONS
{
    . = 0x0;

    .text : {
        *(.text .text.*)
    } :block

    .rodata : { 
        *(.rodata .rodata.*)
    } :block

    .data : {
        *(.sdata .sdata.*)
        *(.data .data.*)
    } :block

    .bss :{
        *(.sbss .sbss.*)
        *(.bss .bss.*)
    } :block
}
