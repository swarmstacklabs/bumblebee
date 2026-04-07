#!/usr/bin/env bash
set -euo pipefail

BUILDROOT_DIR="${1:-${BUILDROOT_DIR:-}}"
TARGET="${2:-${TARGET:-rpi4}}"

if [[ -z "$BUILDROOT_DIR" ]]; then
  echo "Usage: $0 /path/to/buildroot [rpi3|rpi4|rpi5]"
  exit 1
fi

make BUILDROOT_DIR="$BUILDROOT_DIR" TARGET="$TARGET" defconfig
make BUILDROOT_DIR="$BUILDROOT_DIR" TARGET="$TARGET" build
