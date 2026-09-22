#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <result.xcresult> <output.png>" >&2
  exit 2
fi

RESULT_BUNDLE="$1"
OUTPUT="$2"
EXPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gitify-screenshot.XXXXXX")"

cleanup() {
  rm -rf "$EXPORT_DIR"
}
trap cleanup EXIT

xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$EXPORT_DIR" \
  --filter '*.png'

SCREENSHOT_COUNT="$(find "$EXPORT_DIR" -type f -name '*.png' | wc -l | tr -d ' ')"
if [ "$SCREENSHOT_COUNT" -ne 1 ]; then
  echo "expected one screenshot attachment, found $SCREENSHOT_COUNT" >&2
  exit 1
fi

SCREENSHOT="$(find "$EXPORT_DIR" -type f -name '*.png' -print -quit)"
PIXEL_WIDTH="$(sips -g pixelWidth "$SCREENSHOT" | awk '/pixelWidth/ { print $2 }')"
PIXEL_HEIGHT="$(sips -g pixelHeight "$SCREENSHOT" | awk '/pixelHeight/ { print $2 }')"

# XCUI captures the 446×586 pt popover frame including its arrow and shadow.
# Center-crop to the app's 420×560 pt content at either 1× or 2× scale.
if [ "$((PIXEL_WIDTH * 586))" -ne "$((PIXEL_HEIGHT * 446))" ]; then
  echo "unexpected screenshot dimensions: ${PIXEL_WIDTH}x${PIXEL_HEIGHT}" >&2
  exit 1
fi
SCALE="$((PIXEL_WIDTH / 446))"
if [ "$SCALE" -lt 1 ] || [ "$((SCALE * 446))" -ne "$PIXEL_WIDTH" ]; then
  echo "unsupported screenshot scale for width $PIXEL_WIDTH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
sips --cropToHeightWidth "$((560 * SCALE))" "$((420 * SCALE))" \
  "$SCREENSHOT" --out "$OUTPUT" >/dev/null
echo "wrote $OUTPUT (${PIXEL_WIDTH}x${PIXEL_HEIGHT} source, ${SCALE}x scale)"
