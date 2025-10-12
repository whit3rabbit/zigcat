// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.


const std = @import("std");
const windows = std.os.windows;

const IOCP_HANDLE = windows.HANDLE;

pub const Iocp = struct {
    handle: IOCP_HANDLE,

    pub fn init() !Iocp {
        const handle = windows.kernel32.CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            0,
            0,
        ) orelse return error.IocpCreateFailed;

        return Iocp{ .handle = handle };
    }

    pub fn deinit(self: *Iocp) void {
        _ = windows.kernel32.CloseHandle(self.handle);
    }

    pub fn associateSocket(self: *Iocp, socket: windows.SOCKET, completion_key: usize) !void {
        const result = windows.kernel32.CreateIoCompletionPort(
            @ptrFromInt(socket),
            self.handle,
            completion_key,
            0,
        );

        if (result == null) {
            return error.IocpAssociateFailed;
        }
    }

    pub fn getStatus(self: *Iocp, timeout: u32) !CompletionPacket {
        var bytes_transferred: u32 = 0;
        var completion_key: usize = 0;
        var overlapped: ?*windows.OVERLAPPED = null;

        const success = windows.kernel32.GetQueuedCompletionStatus(
            self.handle,
            &bytes_transferred,
            &completion_key,
            &overlapped,
            timeout,
        );

        if (success == 0) {
            const err = windows.kernel32.GetLastError();
            if (err == windows.WAIT_TIMEOUT) {
                return error.Timeout;
            }
            return error.IocpGetStatusFailed;
        }

        return CompletionPacket{
            .bytes_transferred = bytes_transferred,
            .completion_key = completion_key,
            .overlapped = overlapped,
        };
    }
};

pub const CompletionPacket = struct {
    bytes_transferred: u32,
    completion_key: usize,
    overlapped: ?*windows.OVERLAPPED,
};
