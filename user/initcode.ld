OUTPUT_ARCH( "riscv" )
ENTRY( start )

PHDRS {
    code PT_LOAD FLAGS(5);   /* R-X */
}

SECTIONS
{
    . = 0x0;

    .text : {
        .text
    } :code
}
