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
EXPECTED_PIXEL_WIDTH=1680
EXPECTED_PIXEL_HEIGHT=2240

# The app renders its real 420×560 pt SwiftUI popover at a fixed 4× scale.
# Reject lower-density CI captures instead of silently shipping a blurry image.
if [ "$PIXEL_WIDTH" -ne "$EXPECTED_PIXEL_WIDTH" ] || \
   [ "$PIXEL_HEIGHT" -ne "$EXPECTED_PIXEL_HEIGHT" ]; then
  echo "expected ${EXPECTED_PIXEL_WIDTH}x${EXPECTED_PIXEL_HEIGHT} screenshot, got ${PIXEL_WIDTH}x${PIXEL_HEIGHT}" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
cp "$SCREENSHOT" "$OUTPUT"
echo "wrote $OUTPUT (${PIXEL_WIDTH}x${PIXEL_HEIGHT}, app-rendered at 4x)"
