const std = @import("std");
const Messages = @import("root.zig").Messages;

pub fn dysplay(messages: Messages) void {
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
