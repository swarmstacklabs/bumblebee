#!/usr/bin/env bash
set -euo pipefail

DEVICE="${DEVICE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
TARGET="${TARGET:-unknown}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$DEVICE" ]]; then
  if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source ./.env
    DEVICE="${DEVICE:-}"
  fi
fi

if [[ -z "$DEVICE" ]]; then
  echo "DEVICE is required, e.g. make TARGET=rpi4 burn DEVICE=/dev/sdX"
  exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "Not a block device: $DEVICE"
  exit 1
fi

IMAGE="$($SCRIPT_DIR/find-image.sh)"

echo "About to write"
echo "  target : $TARGET"
echo "  image  : $IMAGE"
echo "  device : $DEVICE"
echo
lsblk "$DEVICE" || true
echo
read -r -p "Type YES to continue: " ANSWER
[[ "$ANSWER" == "YES" ]] || { echo "Aborted."; exit 1; }

sync
sudo umount "${DEVICE}"?* 2>/dev/null || true

case "$IMAGE" in
  *.img|*.wic)
    sudo dd if="$IMAGE" of="$DEVICE" bs=4M conv=fsync status=progress
    ;;
  *.img.gz)
    gzip -dc "$IMAGE" | sudo dd of="$DEVICE" bs=4M conv=fsync status=progress
    ;;
  *.img.xz)
    xz -dc "$IMAGE" | sudo dd of="$DEVICE" bs=4M conv=fsync status=progress
    ;;
  *)
    echo "Unsupported image format: $IMAGE"
    exit 1
    ;;
esac

sync
echo "Done. You can now reinsert the SD card."
