set confirm off
set architecture riscv:rv64
target remote 127.0.0.1:26002
symbol-file zig-out/kernel
set disassemble-next-line auto
set riscv use-compressed-breakpoints yes

layout split
# @panic
b print.panicFn
