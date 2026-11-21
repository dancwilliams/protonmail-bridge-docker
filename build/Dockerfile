# debian:trixie-slim supports amd64, arm64, and riscv64 with lockstep package versions.
# The build stage runs on $BUILDPLATFORM so non-native targets (linux/riscv64) cross-compile
# natively instead of running Go and gcc under QEMU emulation.
# The digests here are the only ones that ship, so Renovate keeps every published image current.
FROM --platform=$BUILDPLATFORM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS build

ARG BUILDARCH
ARG TARGETOS
ARG TARGETARCH
ARG version

# Install build dependencies (native or Debian multiarch cross-compilation)
RUN set -eux; \
    if [ "$TARGETARCH" = "$BUILDARCH" ]; then \
        apt-get -o Acquire::http::Timeout=30 update; \
        apt-get -o Acquire::http::Timeout=30 install -y golang build-essential libsecret-1-dev libfido2-dev libcbor-dev; \
    else \
        case "$TARGETARCH" in \
            riscv64) triplet=riscv64-linux-gnu ;; \
            arm64)   triplet=aarch64-linux-gnu ;; \
            amd64)   triplet=x86_64-linux-gnu ;; \
            *) echo "Unsupported cross-compile TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
        esac; \
        dpkg --add-architecture "$TARGETARCH"; \
        apt-get -o Acquire::http::Timeout=30 update; \
        apt-get -o Acquire::http::Timeout=30 install -y \
            golang make pkg-config ca-certificates "gcc-${triplet}" \
            "libsecret-1-dev:${TARGETARCH}" "libfido2-dev:${TARGETARCH}" "libcbor-dev:${TARGETARCH}"; \
    fi

# Build
ADD https://github.com/ProtonMail/proton-bridge.git#${version} /build/
WORKDIR /build/
RUN set -eux; \
    if [ "$TARGETARCH" = "$BUILDARCH" ]; then \
        make build-nogui vault-editor; \
    else \
        case "$TARGETARCH" in \
            riscv64) triplet=riscv64-linux-gnu ;; \
            arm64)   triplet=aarch64-linux-gnu ;; \
            amd64)   triplet=x86_64-linux-gnu ;; \
        esac; \
        CGO_ENABLED=1 \
        GOOS="$TARGETOS" \
        GOARCH="$TARGETARCH" \
        CC="${triplet}-gcc" \
        PKG_CONFIG_LIBDIR="/usr/lib/${triplet}/pkgconfig:/usr/share/pkgconfig" \
        make build-nogui vault-editor; \
    fi

FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
LABEL maintainer="Dan Williams <dancwilliams@github>"
# Lets image-update tooling read the bridge version (and its major) without pulling.
ARG version
LABEL org.opencontainers.image.version=$version

EXPOSE 25/tcp
EXPOSE 143/tcp

# Monitor that the container actually serves mail, not merely that a process exists
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
  CMD bash /protonmail/healthcheck.sh

# Install runtime dependencies
RUN apt-get -o Acquire::http::Timeout=30 update \
    && apt-get -o Acquire::http::Timeout=30 install -y --no-install-recommends socat pass libsecret-1-0 libfido2-1 ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

# Copy bash scripts
COPY gpgparams entrypoint.sh healthcheck.sh /protonmail/

# Copy protonmail
COPY --from=build /build/bridge /protonmail/
COPY --from=build /build/proton-bridge /protonmail/
COPY --from=build /build/vault-editor /protonmail/

# Optional non-root user. The image still starts as root unless the user opts in with
# `--user 1000:1000` (or `user: "1000:1000"` in compose); nothing changes otherwise.
# HOME stays /root and the volume stays mounted there: the vault records absolute paths
# (Settings.GluonDir), so moving HOME would orphan the IMAP cache of existing volumes.
# /root is handed to uid 1000 so that a fresh named volume, which Docker seeds from the
# image's /root ownership and content (.bashrc, .profile), is owned by it. root is
# unaffected: it bypasses ownership.
# ENV HOME keeps HOME at /root for any other uid as well.
RUN useradd --uid 1000 --user-group --no-create-home --home-dir /root --shell /usr/sbin/nologin bridge \
    && chown -R bridge:bridge /root \
    && chmod 700 /root
ENV HOME=/root

# Prevent the bridge's built-in auto-updater from replacing the container binary at runtime.
# Version management is handled externally via the update-check workflow.
RUN chmod -w /protonmail/bridge /protonmail/proton-bridge /protonmail/vault-editor

ENTRYPOINT ["bash", "/protonmail/entrypoint.sh"]
