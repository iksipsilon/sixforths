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

# MCU specific variables (the chip's constants are in src/mcu.s, its
# memory regions in linker.ld)
# The QingKe V2C is RV32EC with the Zmmul (multiply-only) extension.
# rv32ec_zicsr_zmmul needs binutils >= 2.39.
ARCH ?= rv32ec_zicsr_zmmul
EMU ?= elf32lriscv

TERMINAL ?= /dev/ttyACM0


.PHONY: clean

build: $(PROGNAME).o $(PROGNAME).elf $(PROGNAME).bin $(PROGNAME).hex $(PROGNAME).dump

# The pattern rule below only tracks sixforths.s, but the real sources are
# .include'd -- declare them so edits trigger a rebuild
$(PROGNAME).o: $(wildcard src/*.s)
$(PROGNAME).elf: linker.ld

%.o: %.s
		$(AS) $(CFLAGS) -march=$(ARCH) -I src -o $@ $<

%.elf: %.o
		$(LD) -m $(EMU) -T linker.ld -o $@ $<

%.bin: %.elf
		$(OBJCOPY) -O binary $< $@

%.hex: %.elf
		$(OBJCOPY) -O ihex $< $@

%.dump: %.elf
		$(OBJDUMP) -D -S $< > $@

readelf: $(PROGNAME).elf
		$(READELF) -a $<

# Flash over SDI with a WCH-LinkE using minichlink
# (https://github.com/cnlohr/ch32fun); -b reboots the chip after writing
flash-ch32v006:
		minichlink -w $(FIRMWARE) flash -b

# Serial console via picocom.
# Default device is the WCH-LinkE's own CDC-ACM serial passthrough
# (/dev/ttyACM0); override with TERMINAL=/dev/ttyUSB0 for a CH340.
# --imap lfcrlf: the board transmits bare LF; map to CR+LF for display
# --omap crlf:   picocom sends CR on Enter; the board ignores CR and
#                terminates lines on LF, so map CR -> LF
# --send-cmd:    Ctrl-A Ctrl-S sends a file (e.g. prelude.f) one line at a
#                time with a 100 ms pause: the board does not read the UART
#                while it processes a line

term:
		picocom -b 115200 --imap lfcrlf --omap crlf --send-cmd "ascii-xfr -sv -l 100" $(TERMINAL)

clean:
		rm -v *.bin *.elf *.o *.hex *.dump
