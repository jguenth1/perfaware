const std = @import("std");
const Io = std.Io;

const decoder = @import("decoder.zig");
const emulator = @import("emulator.zig");

pub fn disassemble_program(data: []const u8, writer: *Io.Writer) !void {
    var scanner: decoder.ByteScanner = .init(data);

    try emit_preeamble(writer);

    var instruction: decoder.Instruction = undefined;
    while (scanner.peek()) |byte| {
        try decoder.decode_instruction(byte, &scanner, &instruction);
        try instruction.emit(writer);
        try writer.print("\n", .{});
    }
    try writer.flush();
}

//pub fn execute_program(raw_program: []const u8, writer: *Io.Writer) !void {}

fn emit_preeamble(writer: *Io.Writer) !void {
    try writer.print("bits 16\n\n", .{});
}

pub fn emulate_program(raw_program: []const u8, writer: *Io.Writer) !void {
    var scanner: decoder.ByteScanner = .init(raw_program);
    var executor: emulator.Executor = .init();

    // NOTE: if we ever get into PC/jmp stuff, I don't think we'll be able to handle instructions
    // one at a time like this...
    var instruction: decoder.Instruction = undefined;
    while (scanner.peek()) |byte| {
        try decoder.decode_instruction(byte, &scanner, &instruction);
        try instruction.emit(writer);
        try writer.print(" ;", .{});

        const register_snapshot = emulator.snapshot_registers(&executor);
        emulator.execute_instruction(&executor, &instruction);

        try emulator.print_register_diffs(&executor, register_snapshot, writer);
        try writer.print("\n", .{});
        try writer.flush();
    }

    try writer.print("\nFinal registers:\n", .{});
    try executor.print_registers(writer);
}
