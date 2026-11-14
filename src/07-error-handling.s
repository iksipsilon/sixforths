##
# Error handling
##

message error,     "  ?\n"
message ok,        "   ok\n"
message reboot,    "   ok rebooting\n"
message tib,       "   ? tib full\n"
message mem,       "  ? memory full\n"
message token,     "  ? big token\n"
message underflow, "  ? stack underflow\n"
message overflow,  "   ? stack overflow\n"

print_error error, reset
# CH32V006 PORT: err_ok is written out by hand instead of via print_error:
# it first commits the completed line (still in the TIB) to the source-replay
# log, then prints ok and continues to tib_init like before.
.balign CELL
err_ok:
    call log_commit     # append/flush the line to the flash log (if enabled)
    print_message ok
    j tib_init          # jump when print returns
print_error reboot, _start
print_error tib, reset
print_error mem, reset
print_error token, reset
print_error underflow, reset
print_error overflow, reset
