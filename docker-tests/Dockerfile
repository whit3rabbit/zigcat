FROM --platform=$TARGETPLATFORM alpine:3.18 AS builder

ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG ZIG_VERSION=latest
ARG DEFAULT_ZIG_VERSION=0.15.1

RUN apk add --no-cache \
    wget \
    xz \
    ca-certificates \
    bash

COPY docker-tests/scripts/resolve-zig-version.sh /usr/local/bin/resolve-zig-version
RUN chmod +x /usr/local/bin/resolve-zig-version

RUN set -eux; \
    ARCH=$(case "$(uname -m)" in x86_64) echo "x86_64";; aarch64) echo "aarch64";; *) echo "x86_64";; esac); \
    ZIG_ACTUAL=$(DEFAULT_ZIG_VERSION=$DEFAULT_ZIG_VERSION resolve-zig-version "$ZIG_VERSION"); \
    echo "Using Zig version ${ZIG_ACTUAL}"; \
    wget -q https://ziglang.org/download/${ZIG_ACTUAL}/zig-${ARCH}-linux-${ZIG_ACTUAL}.tar.xz; \
    tar -xf zig-${ARCH}-linux-${ZIG_ACTUAL}.tar.xz; \
    mv zig-${ARCH}-linux-${ZIG_ACTUAL} /opt/zig; \
    rm zig-${ARCH}-linux-${ZIG_ACTUAL}.tar.xz

ENV PATH="/opt/zig:$PATH"

WORKDIR /build
COPY . .

RUN zig build -Doptimize=ReleaseSmall

FROM alpine:3.18 AS runtime

RUN apk add --no-cache \
    bash \
    netcat-openbsd \
    curl \
    socat

COPY --from=builder /build/zig-out/bin/zigcat /usr/local/bin/zigcat
COPY docker-tests/scenarios /tests/scenarios
COPY docker-tests/scripts /tests/scripts

WORKDIR /tests

RUN chmod +x /tests/scenarios/*.sh /tests/scripts/*.sh 2>/dev/null || true

RUN zigcat --help || echo "zigcat binary ready"

CMD ["/bin/sh", "-c", "echo 'Zigcat Docker test container ready'"]
