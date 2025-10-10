const std = @import("std");
const testing = std.testing;
const telnet = @import("../src/protocol/telnet.zig");
const TelnetProcessor = @import("../src/protocol/telnet_processor.zig").TelnetProcessor;

const TelnetState = telnet.TelnetState;
const TelnetCommand = telnet.TelnetCommand;
const TelnetOption = telnet.TelnetOption;

test "telnet state transitions" {
    // Test basic IAC sequence
    try telnet.validateStateTransition(.data, .iac, @intFromEnum(TelnetCommand.iac));
    try telnet.validateStateTransition(.iac, .will, @intFromEnum(TelnetCommand.will));
    try telnet.validateStateTransition(.will, .data, @intFromEnum(TelnetOption.echo));

    // Test escaped IAC
    try telnet.validateStateTransition(.iac, .data, @intFromEnum(TelnetCommand.iac));

    // Test subnegotiation
    try telnet.validateStateTransition(.iac, .sb, @intFromEnum(TelnetCommand.sb));
    try telnet.validateStateTransition(.sb, .sb_data, @intFromEnum(TelnetOption.terminal_type));
    try telnet.validateStateTransition(.sb_data, .sb_iac, @intFromEnum(TelnetCommand.iac));
    try telnet.validateStateTransition(.sb_iac, .data, @intFromEnum(TelnetCommand.se));
}

test "invalid state transitions" {
    // Test invalid transitions
    try testing.expectError(telnet.TelnetError.InvalidStateTransition, telnet.validateStateTransition(.data, .will, 100));
    try testing.expectError(telnet.TelnetError.InvalidStateTransition, telnet.validateStateTransition(.iac, .data, 100));
}

test "telnet command validation" {
    try testing.expect(telnet.isValidCommand(@intFromEnum(TelnetCommand.iac)));
    try testing.expect(telnet.isValidCommand(@intFromEnum(TelnetCommand.will)));
    try testing.expect(telnet.isValidCommand(@intFromEnum(TelnetCommand.se)));
    try testing.expect(!telnet.isValidCommand(100));
    try testing.expect(!telnet.isValidCommand(200));
}

test "telnet option validation" {
    try testing.expect(telnet.isRecognizedOption(@intFromEnum(TelnetOption.echo)));
    try testing.expect(telnet.isRecognizedOption(@intFromEnum(TelnetOption.terminal_type)));
    try testing.expect(!telnet.isRecognizedOption(100));
    try testing.expect(!telnet.isRecognizedOption(200));
}

test "command requires option" {
    try testing.expect(telnet.commandRequiresOption(.will));
    try testing.expect(telnet.commandRequiresOption(.wont));
    try testing.expect(telnet.commandRequiresOption(.do));
    try testing.expect(telnet.commandRequiresOption(.dont));
    try testing.expect(telnet.commandRequiresOption(.sb));
    try testing.expect(!telnet.commandRequiresOption(.nop));
    try testing.expect(!telnet.commandRequiresOption(.ga));
}
test "telnet processor basic functionality" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24);
    defer processor.deinit();

    // Test normal data processing
    const input1 = "Hello World";
    const result1 = try processor.processInput(input1);
    defer testing.allocator.free(result1.data);
    defer testing.allocator.free(result1.response);

    try testing.expectEqualStrings("Hello World", result1.data);
    try testing.expect(result1.response.len == 0);
}

test "telnet processor IAC escape" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24);
    defer processor.deinit();

    // Test escaped IAC (IAC IAC -> single IAC in output)
    const input = [_]u8{ @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.iac) };
    const result = try processor.processInput(&input);
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.response);

    try testing.expect(result.data.len == 1);
    try testing.expect(result.data[0] == @intFromEnum(TelnetCommand.iac));
    try testing.expect(result.response.len == 0);
}

test "telnet processor option negotiation" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24);
    defer processor.deinit();

    // Test WILL ECHO negotiation
    const input = [_]u8{ @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.will), @intFromEnum(TelnetOption.echo) };
    const result = try processor.processInput(&input);
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.response);

    // Should produce no application data
    try testing.expect(result.data.len == 0);

    // Should generate DO ECHO response
    try testing.expect(result.response.len == 3);
    try testing.expect(result.response[0] == @intFromEnum(TelnetCommand.iac));
    try testing.expect(result.response[1] == @intFromEnum(TelnetCommand.do));
    try testing.expect(result.response[2] == @intFromEnum(TelnetOption.echo));
}

test "telnet processor mixed data and commands" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24);
    defer processor.deinit();

    // Test mixed data: "Hello" + IAC WILL ECHO + "World"
    const input = [_]u8{ 'H', 'e', 'l', 'l', 'o', @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.will), @intFromEnum(TelnetOption.echo), 'W', 'o', 'r', 'l', 'd' };
    const result = try processor.processInput(&input);
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.response);

    // Should extract "HelloWorld" as application data
    try testing.expectEqualStrings("HelloWorld", result.data);

    // Should generate negotiation response
    try testing.expect(result.response.len == 3);
}

test "telnet processor buffer overflow protection" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24);
    defer processor.deinit();

    // Create oversized subnegotiation
    var long_input = std.ArrayList(u8){};
    defer long_input.deinit(testing.allocator);

    try long_input.appendSlice(testing.allocator, &[_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.terminal_type),
    });

    // Add more than MAX_SUBNEGOTIATION_LENGTH bytes
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        try long_input.append(testing.allocator, 'A');
    }

    // Should return error for buffer overflow
    try testing.expectError(telnet.TelnetError.SubnegotiationTooLong, processor.processInput(long_input.items));
}
