// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


const std = @import("std");
const broker = @import("../broker.zig");
const logging = @import("../../util/logging.zig");

/// Initialize a new chat client with welcome message and nickname prompt
/// SECURITY FIX (2025-10-10): Changed client_id from u32 to u64 to match ClientPool
pub fn initializeChatClient(self: *broker.BrokerServer, client_id: u64) !void {
    const client = self.clients.getClient(client_id) orelse return broker.BrokerError.ClientNotFound;

    const welcome_msg = "Welcome to ZigCat chat! Please enter your nickname: ";
    const bytes_sent = client.connection.write(welcome_msg) catch |err| {
        logging.logError(err, "chat welcome message");
        return broker.BrokerError.ClientSocketError;
    };

    client.bytes_sent += bytes_sent;
    client.updateActivity();

    logging.logDebug("Sent welcome message to client {} ({} bytes)\n", .{ client_id, bytes_sent });
    logging.logTrace("Chat client {} initialized, awaiting nickname\n", .{client_id});
}
