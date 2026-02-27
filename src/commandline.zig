const std = @import("std");

allocator: std.mem.Allocator,
buf: []u8,
input: *std.Io.Reader,
output: *std.Io.Writer,

const CommandLine = @This();

const Command = enum {
    help,
    quit,
    unknown,
};

pub fn init(
    allocator: std.mem.Allocator,
    buf: []u8,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
) CommandLine {
    return .{
        .allocator = allocator,
        .buf = buf,
        .input = input,
        .output = output,
    };
}

pub fn deinit(self: *CommandLine) void {
    _ = self; // autofix
}

pub fn spawn(self: *CommandLine) !void {
    //output prompt
    try self.output.print("\n:", .{});
    try self.output.flush();

    //get string from input from user
    const string = try getStringFromUserInput(
        self.buf,
        self.input,
        self.output,
    );

    //get command and args and handle them
    const command, var args = try getArgs(self.allocator, string);
    defer args.deinit(self.allocator);

    const result = try handle(command, args);

    //print out result
    try printResult(self.output, string, result);

    // wait for user input to continue
    try self.output.print("\n\npress enter to continue", .{});
    try self.output.flush();
    while ((try self.input.takeByte()) != '\n') {}
}

pub fn printResult(
    output: *std.Io.Writer,
    original_string: []const u8,
    result_string: []const u8,
) !void {
    //make it appear empty
    for (original_string) |_| {
        try output.print("\x1b[D \x1b[D", .{});
        try output.flush();
    }

    //print
    try output.print(" {s}\n", .{result_string});
    try output.flush();
}

fn handle(cmd: Command, args: std.ArrayList([]const u8)) ![]const u8 {
    _ = args; // autofix
    return switch (cmd) {
        .quit => error.Quit,
        .help => "nobody will help you",
        .unknown => "unknown command",
    };
}

fn getStringFromUserInput(
    buf: []u8,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
) ![]const u8 {
    var seek: u8 = 0;
    while (true) {
        const char = try input.takeByte();
        if (seek >= buf.len) seek = 0;
        switch (char) {
            //enter  esc
            '\n' => break,
            //esc
            27 => {
                seek = 0;
                break;
            },
            //backspace
            127 => {
                if (seek > 0) {
                    seek -= 1;
                    try output.print("\x1b[D \x1b[D", .{});
                    try output.flush();
                } else seek = 0;
            },

            else => {
                buf[seek] = char;
                seek += 1;
                try output.print("{c}", .{char});
                try output.flush();
            },
        }
    }

    return buf[0..seek];
}
test getStringFromUserInput {
    var dummy_wbuf: [1024]u8 = undefined;
    var dummy_out = std.Io.Writer.fixed(&dummy_wbuf);
    const test_string = "res0\x7fres1\nno";
    var rdr = std.Io.Reader.fixed(test_string);

    // testing backspace and enter
    var buf: [1024]u8 = undefined;
    const res = try getStringFromUserInput(&buf, &rdr, &dummy_out);

    try std.testing.expectEqualStrings("resr", res[0..4]);
    try std.testing.expectEqualStrings("res1", res[3..]);

    // testing escape
    const test_string1 = test_string[0..3] ++ "\x1b" ++ test_string[3..];
    var rdr1 = std.Io.Reader.fixed(test_string1);
    var buf1: [1024]u8 = undefined;
    const res1 = try getStringFromUserInput(&buf1, &rdr1, &dummy_out);

    try std.testing.expectEqualStrings("", res1);
}

fn getArgs(
    allocator: std.mem.Allocator,
    string: []const u8,
) !struct {
    Command,
    std.ArrayList([]const u8),
} {
    var iterator = std.mem.splitScalar(u8, string, ' ');
    const command: Command = blk: {
        if (iterator.next()) |value| {
            if (std.mem.eql(u8, value, "help") or
                std.mem.eql(u8, value, "h"))
                break :blk .help;

            if (std.mem.eql(u8, value, "quit") or
                std.mem.eql(u8, value, "q"))
                break :blk .quit;
        }
        break :blk .unknown;
    };
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |value| {
        try args.append(allocator, value);
    }
    return .{
        command,
        args,
    };
}

test getArgs {
    const allocator = std.testing.allocator;
    const strings = "help a b c|h a b c||";
    var str_it = std.mem.splitScalar(u8, strings, '|');

    try std.testing.expectEqual(
        Command.help,
        blk: {
            var ret = try getArgs(allocator, str_it.next().?);
            const res = ret.command;
            ret.deinit();
            break :blk res;
        },
    );
    try std.testing.expectEqual(
        Command.help,
        blk: {
            var ret = try getArgs(allocator, str_it.next().?);
            const res = ret.command;
            ret.deinit();
            break :blk res;
        },
    );
    try std.testing.expectEqual(
        Command.unknown,
        blk: {
            var ret = try getArgs(allocator, str_it.next().?);
            const res = ret.command;
            ret.deinit();
            break :blk res;
        },
    );
}
