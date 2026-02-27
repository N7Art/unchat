const std = @import("std");
const tls = @import("tls");
const xmpp = @import("xmpp.zig");

const Messages = @import("root.zig").Messages;
const dysplay = @import("output.zig").dysplay;

const Command = enum {
    help,
    quit,
    unknown,
};

const Connection = struct {
    tcp: std.net.Stream,
    tls: tls.Connection,

    tcp_wbuf: [std.crypto.tls.max_ciphertext_record_len]u8,
    tcp_rbuf: [std.crypto.tls.max_ciphertext_record_len]u8,
    tls_wbuf: [tls.max_ciphertext_record_len]u8,
    tls_rbuf: [tls.max_ciphertext_record_len]u8,
};

const TTYsettings = struct {
    tty_file: std.fs.File,
    old_settings: std.os.linux.termios,
};
fn takeMore(reader: *std.Io.Reader) ![]u8 {
    try reader.fillMore();
    const response = try reader.take(reader.bufferedLen());
    return response;
}

fn listenToMessages(
    allocator: std.mem.Allocator,
    connection_reader: *std.Io.Reader,
    msgs: *Messages,
) !void {
    //clear connection reader
    try connection_reader.discardAll(connection_reader.bufferedLen());

    while (true) {
        //reading from connection
        const read = try takeMore(connection_reader);

        //clear connection reader
        try connection_reader.discardAll(connection_reader.bufferedLen());

        const sender = blk: {
            const attr_indx = std.mem.indexOfPos(u8, read, 0, "from") orelse {
                break :blk "recived";
            };
            break :blk getAtributeValue(u8, read, attr_indx);
        };

        const recipient = blk: {
            const attr_indx = std.mem.indexOf(u8, read, "to") orelse
                break :blk "me";
            break :blk getAtributeValue(u8, read, attr_indx);
        };

        //parse response text
        const content = getTagContent(allocator, read, "body") catch |err| switch (err) {
            error.TagNotFound => continue,
            else => return err,
        };

        //skiping if message is empty
        if (std.mem.eql(u8, content, "")) {
            continue;
        }

        try msgs.append(allocator, .{
            .content = content,
            .sender = sender,
            .recipient = recipient,
        });

        dysplay(msgs.*);
    }
}

fn getCommandString(
    buf: []u8,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
) ![]const u8 {
    try output.print(":", .{});
    try output.flush();

    var i: u8 = 0;
    while (true) {
        const char = try input.takeByte();
        if (i >= buf.len) i = 0;
        switch (char) {
            //enter  esc
            '\n' => break,
            //esc
            27 => {
                i = 0;
                break;
            },
            //backspace
            127 => {
                if (i > 0) {
                    i -= 1;
                    try output.print("\x1b[D \x1b[D", .{});
                    try output.flush();
                } else i = 0;
            },

            else => {
                buf[i] = char;
                i += 1;
                try output.print("{c}", .{char});
                try output.flush();
            },
        }
    }
    return buf[0..i];
}
test getCommandString {
    var dummy_wbuf: [1024]u8 = undefined;
    var dummy_out = std.Io.Writer.fixed(&dummy_wbuf);
    const test_string = "res0\x7fres1\nno";
    var rdr = std.Io.Reader.fixed(test_string);

    // testing backspace and enter
    var buf: [1024]u8 = undefined;
    const res = try getCommandString(&buf, &rdr, &dummy_out);

    try std.testing.expectEqualStrings("resr", res[0..4]);
    try std.testing.expectEqualStrings("res1", res[3..]);

    // testing escape
    const test_string1 = test_string[0..3] ++ "\x1b" ++ test_string[3..];
    var rdr1 = std.Io.Reader.fixed(test_string1);
    var buf1: [1024]u8 = undefined;
    const res1 = try getCommandString(&buf1, &rdr1, &dummy_out);

    try std.testing.expectEqualStrings("", res1);
}

fn parseCommandString(
    allocator: std.mem.Allocator,
    string: []const u8,
) !struct {
    allocator: std.mem.Allocator,
    command: Command,
    args: std.ArrayList([]const u8),
    pub fn deinit(self: *@This()) void {
        self.args.deinit(self.allocator);
    }
} {
    var iterator = std.mem.splitScalar(u8, string, ' ');
    var command: Command = undefined;
    command = blk: {
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
        .allocator = allocator,
        .command = command,
        .args = args,
    };
}

