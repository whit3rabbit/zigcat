const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol");
const telnet = protocol.telnet;
const TelnetProcessor = protocol.telnet_processor.TelnetProcessor;

const TelnetCommand = telnet.TelnetCommand;
const TelnetOption = telnet.TelnetOption;

// Test data processing and filtering functionality (Task 3)

test "input processing separates telnet commands from application data" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // Input: "Hello" + IAC WILL ECHO + "World" + IAC NOP + "!"
    const input = [_]u8{
        'H',                             'e',                              'l',                             'l',                             'o',
        @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.will), @intFromEnum(TelnetOption.echo), 'W',                             'o',
        'r',                             'l',                              'd',                             @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.nop),
        '!',
    };

    const result = try processor.processInput(&input);
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.response);

    // Should extract "HelloWorld!" as application data
    try testing.expectEqualStrings("HelloWorld!", result.data);

    // Should generate negotiation response for WILL ECHO
    try testing.expect(result.response.len == 3);
    try testing.expect(result.response[0] == @intFromEnum(TelnetCommand.iac));
    try testing.expect(result.response[1] == @intFromEnum(TelnetCommand.do));
    try testing.expect(result.response[2] == @intFromEnum(TelnetOption.echo));
}

test "output processing escapes IAC bytes in application data" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // Application data containing 0xFF byte
    const app_data = [_]u8{ 'T', 'e', 's', 't', 0xFF, 'D', 'a', 't', 'a' };

    const result = try processor.processOutput(&app_data, null);
    defer testing.allocator.free(result);

    // Should escape 0xFF as IAC IAC
    const expected = [_]u8{ 'T', 'e', 's', 't', 0xFF, 0xFF, 'D', 'a', 't', 'a' };
    try testing.expectEqualSlices(u8, &expected, result);
}

test "output processing injects telnet commands" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    const app_data = "Hello";
    const command = try processor.createCommand(.will, .echo);
    defer testing.allocator.free(command);

    const result = try processor.processOutput(app_data, command);
    defer testing.allocator.free(result);

    // Should start with IAC WILL ECHO, followed by "Hello"
    try testing.expect(result.len == 8); // 3 bytes command + 5 bytes "Hello"
    try testing.expect(result[0] == @intFromEnum(TelnetCommand.iac));
    try testing.expect(result[1] == @intFromEnum(TelnetCommand.will));
    try testing.expect(result[2] == @intFromEnum(TelnetOption.echo));
    try testing.expectEqualStrings("Hello", result[3..]);
}

test "partial IAC sequence handling across input chunks" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // First chunk: "Hello" + IAC (incomplete)
    const chunk1 = [_]u8{ 'H', 'e', 'l', 'l', 'o', @intFromEnum(TelnetCommand.iac) };
    const result1 = try processor.processInput(&chunk1);
    defer testing.allocator.free(result1.data);
    defer testing.allocator.free(result1.response);

    // Should extract "Hello", no response yet
    try testing.expectEqualStrings("Hello", result1.data);
    try testing.expect(result1.response.len == 0);

    // Second chunk: WILL ECHO + "World"
    const chunk2 = [_]u8{ @intFromEnum(TelnetCommand.will), @intFromEnum(TelnetOption.echo), 'W', 'o', 'r', 'l', 'd' };
    const result2 = try processor.processInput(&chunk2);
    defer testing.allocator.free(result2.data);
    defer testing.allocator.free(result2.response);

    // Should extract "World" and generate response
    try testing.expectEqualStrings("World", result2.data);
    try testing.expect(result2.response.len == 3);
    try testing.expect(result2.response[0] == @intFromEnum(TelnetCommand.iac));
    try testing.expect(result2.response[1] == @intFromEnum(TelnetCommand.do));
    try testing.expect(result2.response[2] == @intFromEnum(TelnetOption.echo));
}

test "partial subnegotiation handling" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // First chunk: IAC SB TERMINAL_TYPE (incomplete)
    const chunk1 = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.terminal_type),
    };
    const result1 = try processor.processInput(&chunk1);
    defer testing.allocator.free(result1.data);
    defer testing.allocator.free(result1.response);

    try testing.expect(result1.data.len == 0);
    try testing.expect(result1.response.len == 0);

    // Second chunk: subnegotiation data + IAC SE
    const chunk2 = [_]u8{ 1, 'v', 't', '1', '0', '0', @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.se) };
    const result2 = try processor.processInput(&chunk2);
    defer testing.allocator.free(result2.data);
    defer testing.allocator.free(result2.response);

    // Subnegotiation should be processed
    try testing.expect(result2.data.len == 0);
    // Response depends on subnegotiation handler implementation
}

