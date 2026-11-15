/* CH32V006F8U6 - 62k Flash, 8k SRAM
 *
 * Flash is linked at 0x00000000, matching ch32fun. The QingKe V2 core
 * resets to and executes from the 0x00000000 alias of user flash. Linking
 * at 0x08000000 would break every `la` of an address outside the flash:
 * `la` is auipc-based (PC-relative), so from an alias-space PC it would
 * compute an address 0x08000000 too low, e.g. 0x18002000 for 0x20002000.
 * With ORIGIN = 0 the link base equals the execution base and every
 * la/auipc resolves correctly. (Flashing is unaffected: minichlink writes
 * the raw .bin to flash, which is address-agnostic.)
 */
MEMORY
{
    FLASH (rx)      : ORIGIN = 0x00000000, LENGTH = 16k /* kernel region only: the
        source lines (10k) and the user flash (36k) live above;
        growing the kernel past 16k must fail the link, not eat the lines */
    RAM (xrw)       : ORIGIN = 0x20000000, LENGTH = 8k
}

/* The entry point is the reset handler */
ENTRY(_start);

SECTIONS {
    /* Nothing is placed in RAM: 01-variables-constants.s lays it out from
       RAM_BASE and RAM_SIZE (src/mcu.s), and boot and reset set sp to
       MSP_TOP */

    /* The program code and other data goes into FLASH */
    .text :
    {
        *(.text)           /* .text sections (code) */
        *(.rodata)         /* .rodata sections (constants, strings, etc.) */
    } >FLASH

}
