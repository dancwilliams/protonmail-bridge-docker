# ARG before any FROM is global and available in FROM instructions.
# debian:bookworm-slim is the default; the workflow overrides to debian:sid-slim for riscv64
# since bookworm has no riscv64 image. The digests here are the only ones that ship:
# the workflow reads them from this file so Renovate keeps every published image current.
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

# debian:sid-slim is required for the build stage to support riscv64 (golang:bookworm does not).
FROM debian:sid-slim@sha256:ec3fa4e0b2987ae47be353f56854191e300261915470e40165b1c906d22a65db AS build

ARG version

# Install build dependencies
RUN apt-get -o Acquire::http::Timeout=30 update && apt-get -o Acquire::http::Timeout=30 install -y golang build-essential libsecret-1-dev libfido2-dev libcbor-dev

# Build
ADD https://github.com/ProtonMail/proton-bridge.git#${version} /build/
WORKDIR /build/
RUN make build-nogui vault-editor

FROM ${RUNTIME_IMAGE}
LABEL maintainer="Dan Williams <dancwilliams@github>"

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

# Prevent the bridge's built-in auto-updater from replacing the container binary at runtime.
# Version management is handled externally via the update-check workflow.
RUN chmod -w /protonmail/bridge /protonmail/proton-bridge /protonmail/vault-editor

ENTRYPOINT ["bash", "/protonmail/entrypoint.sh"]
