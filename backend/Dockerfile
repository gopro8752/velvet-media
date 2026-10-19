# One image replacing nzbdav + usenet-streamer + velvet-sync + velvet-intro.
FROM node:22-bookworm-slim AS codex-runtime
RUN npm install --global @openai/codex@0.160.0

FROM rust:slim-bookworm AS builder
WORKDIR /build
# Cache the dependency build separately from source changes.
COPY Cargo.toml Cargo.lock LICENSE ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs && cargo build --locked --release && rm -rf src
COPY src ./src
COPY admin ./admin
# Bust the stale main.rs fingerprint so the real sources rebuild.
RUN touch src/main.rs && cargo build --locked --release

FROM debian:bookworm-slim AS base
# ffmpeg + fpcalc (libchromaprint-tools) power the skip-intro worker.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libchromaprint-tools ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/velvet-backend /usr/local/bin/velvet-backend
COPY LICENSE THIRD_PARTY_NOTICES.md /usr/share/doc/velvet-backend/
ENV VELVET_CONFIG=/config/velvet.toml \
    VELVET_DB=/data/velvet.db
VOLUME ["/config", "/data"]
EXPOSE 8799
ENTRYPOINT ["velvet-backend", "serve"]

# Optional subscription-backed category generator. Authenticate this runtime
# once with `codex login --device-auth`; credentials stay in the private mount.
FROM base AS with-codex
COPY --from=codex-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=codex-runtime /usr/local/lib/node_modules/@openai /usr/local/lib/node_modules/@openai
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex
ENV CODEX_HOME=/config/codex

# Keep the default streaming image small; opt in with --target with-codex.
FROM base AS runtime
