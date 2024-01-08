# xv6-zig

This project rewrites the [xv6-riscv](https://github.com/mit-pdos/xv6-riscv) operating system in the Zig programming language, with the goal of learning and practicing systems programming.

## Dependencies

To compile the project, you will need to download the latest master version of the [Zig compiler](https://ziglang.org/download/). To run xv6, you will need `qemu-system-riscv64`. For debugging (optional), you will also need `riscv64-unknown-elf-gdb`, `riscv64-unknown-elf-objdump`, and `addr2line`.

## Compilation Options

You can use `zig build` to fully compiles the project with default settings or use `zig build run` to compiles and runs the project.

When using zig build, there are several options available:

Compilation options:

- `-Doptimize` - specifies the compilation mode
- `-Dstrip` - specifies whether or not to strip the binary

Runtime options:

- `-Dcpus` - specifies the number of cores to simulate with qemu
- `-Dfs-path` - specifies the path to the fs.img

For example, `zig build -Doptimize=ReleaseFast -Dstrip run -Dcpus=1` enables fast optimization, strips the binary after compilation, and sets the simulated core count to one when running qemu.

Other useful commands include:

- `zig build kernel` - compiles only the kernel
- `zig build apps` - compiles all user programs
- `zig build fs` - compiles the filesystem image fs.img
- `zig build qemu` - runs qemu with gdb server for debugging. Run
- `zig build gdb` in another terminal to start debugging.
- `zig build code` - displays the kernel's assembly code
- `zig build addr2line -- [stack address]` - displays the function name corresponding to the given stack address when a kernel panic occurs

You can see more details by running `zig build -h`.

## Project Goal
The ultimate goal of this project is to gradually replace all C files in xv6-riscv with Zig code. Once all C files have been replaced, the operating system should still be able to run successfully.

## Contributing
Contributions to this project are welcome! Feel free to open an issue or submit a pull request if you notice any bugs or if you would like to contribute to the project in any way.

## License
This project is licensed under the MIT license.
