#syntax=docker/dockerfile:1.0-experimental

ARG DOCKER_CACHED_IMAGE_VERSION=6
ARG APT_BUILD_PREREQ_PKGS="pkg-config=0.29-6 libpq-dev=11.10-0+deb10u1 libssl-dev=1.1.1d-0+deb10u4 rsync=3.1.3-6 tree=1.8.0-1 time=1.7-25.1+b1"
# libpq is needed for diesel-cli
ARG APT_RUN_EXTRA_PKGS="curl=7.64.0-4+deb10u1 libpq-dev=11.10-0+deb10u1 rsync=3.1.3-6 tree=1.8.0-1 time=1.7-25.1+b1"
ARG APP_SRC_PATH="/app"
ARG APP_PORT=8000
ARG CRATE_NAME="test_rust_caching"

#
# NOTE: Rust is broken on musl at the moment. we'll use alpine after the issue is resolved:
#     https://github.com/rust-lang/rust/issues/40174
#
# ** builder_base **
FROM rust:1.48-slim as builder_base

ARG DOCKER_CACHED_IMAGE_VERSION
ARG APT_BUILD_PREREQ_PKGS

WORKDIR /root

RUN rm -vf /etc/apt/apt.conf.d/docker-clean

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    # (cp -vR /mnt/apt1/* /var/cache/apt/ || true) \
    echo "# DOCKER_CACHED_IMAGE_VERSION=${DOCKER_CACHED_IMAGE_VERSION}"; \
    echo "# Installing APT build-prereq packages"; \
    echo "## ${APT_BUILD_PREREQ_PKGS}"; \
    set -ex; \
    apt-get update \
    && apt-get install --reinstall -y ${APT_BUILD_PREREQ_PKGS} \
    && rm -vfR /var/lib/apt/lists/*

# ** builder_tools **
FROM builder_base as builder_tools

ENV CARGO_HOME="/usr/local/cargo"

# NOTE: cargo itself is contained in $CARGO_HOME/bin/
# so we cannot let the initial cache mount overshadow $CARGO_HOME dir directly
#RUN --mount=type=cache,target=/mnt/cargo \
#    time rsync -av /mnt/cargo/ /usr/local/cargo/

COPY rust-toolchain ./

RUN echo "# Installing sccache"; \
    #TEST
    tree -L 2 /usr/local/cargo; \
    set -ex; \
    # workaround for docker-rust's Cargo malfunctioning install+upgrade behaviour
    # ref.: https://github.com/rust-lang/docker-rust/issues/70
    (time cargo install sccache || true; \
    if [ ! -f /usr/local/cargo/bin/sccache ]; then \
    echo "failed installing sccache"; exit -1; \
    fi)

RUN mkdir -p /var/cache/sccache

ENV RUSTC_WRAPPER="/usr/local/cargo/bin/sccache"
ENV SCCACHE_DIR="/var/cache/sccache"

RUN echo "# Installing: rustfmt, clippy" \
    && time rustup component add rustfmt clippy

# NOTE: Q: changed from `master` version to same fixed rev. as in core/Cargo.toml
RUN echo "# Installing Diesel CLI"; \
    #TEST
    tree -L 2 /usr/local/cargo; \
    set -ex; \
    # workaround for docker-rust's Cargo malfunctioning install+upgrade behaviour
    # ref.: https://github.com/rust-lang/docker-rust/issues/70
    (time cargo install diesel_cli \
    # --branch master
    --rev 70ff916 --git https://github.com/diesel-rs/diesel \
    --no-default-features --features postgres || true; \
    if [ ! -f /usr/local/cargo/bin/diesel ]; then \
    echo "failed installing diesel"; exit -1; \
    fi)


# ** deps **
FROM builder_tools as deps

ARG CRATE_NAME
ARG APP_SRC_PATH

ENV CARGO_HOME="/usr/local/cargo"

WORKDIR $APP_SRC_PATH

COPY Cargo.toml Cargo.lock ./
#COPY target ./target

# HACK: make rust be able to cache dockerfile
RUN mkdir -p ./src \
    && echo "fn main() { println!(\"if you see this, the build broke\") }" >src/main.rs;

RUN mv -v /root/rust-toolchain ./ \
    && time cargo build --release \
    && rm -vfR "./target/release/deps/${CRATE_NAME}"*


# ** sources **
FROM deps as source

COPY src src
COPY scripts scripts

# HACK: fix cargo+docker file not updated
RUN touch src/main.rs


# ** test and lint **
FROM source as test

ENV CARGO_HOME=/usr/local/cargo

# Prevent unformatted code from building & merging
# RUN --mount=type=cache,target=/usr/local/cargo \
RUN unformatted_files=$(cargo fmt -- -l --check | wc -l) \
    && (if [ $unformatted_files -gt 0 ]; then \
    echo '# Please run cargo fmt !'; \
    cargo fmt -- -l --check; \
    exit 1; \
    fi)

# RUN --mount=type=cache,target=/usr/local/cargo \
#     --mount=type=cache,target=${APP_SRC_PATH}/target \
RUN echo "# Running clippy" \
    && RUST_LOG=info time cargo clippy -v --release --all-features -- -D warnings

CMD ["scripts/test.sh"]


# ** builder **
FROM source as builder

ENV CARGO_HOME=/usr/local/cargo

# RUN --mount=type=cache,target=/usr/local/cargo \
#     tree -L 2 /usr/local/cargo; \
#     tree -L 3 ./target; \
RUN echo "# Building crates" \
    && RUST_LOG=info time cargo build -v --release


# ** runner_base **
FROM debian:buster-slim as runner_base

ARG DOCKER_CACHED_IMAGE_VERSION
ARG APT_RUN_EXTRA_PKGS

RUN rm -vf /etc/apt/apt.conf.d/docker-clean

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    # (cp -vR /mnt/apt2/* /var/cache/apt/ || true) \
    echo "# DOCKER_CACHED_IMAGE_VERSION=${DOCKER_CACHED_IMAGE_VERSION}"; \
    echo "# Installing APT runtime extra packages"; \
    echo "## ${APT_RUN_EXTRA_PKGS}"; \
    set -ex; \
    apt-get update \
    && apt-get install --reinstall -y ${APT_RUN_EXTRA_PKGS} \
    && rm -vfR /var/lib/apt/lists/*
#time rsync -av /var/cache/apt/ /mnt/apt2/

# ** server **
FROM runner_base as server

ARG APP_SRC_PATH
ARG APP_PORT

EXPOSE ${APP_PORT}

ENV APP_PORT=${APP_PORT}
ENV CARGO_HOME="/usr/local/cargo"

WORKDIR /

COPY --from=builder ${APP_SRC_PATH}/target/release/${CRATE_NAME} ./myapp
COPY --from=builder ${APP_SRC_PATH}/scripts ./scripts
COPY --from=builder ${CARGO_HOME}/bin/diesel ./diesel

RUN echo "# Setting scripts permissions"; \
    set -ex; \
    chmod +x ./scripts/*.sh \
    # TEST
    || echo "## WARN: chmod exited with non-zero code: $?; $(ls -al ./scripts/*.sh)"; \
    chmod +x ./diesel \
    # TEST
    || echo "## WARN: chmod exited with non-zero code: $?; $(ls -al ./diesel)"

CMD ["/myapp"]
