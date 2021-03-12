#!/bin/bash

PATH="${PATH}:${CARGO_HOME}/bin"

tree -L 2 "${CARGO_HOME}"
tree -L 3 target

cargo test -v --release --tests --workspace
