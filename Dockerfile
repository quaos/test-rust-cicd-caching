#syntax=docker/dockerfile:1.0-experimental

ARG CRATE_NAME="test_rust_caching"
ARG CARGO_HOME="/cargo"
ARG APP_SRC_PATH="/app"

#
# NOTE: Rust is broken on musl at the moment. we'll use alpine after the issue is resolved:
#     https://github.com/rust-lang/rust/issues/40174
#
# ** base **
FROM rust:1.48-slim as base

ARG CARGO_HOME

ENV CARGO_HOME=$CARGO_HOME

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update \
    && apt-get install -y \
    pkg-config \
    libpq-dev libssl-dev \
    tree time \
    && rm -vfR /var/lib/apt/lists/* \
    && rm -vf /etc/apt/apt.conf.d/docker-clean

COPY rust-toolchain ./
#COPY temp/.cargo $CARGO_HOME

# NOTE: use `master` version
RUN time cargo install diesel_cli \
    --branch master --git https://github.com/diesel-rs/diesel \
    --no-default-features --features postgres


# ** sources **
FROM base as source

ARG CRATE_NAME
ARG CARGO_HOME
ARG APP_SRC_PATH

ENV CARGO_HOME=$CARGO_HOME

WORKDIR $APP_SRC_PATH

COPY Cargo.toml Cargo.lock ./
COPY target ./target

# HACK: make rust be able to cache dockerfile
RUN --mount=type=cache,target=${CARGO_HOME} \
    set -ex; \
    mkdir -p $CARGO_HOME \
    && mkdir -p ./src \
    && echo "fn main() { println!(\"if you see this, the build broke\") }" >src/main.rs;

RUN --mount=type=cache,target=${CARGO_HOME} \
    set -ex; \
    time cargo build --release

RUN set -ex; \
    rm -vfR "./target/release/deps/${CRATE_NAME}"*

COPY . .

# HACK: fix cargo+docker file not updated
RUN touch src/main.rs

RUN --mount=type=cache,target=${CARGO_HOME} \
    set -ex; \
    time cargo build --release

# ** test and lint **
FROM source as test

ARG CARGO_HOME

ENV CARGO_HOME=$CARGO_HOME

RUN rustup component add rustfmt clippy

# Prevent unformatted code from building & merging
RUN set -e; \
    unformatted_files=$(cargo fmt -- -l --check | wc -l) && \
    if [ $unformatted_files -gt 0 ]; then \
    echo '# Please run cargo fmt !'; \
    cargo fmt -- -l --check; \
    exit 1; \
    fi

RUN --mount=type=cache,target=${CARGO_HOME} \
    time cargo clippy --release --all-features -- -D warnings

CMD ["scripts/test.sh"]


# ** builder **
FROM source as builder

ARG CARGO_HOME

ENV CARGO_HOME=$CARGO_HOME

RUN time cargo build --release


# ** server **
FROM debian:buster-slim as server

ARG CRATE_NAME
ARG APP_SRC_PATH

COPY --from=builder ${APP_SRC_PATH}/target/release/${CRATE_NAME} /myapp

WORKDIR /

CMD ["/myapp"]
