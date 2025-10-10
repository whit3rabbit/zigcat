// Telnet Protocol Tests (RFC 854, RFC 855)
// Tests IAC (Interpret As Command) sequence handling and option negotiation
//
// CRITICAL: This is a standalone test file - CANNOT import from src/
// Uses only std library for self-contained testing

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

// Telnet Protocol Constants (RFC 854)
const IAC = 0xFF; // Interpret As Command
const DONT = 0xFE; // Don't do option
const DO = 0xFD; // Do option
const WONT = 0xFC; // Won't do option
const WILL = 0xFB; // Will do option
const SB = 0xFA; // Subnegotiation begin
const SE = 0xF0; // Subnegotiation end

// Telnet Commands (RFC 854)
const NOP = 0xF1; // No operation
const DM = 0xF2; // Data Mark
const BRK = 0xF3; // Break
const IP = 0xF4; // Interrupt Process
const AO = 0xF5; // Abort Output
const AYT = 0xF6; // Are You There
const EC = 0xF7; // Erase Character
const EL = 0xF8; // Erase Line
const GA = 0xF9; // Go Ahead

// Telnet Options (RFC 855)
const TELOPT_ECHO = 0x01; // Echo option
const TELOPT_SUPPRESS_GO_AHEAD = 0x03; // Suppress Go Ahead
const TELOPT_STATUS = 0x05; // Status
const TELOPT_TIMING_MARK = 0x06; // Timing Mark
const TELOPT_TERMINAL_TYPE = 0x18; // Terminal Type
const TELOPT_WINDOW_SIZE = 0x1F; // Window Size (NAWS)
const TELOPT_TERMINAL_SPEED = 0x20; // Terminal Speed
const TELOPT_LINEMODE = 0x22; // Linemode

// ============================================================================
// Test 1: IAC NOP sequence parsing
// ============================================================================

/// Test: IAC NOP (No Operation) sequence is stripped from data
///
/// Input: IAC NOP "Hello"
/// Expected: "Hello" (IAC NOP removed)
///
/// RFC 854: NOP may be used as a filler when timing is critical
test "IAC NOP sequence parsing" {
    const allocator = testing.allocator;

    // Input: IAC NOP followed by "Hello"
    const input = [_]u8{ IAC, NOP, 'H', 'e', 'l', 'l', 'o' };
    const expected_output = "Hello";

    // Simulate telnet processing: strip IAC sequences
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == IAC and i + 1 < input.len) {
            // IAC command - skip IAC and next byte
            i += 2;
        } else {
            try output.append(input[i]);
            i += 1;
        }
    }

    try testing.expectEqualStrings(expected_output, output.items);
}

// ============================================================================
// Test 2: IAC WILL ECHO option negotiation
// ============================================================================

/// Test: Server sends IAC WILL ECHO, client responds with IAC DO ECHO
///
/// Server: IAC WILL ECHO (I will echo your input)
/// Client: IAC DO ECHO (Please echo my input)
///
/// RFC 857: ECHO option allows server to echo client's input
test "IAC WILL ECHO option negotiation" {
    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const server_sock = sockets[0];
    const client_sock = sockets[1];

    // Server sends: IAC WILL ECHO
    const server_msg = [_]u8{ IAC, WILL, TELOPT_ECHO };
    const sent = try posix.send(server_sock, &server_msg, 0);
    try testing.expectEqual(server_msg.len, sent);

    // Client receives and should respond: IAC DO ECHO
    var recv_buf: [64]u8 = undefined;
    const recv_len = try posix.recv(client_sock, &recv_buf, 0);
    try testing.expectEqual(server_msg.len, recv_len);
    try testing.expectEqualSlices(u8, &server_msg, recv_buf[0..recv_len]);

    // Client sends response: IAC DO ECHO
    const client_response = [_]u8{ IAC, DO, TELOPT_ECHO };
    const response_sent = try posix.send(client_sock, &client_response, 0);
    try testing.expectEqual(client_response.len, response_sent);

    // Server receives response
    const response_recv = try posix.recv(server_sock, &recv_buf, 0);
    try testing.expectEqual(client_response.len, response_recv);
    try testing.expectEqualSlices(u8, &client_response, recv_buf[0..response_recv]);
}

// ============================================================================
// Test 3: IAC WONT option rejection
// ============================================================================

