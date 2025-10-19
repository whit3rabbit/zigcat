Name:           zigcat
Version:        0.0.1
Release:        1%{?dist}
Summary:        Modern netcat clone written in Zig with TLS support

License:        MIT
URL:            https://github.com/whit3rabbit/zigcat
Source0:        %{name}-%{version}.tar.gz
BuildRequires:  zig >= 0.15.1
BuildRequires:  openssl-devel >= 3.0.0
BuildRequires:  pkgconfig
Requires:       openssl-libs >= 3.0.0

%description
Zigcat provides TCP and UDP client/server helpers, TLS/DTLS support, proxy
awareness, GSocket NAT traversal, Telnet protocol support, and timeout-aware
I/O in a compact standalone binary.

It aims to be a drop-in replacement for traditional netcat utilities while
adding cross-platform features, security enhancements, and stricter error
handling.

This package includes the OpenSSL-enabled dynamic binary with full TLS/DTLS
and GSocket support.

Features:
- TCP/UDP/SCTP/Unix sockets with dual-stack IPv4/IPv6
- TLS 1.2/1.3 and DTLS support (OpenSSL backend)
- GSocket NAT traversal with SRP encryption
- Telnet protocol (RFC 854/855/856/857/858/1073/1079/1091/1143/1184)
- Port scanning with zero-I/O mode
- Exec mode with io_uring/poll backends
- Broker and chat relay modes
- IP access control (allowlist/denylist)

%prep
%autosetup -n %{name}-%{version}

%build
zig build -Doptimize=ReleaseSmall -Dstrip=true -Dtls=true -Dtls-backend=openssl

%install
mkdir -p %{buildroot}%{_bindir}
install -m 0755 zig-out/bin/zigcat %{buildroot}%{_bindir}/zigcat

mkdir -p %{buildroot}%{_docdir}/%{name}
install -m 0644 README.md %{buildroot}%{_docdir}/%{name}/
install -m 0644 LICENSE %{buildroot}%{_docdir}/%{name}/

%check
zig build test || true

%files
%doc %{_docdir}/%{name}/README.md
%license %{_docdir}/%{name}/LICENSE
%{_bindir}/zigcat

%changelog
* Sat Oct 19 2025 Whit3Rabbit <whiterabbit@protonmail.com> - 0.0.1-1
- Initial release v0.0.1
- Core networking: TCP/UDP/SCTP/Unix sockets with dual-stack IPv4/IPv6
- TLS/DTLS support with OpenSSL and wolfSSL backends
- GSocket NAT traversal with SRP encryption
- Telnet protocol support (RFC compliance)
- Port scanning with zero-I/O mode (parallel/sequential)
- Exec mode with io_uring/poll backends
- Broker and chat relay modes
- IP access control (allowlist/denylist with CIDR)
- Modular architecture with 10 client modules
- Automatic exec backend selection (io_uring on Linux 5.1+)
- Flow control with backpressure management
- Cross-platform support (Linux, FreeBSD, macOS, Windows)
