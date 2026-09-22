# Sparkle Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Gitify's custom updater with Sparkle 2.10.0 and publish a signed Sparkle appcast in every GitHub Release.

**Architecture:** A small `UpdateController` owns Sparkle's `SPUStandardUpdaterController` and is shared by the menu and SwiftUI settings view. GitHub Releases remains the artifact host; a testable shell script invokes Sparkle's official `generate_appcast` tool and the release workflow uploads the resulting single-item `appcast.xml` beside the existing DMG, ZIP, and checksums.

**Tech Stack:** Swift 5, AppKit, SwiftUI, Sparkle 2.10.0 via Swift Package Manager, XcodeGen, Bash, Python `unittest`, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-09-22-sparkle-updater-design.md`

## Global Constraints

- The deployment target remains macOS 14.0.
- Sparkle is pinned to exact version 2.10.0.
- `SUFeedURL` is `https://github.com/moreal/gitify-native/releases/latest/download/appcast.xml`.
- Automatic checking is enabled and unattended installation is disabled.
- GitHub Releases remains the only update artifact host; GitHub Pages is not used for the appcast.
- Developer ID signing, notarization, DMG, ZIP, and SHA-256 artifacts remain unchanged.
- Sparkle's private Ed25519 key never enters the repository, command arguments, or logs.
- UI tests and screenshot capture never start Sparkle.
- macOS UI tests run only through `scripts/run-in-tart.sh test`, never directly on the host.
- Every commit created by Codex contains exactly one `Assisted-by: Codex:gpt-5.6-sol` trailer.

## Review Focus

- A missing or malformed `SUPublicEDKey` must fail the distribution contract tests before an unverifiable client is built; Task 1 validates strict base64 and a 32-byte decoded key.
- UI-test mode must construct the shared updater without starting Sparkle or opening an update window; Task 1 covers the policy decision with a unit test and the Tart UI suite exercises launch.
- A missing CI private key must stop appcast generation before publication; Task 2 tests the script's non-zero failure and diagnostic.
- A generated feed without an EdDSA signature or the immutable versioned GitHub download URL must be rejected; Task 2 tests both validation branches with fake generator output.
- Existing custom-updater clients must still find the versioned ZIP and checksum in the migration release; Task 2 preserves and reasserts both release assets.

---

### Task 1: Integrate Sparkle's standard updater

**Files:**
- Modify: `project.yml`
- Modify: `Sources/Info.plist`
- Replace: `Sources/App/UpdateChecker.swift`
- Modify: `Sources/App/AppDelegate.swift`
- Modify: `Sources/App/StatusItemController.swift`
- Modify: `Sources/UI/SettingsView.swift`
- Modify: `Sources/UI/LandingScreenshotRenderer.swift`
- Modify: `Sources/Core/UITestMock.swift`
- Create: `Tests/GitifyTests/UpdateControllerTests.swift`
- Modify: `Tests/DistributionTests/validate_distribution.py`

**Interfaces:**
- Consumes: Sparkle `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)` and `checkForUpdates(_:)`.
- Produces: `@MainActor final class UpdateController: ObservableObject`, `func checkForUpdates()`, `static let currentVersion`, and `static var releaseNotesURL`.
- Produces: `UITestMock.shouldStartUpdater(isUITestActive: Bool) -> Bool`, returning the inverse of its argument so the policy is unit-testable without mutating process arguments.

- [ ] **Step 1: Add failing tests for the updater start policy and distribution configuration**

Create `Tests/GitifyTests/UpdateControllerTests.swift`:

```swift
import XCTest
@testable import Gitify

final class UpdateControllerTests: XCTestCase {
    func testNormalLaunchStartsUpdater() {
        XCTAssertTrue(UITestMock.shouldStartUpdater(isUITestActive: false))
    }

    func testUITestLaunchDoesNotStartUpdater() {
        XCTAssertFalse(UITestMock.shouldStartUpdater(isUITestActive: true))
    }
}
```

Extend `ReleaseDistributionTests` in
`Tests/DistributionTests/validate_distribution.py` so it loads
`Sources/Info.plist` with `plistlib` after `xcodegen generate`, then asserts:

