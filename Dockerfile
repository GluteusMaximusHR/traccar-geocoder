# Stage 1: Build C++ indexer
FROM debian:trixie-slim AS builder-cpp

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake ca-certificates \
    libosmium2-dev libprotozero-dev \
    zlib1g-dev libbz2-dev libexpat1-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY builder/ builder/
RUN cmake -S builder -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build -j$(nproc)

# Stage 2: Build Rust server
FROM rust:trixie AS builder-rust

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY server/ server/
RUN cargo build --locked --release --manifest-path server/Cargo.toml

# Stage 3: Runtime
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    zlib1g libbz2-1.0 libexpat1 liblz4-1 \
    curl ca-certificates \
    osmctools osmium-tool \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder-cpp /src/build/build-index /usr/local/bin/
COPY --from=builder-rust /src/server/target/release/query-server /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["entrypoint.sh"]
CMD ["auto"]
