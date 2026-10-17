const std = @import("std");
const Io = std.Io;

pub const DecodeError = error{
    /// Reached the end of buffer while decoding an instruction
    IncompleteInstruction,
    /// Invalid OR Unimplemented OpCode
    UnrecognizedOpCode,
};

pub fn decode_program(data: []const u8, writer: *Io.Writer) !void {
    var scanner: ByteScanner = .init(data);

    var instruction: Instruction = undefined;

    try emit_preeamble(writer);

    while (scanner.peek()) |byte| {
        try decode_instruction(byte, &scanner, &instruction);
        try instruction.emit(writer);
    }
}

fn decode_instruction(leading_byte: u8, scanner: *ByteScanner, instruction: *Instruction) !void {
    switch (leading_byte) {
        0b1000_1000...0b1000_1011 => {
            instruction.type = .Mov;
            try mov_to_reg(scanner, instruction);
        },
        0b1011_0000...0b1011_1111 => {
            instruction.type = .Mov;
            try mov_imm_to_reg(scanner, instruction);
        },
        else => {
            return DecodeError.UnrecognizedOpCode;
        },
    }
}

fn mask_bits(input: u8, mask: u8, right_shift: u3) u8 {
    return (input & mask) >> right_shift;
}

fn mov_to_reg(scanner: *ByteScanner, instruction: *Instruction) !void {
    const bytes = try scanner.pop_n(2);
    const D_MASK = 0b0000_0010;
    const W_MASK = 0b0000_0001;

    const d: bool = (bytes[0] & D_MASK) > 0;
    const w: bool = (bytes[0] & W_MASK) > 0;

    const R_M_MASK = 0b0000_0111;
    const R_M_SHIFT = 0;
    const REG_MASK = 0b0011_1000;
    const REG_SHIFT = 3;
    const MOD_MASK = 0b1100_0000;
    const MOD_SHIFT = 6;

    const r_m = mask_bits(bytes[1], R_M_MASK, R_M_SHIFT);
    const reg = mask_bits(bytes[1], REG_MASK, REG_SHIFT);
    const mod = mask_bits(bytes[1], MOD_MASK, MOD_SHIFT);

    switch (mod) {
        0b11 => mov_to_reg_from_reg(instruction, d, w, r_m, reg),
        0b00 => try mov_to_reg_from_mem_null_displacement(scanner, instruction, d, w, r_m, reg),
        0b01 => try mov_to_reg_from_mem_with_displacement(scanner, instruction, d, w, r_m, reg, .byte),
        0b10 => try mov_to_reg_from_mem_with_displacement(scanner, instruction, d, w, r_m, reg, .word),
        else => unreachable,
    }
}

fn set_source_target_by_flag(instruction: *Instruction, d: bool, reg: Location, other: Location) void {
    if (d) {
        instruction.source = other;
        instruction.target = reg;
    } else {
        instruction.source = reg;
        instruction.target = other;
    }
}

fn mov_to_reg_from_reg(instruction: *Instruction, d: bool, w: bool, r_m: u8, reg: u8) void {
    const register_offset = if (w) WORD_REG_START else BYTE_REG_START;
    //const r_m_register: Register = @fromBackingInt(r_m + register_offset);
    //const reg_register: Register = @fromBackingInt(reg + register_offset);
    const r_m_location = Location{ .register = @fromBackingInt(r_m + register_offset) };
    const reg_location = Location{ .register = @fromBackingInt(reg + register_offset) };
    set_source_target_by_flag(instruction, d, reg_location, r_m_location);
}

fn mov_to_reg_from_mem_null_displacement(
    scanner: *ByteScanner,
    instruction: *Instruction,
    d: bool,
    w: bool,
    r_m: u8,
    reg: u8,
) !void {
    const register_offset = if (w) WORD_REG_START else BYTE_REG_START;
    const reg_location = Location{ .register = @fromBackingInt(reg + register_offset) };

    var effective_address: Location = undefined;

    // special case -- r/m 110 maps to direct address, not bp
    if (r_m == 0b110) {
        const addr: u16 = std.mem.readInt(u16, try scanner.pop_n(2), .little);
        effective_address = Location{ .address = EffectiveAddress{ .direct_address = addr } };
    } else {
        const register: AddressingRegister = @fromBackingInt(r_m);
        effective_address = Location{ .address = EffectiveAddress{ .register = register } };
    }

    set_source_target_by_flag(instruction, d, reg_location, effective_address);
}

fn scan_byte_or_word(scanner: *ByteScanner, size: ValueSize) !SizedValue {
    return switch (size) {
        .byte => SizedValue{ .byte = try scanner.pop() },
        .word => SizedValue{
            .word = std.mem.readInt(u16, try scanner.pop_n(2), .little),
        },
    };
}