```python
import base64
import plistlib

INFO_PLIST = ROOT / "Sources/Info.plist"
PROJECT_SPEC = ROOT / "project.yml"

def test_sparkle_configuration_is_publishable(self) -> None:
    info = plistlib.loads(INFO_PLIST.read_bytes())
    self.assertEqual(
        info["SUFeedURL"],
        "https://github.com/moreal/gitify-native/releases/latest/download/appcast.xml",
    )
    self.assertIs(info["SUEnableAutomaticChecks"], True)
    self.assertIs(info["SUAutomaticallyUpdate"], False)
    self.assertEqual(len(base64.b64decode(info["SUPublicEDKey"], validate=True)), 32)
    project = PROJECT_SPEC.read_text()
    self.assertIn("https://github.com/sparkle-project/Sparkle", project)
    self.assertIn("exactVersion: 2.10.0", project)
```

The production change caught by the Swift tests is accidentally starting
Sparkle during deterministic UI runs. The distribution test catches a client
that points to the wrong feed, enables unattended installation, lacks a valid
Ed25519 public key, or silently floats to an unreviewed Sparkle version.

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
python3 -m unittest Tests/DistributionTests/validate_distribution.py
xcodegen generate
xcodebuild test \
  -project Gitify.xcodeproj \
  -scheme Gitify \
  -destination 'platform=macOS' \
  -only-testing:GitifyTests/UpdateControllerTests
```

Expected: the Python test fails because the Sparkle keys are absent, and the
Swift test target fails to compile because `shouldStartUpdater` is absent. This
host run is limited to unit tests and does not launch Gitify.

- [ ] **Step 3: Add Sparkle and generate the one-time signing key**

Add the exact Swift package and application dependency to `project.yml`:

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: 2.10.0

targets:
  Gitify:
    dependencies:
      - package: Sparkle
```

Run `xcodegen generate`, resolve/build once, and locate the official tools:

```bash
xcodebuild -resolvePackageDependencies \
  -project Gitify.xcodeproj \
  -scheme Gitify \
  -derivedDataPath build
find build/SourcePackages/artifacts -type f -path '*/Sparkle/bin/generate_keys' -print
```

Run the discovered `generate_keys` once. It stores the private key in the login
Keychain and prints the public key. Export the private key to a mode-600 file
under a newly created temporary directory, set the GitHub secret directly from
stdin, verify the secret name appears in `gh secret list`, and remove the
temporary directory. Keep the Keychain copy and arrange an encrypted backup
before the first public release.

```bash
umask 077
SPARKLE_KEY_DIR=$(mktemp -d)
SPARKLE_GENERATE_KEYS="build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
"$SPARKLE_GENERATE_KEYS"
"$SPARKLE_GENERATE_KEYS" -x "$SPARKLE_KEY_DIR/private-key"
gh secret set SPARKLE_ED_PRIVATE_KEY < "$SPARKLE_KEY_DIR/private-key"
gh secret list
rm -f "$SPARKLE_KEY_DIR/private-key"
rmdir "$SPARKLE_KEY_DIR"
```

Insert the printed public key into the `SUPublicEDKey` property described in
Step 4. Do not copy the private key into shell history, output, source files, or
the plan.

- [ ] **Step 4: Replace the custom updater with the standard controller**

Replace `Sources/App/UpdateChecker.swift` with an `UpdateController` that keeps
the existing filename to minimize project churn:

```swift
import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = UITestMock.shouldStartUpdater()) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    static var releaseNotesURL: URL {
        URL(string: "https://github.com/moreal/gitify-native/releases/tag/v\(currentVersion)")!
    }
}
```

Add the policy function to `UITestMock`:

```swift
static func shouldStartUpdater(isUITestActive: Bool = isActive) -> Bool {
    !isUITestActive
}
```

In `project.yml`, add the generated Info.plist properties below. Set
`SUPublicEDKey` to the exact base64 string printed by `generate_keys` in Step 3;
the key is intentionally dynamic because it must be generated once for this
repository rather than copied from an example application.

```yaml
SUFeedURL: https://github.com/moreal/gitify-native/releases/latest/download/appcast.xml
SUEnableAutomaticChecks: true
SUAutomaticallyUpdate: false
```

Run `xcodegen generate` to update `Sources/Info.plist` and the ignored Xcode
project.

