##
# Error handling
##

print_error error, 4, reset
# CH32V006 PORT: err_ok is written out by hand instead of via print_error:
# it first commits the completed line (still in the TIB) to the source-replay
# log, then prints ok and continues to tib_init like before.
.balign CELL
err_ok:
    call log_commit     # append/flush the line to the flash log (if enabled)
    la a1, msg_ok       # load string message
    addi a2, a1, 6      # load string length
    call uart_print     # call uart print function
    j tib_init          # jump when print returns
print_error reboot, 16, _start
print_error tib, 14, reset
print_error mem, 16, reset
print_error token, 14, reset
print_error underflow, 20, reset
print_error overflow, 20, reset

msg_error: .ascii "  ?\n"
msg_ok: .ascii "   ok\n"
msg_reboot: .ascii "   ok rebooting\n"
msg_tib: .ascii "   ? tib full\n"
msg_mem: .ascii "  ? memory full\n"
msg_token: .ascii "  ? big token\n"
msg_underflow: .ascii "  ? stack underflow\n"
msg_overflow: .ascii "   ? stack overflow\n"