test parseCommandString {
    const allocator = std.testing.allocator;
    const strings = "help a b c|h a b c||";
    var str_it = std.mem.splitScalar(u8, strings, '|');

    try std.testing.expectEqual(
        Command.help,
        blk: {
            var ret = try parseCommandString(allocator, str_it.next().?);
            const res = ret.command;
            ret.deinit();
            break :blk res;
        },
    );
    try std.testing.expectEqual(
        Command.help,
        blk: {
            var ret = try parseCommandString(allocator, str_it.next().?);
            const res = ret.command;
            ret.deinit();
            break :blk res;
        },
    );
    try std.testing.expectEqual(
        Command.unknown,
        blk: {
            var ret = try parseCommandString(allocator, str_it.next().?);
            const res = ret.command;
            ret.deinit();
            break :blk res;
        },
    );
}

fn selectFromList(
    list: std.ArrayList([]const u8),
    input: *std.Io.Reader,
    output: *std.Io.Writer,
) ![]const u8 {
    const symbols = struct {
        pub const arrow = @constCast("->");
        pub const empty = @constCast("  ");
    };

    var selected: u8 = 0;
    const account_num: u8 = @intCast(list.items.len);
    var move: u8 = undefined;
    var sign: []u8 = symbols.arrow;

    const tty_settings = try hide_input();
    while (move != '\n') {
        //clear
        try output.print("\x1b[2J\x1b[H", .{});
        try output.print("select account:\n", .{});

        for (list.items, 0..) |account, i| {
            sign = if (selected == i) symbols.arrow else symbols.empty;
            try output.print("{s} {s}\n", .{ sign, account });
        }
        try output.flush();

        try input.discardAll(input.bufferedLen());
        move = (try input.take(1))[0];
        if (move == ':') {
            var buf: [1024]u8 = undefined;
            _ = try getCommandString(&buf, input, output);
        }
        selected = switch (move) {
            'j' => if (selected < account_num - 1) selected + 1 else 0,
            'k' => if (selected > 0) selected - 1 else account_num - 1,
            else => selected,
        };
    }

    try show_input(tty_settings);
    return list.items[selected];
}

fn saslNegotioation(
    allocator: std.mem.Allocator,
    conn: *tls.Connection,
    username: []const u8,
    hostname: []const u8,
    pass: []const u8,
) !void {
    var buf: [1024]u8 = undefined;
    var pass_buf: [1024]u8 = undefined;
    var tls_rbuf: [tls.max_ciphertext_record_len]u8 = undefined;
    var tls_wbuf: [tls.max_ciphertext_record_len]u8 = undefined;

    var conn_reader = conn.reader(&tls_rbuf);
    var conn_writer = conn.writer(&tls_wbuf);

    const auth_string = std.base64.standard.Encoder.encode(&buf, try std.fmt.bufPrint(&pass_buf, "\x00{s}\x00{s}", .{ username, pass }));
    try conn_writer.interface.writeAll(try xmpp.Stanzas.formatAuth(allocator, @constCast(xmpp.AuthMechanism.PLAIN), @constCast(auth_string)));
    try conn_writer.interface.flush();

    // read response
    const response = try takeMore(&conn_reader.interface);
    if (std.mem.eql(u8, response[0..xmpp.ResponseErrors.failed_response.len], xmpp.ResponseErrors.failed_response)) {
        std.debug.print("\nfailure!\n{s}", .{response});
        return;
    }

    //clear connection reader
    try conn_reader.interface.discardAll(conn_reader.interface.bufferedLen());

    //restart xmpp stream
    try conn_writer.interface.writeAll(try xmpp.Stanzas.formatHeader(
        allocator,
        try std.fmt.allocPrint(allocator, "{s}@{s}", .{ username, hostname }),
        @constCast(hostname),
    ));
    try conn_writer.interface.flush();

    // read response
    _ = try takeMore(&conn_reader.interface);
}

fn resourceBinding(
    allocator: std.mem.Allocator,
    conn: *tls.Connection,
) !void {
    var tls_rbuf: [tls.max_ciphertext_record_len]u8 = undefined;
    var tls_wbuf: [tls.max_ciphertext_record_len]u8 = undefined;

    var conn_reader = conn.reader(&tls_rbuf);
    var conn_writer = conn.writer(&tls_wbuf);

    // has 2 components with params iq and its body
    try conn_writer.interface.writeAll(try xmpp.Stanzas.Iq.formatIq(
        allocator,
        .set,
        try xmpp.Stanzas.Iq.Requests.formatBind(allocator, "unchat"),
    ));
    try conn_writer.interface.flush();
    //read responce
    _ = try takeMore(&conn_reader.interface);
}

