const std = @import("std");
const Io = std.Io;

pub const DecodeError = error{
    /// Reached the end of buffer while decoding an instruction
    IncompleteInstruction,
    /// Invalid OR Unimplemented OpCode
    UnrecognizedOpCode,
};

pub fn decode_instruction(leading_byte: u8, scanner: *ByteScanner, instruction: *Instruction) !void {
    switch (leading_byte) {
        0b0111_0000...0b0111_1111 => {
            const lookup_index = leading_byte & 0b1111;
            instruction.type = @fromBackingInt(lookup_index + JUMP_INSTRUCTION_OFFSET);
            try read_label(scanner, instruction);
        },
        0b1110_0000...0b1110_1111 => {
            const lookup_index = leading_byte & 0b11;
            instruction.type = @fromBackingInt(lookup_index + LOOP_INSTRUCTION_OFFSET);
            try read_label(scanner, instruction);
        },
        0b100010_00...0b100010_11 => {
            instruction.type = .mov;
            try reg_mem_to_reg(scanner, instruction);
        },
        0b1011_0000...0b1011_1111 => {
            instruction.type = .mov;
            try mov_imm_to_reg(scanner, instruction);
        },
        0b1100011_0...0b1100011_1 => {
            instruction.type = .mov;
            try mov_imm_to_effective_address(scanner, instruction);
        },
        0b101000_00...0b101000_11 => {
            instruction.type = .mov;
            try mem_to_from_acc(scanner, instruction);
        },
        0b000000_00...0b000000_11 => {
            instruction.type = .add;
            try reg_mem_to_reg(scanner, instruction);
        },
        0b0000010_0...0b0000010_1 => {
            instruction.type = .add;
            try imm_to_acc(scanner, instruction);
        },
        0b100000_00...0b100000_11 => {
            try arith_imm_to_reg_addr(scanner, instruction);
        },
        0b001010_00...0b001010_11 => {
            instruction.type = .sub;
            try reg_mem_to_reg(scanner, instruction);
        },
        0b0010110_0...0b0010110_1 => {
            instruction.type = .sub;
            try imm_to_acc(scanner, instruction);
        },
        0b001110_00...0b001110_11 => {
            instruction.type = .cmp;
            try reg_mem_to_reg(scanner, instruction);
        },
        0b0011110_0...0b0011110_1 => {
            instruction.type = .cmp;
            try imm_to_acc(scanner, instruction);
        },
        else => {
            return DecodeError.UnrecognizedOpCode;
        },
    }
}

fn read_label(scanner: *ByteScanner, instruction: *Instruction) !void {
    _ = try scanner.pop();

    const label = try scan_byte_or_word(scanner, .byte);
    instruction.target = Location{
        .immediate = label,
    };
}

fn mask_bits(input: u8, mask: u8, right_shift: u3) u8 {
    return (input & mask) >> right_shift;
}

// TODO: replace this with a packed struct?
fn scan_mod_reg_r_m(byte: u8) struct { u8, u8, u8 } {
    const R_M_MASK = 0b0000_0111;
    const R_M_SHIFT = 0;
    const REG_MASK = 0b0011_1000;
    const REG_SHIFT = 3;
    const MOD_MASK = 0b1100_0000;
    const MOD_SHIFT = 6;

    return .{
        mask_bits(byte, MOD_MASK, MOD_SHIFT),
        mask_bits(byte, REG_MASK, REG_SHIFT),
        mask_bits(byte, R_M_MASK, R_M_SHIFT),
    };
}

