# syntax=docker/dockerfile:1
ARG FDB_VERSION=7.3.77
ARG RUST_VERSION=1.99.0
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-trixie AS builder

ARG FDB_VERSION
ARG TARGETARCH
WORKDIR /app

RUN set -eu; \
    dpkg --add-architecture "$TARGETARCH"; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl libclang-dev pkg-config "libssl-dev:$TARGETARCH" "liblzma-dev:$TARGETARCH" "zlib1g-dev:$TARGETARCH"; \
    if [ "$TARGETARCH" = arm64 ]; then apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu; fi; \
    rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; *) exit 1 ;; esac; \
    mkdir -p /opt/fdb; \
    curl -fsSL "https://github.com/apple/foundationdb/releases/download/$FDB_VERSION/libfdb_c.$arch.so" -o /opt/fdb/libfdb_c.so; \
    curl -fsSL "https://github.com/apple/foundationdb/releases/download/$FDB_VERSION/libfdb_c.$arch.so.sha256" -o /tmp/libfdb.sha256; \
    expected=$(awk '{print $1}' /tmp/libfdb.sha256); \
    echo "$expected  /opt/fdb/libfdb_c.so" | sha256sum --check

COPY Cargo.toml Cargo.lock build.rs ./
COPY src ./src

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,id=fdbexporter-target,target=/app/target \
    set -eu; \
    case "$TARGETARCH" in \
        amd64) triple=x86_64-unknown-linux-gnu; multiarch=x86_64-linux-gnu ;; \
        arm64) triple=aarch64-unknown-linux-gnu; multiarch=aarch64-linux-gnu; \
            export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc; \
            export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc; \
            export BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="-I/usr/aarch64-linux-gnu/include" ;; \
    esac; \
    case "$FDB_VERSION" in 7.1.*) features=binary,fdb-7_1 ;; 7.3.*) features=binary,fdb-7_3 ;; *) exit 1 ;; esac; \
    rustup target add "$triple"; \
    export PKG_CONFIG_ALLOW_CROSS=1; \
    export PKG_CONFIG_LIBDIR="/usr/lib/$multiarch/pkgconfig:/usr/share/pkgconfig"; \
    export FDB_CLIENT_LIB_PATH=/opt/fdb; \
    cargo build --locked --release --target "$triple" --no-default-features --features "$features" --jobs 4; \
    install -Dm755 "target/$triple/release/fdbexporter" /output/fdbexporter

FROM debian:trixie-slim
ARG FDB_VERSION
ARG TARGETARCH
WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl dnsutils openssh-client libssl3t64 liblzma5 zlib1g libstdc++6 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/fdb/libfdb_c.so /usr/local/lib/libfdb_c.so
RUN set -eu; \
    case "$TARGETARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; esac; \
    curl -fsSL "https://github.com/apple/foundationdb/releases/download/$FDB_VERSION/fdbcli.$arch" -o /usr/local/bin/fdbcli; \
    curl -fsSL "https://github.com/apple/foundationdb/releases/download/$FDB_VERSION/fdbcli.$arch.sha256" -o /tmp/fdbcli.sha256; \
    expected=$(awk '{print $1}' /tmp/fdbcli.sha256); \
    echo "$expected  /usr/local/bin/fdbcli" | sha256sum --check; \
    chmod +x /usr/local/bin/fdbcli; \
    ldconfig

COPY --from=builder /output/fdbexporter /app/fdbexporter
COPY .github/docker/run.sh /app/docker_entrypoint.sh
ENTRYPOINT ["/app/docker_entrypoint.sh"]