fn findAllAtribute(
    comptime T: type,
    allocator: std.mem.Allocator,
    haystack: []const T,
    needle: []const T,
) !std.ArrayList(usize) {
    var list: std.ArrayList(usize) = .empty;

    var pos: usize = 0;
    while (std.mem.indexOfPos(T, haystack, pos, needle)) |idx| {
        try list.append(allocator, idx);
        pos = idx + needle.len;
    }
    return list;
}

test findAllAtribute {
    var res = try findAllAtribute(u8, std.testing.allocator, "wqqqqqqqwqqqqqqqqw", "w");
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), res.items[0]);
    try std.testing.expectEqual(@as(usize, 8), res.items[1]);
    try std.testing.expectEqual(@as(usize, 17), res.items[2]);
}

fn getAtributeValue(
    comptime T: type,
    haystack: []const T,
    idx: usize,
) []const T {
    const strt = std.mem.indexOfScalarPos(T, haystack, idx, '\'').?;
    const end = std.mem.indexOfScalarPos(T, haystack, strt + 1, '\'').?;
    return haystack[strt + 1 .. end];
}

fn getAllAtributeValues(
    comptime T: type,
    allocator: std.mem.Allocator,
    haystack: []const T,
    atributeIndexes: std.ArrayList(usize),
) !std.ArrayList([]const T) {
    var list: std.ArrayList([]const T) = .empty;

    for (atributeIndexes.items) |idx| {
        try list.append(allocator, @constCast(getAtributeValue(u8, haystack, idx)));
    }

    return list;
}

test getAllAtributeValues {
    const value1 = "value1";
    const wrong = "asd\"gjasdkgghi\"o\"h";
    const value2 = "value2";
    const haystack: []const u8 =
        \\<tag name='
    ++ value1 ++
        \\'>"
    ++ wrong ++
        \\"<tag name='
    ++ value2 ++ "'>";

    var atributeIndexes: std.ArrayList(usize) = .empty;
    defer atributeIndexes.deinit(std.testing.allocator);
    try atributeIndexes.append(std.testing.allocator, 5);
    try atributeIndexes.append(std.testing.allocator, haystack.len - 15);

    var res: std.ArrayList([]const u8) = try getAllAtributeValues(
        u8,
        std.testing.allocator,
        haystack,
        atributeIndexes,
    );
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(value1, res.items[0]);
    try std.testing.expectEqualStrings(value2, res.items[1]);
}

fn getRosterJids(
    allocator: std.mem.Allocator,
    src: []const u8,
) !std.ArrayList([]const u8) {
    var atributeIndexes = try findAllAtribute(u8, allocator, src, "jid");
    defer atributeIndexes.deinit(allocator);

    return getAllAtributeValues(u8, allocator, src, atributeIndexes);
}
test getRosterJids {
    const src: []const u8 = "<iq type='result' id='1' to='me@s.com/res'><query ver='14' xmlns='jabber:iq:roster'><item subscription='from' jid='a@s.com' name='a'><group/></item><item subscription='both' jid='b@s.com'><group/></item><item subscription='from' jid='c@s.com'/></query></iq>";
    var res = try getRosterJids(std.testing.allocator, src);
    defer res.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, res.items.len);

    try std.testing.expectEqualStrings("a@s.com", res.items[0]);
    try std.testing.expectEqualStrings("b@s.com", res.items[1]);
    try std.testing.expectEqualStrings("c@s.com", res.items[2]);
}

