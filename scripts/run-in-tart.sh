#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-in-tart.sh test
       scripts/run-in-tart.sh screenshot [output.png]

Run Gitify's macOS tests in a disposable, non-graphical Tart VM. The host
checkout is copied to a temporary read-only share; the VM cannot modify it.

Environment:
  GITIFY_TART_IMAGE  Tart image or local VM to clone (default: pinned Xcode 16.4 image)
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ACTION="${1:-}"
if [ "$ACTION" != "test" ] && [ "$ACTION" != "screenshot" ]; then
  usage >&2
  exit 2
fi
if [ "$ACTION" = "test" ] && [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi
if [ "$ACTION" = "screenshot" ] && [ "$#" -gt 2 ]; then
  usage >&2
  exit 2
fi

for command_name in tart rsync xcodegen; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required" >&2
    exit 1
  fi
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_IMAGE="${GITIFY_TART_IMAGE:-ghcr.io/cirruslabs/macos-sequoia-xcode@sha256:d25b1ba480166790c90326c33f9add68c745f38bad443db0bf803ddb50931f72}"
VM="gitify-native-${ACTION}-$(date +%s)-$$"
SHARE="$(mktemp -d "${TMPDIR:-/tmp}/gitify-tart.XXXXXX")"
RUN_PID=""
SUCCEEDED=false

cleanup() {
  exit_code=$?
  if [ -n "$RUN_PID" ]; then
    tart stop "$VM" --timeout 10 >/dev/null 2>&1 || true
    wait "$RUN_PID" >/dev/null 2>&1 || true
  fi
  tart delete "$VM" >/dev/null 2>&1 || true
  if [ "$SUCCEEDED" = true ]; then
    rm -rf "$SHARE"
  else
    echo "Tart artifacts preserved at $SHARE" >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT

mkdir -p "$SHARE/source" "$SHARE/artifacts"
rsync -a \
  --exclude '.git/' \
  --exclude '*.p12' \
  --exclude 'Gitify.xcodeproj/' \
  --exclude 'DerivedData/' \
  --exclude 'build/' \
  --exclude 'gitify/' \
  "$ROOT/" "$SHARE/source/"
xcodegen generate \
  --spec "$SHARE/source/project.yml" \
  --project "$SHARE/source" \
  --project-root "$SHARE/source"

TART_NO_AUTO_PRUNE=1 tart clone "$BASE_IMAGE" "$VM"
tart run \
  --no-graphics \
  --no-audio \
  --no-clipboard \
  --dir="source:$SHARE/source:ro" \
  --dir="artifacts:$SHARE/artifacts" \
  "$VM" >"$SHARE/tart.log" 2>&1 &
RUN_PID=$!

ready=false
for _ in $(seq 1 90); do
  if tart exec "$VM" /usr/bin/true >/dev/null 2>&1; then
    ready=true
    break
  fi
  if ! kill -0 "$RUN_PID" >/dev/null 2>&1; then
    echo "Tart VM stopped before its guest agent became ready" >&2
    cat "$SHARE/tart.log" >&2
    exit 1
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  echo "Timed out waiting for the Tart guest agent" >&2
  exit 1
fi

if [ "$ACTION" = "test" ]; then
  GUEST_COMMAND=$(cat <<'EOF'
set -euo pipefail
WORK="$HOME/gitify-native-work"
rm -rf "$WORK"
mkdir -p "$WORK"
rsync -a "/Volumes/My Shared Files/source/" "$WORK/"
cd "$WORK"
xcodebuild test \
  -project Gitify.xcodeproj \
  -scheme Gitify \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/gitify-derived-data
EOF
)
else
  GUEST_COMMAND=$(cat <<'EOF'
set -euo pipefail
WORK="$HOME/gitify-native-work"
RESULT="/tmp/GitifyLanding.xcresult"
rm -rf "$WORK" "$RESULT"
mkdir -p "$WORK"
rsync -a "/Volumes/My Shared Files/source/" "$WORK/"
cd "$WORK"
xcodebuild test \
  -project Gitify.xcodeproj \
  -scheme Gitify \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/gitify-derived-data \
  -resultBundlePath "$RESULT" \
  -only-testing:GitifyUITests/PopoverStabilityUITests/testCaptureLandingScreenshot
scripts/export-landing-screenshot.sh \
  "$RESULT" \
  "/Volumes/My Shared Files/artifacts/gitify-popover.png"
EOF
)
fi

tart exec "$VM" /bin/zsh -lc "$GUEST_COMMAND"

if [ "$ACTION" = "screenshot" ]; then
  OUTPUT="${2:-$ROOT/docs/site/assets/gitify-popover.png}"
  mkdir -p "$(dirname "$OUTPUT")"
  cp "$SHARE/artifacts/gitify-popover.png" "$OUTPUT"
  echo "Wrote $OUTPUT"
fi

SUCCEEDED=true
