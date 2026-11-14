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
message flash,     "  ? flash\n"

print_error error, reset
print_error ok, tib_init
print_error reboot, _start
print_error tib, reset
print_error mem, reset
print_error token, reset
print_error underflow, reset
print_error overflow, reset
print_error flash, reset
