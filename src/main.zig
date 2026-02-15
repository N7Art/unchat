const std = @import("std");
const unchat = @import("unchat");
const tls = @import("tls");
const xmpp = unchat.Xmpp;

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

fn dysplay(messages: Messages) void {
    //clear dysplay
    std.debug.print("\x1b[2J\x1b[H", .{});
    //dump log in stdout
    for (messages.indxs.items) |index| {
        std.debug.print("{d} {s}\n\t{s}\n", .{
            index,
            messages.senders.items[index],
            messages.contents.items[index],
        });
    }
    //input field to stdout
    std.debug.print("\n---------------------\n|", .{});
}

test dysplay {
    const allocator = std.testing.allocator;
    var msgs: Messages = try .init(allocator, .{
        .content = @constCast("c0"),
        .sender = @constCast("s0"),
        .recipient = @constCast("r0"),
    });
    try msgs.append(allocator, .{
        .content = "asfdasdfasdf",
        .recipient = "me",
        .sender = "somebody",
    });
    defer msgs.deinit(allocator);
    dysplay(msgs);
}

fn selectUser(
    account_list: *std.ArrayList([]const u8),
) ![]const u8 {
    var in_buff: [1024]u8 = undefined;
    var in_reader = std.fs.File.stdin().reader(&in_buff);
    const inr = &in_reader.interface;
    //clear terminal
    std.debug.print("\x1b[2J\x1b[H", .{});

    const symbols = struct {
        pub const arrow = @constCast("->");
        pub const empty = @constCast("  ");
    };

    var selected: u8 = 0;
    const account_num: u8 = @intCast(account_list.items.len);
    var move: u8 = undefined;
    var sign: []u8 = symbols.arrow;
    while (move != '\n') {
        //clear
        std.debug.print("\x1b[2J\x1b[H", .{});
        try inr.discardAll(inr.bufferedLen());
        std.debug.print("select account:\n", .{});

        for (account_list.items, 0..) |account, i| {
            sign = if (selected == i) symbols.arrow else symbols.empty;
            std.debug.print("{s} {s}\n", .{ sign, account });
        }
        move = (try inr.take(1))[0];
        selected = switch (move) {
            'j' => if (selected < account_num - 1) selected + 1 else 0,
            'k' => if (selected > 0) selected - 1 else account_num - 1,
            else => selected,
        };
    }

    return account_list.items[selected];
}

fn getConnection(
    allocator: std.mem.Allocator,
    hostname: []const u8,
    reader: *std.net.Stream.Reader,
    writer: *std.net.Stream.Writer,
) !tls.Connection {
    const url = try std.fmt.allocPrint(allocator, "https://{s}", .{hostname});
    const uri = try std.Uri.parse(url);
    const host = uri.host.?.percent_encoded;

    var root_ca = try tls.config.cert.fromSystem(allocator);
    defer root_ca.deinit(allocator);

    return tls.client(reader.interface(), &writer.interface, .{
        .host = host,
        .root_ca = root_ca,
    });
}

fn saslNegotioation(
    allocator: std.mem.Allocator,
    conn_reader: *std.Io.Reader,
    conn_writer: *std.Io.Writer,
    debug_file_writer: *std.Io.Writer,
    username: []const u8,
    hostname: []const u8,
    pass: []const u8,
) !void {
    var buf: [1024]u8 = undefined;
    var pass_buf: [1024]u8 = undefined;
    const auth_string = std.base64.standard.Encoder.encode(&buf, try std.fmt.bufPrint(&pass_buf, "\x00{s}\x00{s}", .{ username, pass }));
    try conn_writer.writeAll(try xmpp.Stanzas.formatAuth(allocator, @constCast(xmpp.AuthMechanism.PLAIN), @constCast(auth_string)));
    try conn_writer.flush();

    // read response
    const response = try takeMore(conn_reader);
    if (std.mem.eql(u8, response[0..xmpp.ResponseErrors.failed_response.len], xmpp.ResponseErrors.failed_response)) {
        std.debug.print("\nfailure!\n{s}", .{response});
        return;
    }

    // read response
    try debug_file_writer.writeAll(response);
    try debug_file_writer.flush();

    //clear connection reader
    try conn_reader.discardAll(conn_reader.bufferedLen());

    //restart xmpp stream
    try conn_writer.writeAll(try xmpp.Stanzas.formatHeader(
        allocator,
        try std.fmt.allocPrint(allocator, "{s}@{s}", .{ username, hostname }),
        @constCast(hostname),
    ));
    try conn_writer.flush();

    // read response
    try debug_file_writer.writeAll(try takeMore(conn_reader));
    try debug_file_writer.flush();
}

