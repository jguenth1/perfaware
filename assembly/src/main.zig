const std = @import("std");
const Io = std.Io;

const assembly = @import("assembly");

fn read_entire_file(alloc: std.mem.Allocator, io: Io, file: []const u8) ![]u8 {
    const dir = Io.Dir.cwd();
    const whole = try dir.readFileAlloc(io, file, alloc, .unlimited);
    return whole;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    // accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    std.debug.assert(args.len == 2);

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;
    const buf: []const u8 = try read_entire_file(arena, io, args[1]);

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    //try decoder.disassemble_program(buf, stdout_writer);
    try assembly.emulate_program(buf, stdout_writer);

    try stdout_writer.flush(); // Don't forget to flush!
}