fn getTagContent(
    allocator: std.mem.Allocator,
    src: []const u8,
    tag_name: []const u8,
) ![]const u8 {
    return blk: {
        const open_name = try std.fmt.allocPrint(
            allocator,
            "<{s}",
            .{tag_name},
        );
        defer allocator.free(open_name);
        const close_name = try std.fmt.allocPrint(
            allocator,
            "</{s}",
            .{tag_name},
        );
        defer allocator.free(close_name);

        const tag_start = std.mem.indexOf(
            u8,
            src,
            open_name,
        ) orelse return error.TagNotFound;
        const strt = std.mem.indexOfScalarPos(
            u8,
            src,
            tag_start + open_name.len,
            '>',
        ) orelse return error.TagNotClosed;

        const end = std.mem.indexOfPos(
            u8,
            src,
            strt,
            close_name,
        ) orelse {
            std.debug.print("{s}", .{src[strt..]});
            return error.ClosingTagNotFound;
        };

        break :blk src[strt + 1 .. end];
    };
}
test getTagContent {
    const allocator = std.testing.allocator;
    const s0: []const u8 = "<tag>string 0</tag>";
    const s1: []const u8 = "<tag attr='val'>string 1</tag>";
    const s2: []const u8 = "<tag>string 2<>";
    const src: []const u8 = s0 ++ "<><<<>><><>\nwrong\n;" ++ s1 ++ s2;
    const res: []const u8 = try getTagContent(
        allocator,
        src,
        "tag",
    );
    try std.testing.expectEqualStrings("string 0", res);
}

test "Messages.append" {
    var messages: Messages = .empty;
    defer messages.deinit(std.testing.allocator);

    try messages.append(std.testing.allocator, .{
        .content = @constCast("ca"),
        .sender = @constCast("sa"),
        .recipient = @constCast("ra"),
    });

    try std.testing.expectEqualStrings("ca", messages.contents.items[0]);
    try std.testing.expectEqualStrings("sa", messages.senders.items[0]);
    try std.testing.expectEqualStrings("ra", messages.recipients.items[0]);
    try std.testing.expectEqual(0, messages.indxs.items[0]);
    try std.testing.expectEqual(0, messages.ids.items[0]);

    try messages.append(std.testing.allocator, .{
        .content = @constCast("cb"),
        .sender = @constCast("sb"),
        .recipient = @constCast("rb"),
    });

    try std.testing.expectEqual(2, messages.recipients.items.len);
    try std.testing.expectEqual(2, messages.senders.items.len);
    try std.testing.expectEqual(2, messages.recipients.items.len);
}
test "Messages.remove" {
    const allocator = std.testing.allocator;
    var msgs: Messages = try .init(allocator, .{
        .content = @constCast("c0"),
        .sender = @constCast("s0"),
        .recipient = @constCast("r0"),
    });
    defer msgs.deinit(allocator);

    try msgs.append(allocator, .{
        .content = @constCast("c1"),
        .sender = @constCast("s1"),
        .recipient = @constCast("r1"),
    });
    try msgs.append(allocator, .{
        .content = @constCast("c2"),
        .sender = @constCast("s2"),
        .recipient = @constCast("r2"),
    });

    try msgs.remove(1);

    try std.testing.expectEqual(2, msgs.contents.items.len);
    try std.testing.expectEqual(2, msgs.senders.items.len);
    try std.testing.expectEqual(2, msgs.recipients.items.len);

    try std.testing.expectEqualStrings("r2", msgs.recipients.items[msgs.recipients.items.len - 1]);
    try std.testing.expectEqualStrings("s2", msgs.senders.items[msgs.senders.items.len - 1]);
    try std.testing.expectEqualStrings("c2", msgs.contents.items[msgs.contents.items.len - 1]);

    try msgs.append(allocator, .{
        .content = @constCast("cnew"),
        .sender = @constCast("snew"),
        .recipient = @constCast("rnew"),
    });

    try std.testing.expectEqualStrings("rnew", msgs.recipients.items[msgs.recipients.items.len - 1]);
    try std.testing.expectEqualStrings("snew", msgs.senders.items[msgs.senders.items.len - 1]);
    try std.testing.expectEqualStrings("cnew", msgs.contents.items[msgs.contents.items.len - 1]);
}

fn writeToLog(
    file_writer: *std.fs.File.Writer,
    messages: Messages,
) !void {
    for (messages.indxs.items) |idx| {
        const msg = messages.getMessage(idx);
        try file_writer.interface.print("{s},{s},{s}\n", .{
            @constCast(msg.sender),
            @constCast(msg.recipient),
            @constCast(msg.content),
        });
        try file_writer.interface.flush();
    }
}

