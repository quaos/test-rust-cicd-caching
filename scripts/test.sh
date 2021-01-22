#!/bin/bash

PATH="${PATH}:${CARGO_HOME}/bin"

tree -L 3 target

cargo test --release --tests --workspace
