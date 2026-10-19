const std = @import("std");
const Io = std.Io;
const decoder = @import("decoder.zig");

const REGISTER_COUNT = decoder.REGISTER_COUNT;
pub const RegisterTable = [REGISTER_COUNT]u16;

pub const Executor = struct {
    register_table: RegisterTable,

    pub fn init() Executor {
        return Executor{
            .register_table = @splat(0),
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

    pub fn print_registers(self: *Executor, writer: *Io.Writer) !void {
        var i: u8 = decoder.WORD_REG_START;
        while (i < self.register_table.len) : (i += 1) {
            const register: decoder.Register = @fromBackingInt(i);
            const reg_str = register.string_representation();
            const value = self.register_table[i];

            try writer.print("\t{s}: 0x{x:0>4} ({d})\n", .{ reg_str, value, value });
        }
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

pub fn execute_instruction(executor: *Executor, instruction: *decoder.Instruction) void {
    std.debug.assert(instruction.type == .mov);
    switch (instruction.type) {
        .mov => emulate_mov(executor, instruction),
        else => unreachable,
    }
}

fn retrieve_value(executor: *Executor, location: *decoder.Location) decoder.Sized {
    return switch (location.*) {
        .immediate => |i| i,
        .register => |r| executor.get_register(r),
        else => unreachable,
    };
}

fn emulate_mov(executor: *Executor, instruction: *decoder.Instruction) void {
    std.debug.assert(instruction.target == .register);
    const value: decoder.Sized = retrieve_value(executor, &instruction.source);
    switch (instruction.target) {
        .register => |r| executor.set_register(r, value),
        else => unreachable,
    }
}