fn reg_mem_to_reg(scanner: *ByteScanner, instruction: *Instruction) !void {
    const bytes = try scanner.pop_n(2);
    const D_MASK = 0b0000_0010;
    const W_MASK = 0b0000_0001;

    const d: bool = (bytes[0] & D_MASK) > 0;
    const w: bool = (bytes[0] & W_MASK) > 0;

    const mod, const reg, const r_m = scan_mod_reg_r_m(bytes[1]);

    switch (mod) {
        0b00...0b10 => {
            const register_offset = if (w) WORD_REG_START else BYTE_REG_START;
            const reg_location = Location{ .register = @fromBackingInt(reg + register_offset) };

            const eff_addr = try effective_address(scanner, mod, r_m);
            set_source_target_by_flag(instruction, d, reg_location, eff_addr);
        },
        0b11 => {
            const register_offset = if (w) WORD_REG_START else BYTE_REG_START;
            const r_m_location = Location{ .register = @fromBackingInt(r_m + register_offset) };
            const reg_location = Location{ .register = @fromBackingInt(reg + register_offset) };
            set_source_target_by_flag(instruction, d, reg_location, r_m_location);
        },
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

fn displaced_effective_address(scanner: *ByteScanner, r_m: u8, size: RegisterSize) !Location {
    const register: AddressingRegister = @fromBackingInt(r_m);
    const sized_displacement = try scan_byte_or_word(scanner, size);

    const displacement: i16 = switch (sized_displacement) {
        // bitwise cast u8 -> i8, sign-extend i8 -> i16
        .byte => |b| @as(i16, @as(i8, @bitCast(b))),
        .word => |w| @bitCast(w),
    };

    return Location{
        .address = EffectiveAddress{
            .register_displacement = .{
                .register = register,
                .displacement = displacement,
            },
        },
    };
}

fn effective_address(scanner: *ByteScanner, mod: u8, r_m: u8) !Location {
    switch (mod) {
        0b00 => {
            // special case -- r/m 110 maps to direct address, not bp
            if (r_m == 0b110) {
                const addr: u16 = std.mem.readInt(u16, try scanner.pop_n(2), .little);
                return Location{ .address = EffectiveAddress{ .direct_address = addr } };
            } else {
                const register: AddressingRegister = @fromBackingInt(r_m);
                return Location{ .address = EffectiveAddress{ .register = register } };
            }
        },
        0b01 => return try displaced_effective_address(scanner, r_m, .byte),
        0b10 => return try displaced_effective_address(scanner, r_m, .word),
        else => unreachable,
    }
}

fn scan_byte_or_word(scanner: *ByteScanner, size: RegisterSize) !Sized {
    return switch (size) {
        .byte => Sized{ .byte = try scanner.pop() },
        .word => Sized{
            .word = std.mem.readInt(u16, try scanner.pop_n(2), .little),
        },
    };
}

fn arith_imm_to_reg_addr(scanner: *ByteScanner, instruction: *Instruction) !void {
    const bytes = try scanner.pop_n(2);

    const s = (bytes[0] & 0b10) > 0;
    const w = (bytes[0] & 0b01) > 0;

    const mod, const reg, const r_m = scan_mod_reg_r_m(bytes[1]);
    instruction.type = switch (reg) {
        0b000 => .add,
        0b101 => .sub,
        0b111 => .cmp,
        else => unreachable,
    };

    if (mod == 0b11) {
        const register_offset = if (w) WORD_REG_START else BYTE_REG_START;
        instruction.target = Location{
            .register = @fromBackingInt(r_m + register_offset),
        };
    } else {
        instruction.target = try effective_address(scanner, mod, r_m);
    }

    const size: RegisterSize = if (w and !s) .word else .byte;
    const immediate = try scan_byte_or_word(scanner, size);

    instruction.source = Location{ .immediate = immediate };
}

fn mov_imm_to_effective_address(scanner: *ByteScanner, instruction: *Instruction) !void {
    const bytes = try scanner.pop_n(2);

    const mod, const reg, const r_m = scan_mod_reg_r_m(bytes[1]);

    std.debug.assert(reg == 0b000);
    instruction.target = try effective_address(scanner, mod, r_m);

    const w = (bytes[0] & 0b1) > 0;
    const size: RegisterSize = if (w) .word else .byte;
    const immediate = try scan_byte_or_word(scanner, size);
    instruction.source = Location{ .immediate = immediate };
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

    const size: RegisterSize = if (w) .word else .byte;
    const immediate_value = try scan_byte_or_word(scanner, size);

    instruction.target = Location{ .register = reg_register };
    instruction.source = Location{ .immediate = immediate_value };
}

fn imm_to_acc(scanner: *ByteScanner, instruction: *Instruction) !void {
    const leading_byte = try scanner.pop();
    const w = (leading_byte & 0b1) > 0;

    const imm = try scan_byte_or_word(scanner, if (w) .word else .byte);

    const register_offset = if (w) WORD_REG_START else BYTE_REG_START;
    const register: Register = @fromBackingInt(@backingInt(Register.al) + register_offset);
    instruction.target = Location{ .register = register };
    instruction.source = Location{ .immediate = imm };
}

fn mem_to_from_acc(scanner: *ByteScanner, instruction: *Instruction) !void {
    const leading_byte = try scanner.pop();
    const D_MASK = 0b10;
    const W_MASK = 0b1;
    const d = (leading_byte & D_MASK) > 0;
    const w = (leading_byte & W_MASK) > 0;

    const addr_bytes = try scanner.pop_n(2);
    const addr = std.mem.readInt(u16, addr_bytes, .little);
    const mem = Location{
        .address = EffectiveAddress{
            .direct_address = addr,
        },
    };

    const acc = Location{
        .register = if (w) .ax else .al,
    };

    set_source_target_by_flag(instruction, d, mem, acc);
}

pub const Instruction = struct {
    type: InstructionType,
    source: Location,
    target: Location,

    pub fn emit(self: *Instruction, writer: *Io.Writer) !void {
        try writer.print("{s} ", .{self.type.string_representation()});
        try self.target.emit(writer);
        if (self.type.is_single_operand()) {
            return;
        }

        try writer.print(", ", .{});

        // special case - need to include size annotation when it's not inferred
        if (self.source == .immediate and self.target == .address) {
            const immediate = self.source.immediate;
            try immediate.emit_with_size(writer);
        } else {
            try self.source.emit(writer);
        }
    }
};

pub const Location = union(enum) {
    register: Register,
    immediate: Sized,
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
pub const RegisterSize = enum { byte, word };
pub const Sized = union(RegisterSize) {
    byte: u8,
    word: u16,

    fn emit(self: Sized, writer: *Io.Writer) !void {
        switch (self) {
            .byte => |b| try writer.print("{d}", .{b}),
            .word => |w| try writer.print("{d}", .{w}),
        }
    }

    fn emit_with_size(self: Sized, writer: *Io.Writer) !void {
        switch (self) {
            .byte => |b| try writer.print("byte {d}", .{b}),
            .word => |w| try writer.print("word {d}", .{w}),
        }
    }

    pub fn widen(self: Sized) u16 {
        return switch (self) {
            .word => |w| w,
            .byte => |b| @as(u16, b),
        };
    }
};

pub const InstructionType = enum(u8) {
    mov = 0,
    add,
    sub,
    cmp,

    // start of single operand instructions
    loopnz,
    loopz,
    loop,
    jcxz,
    // Start Jump instructions
    jo,
    jno,
    jb,
    jnb,
    je,
    jnz,
    jbe,
    ja,
    js,
    jns,
    jp,
    jnp,
    jl,
    jnl,
    jle,
    jg,

    fn emit(self: InstructionType, writer: *Io.Writer) !void {
        try writer.print("{s}", .{self.string_representation()});
    }

    fn is_single_operand(self: InstructionType) bool {
        return @backingInt(self) >= SINGLE_OPERAND_OFFSET;
    }

    fn string_representation(self: InstructionType) []const u8 {
        return @tagName(self);
    }
};

const SINGLE_OPERAND_OFFSET = @backingInt(InstructionType.loopnz);
const LOOP_INSTRUCTION_OFFSET = @backingInt(InstructionType.loopnz);
const JUMP_INSTRUCTION_OFFSET = @backingInt(InstructionType.jo);

pub const RegisterHalf = enum { low, high };
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
    ax,
    cx,
    dx,
    bx,
    sp,
    bp,
    si,
    di,

    pub fn is_byte_width(self: Register) bool {
        return @backingInt(self) < WORD_REG_START;
    }

    /// only call this on byte addressable registers (al/ah, etc.)
    pub fn byte_register_half(self: Register) RegisterHalf {
        std.debug.assert(self.is_byte_width());

        return switch (self) {
            .al, .bl, .cl, .dl => .low,
            .ah, .bh, .ch, .dh => .high,
            else => unreachable,
        };
    }

    pub fn emit(self: Register, writer: *Io.Writer) !void {
        try writer.print("{s}", .{self.string_representation()});
    }

    pub fn string_representation(self: Register) []const u8 {
        return @tagName(self);
    }
};

pub const BYTE_REG_START: u8 = @backingInt(Register.al);
pub const WORD_REG_START: u8 = @backingInt(Register.ax);
pub const REGISTER_COUNT: u8 = @typeInfo(Register).@"enum".field_values.len;

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
        displacement: i16,
    },

    fn emit(self: EffectiveAddress, writer: *Io.Writer) !void {
        switch (self) {
            .direct_address => |d| try writer.print("[{d}]", .{d}),
            .register => |r| try writer.print("[{s}]", .{r.string_representation()}),
            .register_displacement => |r_d| {
                const register = r_d.register.string_representation();
                if (r_d.displacement == 0) {
                    try writer.print("[{s}]", .{register});
                } else if (r_d.displacement < 0) {
                    try writer.print("[{s} - {d}]", .{ register, -r_d.displacement });
                } else {
                    try writer.print("[{s} + {d}]", .{ register, r_d.displacement });
                }
            },
        }
    }
};

/// Convenience functions for handling encoded instructions
pub const ByteScanner = struct {
    src: []const u8,
    idx: u32,

    pub fn init(src: []const u8) ByteScanner {
        return ByteScanner{
            .src = src,
            .idx = 0,
        };
    }

    pub fn peek(self: *ByteScanner) ?u8 {
        if (self.idx >= self.src.len) {
            return null;
        } else {
            return self.src[self.idx];
        }
    }

    pub fn pop(self: *ByteScanner) DecodeError!u8 {
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
    pub fn pop_n(self: *ByteScanner, comptime n: u32) DecodeError!*const [n]u8 {
        if (self.idx + n - 1 >= self.src.len) {
            return DecodeError.IncompleteInstruction;
        }
        std.debug.assert(self.idx < self.src.len);
        const res = self.src[self.idx..self.src.len];
        self.idx += n;
        return res[0..n];
    }
};
