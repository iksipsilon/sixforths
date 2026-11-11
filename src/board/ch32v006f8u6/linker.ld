/* CH32V006F8U6 - 62k Flash, 8k SRAM
 *
 * CH32V006 PORT BUGFIX: flash is linked at 0x00000000, matching ch32fun.
 * The QingKe V2 core resets to and executes from the 0x00000000 alias of
 * user flash. Linking at 0x08000000 (as for the GD32V) breaks every
 * PC-relative `la` of an absolute out-of-flash symbol: e.g.
 * `la sp, __stacktop` is auipc-based, so from an alias-space PC it would
 * compute 0x20002000 - 0x08000000 = 0x18002000 -- a nonexistent address --
 * silently destroying the data stack pointer. With ORIGIN = 0 the link
 * base equals the execution base and every la/auipc resolves correctly.
 * (Flashing is unaffected: minichlink writes the raw .bin to flash, which
 * is address-agnostic.)
 */
MEMORY
{
    FLASH (rx)      : ORIGIN = 0x00000000, LENGTH = 16k /* kernel region only: the
        source-replay log (10k), phonebook and SMS slot regions live above;
        growing the kernel past 16k must fail the link, not eat the log */
    RAM (xrw)       : ORIGIN = 0x20000000, LENGTH = 8k
}

/* The entry point is the reset handler */
ENTRY(_start);

SECTIONS {
    __stacktop = ORIGIN(RAM) + LENGTH(RAM);

    /* The program code and other data goes into FLASH */
    .text :
    {
        . = ALIGN(4);
        *(.text)           /* .text sections (code) */
        *(.rodata)         /* .rodata sections (constants, strings, etc.) */
    } >FLASH

}