fn mov_to_reg_from_mem_with_displacement(
    scanner: *ByteScanner,
    instruction: *Instruction,
    d: bool,
    w: bool,
    r_m: u8,
    reg: u8,
    size: ValueSize,
) !void {
    const register_offset = if (w) WORD_REG_START else BYTE_REG_START;
    const reg_location = Location{ .register = @fromBackingInt(reg + register_offset) };

    const register: AddressingRegister = @fromBackingInt(r_m);
    const displacement = try scan_byte_or_word(scanner, size);
    const effective_address = Location{
        .address = EffectiveAddress{ .register_displacement = .{
            .register = register,
            .displacement = displacement,
        } },
    };

    set_source_target_by_flag(instruction, d, reg_location, effective_address);
}

fn mov_imm_to_reg(scanner: *ByteScanner, instruction: *Instruction) !void {
    const leading_byte = try scanner.pop();
    const W_MASK = 0b0000_1000;
    const w: bool = leading_byte & W_MASK > 0;

    const REG_MASK = 0b111;
    const REG_SHIFT = 0;
    const reg = mask_bits(leading_byte, REG_MASK, REG_SHIFT);

    const register_offset = if (w) WORD_REG_START else BYTE_REG_START;
    const reg_register: Register = @fromBackingInt(reg + register_offset);

    const size: ValueSize = if (w) .word else .byte;
    const immediate_value = try scan_byte_or_word(scanner, size);

    instruction.target = Location{ .register = reg_register };
    instruction.source = Location{ .immediate = immediate_value };
}

fn emit_preeamble(writer: *Io.Writer) !void {
    try writer.print("bits 16\n\n", .{});
}

pub const Instruction = struct {
    type: InstructionType,
    source: Location,
    target: Location,

    fn emit(self: *Instruction, writer: *Io.Writer) !void {
        try self.type.emit(writer);
        try writer.print(" ", .{});
        try self.target.emit(writer);
        try writer.print(", ", .{});
        try self.source.emit(writer);
        try writer.print("\n", .{});
    }
};

const Location = union(enum) {
    register: Register,
    immediate: SizedValue,
    address: EffectiveAddress,

    fn emit(self: Location, writer: *Io.Writer) !void {
        switch (self) {
            .register => |r| try r.emit(writer),
            .immediate => |i| try i.emit(writer),
            .address => |a| try a.emit(writer),
        }
    }
};

// TODO: come up with better names for these
const ValueSize = enum { byte, word };
const SizedValue = union(ValueSize) {
    byte: u8,
    word: u16,

    fn emit(self: SizedValue, writer: *Io.Writer) !void {
        switch (self) {
            .byte => |b| try writer.print("{d}", .{b}),
            .word => |w| try writer.print("{d}", .{w}),
        }
    }
};

pub const InstructionType = enum {
    Mov,

    fn emit(self: InstructionType, writer: *Io.Writer) !void {
        try writer.print("{s}", .{self.string_representation()});
    }

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

    fn emit(self: Register, writer: *Io.Writer) !void {
        try writer.print("{s}", .{self.string_representation()});
    }

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

pub const AddressingRegister = enum(u8) {
    bx_si = 0,
    bx_di,
    bp_si,
    bp_di,
    si,
    di,
    bp,
    bx,

    fn emit(self: AddressingRegister, writer: *Io.Writer) !void {
        try writer.print("{s}", .{self.string_representation()});
    }

    fn string_representation(self: AddressingRegister) []const u8 {
        return switch (self) {
            .bx_si => "bx + si",
            .bx_di => "bx + di",
            .bp_si => "bp + si",
            .bp_di => "bp + di",
            .si => "si",
            .di => "di",
            .bp => "bp",
            .bx => "bx",
        };
    }
};

pub const EffectiveAddress = union(enum) {
    direct_address: u16,
    register: AddressingRegister,
    register_displacement: struct {
        register: AddressingRegister,
        displacement: SizedValue,
    },

    fn emit(self: EffectiveAddress, writer: *Io.Writer) !void {
        switch (self) {
            .direct_address => |d| try writer.print("[{d}]", .{d}),
            .register => |r| try writer.print("[{s}]", .{r.string_representation()}),
            .register_displacement => |r_d| {
                const register = r_d.register.string_representation();
                const displacement: u16 = switch (r_d.displacement) {
                    .byte => |b| @as(u16, b),
                    .word => |w| w,
                };
                try writer.print("[{s} + {d}]", .{ register, displacement });
            },
        }
    }
};

/// Convenience functions for handling encoded instructions
const ByteScanner = struct {
    src: []const u8,
    idx: u32,

    fn init(src: []const u8) ByteScanner {
        return ByteScanner{
            .src = src,
            .idx = 0,
        };
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

    /// How many bytes we're popping is basically always known at comptime.
    /// Using a comptime-sized return value for this function allows us to catch
    /// some out-of-bounds issues at compile time.
    fn pop_n(self: *ByteScanner, comptime n: u32) DecodeError!*const [n]u8 {
        if (self.idx + n - 1 >= self.src.len) {
            return DecodeError.IncompleteInstruction;
        }
        std.debug.assert(self.idx < self.src.len);
        const res = self.src[self.idx..self.src.len];
        self.idx += n;
        return res[0..n];
    }
};
