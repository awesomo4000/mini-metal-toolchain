#!/bin/bash
# Compile and link a test shader with the extracted toolchain, then load it on the GPU.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tc=${1:-$here/toolchain}
bin=$tc/bin
work=$(mktemp -d "${TMPDIR:-/tmp}/mini-metal-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT

"$bin/metal" --version | head -1
"$bin/metal" -c "$here/test/shader.metal" -o "$work/shader.air"
"$bin/metallib" "$work/shader.air" -o "$work/shader.metallib"
echo "built shader.metallib ($(wc -c < "$work/shader.metallib" | tr -d ' ') bytes)"

clang -fobjc-arc -framework Metal -framework Foundation "$here/test/load.m" -o "$work/load"
"$work/load" "$work/shader.metallib"