/// Test: Server refuses option with IAC WONT
///
/// Client: IAC DO TERMINAL_TYPE (Please send terminal type)
/// Server: IAC WONT TERMINAL_TYPE (I won't send terminal type)
///
/// RFC 855: WONT indicates refusal to perform option
test "IAC WONT option rejection" {
    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const client_sock = sockets[0];
    const server_sock = sockets[1];

    // Client requests: IAC DO TERMINAL_TYPE
    const client_request = [_]u8{ IAC, DO, TELOPT_TERMINAL_TYPE };
    const sent = try posix.send(client_sock, &client_request, 0);
    try testing.expectEqual(client_request.len, sent);

    // Server receives request
    var recv_buf: [64]u8 = undefined;
    const recv_len = try posix.recv(server_sock, &recv_buf, 0);
    try testing.expectEqual(client_request.len, recv_len);

    // Server refuses: IAC WONT TERMINAL_TYPE
    const server_response = [_]u8{ IAC, WONT, TELOPT_TERMINAL_TYPE };
    const response_sent = try posix.send(server_sock, &server_response, 0);
    try testing.expectEqual(server_response.len, response_sent);

    // Client receives rejection
    const response_recv = try posix.recv(client_sock, &recv_buf, 0);
    try testing.expectEqual(server_response.len, response_recv);
    try testing.expectEqualSlices(u8, &server_response, recv_buf[0..response_recv]);
}

// ============================================================================
// Test 4: Mixed data and IAC sequences
// ============================================================================

/// Test: Data interleaved with IAC commands is processed correctly
///
/// Input: "Hello" IAC NOP "World" IAC NOP "!"
/// Expected: "HelloWorld!"
test "mixed data and IAC sequences" {
    const allocator = testing.allocator;

    // Input: "Hello" + IAC NOP + "World" + IAC NOP + "!"
    const input = [_]u8{
        'H', 'e', 'l', 'l', 'o',
        IAC, NOP,
        'W', 'o', 'r', 'l', 'd',
        IAC, NOP,
        '!',
    };
    const expected_output = "HelloWorld!";

    // Process telnet stream: strip IAC sequences
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == IAC and i + 1 < input.len) {
            // Skip IAC and next byte
            i += 2;
        } else {
            try output.append(input[i]);
            i += 1;
        }
    }

    try testing.expectEqualStrings(expected_output, output.items);
}

// ============================================================================
// Test 5: IAC IAC escape sequence (literal 0xFF)
// ============================================================================

/// Test: IAC IAC represents literal 0xFF byte in data
///
/// Input: "Test" IAC IAC "Data"
/// Expected: "Test\xFFData"
///
/// RFC 854: IAC must be doubled to send literal 0xFF
test "IAC IAC escape sequence for literal 0xFF" {
    const allocator = testing.allocator;

    // Input: "Test" + IAC IAC + "Data"
    const input = [_]u8{
        'T', 'e', 's', 't',
        IAC, IAC,
        'D', 'a', 't', 'a',
    };

    // Expected: "Test" + 0xFF + "Data"
    const expected_output = [_]u8{ 'T', 'e', 's', 't', 0xFF, 'D', 'a', 't', 'a' };

    // Process telnet stream: IAC IAC -> single 0xFF
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == IAC and i + 1 < input.len) {
            if (input[i + 1] == IAC) {
                // IAC IAC -> literal 0xFF
                try output.append(0xFF);
                i += 2;
            } else {
                // IAC <command> -> skip both bytes
                i += 2;
            }
        } else {
            try output.append(input[i]);
            i += 1;
        }
    }

    try testing.expectEqualSlices(u8, &expected_output, output.items);
}

// ============================================================================
// Test 6: Subnegotiation sequence parsing
// ============================================================================

/// Test: Subnegotiation (IAC SB ... IAC SE) is parsed correctly
///
/// Input: IAC SB TERMINAL_TYPE 0 "vt100" IAC SE
/// Expected: Subnegotiation extracted, data processed
///
/// RFC 855: Subnegotiation provides option-specific parameters
test "subnegotiation sequence parsing" {
    const allocator = testing.allocator;

    // Input: IAC SB TERMINAL_TYPE 0 "vt100" IAC SE
    const input = [_]u8{
        IAC, SB, TELOPT_TERMINAL_TYPE, 0,
        'v', 't', '1', '0', '0',
        IAC, SE,
    };

    // Extract subnegotiation data
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var i: usize = 0;
    var in_subneg = false;

    while (i < input.len) {
        if (input[i] == IAC and i + 1 < input.len) {
            if (input[i + 1] == SB) {
                // Start subnegotiation
                in_subneg = true;
                i += 2; // Skip IAC SB
                continue;
            } else if (input[i + 1] == SE) {
                // End subnegotiation
                in_subneg = false;
                i += 2; // Skip IAC SE
                continue;
            } else if (input[i + 1] == IAC) {
                // IAC IAC in subnegotiation -> literal 0xFF
                if (in_subneg) {
                    try output.append(0xFF);
                }
                i += 2;
                continue;
            } else {
                // Other IAC command
                i += 2;
                continue;
            }
        }

        if (in_subneg) {
            try output.append(input[i]);
        }
        i += 1;
    }

    // Subnegotiation data: TERMINAL_TYPE 0 "vt100"
    const expected = [_]u8{ TELOPT_TERMINAL_TYPE, 0, 'v', 't', '1', '0', '0' };
    try testing.expectEqualSlices(u8, &expected, output.items);
}