test "buffer overflow protection for partial sequences" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // Create oversized partial sequence
    var large_chunk = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer large_chunk.deinit(testing.allocator);

    try large_chunk.append(testing.allocator, @intFromEnum(TelnetCommand.iac));
    // Add more bytes than MAX_PARTIAL_BUFFER_SIZE
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try large_chunk.append(testing.allocator, 'A');
    }

    // Should return buffer overflow error
    try testing.expectError(telnet.TelnetError.BufferOverflow, processor.processInput(large_chunk.items));
}

test "subnegotiation buffer management" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // Create subnegotiation that exceeds maximum length
    var long_subneg = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer long_subneg.deinit(testing.allocator);

    try long_subneg.appendSlice(testing.allocator, &[_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.terminal_type),
    });

    // Add more than MAX_SUBNEGOTIATION_LENGTH bytes
    var j: usize = 0;
    while (j < 2000) : (j += 1) {
        try long_subneg.append(testing.allocator, 'A');
    }

    // Should return subnegotiation too long error
    try testing.expectError(telnet.TelnetError.SubnegotiationTooLong, processor.processInput(long_subneg.items));
}

test "create command sequences" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // Test simple command
    const nop_cmd = try processor.createCommand(.nop, null);
    defer testing.allocator.free(nop_cmd);

    try testing.expect(nop_cmd.len == 2);
    try testing.expect(nop_cmd[0] == @intFromEnum(TelnetCommand.iac));
    try testing.expect(nop_cmd[1] == @intFromEnum(TelnetCommand.nop));

    // Test option command
    const will_echo = try processor.createCommand(.will, .echo);
    defer testing.allocator.free(will_echo);

    try testing.expect(will_echo.len == 3);
    try testing.expect(will_echo[0] == @intFromEnum(TelnetCommand.iac));
    try testing.expect(will_echo[1] == @intFromEnum(TelnetCommand.will));
    try testing.expect(will_echo[2] == @intFromEnum(TelnetOption.echo));

    // Test invalid command (requires option but none provided)
    try testing.expectError(telnet.TelnetError.InvalidCommand, processor.createCommand(.will, null));
}

test "mixed IAC escape and commands" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // Input: IAC IAC (escaped) + IAC WILL ECHO + IAC IAC (escaped)
    const input = [_]u8{
        @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.iac), // Escaped IAC
        @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.will), @intFromEnum(TelnetOption.echo), // Command
        @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.iac), // Escaped IAC
    };

    const result = try processor.processInput(&input);
    defer testing.allocator.free(result.data);
    defer testing.allocator.free(result.response);

    // Should extract two 0xFF bytes as application data
    try testing.expect(result.data.len == 2);
    try testing.expect(result.data[0] == 0xFF);
    try testing.expect(result.data[1] == 0xFF);

    // Should generate response for WILL ECHO
    try testing.expect(result.response.len == 3);
}

test "error recovery with buffer clearing" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // Put processor in subnegotiation state
    const input = [_]u8{
        @intFromEnum(TelnetCommand.iac),
        @intFromEnum(TelnetCommand.sb),
        @intFromEnum(TelnetOption.terminal_type),
        'v',
        't',
        '1',
        '0',
        '0',
    };

    _ = try processor.processInput(&input);

    // Verify buffers have data
    try testing.expect(processor.sb_buffer.items.len > 0);

    // Clear buffers for error recovery
    processor.clearBuffers();

    // Verify buffers are cleared
    try testing.expect(processor.sb_buffer.items.len == 0);
    try testing.expect(processor.partial_buffer.items.len == 0);
}

test "state preservation across multiple input calls" {
    var processor = TelnetProcessor.init(testing.allocator, "xterm", 80, 24, null);
    defer processor.deinit();

    // First call: normal data
    const result1 = try processor.processInput("Hello");
    defer testing.allocator.free(result1.data);
    defer testing.allocator.free(result1.response);

    try testing.expectEqualStrings("Hello", result1.data);

    // Second call: IAC command
    const cmd = [_]u8{ @intFromEnum(TelnetCommand.iac), @intFromEnum(TelnetCommand.will), @intFromEnum(TelnetOption.echo) };
    const result2 = try processor.processInput(&cmd);
    defer testing.allocator.free(result2.data);
    defer testing.allocator.free(result2.response);

    try testing.expect(result2.data.len == 0);
    try testing.expect(result2.response.len == 3);

    // Third call: more data
    const result3 = try processor.processInput("World");
    defer testing.allocator.free(result3.data);
    defer testing.allocator.free(result3.response);

    try testing.expectEqualStrings("World", result3.data);
}
