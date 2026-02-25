//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const Messages = struct {
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
