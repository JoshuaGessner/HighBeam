FROM rust:1.87-bookworm AS builder

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY Resources ./Resources
COPY ServerConfig.default.toml ./ServerConfig.default.toml

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/highbeam

COPY --from=builder /app/target/release/highbeam-server ./highbeam-server
COPY --from=builder /app/ServerConfig.default.toml ./ServerConfig.toml
COPY --from=builder /app/Resources ./Resources

EXPOSE 18860/tcp
EXPOSE 18860/udp

# Optional ports are not exposed by default:
# - 18861/tcp for launcher mod sync
# - 18862/tcp for community browser discovery

CMD ["./highbeam-server", "--headless"]