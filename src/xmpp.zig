const std = @import("std");
pub const AuthMechanism = struct {
    pub const PLAIN: []const u8 = "PLAIN";
};
pub const ResponseErrors = struct {
    pub const failed_response = "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>";
};
pub const Stanzas = struct {
    pub const terminate_stream_string: []const u8 = "</stream:stream>";
    pub const starttls_string: []const u8 = "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>";
    pub const auth_string: []const u8 =
        \\<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl'
        \\ mechanism='{s}'>{s}</auth>
    ;
    pub const header_string =
        \\<?xml version='1.0'?>
        \\<stream:stream
        \\  from='{s}'
        \\  to='{s}'
        \\  version='1.0'
        \\  xml:lang='en'
        \\  xmlns='jabber:client'
        \\  xmlns:stream='http://etherx.jabber.org/streams'>
    ;

    pub const Iq = struct {
        pub const iq_string =
            \\<iq id='{d}' type='{s}'>
            \\ {s}
            \\</iq>
        ;
        pub const IqType = enum { set, get };
        pub var id: u8 = 0;

        //fill the stanza with parameters, increments id variable
        pub fn formatIq(allocator: std.mem.Allocator, t: IqType, body: []const u8) ![]const u8 {
            id += 1;
            const iq_type = switch (t) {
                .set => "set",
                .get => "get",
            };
            return try std.fmt.allocPrint(allocator, Stanzas.Iq.iq_string, .{ id, iq_type, body });
        }
        pub const Requests = struct {
            pub const bind_string =
                \\<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>
                \\ <resource>{s}</resource>
                \\</bind>
            ;
            pub const query_string =
                \\ <query xmlns='jabber:iq:roster'/>
            ;
            pub fn formatBind(allocator: std.mem.Allocator, resource_name: []const u8) ![]const u8 {
                return try std.fmt.allocPrint(allocator, Stanzas.Iq.Requests.bind_string, .{resource_name});
            }
            pub fn formatQuery(allocator: std.mem.Allocator) ![]const u8 {
                return try std.fmt.allocPrint(allocator, Stanzas.Iq.Requests.query_string, .{});
            }
        };
    };
    pub const Message = struct {
        pub var id: u8 = 0;
        pub const MessageType = enum { chat };
        pub const message_string =
            \\<message
            \\       from='{s}'
            \\       id='{d}'
            \\       to='{s}'
            \\       type='{s}'
            \\       xml:lang='en'>
            \\     <body>{s}</body>
            \\   </message>
        ;
        //fill the stanza with parameters, increments id variable
        pub fn formatMessage(allocator: std.mem.Allocator, from: []u8, to: []u8, t: MessageType, message_text: []u8) ![]const u8 {
            id += 1;
            const messageType = switch (t) {
                .chat => "chat",
            };

            return try std.fmt.allocPrint(allocator, Stanzas.Message.message_string, .{ from, id, to, messageType, message_text });
        }
    };
    pub fn formatHeader(allocator: std.mem.Allocator, from: []u8, to: []u8) ![]u8 {
        return try std.fmt.allocPrint(allocator, Stanzas.header_string, .{ from, to });
    }
    pub fn formatAuth(allocator: std.mem.Allocator, mechanism: []u8, login_base64: []u8) ![]u8 {
        return try std.fmt.allocPrint(allocator, Stanzas.auth_string, .{ mechanism, login_base64 });
    }
};