// ============================================================================
// Test 7: SUPPRESS-GO-AHEAD option
// ============================================================================

/// Test: SUPPRESS-GO-AHEAD option negotiation
///
/// Server: IAC WILL SUPPRESS-GO-AHEAD
/// Client: IAC DO SUPPRESS-GO-AHEAD
///
/// RFC 858: Suppresses GA (Go Ahead) signal after each line
test "suppress-go-ahead option negotiation" {
    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const server_sock = sockets[0];
    const client_sock = sockets[1];

    // Server proposes: IAC WILL SUPPRESS-GO-AHEAD
    const server_msg = [_]u8{ IAC, WILL, TELOPT_SUPPRESS_GO_AHEAD };
    const sent = try posix.send(server_sock, &server_msg, 0);
    try testing.expectEqual(server_msg.len, sent);

    // Client receives
    var recv_buf: [64]u8 = undefined;
    const recv_len = try posix.recv(client_sock, &recv_buf, 0);
    try testing.expectEqual(server_msg.len, recv_len);

    // Client accepts: IAC DO SUPPRESS-GO-AHEAD
    const client_response = [_]u8{ IAC, DO, TELOPT_SUPPRESS_GO_AHEAD };
    const response_sent = try posix.send(client_sock, &client_response, 0);
    try testing.expectEqual(client_response.len, response_sent);

    // Server receives acceptance
    const response_recv = try posix.recv(server_sock, &recv_buf, 0);
    try testing.expectEqual(client_response.len, response_recv);
    try testing.expectEqualSlices(u8, &client_response, recv_buf[0..response_recv]);
}

// ============================================================================
// Test 8: Multiple option negotiations in sequence
// ============================================================================

/// Test: Multiple telnet options negotiated sequentially
///
/// Server sends:
/// - IAC WILL ECHO
/// - IAC WILL SUPPRESS-GO-AHEAD
/// - IAC DO TERMINAL_TYPE
///
/// Client responds appropriately to each
test "multiple option negotiations" {
    const allocator = testing.allocator;

    const sockets = try posix.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);

    const server_sock = sockets[0];
    const client_sock = sockets[1];

    // Server sends multiple options
    var server_msgs = std.ArrayList(u8).init(allocator);
    defer server_msgs.deinit();

    // IAC WILL ECHO
    try server_msgs.appendSlice(&[_]u8{ IAC, WILL, TELOPT_ECHO });

    // IAC WILL SUPPRESS-GO-AHEAD
    try server_msgs.appendSlice(&[_]u8{ IAC, WILL, TELOPT_SUPPRESS_GO_AHEAD });

    // IAC DO TERMINAL_TYPE
    try server_msgs.appendSlice(&[_]u8{ IAC, DO, TELOPT_TERMINAL_TYPE });

    // Send all at once
    const sent = try posix.send(server_sock, server_msgs.items, 0);
    try testing.expectEqual(server_msgs.items.len, sent);

    // Client receives all options
    var recv_buf: [128]u8 = undefined;
    const recv_len = try posix.recv(client_sock, &recv_buf, 0);
    try testing.expectEqual(server_msgs.items.len, recv_len);
    try testing.expectEqualSlices(u8, server_msgs.items, recv_buf[0..recv_len]);

    // Parse and count options
    var i: usize = 0;
    var option_count: usize = 0;
    while (i < recv_len) {
        if (recv_buf[i] == IAC and i + 2 < recv_len) {
            option_count += 1;
            i += 3; // Skip IAC, command, option
        } else {
            i += 1;
        }
    }

    // Expect 3 options
    try testing.expectEqual(@as(usize, 3), option_count);
}
