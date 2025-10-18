// Copyright (c) 2025 whit3rabbit
// SPDX-License-Identifier: MIT
//
// This file is part of zigcat and is licensed under the MIT license.
// See the LICENSE-MIT file in the root of this repository for details.

//! zigcat configuration primitives.
//!
//! This module now acts as a thin facade that re-exports focused
//! configuration domains located under `src/config/`.

const types = @import("config/types.zig");
const config_struct = @import("config/config_struct.zig");
const cli = @import("config/cli.zig");
const network = @import("config/network.zig");
const tls = @import("config/tls.zig");
const security = @import("config/security.zig");
const validator = @import("config/validator.zig");
const timeout = @import("config/timeout.zig");

pub const VerbosityLevel = types.VerbosityLevel;
pub const ProxyType = types.ProxyType;
pub const ProxyDns = types.ProxyDns;
pub const TelnetSignalMode = types.TelnetSignalMode;
pub const TelnetEditMode = types.TelnetEditMode;
pub const AnsiMode = types.AnsiMode;

pub const Config = config_struct.Config;
pub const buildExecSessionConfig = config_struct.buildExecSessionConfig;

pub const IOControlError = cli.IOControlError;
pub const validateIOControl = cli.validateIOControl;

pub const UnixSocketSupport = network.UnixSocketSupport;
pub const UnixSocketError = network.UnixSocketError;
pub const validateUnixSocket = network.validateUnixSocket;

pub const TLSConfigError = tls.TLSConfigError;
pub const validateTlsConfiguration = tls.validateTlsConfiguration;

pub const BrokerChatError = security.BrokerChatError;
pub const validateBrokerChat = security.validateBrokerChat;

pub const validate = validator.validate;

// Timeout selection
pub const TimeoutContext = timeout.TimeoutContext;
pub const getConnectionTimeout = timeout.getConnectionTimeout;
