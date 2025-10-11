# TLS Implementation for zigcat

## Overview

This directory contains the TLS implementation for zigcat, which relies on **OpenSSL** for all cryptographic operations. The native Zig TLS implementation was a proof-of-concept and is **no longer used**.

## Architecture

The TLS implementation uses Zig's FFI (Foreign Function Interface) to call OpenSSL's `libssl` and `libcrypto`.

### Files

-   **`tls_iface.zig`**: Defines the common TLS interface used by `zigcat`.
-   **`tls_openssl.zig`**: The OpenSSL-based implementation of the TLS interface.
-   **`tls.zig`**: The public API module that abstracts the backend implementation.

## Security

All TLS functionality, including encryption, key exchange, and certificate validation, is handled by OpenSSL. This ensures that `zigcat` benefits from a mature, widely-used, and well-vetted TLS implementation.

## Building with TLS

TLS support is enabled by default and requires OpenSSL to be installed on the system. You can disable it at build time with the following flag:

```bash
zig build -Dtls=false
```

## Conclusion

The native TLS implementation (`tls_builtin.zig`) was an exploratory effort and is preserved for historical reference only. It is **not functional** and **not used** in any build configuration. All TLS operations are delegated to OpenSSL.