test writeToLog {
    const allocator = std.testing.allocator;
    var msgs: Messages = try .init(allocator, .{
        .content = @constCast("c0"),
        .sender = @constCast("s0"),
        .recipient = @constCast("r0"),
    });
    defer msgs.deinit(allocator);

    const config = try getConfigDir(allocator, ".config", "unchat");

    const path: []u8 = @constCast("./writeToLog_test.txt");
    var file = try config.createFile(path, .{ .read = true, .truncate = false });
    defer file.close();

    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;

    var reader: std.fs.File.Reader = file.reader(&rbuf);
    var writer: std.fs.File.Writer = file.writer(&wbuf);

    try writeToLog(&writer, msgs);

    const expected = "s0,r0,c0";
    const actual = (try reader.interface.takeDelimiter('\n')).?;

    try std.testing.expectEqualStrings(expected, actual);

    try config.deleteFile(path);
}

fn readFromLog(
    allocator: std.mem.Allocator,
    file_reader: *std.fs.File.Reader,
) !Messages {
    var msgs: Messages = .empty;
    const src = takeMore(&file_reader.interface) catch |err| switch (err) {
        error.EndOfStream => @constCast(""),
        error.ReadFailed => @constCast("ReadFailed"),
        else => return err,
    };

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var values = std.mem.splitScalar(u8, line, ',');
        const sender = values.next() orelse return error.InvalidLogLine;
        const recipient = values.next() orelse return error.InvalidLogLine;
        const content = values.rest();

        try msgs.append(allocator, .{
            .sender = sender,
            .recipient = recipient,
            .content = content,
        });
    }
    return msgs;
}

test readFromLog {
    const allocator = std.testing.allocator;
    const path: []u8 = @constCast("./writeToLog_test.txt");
    const config = try getConfigDir(allocator, ".config", "unchat");
    var file = try config.createFile(
        path,
        .{ .read = true, .truncate = true },
    );
    defer file.close();

    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;

    var reader: std.fs.File.Reader = file.reader(&rbuf);
    var writer: std.fs.File.Writer = file.writer(&wbuf);
    const expected = "s0,r0,c0\ns1,r1,c1\ns2,r2,c2\n";

    try writer.interface.print("{s}", .{expected});
    try writer.interface.flush();

    try file.seekTo(0);
    var msgs: Messages = try readFromLog(allocator, &reader);
    defer msgs.deinit(allocator);

    const msg = msgs.getMessage(1);
    try std.testing.expectEqualStrings("s1", msg.sender);
    try std.testing.expectEqualStrings("r1", msg.recipient);
    try std.testing.expectEqualStrings("c1", msg.content);

    try config.deleteFile(path);
}

fn run(
    allocator: std.mem.Allocator,
    conn: *Connection,
) !void {
    var input_buff: [1024]u8 = undefined;
    var output_buff: [1024]u8 = undefined;

    var conn_reader = conn.tls.reader(&conn.tls_rbuf);
    var conn_writer = conn.tls.writer(&conn.tls_wbuf);
    var input_reader = std.fs.File.stdin().reader(&input_buff);
    var output_writer = std.fs.File.stdout().writer(&output_buff);

    //roster
    try conn_writer.interface.writeAll(try xmpp.Stanzas.Iq.formatIq(
        allocator,
        .get,
        try xmpp.Stanzas.Iq.Requests.formatQuery(allocator),
    ));

    try conn_writer.interface.writeAll("<presence/>");
    try conn_writer.interface.flush();

    const roster_src = try takeMore(&conn_reader.interface);
    const user_jid: []const u8 = blk: {
        const idx: usize = std.mem.indexOf(u8, roster_src, "to").?;
        break :blk getAtributeValue(u8, roster_src, idx);
    };

    var roster_jids = try getRosterJids(allocator, roster_src);
    defer roster_jids.deinit(allocator);

    const chat_jid = try selectFromList(
        roster_jids,
        &input_reader.interface,
        &output_writer.interface,
    );

    const log_file = blk: {
        const log_dir = "log";
        const config = try getConfigDir(allocator, ".config", "unchat");
        config.makeDir(log_dir) catch |err| switch (err) {
            std.fs.Dir.MakeError.PathAlreadyExists => {},
            else => return err,
        };
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}_log.txt",
            .{ log_dir, chat_jid },
        );
        defer allocator.free(path);
        var file = try config.createFile(
            path,
            .{ .read = true, .truncate = false },
        );
        try file.seekFromEnd(0);
        break :blk file;
    };
    defer log_file.close();

    var rbuf: [1024]u8 = undefined;
    var wbuf: [1024]u8 = undefined;

    var reader = log_file.reader(&rbuf);
    var writer = log_file.writer(&wbuf);

    //reading chat log
    var messages: Messages = try readFromLog(allocator, &reader);
    defer messages.deinit(allocator);

    //listen to messages in background
    const listen_thread = try std.Thread.spawn(.{}, listenToMessages, .{
        allocator,
        &conn_reader.interface,
        &messages,
    });
    listen_thread.detach();

    while (true) {
        dysplay(messages);

        //clear input reader
        try input_reader.interface.discardAll(input_reader.interface.bufferedLen());
        //get text from user
        const user_message = try input_reader.interface.takeDelimiterExclusive('\n');

        if (std.mem.eql(u8, user_message, ":q")) {
            break;
        }

        //send message
        try conn_writer.interface.writeAll(
            try xmpp.Stanzas.Message.formatMessage(
                allocator,
                @constCast(user_jid),
                @constCast(chat_jid),
                .chat,
                user_message,
            ),
        );
        try conn_writer.interface.flush();

        //save a message
        try messages.append(allocator, .{
            .sender = user_jid,
            .recipient = chat_jid,
            .content = try allocator.dupe(u8, std.mem.trimEnd(u8, user_message, " \n\r")),
        });

        dysplay(messages);
    }
    try writeToLog(&writer, messages);
}

