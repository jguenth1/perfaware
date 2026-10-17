//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const DecodeError = error{
    /// Reached the end of buffer while decoding an instruction
    IncompleteInstruction,
    UnrecognizedOpCode,
};

const ByteScanner = struct {
    src: []const u8,
    idx: u32,

    fn init(src: []const u8) ByteScanner {
        return ByteScanner{
            .src = src,
            .idx = 0,
        };
    }

    fn has_byte(self: *ByteScanner) bool {
        return self.idx < self.src.len;
    }

    fn peek(self: *ByteScanner) ?u8 {
        if (self.idx >= self.src.len) {
            return null;
        }
        return self.src[self.idx];
    }

    fn pop(self: *ByteScanner) DecodeError!u8 {
        if (self.idx >= self.src.len) {
            return DecodeError.IncompleteInstruction;
        }
        const res = self.src[self.idx];
        self.idx += 1;
        return res;
    }

    fn pop_n(self: *ByteScanner, comptime n: u32) DecodeError!*const [n]u8 {
        if (self.idx + n - 1 >= self.src.len) {
            return DecodeError.IncompleteInstruction;
        }
        const res = self.src[self.idx..self.src.len];
        self.idx += n;
        return res[0..n];
    }
};

pub const Instruction = struct {
    type: InstructionType,
    source: Location,
    target: Location,
};

const Location = union(enum) {
    register: Register,
    immediate: SizedValue,
    memory: SizedValue,

    fn string_representation(self: Location) []const u8 {
        std.debug.assert(self == .register);
        switch (self) {
            .register => |r| return r.string_representation(),
            .immediate => unreachable,
            .memory => unreachable,
        }
    }
};

const SizedValue = union(enum) {
    byte: u8,
    word: u16,
};

pub const InstructionType = enum {
    Mov,

    fn string_representation(self: InstructionType) []const u8 {
        return switch (self) {
            .Mov => "mov",
        };
    }
};

pub const Register = enum(u8) {
    // Byte registers
    al = 0,
    cl,
    dl,
    bl,
    ah,
    ch,
    dh,
    bh,

    // Word (16 bit) register
    ax = 128,
    cx,
    dx,
    bx,
    sp,
    bp,
    si,
    di,

    fn string_representation(self: Register) []const u8 {
        return switch (self) {
            .al => "al",
            .cl => "cl",
            .dl => "dl",
            .bl => "bl",
            .ah => "ah",
            .ch => "ch",
            .dh => "dh",
            .bh => "bh",

            .ax => "ax",
            .cx => "cx",
            .dx => "dx",
            .bx => "bx",
            .sp => "sp",
            .bp => "bp",
            .si => "si",
            .di => "di",
        };
    }
};

const BYTE_REG_START: u8 = @backingInt(Register.al);
const WORD_REG_START: u8 = @backingInt(Register.ax);

pub fn decode_program(data: []const u8, writer: *Io.Writer) !void {
    var scanner: ByteScanner = .init(data);

    var instruction: Instruction = undefined;

    try emit_preeamble(writer);

    while (scanner.peek()) |byte| {
        try decode_instruction(byte, &scanner, &instruction);
        try emit_instruction(writer, &instruction);
    }
}

fn emit_preeamble(writer: *Io.Writer) !void {
    try writer.print("bits 16\n\n", .{});
}

fn emit_instruction(writer: *Io.Writer, instruction: *Instruction) !void {
    const mnemonic = instruction.type.string_representation();
    const source = instruction.source.string_representation();
    const target = instruction.target.string_representation();

    try writer.print("{s} {s}, {s}\n", .{ mnemonic, target, source });
}

fn decode_instruction(leading_byte: u8, scanner: *ByteScanner, instruction: *Instruction) !void {
    switch (leading_byte) {
        0b10001000...0b10001011 => {
            instruction.type = .Mov;
            const bytes = try scanner.pop_n(2);
            mov_register_to_register(bytes, instruction);
        },
        else => {
            return DecodeError.UnrecognizedOpCode;
        },
    }
}

fn mask_bits(input: u8, mask: u8, right_shift: u3) u8 {
    return (input & mask) >> right_shift;
}

fn mov_register_to_register(bytes: *const [2]u8, instruction: *Instruction) void {
    const D_MASK = 0b0000_0010;
    const W_MASK = 0b0000_0001;

    const d_unshifted: u8 = bytes[0] & D_MASK;
    const w_unshifted: u8 = bytes[0] & W_MASK;

    const R_M_MASK = 0b0000_0111;
    const R_M_SHIFT = 0;
    const REG_MASK = 0b0011_1000;
    const REG_SHIFT = 3;
    const MOD_MASK = 0b1100_0000;
    const MOD_SHIFT = 6;

    const r_m = mask_bits(bytes[1], R_M_MASK, R_M_SHIFT);
    const reg = mask_bits(bytes[1], REG_MASK, REG_SHIFT);
    const mod = mask_bits(bytes[1], MOD_MASK, MOD_SHIFT);

    std.debug.assert(mod == 0b0000_0011);

    //std.debug.print("mod: {b}, reg: {b}, r_m: {b}\n", .{ mod, reg, r_m });

    const register_offset = if (w_unshifted > 0) WORD_REG_START else BYTE_REG_START;
    const r_m_register: Register = @fromBackingInt(r_m + register_offset);
    const reg_register: Register = @fromBackingInt(reg + register_offset);

    //std.debug.print("r_m: {any}, reg: {any}\n", .{ r_m_register, reg_register });

    if (d_unshifted > 0) {
        instruction.source = Location{ .register = r_m_register };
        instruction.target = Location{ .register = reg_register };
    } else {
        instruction.source = Location{ .register = reg_register };
        instruction.target = Location{ .register = r_m_register };
    }
}
