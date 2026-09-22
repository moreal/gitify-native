#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <zip-path> <version> <output-path>" >&2
  exit 2
fi

ZIP_PATH="$1"
VERSION="$2"
OUTPUT_PATH="$3"

if [ -z "${SPARKLE_GENERATE_APPCAST:-}" ]; then
  echo "SPARKLE_GENERATE_APPCAST is required" >&2
  exit 1
fi
if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  echo "SPARKLE_ED_PRIVATE_KEY is required" >&2
  exit 1
fi
if [ ! -x "$SPARKLE_GENERATE_APPCAST" ]; then
  echo "SPARKLE_GENERATE_APPCAST is not executable" >&2
  exit 1
fi
if [ ! -f "$ZIP_PATH" ]; then
  echo "Update archive not found: $ZIP_PATH" >&2
  exit 1
fi

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gitify-appcast.XXXXXX")
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

ZIP_NAME=$(basename "$ZIP_PATH")
cp "$ZIP_PATH" "$STAGING_DIR/$ZIP_NAME"
DOWNLOAD_PREFIX="https://github.com/moreal/gitify-native/releases/download/v$VERSION/"

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_GENERATE_APPCAST" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/moreal/gitify-native/releases" \
  "$STAGING_DIR"

APPCAST="$STAGING_DIR/appcast.xml"
EXPECTED_URL="$DOWNLOAD_PREFIX$ZIP_NAME"
python3 - "$APPCAST" "$VERSION" "$EXPECTED_URL" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast, version, expected_url = sys.argv[1:]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
try:
    root = ET.parse(appcast).getroot()
except (OSError, ET.ParseError) as error:
    raise SystemExit(f"Invalid generated appcast: {error}")
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit("Generated appcast must contain exactly one item")
item = items[0]
short_version = item.findtext(f"{{{sparkle}}}shortVersionString")
if short_version != version:
    raise SystemExit(f"Unexpected appcast version: {short_version!r}")
enclosure = item.find("enclosure")
if enclosure is None or enclosure.get("url") != expected_url:
    raise SystemExit("Generated appcast has unexpected enclosure URL")
if not enclosure.get(f"{{{sparkle}}}edSignature"):
    raise SystemExit("Generated appcast is missing EdDSA signature")
PY

OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
mkdir -p "$OUTPUT_DIR"
TEMP_OUTPUT=$(mktemp "$OUTPUT_DIR/.appcast.XXXXXX")
cp "$APPCAST" "$TEMP_OUTPUT"
mv "$TEMP_OUTPUT" "$OUTPUT_PATH"
