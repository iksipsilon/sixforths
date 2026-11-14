#!/bin/sh
set -e
AS="riscv64-unknown-elf-as -march=rv32ec_zicsr_zmmul -mabi=ilp32e -I."
LD="riscv64-unknown-elf-ld -m elf32lriscv"
$AS -o fotrh.o fiveforths.s
$LD -T linker.ld -o fotrh.elf fotrh.o
riscv64-unknown-elf-objcopy -O binary fotrh.elf fotrh.bin
riscv64-unknown-elf-size fotrh.elf
