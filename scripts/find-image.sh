#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-}"

if [[ -z "$OUTPUT_DIR" || ! -d "$OUTPUT_DIR/images" ]]; then
  echo "Missing Buildroot images directory: ${OUTPUT_DIR}/images" >&2
  exit 1
fi

for f in \
  "$OUTPUT_DIR/images/sdcard.img" \
  "$OUTPUT_DIR/images"/*.img \
  "$OUTPUT_DIR/images"/*.wic \
  "$OUTPUT_DIR/images"/*.img.gz \
  "$OUTPUT_DIR/images"/*.img.xz
  do
  [[ -e "$f" ]] || continue
  echo "$f"
  exit 0
 done

echo "No burnable image found in $OUTPUT_DIR/images" >&2
exit 1
