FROM rust:1.49-slim as builder
RUN apt-get update && apt-get install -y pkg-config libssl-dev
WORKDIR /usr/src/bwt
COPY . .
ARG FEATURES=electrum,http,webhooks,track-spends
RUN cargo install --locked --path . --no-default-features --features "cli,$FEATURES"

FROM debian:buster-slim
ARG FEATURES=electrum,http,webhooks,track-spends
RUN echo $FEATURES | grep -v webhooks > /dev/null || (apt-get update && apt-get install -y libssl-dev)
COPY --from=builder /usr/local/cargo/bin/bwt /usr/local/bin/
ENTRYPOINT [ "bwt", "--bitcoind-dir", "/bitcoin" ]