///set tty settings to hide input
fn hide_input() !TTYsettings {
    const tty_file = try std.fs.openFileAbsolute("/dev/tty", .{});
    const tty_fd = tty_file.handle;

    var old_settings: std.os.linux.termios = undefined;
    _ = std.os.linux.tcgetattr(tty_fd, &old_settings);

    var new_settings: std.os.linux.termios = old_settings;
    new_settings.lflag.ICANON = false;
    new_settings.lflag.ECHO = false;

    _ = std.os.linux.tcsetattr(tty_fd, .NOW, &new_settings);

    return .{
        .tty_file = tty_file,
        .old_settings = old_settings,
    };
}

///return input to the start state
fn show_input(settings: TTYsettings) !void {
    _ = std.os.linux.tcsetattr(
        settings.tty_file.handle,
        .NOW,
        &settings.old_settings,
    );
    settings.tty_file.close();
}

fn getAccountList(
    allocator: std.mem.Allocator,
    filepath: []const u8,
) !struct {
    allocator: std.mem.Allocator,
    src: []u8,
    list: std.ArrayList([]const u8),

    fn deinit(
        self: *@This(),
    ) void {
        self.list.deinit(self.allocator);
        self.allocator.free(self.src);
    }
} {
    var res: std.ArrayList([]const u8) = .empty;
    var config = try getConfigDir(allocator, ".config", "unchat");
    defer config.close();

    config.access(filepath, .{}) catch |err| switch (err) {
        error.FileNotFound => try initAccount(allocator),
        else => return err,
    };

    const src = try config.readFileAlloc(allocator, filepath, 2048);

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        //skip empty lines
        if (std.mem.eql(u8, line, "")) continue;
        try res.append(
            allocator,
            line,
        );
    }
    return .{
        .src = src,
        .list = res,
        .allocator = allocator,
    };
}
test getAccountList {
    const allocator = std.testing.allocator;
    const path: []const u8 = "tst";
    const config = try getConfigDir(allocator, ".config", "unchat");
    var file: std.fs.File = try config.createFile(path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close();

    var wbuf: [1024]u8 = undefined;
    var wrt = file.writer(&wbuf);

    try wrt.interface.print("a@b\nc@d\n", .{});
    try wrt.interface.flush();

    var res = try getAccountList(
        allocator,
        path,
    );
    defer res.deinit();

    try std.testing.expectEqualStrings("a@b", res.list.items[0]);
    try std.testing.expectEqualStrings("c@d", res.list.items[1]);

    try config.deleteFile(path);
}

fn getConfigDir(
    allocator: std.mem.Allocator,
    default_config_dir: []const u8,
    appname: []const u8,
) !std.fs.Dir {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    const home_path = env.get("HOME") orelse return error.HomeNotFound;

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{
        home_path,
        default_config_dir,
        appname,
    });
    defer allocator.free(config_path);

    std.fs.makeDirAbsolute(config_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return std.fs.openDirAbsolute(config_path, .{ .access_sub_paths = true });
}

fn initAccount(allocator: std.mem.Allocator) !void {
    const filename: []const u8 = "accounts.md";
    const config = try getConfigDir(allocator, ".config", "unchat");
    _ = try config.createFile("accounts.md", .{});

    var in_buff: [1024]u8 = undefined;
    var in_reader = std.fs.File.stdin().reader(&in_buff);
    const in_r = &in_reader.interface;

    std.debug.print("enter your jid:\n", .{});

    const jid = try in_r.takeDelimiterExclusive('\n');
    var file = try config.openFile(filename, .{ .mode = .write_only });
    defer file.close();

    var buf: [1024]u8 = undefined;
    var wrt = file.writer(&buf);

    try wrt.interface.print("{s}\n", .{jid});
    try wrt.interface.flush();
}

fn makeConnection(
    allocator: std.mem.Allocator,
    port: u16,
    hostname: []const u8,
    username: []const u8,
    pass: []const u8,
) !Connection {
    var conn: Connection = undefined;

    //open tcp connection
    conn.tcp = try std.net.tcpConnectToHost(allocator, hostname, port);

    //get reader & writer interfaces from tcp connection
    var tcp_reader = conn.tcp.reader(&conn.tcp_rbuf);
    var tcp_writer = conn.tcp.writer(&conn.tcp_wbuf);

    //open xmpp stream
    try tcp_writer.interface.writeAll(try xmpp.Stanzas.formatHeader(allocator, @constCast("me"), @constCast(hostname)));
    try tcp_writer.interface.flush();

    //read response
    _ = try takeMore(tcp_reader.interface());

    //start tls negotiation
    try tcp_writer.interface.writeAll(xmpp.Stanzas.starttls_string);
    try tcp_writer.interface.flush();

    //read response
    _ = try takeMore(tcp_reader.interface());

    //establish tls connection

    var tls_reader = conn.tcp.reader(&conn.tls_rbuf);
    var tls_writer = conn.tcp.writer(&conn.tls_wbuf);

    conn.tls = blk: {
        const url = try std.fmt.allocPrint(allocator, "https://{s}", .{hostname});
        const uri = try std.Uri.parse(url);
        const host = uri.host.?.percent_encoded;

        var root_ca = try tls.config.cert.fromSystem(allocator);
        defer root_ca.deinit(allocator);

        break :blk try tls.client(tls_reader.interface(), &tls_writer.interface, .{
            .host = host,
            .root_ca = root_ca,
        });
    };

    //tls connection reader and writer
    var conn_reader = conn.tls.reader(&conn.tls_rbuf);
    var conn_writer = conn.tls.writer(&conn.tcp_wbuf);

    //restart xmpp stream
    try conn_writer.interface.writeAll(try xmpp.Stanzas.formatHeader(
        allocator,
        @constCast("me"),
        @constCast(hostname),
    ));
    try conn_writer.interface.flush();

    //read response
    _ = try takeMore(&conn_reader.interface);

    //sasl negotioation (login)
    try saslNegotioation(
        allocator,
        &conn.tls,
        username,
        hostname,
        pass,
    );

    // resourse binding
    try resourceBinding(allocator, &conn.tls);

    return conn;
}

fn start(
    allocator: std.mem.Allocator,
    port: u16,
) !Connection {
    var input_buff: [1024]u8 = undefined;
    var output_buff: [1024]u8 = undefined;

    var input_reader = std.fs.File.stdin().reader(&input_buff);
    var output_writer = std.fs.File.stdout().writer(&output_buff);

    const account_file_name: []const u8 = "accounts.md";
    var account_list = try getAccountList(allocator, account_file_name);
    defer account_list.deinit();

    const jid = try selectFromList(
        account_list.list,
        &input_reader.interface,
        &output_writer.interface,
    );
    const at = std.mem.indexOfScalar(u8, jid, '@').?;

    const username = jid[0..at];
    const hostname = jid[at + 1 ..];

    //enter password
    std.debug.print("\np:", .{});
    const tty_settings = try hide_input();
    const pass = try input_reader.interface.takeDelimiterExclusive('\n');
    try show_input(tty_settings);

    std.debug.print("Connecting to {s}:{d}...\n", .{ hostname, port });

    const conn = try makeConnection(
        allocator,
        port,
        hostname,
        username,
        pass,
    );

    //clear
    std.debug.print("\x1b[2J\x1b[H", .{});
    std.debug.print("\nsuccess!\n", .{});

    return conn;
}

pub fn main() !void {
    const port = 5222;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var conn = try start(
        allocator,
        port,
    );

    try run(allocator, &conn);
}
