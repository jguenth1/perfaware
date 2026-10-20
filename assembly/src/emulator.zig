const std = @import("std");
const Io = std.Io;
const decoder = @import("decoder.zig");

const REGISTER_COUNT = decoder.REGISTER_COUNT;
pub const RegisterTable = [REGISTER_COUNT]u16;

const FlagRegister = packed struct(u8) {
    zero: bool,
    sign: bool,
    _res: u6,

    fn default() FlagRegister {
        return FlagRegister{
            .zero = false,
            .sign = false,
            ._res = 0,
        };
    }

    fn print(self: FlagRegister, writer: *Io.Writer) !void {
        if (self.zero) {
            try writer.print("Z", .{});
        }
        if (self.sign) {
            try writer.print("S", .{});
        }
    }
};

pub const Executor = struct {
    register_table: RegisterTable,
    flags: FlagRegister,

    pub fn init() Executor {
        return Executor{
            .register_table = @splat(0),
            .flags = .default(),
        };
    }

    fn set_register(self: *Executor, register: decoder.Register, value: decoder.Sized) void {
        const idx = @backingInt(register);
        std.debug.assert(idx < self.register_table.len);
        switch (value) {
            .word => |w| {
                self.register_table[idx] = w;
            },
            .byte => |b| {
                std.debug.assert(register.is_byte_width());
                switch (register.byte_register_half()) {
                    .low => {
                        const word = @as(u16, b);
                        self.register_table[idx] &= 0xFF00;
                        self.register_table[idx] |= word;
                    },
                    .high => {
                        const word = @as(u16, b) << 8;
                        self.register_table[idx] &= 0x00FF;
                        self.register_table[idx] |= word;
                    },
                }
            },
        }
    }

    fn get_register(self: *Executor, register: decoder.Register) decoder.Sized {
        const idx: u8 = @backingInt(register);
        std.debug.assert(idx < self.register_table.len);
        const reg_val = self.register_table[idx];

        if (register.is_byte_width()) {
            const byte_val: u8 = switch (register.byte_register_half()) {
                .low => @truncate(reg_val),
                .high => @truncate(reg_val >> 8),
            };
            return decoder.Sized{ .byte = byte_val };
        } else {
            return decoder.Sized{ .word = reg_val };
        }
    }

    pub fn set_flags(self: *Executor, result: u16) void {
        self.flags.zero = result == 0;

        const U16_LEADING_BITMASK = 0x8000;
        self.flags.sign = (result & U16_LEADING_BITMASK > 0);
    }

    pub fn print_registers(self: *Executor, writer: *Io.Writer) !void {
        var i: u8 = decoder.WORD_REG_START;
        while (i < self.register_table.len) : (i += 1) {
            const register: decoder.Register = @fromBackingInt(i);
            const reg_str = register.string_representation();
            const value = self.register_table[i];

            if (value > 0) {
                try writer.print("\t{s}: 0x{x:0>4} ({d})\n", .{ reg_str, value, value });
            }
        }
    }

    pub fn print_flags(self: *Executor, writer: *Io.Writer) !void {
        try self.flags.print(writer);
    }
};

pub fn snapshot_registers(executor: *Executor) RegisterTable {
    return executor.register_table;
}

pub fn print_register_diffs(executor: *Executor, snapshot: RegisterTable, writer: *Io.Writer) !void {
    std.debug.assert(executor.register_table.len == snapshot.len);

    var diff_cnt: u8 = 0;
    var i: u8 = 0;
    while (i < snapshot.len) : (i += 1) {
        if (executor.register_table[i] != snapshot[i]) {
            diff_cnt += 1;
            const reg_val: decoder.Register = @fromBackingInt(i);
            const reg_str = reg_val.string_representation();

            try writer.print(" {s}:0x{x}->0x{x}", .{ reg_str, snapshot[i], executor.register_table[i] });
        }
    }

    std.debug.assert(diff_cnt <= 1);
}

pub fn print_flag_diffs(executor: *Executor, snapshot: FlagRegister, writer: *Io.Writer) !void {
    if (snapshot == executor.flags) {
        return;
    }

    try writer.print("flags:", .{});
    try snapshot.print(writer);
    try writer.print("->", .{});
    try executor.print_flags(writer);
}

pub fn emulate_instruction(executor: *Executor, instruction: *decoder.Instruction) void {
    switch (instruction.type) {
        .mov => emulate_mov(executor, instruction),
        .add, .sub, .cmp => emulate_arith(executor, instruction),
        else => unreachable,
    }
}

// TODO: registers and immediates are naturally sized, when we get to memory we will need to
// know/decide how many bytes to get from the addr...
fn retrieve_value(
    executor: *Executor,
    location: *decoder.Location,
    opposite: *decoder.Location,
) decoder.Sized {
    switch (location.*) {
        .immediate => |i| return i,
        .register => |r| return executor.get_register(r),
        .address => |a| {
            std.debug.assert(opposite.* != .address); // no memory-to-memory instrs.
            const read_size: decoder.RegisterSize = switch (opposite.*) {
                .immediate => |i| i,
                .register => |r| if (r.is_byte_width()) .byte else .word,
                else => unreachable,
            };
            return memory_read(executor, a, read_size);
        },
    }
}

// TODO: Implement memory, this will probably move into the emulator
fn memory_read(
    executor: *Executor,
    address: decoder.EffectiveAddress,
    size: decoder.RegisterSize,
) decoder.Sized {
    _ = executor;
    _ = address;
    return switch (size) {
        .byte => decoder.Sized{ .byte = 0 },
        .word => decoder.Sized{ .word = 0 },
    };
}

fn set_value(executor: *Executor, location: *decoder.Location, value: decoder.Sized) void {
    std.debug.assert(location.* == .register);
    switch (location.*) {
        .register => |r| executor.set_register(r, value),
        else => unreachable,
    }
}

const ArithmeticOp = enum { add, sub };
fn apply_arithmetic_op(source: anytype, target: @TypeOf(source), op: ArithmeticOp) @TypeOf(source) {
    return switch (op) {
        .add => source + target,
        .sub => target - source,
    };
}

fn sized_op(source: decoder.Sized, target: decoder.Sized, op: ArithmeticOp) decoder.Sized {
    std.debug.assert(@as(decoder.RegisterSize, source) == @as(decoder.RegisterSize, target));
    switch (target) {
        .byte => |target_byte| {
            std.debug.assert(source == .byte);
            return decoder.Sized{
                .byte = apply_arithmetic_op(source.byte, target_byte, op),
            };
        },
        .word => |target_word| {
            std.debug.assert(source == .word);
            return decoder.Sized{
                .word = apply_arithmetic_op(source.word, target_word, op),
            };
        },
    }
}

fn emulate_mov(executor: *Executor, instruction: *decoder.Instruction) void {
    const value = retrieve_value(executor, &instruction.source, &instruction.target);
    set_value(executor, &instruction.target, value);
}

fn emulate_arith(executor: *Executor, instruction: *decoder.Instruction) void {
    const source_value = retrieve_value(executor, &instruction.source, &instruction.target);
    const target_value = retrieve_value(executor, &instruction.target, &instruction.source);
    const arith_op: ArithmeticOp = switch (instruction.type) {
        .add => .add,
        .sub => .sub,
        .cmp => .sub,
        else => unreachable,
    };
    const res = sized_op(source_value, target_value, arith_op);
    executor.set_flags(res.widen());
    if (instruction.type != .cmp) {
        set_value(executor, &instruction.target, res);
    }
}
