# Makefile for building and testing

PROGNAME = sixforths
FIRMWARE ?= $(PROGNAME).bin
CFLAGS := -g
CROSS ?= /usr/bin/riscv64-unknown-elf-
AS := $(CROSS)as
LD := $(CROSS)ld
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
READELF := $(CROSS)readelf

# MCU and board specific variables
# CH32V006 PORT: the QingKe V2C is RV32EC with the Zmmul (multiply-only)
# extension. rv32ec_zicsr_zmmul needs binutils >= 2.39; on older binutils
# use ARCH=rv32ec_zicsr and swap the single `mul` instruction in
# src/05-internal-functions.s (in `number`) for the commented shift-add
# fallback.
ARCH ?= rv32ec_zicsr_zmmul
EMU ?= elf32lriscv
MCU ?= ch32v006
BOARD ?= ch32v006f8u6

TERMINAL ?= /dev/ttyACM0


.PHONY: clean

build: $(PROGNAME).o $(PROGNAME).elf $(PROGNAME).bin $(PROGNAME).hex $(PROGNAME).dump

# CH32V006 PORT: the pattern rule below only tracks fiveforths.s, but the
# real sources are .include'd -- declare them so edits trigger a rebuild
$(PROGNAME).o: $(wildcard src/*.s) $(wildcard src/mcu/$(MCU)/*.s) $(wildcard src/board/$(BOARD)/*.s)
$(PROGNAME).elf: src/board/$(BOARD)/linker.ld

%.o: %.s
		$(AS) $(CFLAGS) -march=$(ARCH) -I src/board/$(BOARD) -I src/mcu/$(MCU) -I src -o $@ $<

%.elf: %.o
		$(LD) -m $(EMU) -T src/board/$(BOARD)/linker.ld -o $@ $<

%.bin: %.elf
		$(OBJCOPY) -O binary $< $@

%.hex: %.elf
		$(OBJCOPY) -O ihex $< $@

%.dump: %.elf
		$(OBJDUMP) -D -S $< > $@

readelf: $(PROGNAME).elf
		$(READELF) -a $<

# CH32V006 PORT: flash over SDI with a WCH-LinkE using minichlink
# (https://github.com/cnlohr/ch32fun); -b reboots the chip after writing
flash-ch32v006:
		minichlink -w $(FIRMWARE) flash -b

# CH32V006 PORT: serial console via picocom.
# Default device is the WCH-LinkE's own CDC-ACM serial passthrough
# (/dev/ttyACM0); override with TERMINAL=/dev/ttyUSB0 for a CH340.
# --imap lfcrlf: FiveForths transmits bare LF; map to CR+LF for display
# --omap crlf:   picocom sends CR on Enter; FiveForths ignores CR and
#                terminates lines on LF, so map CR -> LF
# --send-cmd:    Ctrl-A Ctrl-S sends a file (e.g. prelude.f) one line at a
#                time with a 100 ms pause: the board does not read the UART
#                while it processes a line (the slowest prelude line ~2 ms)

term:
		picocom -b 115200 --imap lfcrlf --omap crlf --send-cmd "ascii-xfr -sv -l 100" $(TERMINAL)

# CH32V006 PORT: build for the CH32V006F8U6 (this is also the default)
ch32v006f8u6:
		$(MAKE) build BOARD=ch32v006f8u6 MCU=ch32v006 ARCH=rv32ec_zicsr_zmmul

clean:
		rm -v *.bin *.elf *.o *.hex *.dump