Rename stored and injected values from `UpdateChecker` to `UpdateController` in
`AppDelegate`, `StatusItemController`, `SettingsView`, and
`LandingScreenshotRenderer`. Remove `onUpdateAvailable`,
`startAutomaticChecks()`, `deliverUpdateNotification(for:)`, phase rendering,
and `installUpdate`. The tray menu always adds one enabled **Check for updates**
item. The Settings footer always renders one **Check for updates** button. Both
call the shared `UpdateController.checkForUpdates()` instance.

Delete the update-feed branch from `UITestMockURLProtocol.respond(to:)`; Sparkle
does not use the application's GitHub `URLSession`.

- [ ] **Step 5: Run focused checks and verify GREEN**

Run:

```bash
python3 -m unittest Tests/DistributionTests/validate_distribution.py
xcodegen generate
xcodebuild test \
  -project Gitify.xcodeproj \
  -scheme Gitify \
  -destination 'platform=macOS' \
  -only-testing:GitifyTests/UpdateControllerTests
xcodebuild \
  -project Gitify.xcodeproj \
  -scheme Gitify \
  -configuration Debug \
  -derivedDataPath build \
  build
```

Expected: distribution tests and both unit tests pass, and the application
build completes without Sparkle linkage or signing errors. Do not run UI tests
on the host.

- [ ] **Step 6: Commit the runtime integration**

```bash
git add project.yml Sources/Info.plist Sources/App/UpdateChecker.swift \
  Sources/App/AppDelegate.swift Sources/App/StatusItemController.swift \
  Sources/UI/SettingsView.swift Sources/UI/LandingScreenshotRenderer.swift \
  Sources/Core/UITestMock.swift Tests/GitifyTests/UpdateControllerTests.swift \
  Tests/DistributionTests/validate_distribution.py
git commit -m "Replace custom updater with Sparkle" \
  -m "Assisted-by: Codex:gpt-5.6-sol"
```

### Task 2: Generate and publish the GitHub-hosted appcast

**Files:**
- Create: `scripts/generate-sparkle-appcast.sh`
- Create: `Tests/DistributionTests/test_sparkle_appcast.py`
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/DistributionTests/validate_distribution.py`

**Interfaces:**
- Consumes: positional arguments `<zip-path> <version> <output-path>`, executable path in `SPARKLE_GENERATE_APPCAST`, and private key contents in `SPARKLE_ED_PRIVATE_KEY`.
- Produces: a validated single-item `appcast.xml` with an enclosure URL under `https://github.com/moreal/gitify-native/releases/download/v<version>/` and a non-empty `sparkle:edSignature`.

- [ ] **Step 1: Write failing behavioral tests for appcast generation**

Create `Tests/DistributionTests/test_sparkle_appcast.py`. Each test creates a
temporary ZIP and an executable fake generator. The successful fake consumes
stdin, records its arguments, and writes an appcast containing:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
    <enclosure
      url="https://github.com/moreal/gitify-native/releases/download/v1.2.3/Gitify-1.2.3.zip"
      sparkle:edSignature="test-signature"
      length="1"
      type="application/octet-stream" />
  </item></channel>