fn resourceBinding(
    allocator: std.mem.Allocator,
    conn_writer: *std.Io.Writer,
    conn_reader: *std.Io.Reader,
) !void {
    // has 2 components with params iq and its body
    try conn_writer.writeAll(try xmpp.Stanzas.Iq.formatIq(
        allocator,
        .set,
        try xmpp.Stanzas.Iq.Requests.formatBind(allocator, "unchat"),
    ));
    try conn_writer.flush();
    //read responce
    _ = try takeMore(conn_reader);
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
    const start = std.mem.indexOfScalarPos(T, haystack, idx, '\'').?;
    const end = std.mem.indexOfScalarPos(T, haystack, start + 1, '\'').?;
    return haystack[start + 1 .. end];
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
        const start = std.mem.indexOfScalarPos(
            u8,
            src,
            tag_start + open_name.len,
            '>',
        ) orelse return error.TagNotClosed;

        const end = std.mem.indexOfPos(
            u8,
            src,
            start,
            close_name,
        ) orelse {
            std.debug.print("{s}", .{src[start..]});
            return error.ClosingTagNotFound;
        };

        break :blk src[start + 1 .. end];
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

const Messages = struct {
    indxs: std.ArrayList(usize),
    ids: std.ArrayList(usize),

    senders: std.ArrayList([]const u8),
    recipients: std.ArrayList([]const u8),
    contents: std.ArrayList([]const u8),

    pub const empty: Messages = .{
        .ids = .empty,
        .indxs = .empty,
        .contents = .empty,
        .senders = .empty,
        .recipients = .empty,
    };

    pub fn init(allocator: std.mem.Allocator, message: Message) !Messages {
        var tmp: Messages = .empty;
        try tmp.append(allocator, message);
        return tmp;
    }

    pub fn deinit(self: *Messages, allocator: std.mem.Allocator) void {
        self.indxs.deinit(allocator);
        self.ids.deinit(allocator);
        self.senders.deinit(allocator);
        self.recipients.deinit(allocator);
        self.contents.deinit(allocator);
    }

    pub const Message = struct {
        sender: []const u8,
        recipient: []const u8,
        content: []const u8,
    };

    pub fn getMessage(self: Messages, indx: usize) Message {
        const data_indx = self.indxs.items[indx];
        return .{
            .sender = self.senders.items[data_indx],
            .recipient = self.recipients.items[data_indx],
            .content = self.contents.items[data_indx],
        };
    }

    pub fn append(self: *Messages, allocator: std.mem.Allocator, message: Message) !void {
        const rec_len = self.recipients.items.len;
        const sen_len = self.senders.items.len;
        const con_len = self.contents.items.len;
        std.debug.assert(rec_len == sen_len and rec_len == con_len and sen_len == con_len);

        const is_full: bool = rec_len == self.ids.items.len and
            sen_len == self.ids.items.len and
            con_len == self.ids.items.len;

        if (is_full) {
            try self.indxs.append(allocator, self.indxs.items.len);
            try self.ids.append(allocator, self.ids.items.len);
        }

        try self.senders.append(allocator, message.sender);
        try self.recipients.append(allocator, message.recipient);
        try self.contents.append(allocator, message.content);
    }

    pub fn remove(self: *Messages, indx: usize) !void {
        const element_indx = self.indxs.items[indx];
        _ = self.contents.swapRemove(element_indx);
        _ = self.recipients.swapRemove(element_indx);
        _ = self.senders.swapRemove(element_indx);

        //swap in id
        const id_last = self.ids.items.len - 1;
        const tmp = self.ids.items[id_last];
        self.ids.items[id_last] = self.ids.items[element_indx];
        self.ids.items[element_indx] = tmp;

        //update in indx
        self.indxs.items[indx] = self.ids.items[indx];
        self.indxs.items[self.indxs.items.len - 1] = self.ids.items[id_last];
    }
};
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
    conn_reader: *std.Io.Reader,
    conn_writer: *std.Io.Writer,
    inr: *std.Io.Reader,
) !void {

    //roster
    try conn_writer.writeAll(try xmpp.Stanzas.Iq.formatIq(
        allocator,
        .get,
        try xmpp.Stanzas.Iq.Requests.formatQuery(allocator),
    ));

    try conn_writer.writeAll("<presence/>");

    try conn_writer.flush();

    const roster_src = try takeMore(conn_reader);
    const user_jid: []const u8 = blk: {
        const idx: usize = std.mem.indexOf(u8, roster_src, "to").?;
        break :blk getAtributeValue(u8, roster_src, idx);
    };

    var roster_jids = try getRosterJids(allocator, roster_src);
    defer roster_jids.deinit(allocator);

    const tty_file = try std.fs.openFileAbsolute("/dev/tty", .{});
    defer tty_file.close();
    const tty_fd = tty_file.handle;

    const old_settings = try hide_input(tty_fd);

    const chat_jid = try selectUser(&roster_jids);
    try show_input(tty_fd, old_settings);

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
        conn_reader,
        &messages,
    });
    listen_thread.detach();

    while (true) {
        dysplay(messages);

        //clear input reader
        try inr.discardAll(inr.bufferedLen());
        //get text from user
        const user_message = try inr.takeDelimiterExclusive('\n');

        if (std.mem.eql(u8, user_message, ":q")) {
            break;
        }

        //send message
        try conn_writer.writeAll(
            try xmpp.Stanzas.Message.formatMessage(
                allocator,
                @constCast(user_jid),
                @constCast(chat_jid),
                .chat,
                user_message,
            ),
        );
        try conn_writer.flush();

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

fn hide_input(tty_fd: i32) !std.os.linux.termios {
    var old_settings: std.os.linux.termios = undefined;
    _ = std.os.linux.tcgetattr(tty_fd, &old_settings);

    var new_settings: std.os.linux.termios = old_settings;
    new_settings.lflag.ICANON = false;
    new_settings.lflag.ECHO = false;

    _ = std.os.linux.tcsetattr(tty_fd, .NOW, &new_settings);

    return old_settings;
}

fn show_input(tty_fd: i32, old_settings: std.os.linux.termios) !void {

    //return input to the start state
    _ = std.os.linux.tcsetattr(tty_fd, .NOW, &old_settings);
    std.debug.print("\n", .{});
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
    const config = try getConfigDir(allocator, ".config", "unchat");
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

pub fn main() !void {
    const port = 5222;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var in_buff: [1024]u8 = undefined;
    var in_reader = std.fs.File.stdin().reader(&in_buff);
    const in_r = &in_reader.interface;

    const tty_file = try std.fs.openFileAbsolute("/dev/tty", .{});
    defer tty_file.close();
    const tty_fd = tty_file.handle;

    const account_file_name: []const u8 = "accounts.md";

    var config = try getConfigDir(allocator, ".config", "unchat");
    defer config.close();

    config.access(account_file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => try initAccount(allocator),
        else => return err,
    };

    var account_list = try getAccountList(allocator, account_file_name);
    defer account_list.deinit();

    const old_settings = try hide_input(tty_fd);
    const jid = try selectUser(&account_list.list);
    const at = std.mem.indexOfScalar(u8, jid, '@').?;

    const username = jid[0..at];
    const hostname = jid[at + 1 ..];
    //enter password
    std.debug.print("\np:", .{});
    const pass = try in_r.takeDelimiterExclusive('\n');

    try show_input(tty_fd, old_settings);

    std.debug.print("Connecting to {s}:{d}...\n", .{ hostname, port });

    //open tcp connection
    var tcp = try std.net.tcpConnectToHost(allocator, hostname, port);
    defer tcp.close();

    //get reader & writer interfaces from tcp connection
    var reader_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
    var tcp_reader_wraper = tcp.reader(&reader_buf);
    const tcp_reader: *std.Io.Reader = tcp_reader_wraper.interface();
    var writer_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
    var tcp_writer_wraper = tcp.writer(&writer_buf);
    const tcp_writer: *std.Io.Writer = &tcp_writer_wraper.interface;

    //open debug file
    const debug_file = try config.createFile("debug.xml", .{ .truncate = true });
    defer debug_file.close();

    //get debug file writer
    var debug_file_writer_buf: [1024]u8 = undefined;
    var debug_file_writer_wraper = debug_file.writer(&debug_file_writer_buf);
    const debug_file_writer = &debug_file_writer_wraper.interface;

    //open xmpp stream
    try tcp_writer.writeAll(try xmpp.Stanzas.formatHeader(allocator, @constCast("me"), @constCast(hostname)));
    try tcp_writer.flush();

    //read response
    _ = try takeMore(tcp_reader);

    //start tls negotiation
    try tcp_writer.writeAll(xmpp.Stanzas.starttls_string);
    try tcp_writer.flush();

    //read response
    _ = try takeMore(tcp_reader);

    //establish tls connection
    var tls_input_buf: [tls.input_buffer_len]u8 = undefined;
    var tls_output_buf: [tls.output_buffer_len]u8 = undefined;
    var tls_reader = tcp.reader(&tls_input_buf);
    var tls_writer = tcp.writer(&tls_output_buf);

    var conn: tls.Connection = try getConnection(allocator, hostname, &tls_reader, &tls_writer);

    //tls connection reader and writer
    var conn_reader_buf: [4056]u8 = undefined;
    var conn_reader_wrap = conn.reader(&conn_reader_buf);
    const conn_reader = &conn_reader_wrap.interface;
    var conn_writer_buf: [4056]u8 = undefined;
    var conn_writer_wrap = conn.writer(&conn_writer_buf);
    const conn_writer = &conn_writer_wrap.interface;

    //restart xmpp stream
    try conn_writer.writeAll(try xmpp.Stanzas.formatHeader(
        allocator,
        @constCast("me"),
        @constCast(hostname),
    ));
    try conn_writer.flush();

    //read response
    _ = try takeMore(conn_reader);

    //sasl negotioation (login)
    try saslNegotioation(
        allocator,
        conn_reader,
        conn_writer,
        debug_file_writer,
        username,
        hostname,
        pass,
    );

    // resourse binding
    try resourceBinding(allocator, conn_writer, conn_reader);

    //clear
    std.debug.print("\x1b[2J\x1b[H", .{});
    std.debug.print("\nsuccess!\n", .{});

    //////////// chatting
    try run(
        allocator,
        conn_reader,
        conn_writer,
        in_r,
    );
}
