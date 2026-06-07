# syntax=docker/dockerfile:1.7
FROM rust:1.88-bookworm AS builder

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY Resources ./Resources
COPY ServerConfig.default.toml ./ServerConfig.default.toml

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo build --release --no-default-features \
    && cp target/release/highbeam-server /tmp/highbeam-server

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/highbeam

COPY --from=builder /tmp/highbeam-server ./highbeam-server
COPY --from=builder /app/ServerConfig.default.toml ./ServerConfig.toml
COPY --from=builder /app/Resources ./Resources

EXPOSE 18860/tcp
EXPOSE 18860/udp

# Optional ports are not exposed by default:
# - 18861/tcp for launcher mod sync
# - 18862/tcp for community browser discovery

CMD ["./highbeam-server", "--headless"]