</rss>
```

Use the following complete test structure so the fake replaces only Sparkle's
external binary while the repository's shell script and XML validation run for
real:

```python
#!/usr/bin/env python3
from pathlib import Path
import os
import stat
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/generate-sparkle-appcast.sh"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class SparkleAppcastScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)
        self.zip = self.dir / "Gitify-1.2.3.zip"
        self.zip.write_bytes(b"zip fixture")
        self.output = self.dir / "appcast.xml"
        self.args_file = self.dir / "args.txt"
        self.stdin_file = self.dir / "stdin.txt"
        self.generator = self.dir / "fake-generate-appcast"
        self.generator.write_text(
            """#!/usr/bin/env python3
from pathlib import Path
import os
import sys

Path(os.environ["FAKE_ARGS_FILE"]).write_text("\\n".join(sys.argv[1:]))
Path(os.environ["FAKE_STDIN_FILE"]).write_text(sys.stdin.read())
staging = Path(sys.argv[-1])
mode = os.environ.get("FAKE_MODE", "valid")
url = (
    "https://example.invalid/Gitify-1.2.3.zip"
    if mode == "wrong-url"
    else "https://github.com/moreal/gitify-native/releases/download/"
         "v1.2.3/Gitify-1.2.3.zip"
)
signature = "" if mode == "unsigned" else ' sparkle:edSignature="test-signature"'
(staging / "appcast.xml").write_text(f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item>
<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
<enclosure url="{url}"{signature} length="1" type="application/octet-stream" />
</item></channel></rss>''')
"""
        )
        self.generator.chmod(self.generator.stat().st_mode | stat.S_IXUSR)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_script(self, *, mode: str = "valid", include_key: bool = True):
        env = os.environ.copy()
        env.update({
            "SPARKLE_GENERATE_APPCAST": str(self.generator),
            "FAKE_ARGS_FILE": str(self.args_file),
            "FAKE_STDIN_FILE": str(self.stdin_file),
            "FAKE_MODE": mode,
        })
        if include_key:
            env["SPARKLE_ED_PRIVATE_KEY"] = "private-test-key"
        else:
            env.pop("SPARKLE_ED_PRIVATE_KEY", None)
        return subprocess.run(
            [str(SCRIPT), str(self.zip), "1.2.3", str(self.output)],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
        )

    def test_generates_signed_appcast_with_versioned_github_url(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        root = ET.parse(self.output).getroot()
        enclosure = root.find("./channel/item/enclosure")
        self.assertIsNotNone(enclosure)
        self.assertEqual(
            enclosure.attrib["url"],
            "https://github.com/moreal/gitify-native/releases/download/"
            "v1.2.3/Gitify-1.2.3.zip",
        )
        self.assertEqual(enclosure.attrib[f"{{{SPARKLE}}}edSignature"], "test-signature")
        self.assertIn("--ed-key-file\\n-", self.args_file.read_text())
        self.assertEqual(self.stdin_file.read_text(), "private-test-key")

    def test_rejects_missing_private_key(self) -> None:
        result = self.run_script(include_key=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY is required", result.stderr)

    def test_rejects_unsigned_generated_appcast(self) -> None:
        result = self.run_script(mode="unsigned")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing EdDSA signature", result.stderr)
        self.assertNotIn("private-test-key", result.stdout + result.stderr)

    def test_rejects_wrong_enclosure_url(self) -> None:
        result = self.run_script(mode="wrong-url")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected enclosure URL", result.stderr)


if __name__ == "__main__":
    unittest.main()
```

The success test asserts exit code zero, an output file at the requested path,
the exact versioned URL, a non-empty signature, `--ed-key-file -`, and that the
fake received the private key through stdin. Failure tests assert non-zero exit
status and a specific diagnostic without echoing key contents.

- [ ] **Step 2: Run appcast tests and verify RED**

Run:

```bash
python3 -m unittest Tests/DistributionTests/test_sparkle_appcast.py
```

Expected: all tests fail because `scripts/generate-sparkle-appcast.sh` does not
exist.

- [ ] **Step 3: Implement the appcast generator wrapper**

Create executable `scripts/generate-sparkle-appcast.sh` with strict mode. It
using this implementation:

```bash
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
from pathlib import Path
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
```

- [ ] **Step 4: Run appcast tests and verify GREEN**

Run:

```bash
chmod +x scripts/generate-sparkle-appcast.sh
python3 -m unittest Tests/DistributionTests/test_sparkle_appcast.py
```

Expected: four appcast behavior tests pass.

- [ ] **Step 5: Wire appcast publication into the release workflow**

After checksums are created in `.github/workflows/release.yml`, locate the
Sparkle artifact tool and call the wrapper without placing the key on the
command line:

```yaml
- name: Generate Sparkle appcast
  env:
    VERSION: ${{ steps.version.outputs.version }}
    SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
  run: |
    SPARKLE_GENERATE_APPCAST=$(find build/SourcePackages/artifacts \
      -type f -path '*/Sparkle/bin/generate_appcast' -print -quit)
    if [ -z "$SPARKLE_GENERATE_APPCAST" ]; then
      echo "::error::Sparkle generate_appcast tool was not resolved"
      exit 1
    fi
    export SPARKLE_GENERATE_APPCAST
    scripts/generate-sparkle-appcast.sh \
      "Gitify-$VERSION.zip" "$VERSION" appcast.xml
```

Add `appcast.xml` to `gh release create`. Keep the existing ZIP and its
`.sha256` asset so the pre-Sparkle updater can install the migration release.

Extend `ReleaseDistributionTests` to assert that the release workflow invokes
the wrapper, provides `secrets.SPARKLE_ED_PRIVATE_KEY`, and uploads
`appcast.xml`; this complements the behavioral script tests with the GitHub
Actions wiring contract.

- [ ] **Step 6: Run distribution tests and workflow syntax checks**

Run:

```bash
python3 -m unittest discover -s Tests/DistributionTests -p '*.py'
git diff --check
```

Expected: all distribution tests pass and the diff has no whitespace errors.

- [ ] **Step 7: Commit appcast publication**

```bash
git add scripts/generate-sparkle-appcast.sh \
  Tests/DistributionTests/test_sparkle_appcast.py \
  Tests/DistributionTests/validate_distribution.py \
  .github/workflows/release.yml
git commit -m "Publish signed Sparkle appcasts" \
  -m "Assisted-by: Codex:gpt-5.6-sol"
```

### Task 3: Document, validate, and exercise the migration

**Files:**
- Modify: `README.md`
- Modify: `HANDOFF.md`

**Interfaces:**
- Consumes: the runtime and release contracts from Tasks 1 and 2.
- Produces: maintainer instructions for key custody, GitHub secret setup,
  GitHub-hosted appcasts, and first-release migration behavior.

- [ ] **Step 1: Update maintainer documentation**

Change README's Auto-update section to state that Sparkle checks the GitHub
Release appcast automatically, presents standard UI, verifies EdDSA and
Developer ID signatures, and installs after confirmation. Add
`SPARKLE_ED_PRIVATE_KEY` to the release secret table and document the exact
one-time setup commands from Task 1, emphasizing encrypted backup and that the
private key must never be committed.

Update `HANDOFF.md` to replace the zero-dependency custom updater description
with `UpdateController`, Sparkle 2.10.0, the stable appcast URL, and the release
wrapper. Remove the obsolete claim that the repository has no third-party
dependencies.

- [ ] **Step 2: Run every host-safe check**

Run:

```bash
python3 -m unittest discover -s Tests/DistributionTests -p '*.py'
python3 -m unittest discover -s Tests/ToolingTests -p '*.py'
xcodegen generate
xcodebuild test \
  -project Gitify.xcodeproj \
  -scheme Gitify \
  -destination 'platform=macOS' \
  -only-testing:GitifyTests
xcodebuild \
  -project Gitify.xcodeproj \
  -scheme Gitify \
  -configuration Release \
  -derivedDataPath build \
  build
git diff --check
```

Expected: all Python and Swift unit tests pass, the Release build succeeds, and
the diff has no whitespace errors. Unit tests are allowed on the host because
they do not launch the application.

- [ ] **Step 3: Run the complete suite in Tart**

Run:

```bash
scripts/run-in-tart.sh test
```

Expected: the disposable VM completes all `GitifyTests` and `GitifyUITests`
without an update window, network-dependent failure, or host UI interaction. If
Tart cannot run, record the exact blocking condition and do not run UI tests on
the host.

- [ ] **Step 4: Inspect generated release metadata**

Build a local signed-test fixture with the appcast behavior test's fake
generator and inspect it with Python's XML parser. Confirm the feed contains
one `1.2.3` item, the versioned GitHub URL, and `sparkle:edSignature`. Do not
attempt a production release or upload a tag as part of this task.

- [ ] **Step 5: Commit documentation and any verification-only adjustments**

```bash
git add README.md HANDOFF.md
git commit -m "Document Sparkle release operations" \
  -m "Assisted-by: Codex:gpt-5.6-sol"
```

- [ ] **Step 6: Perform final review and repository-state check**

Review the complete diff against the design spec, verify every commit contains
exactly one required assistance trailer, and run:

```bash
git status --short --branch
git log --format='%h%n%B%n---' -4
```

Report any unrelated pre-existing changes separately and leave them untouched.
