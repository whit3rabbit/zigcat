Name:           zigcat
Version:        0.1.0
Release:        1%{?dist}
Summary:        Modern netcat clone written in Zig

License:        MIT
URL:            https://github.com/whit3rabbit/zigcat
Source0:        %{name}-%{version}.tar.gz
BuildRequires:  zig >= 0.15.1
BuildRequires:  openssl-devel
BuildRequires:  pkgconfig
BuildRequires:  gcc
%description
Zigcat provides TCP and UDP client/server helpers, TLS support, proxy
awareness, and timeout-aware I/O in a compact standalone binary. It aims
to be a drop-in replacement for traditional netcat utilities while adding
cross-platform features and stricter error handling.

%prep
%autosetup -n %{name}-%{version}

%build
zig build -Doptimize=ReleaseSafe

%install
mkdir -p %{buildroot}%{_bindir}
install -m 0755 zig-out/bin/zigcat %{buildroot}%{_bindir}/zigcat

%check
zig build test

%files
%doc README.md TESTS.md
%{_bindir}/zigcat

%changelog
* Fri Oct 10 2025 Whit3Rabbit <whiterabbit@protonmail.com> - 0.1.0-1
- Initial RPM release
