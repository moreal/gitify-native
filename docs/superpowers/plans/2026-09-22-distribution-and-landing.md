# Distribution and Landing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable launch at login for new users, publish a verified drag-install DMG at a stable URL, and deploy a small GitHub Pages download site.

**Architecture:** A testable login-item adapter reconciles `SettingsStore` intent with `SMAppService`; the existing release workflow keeps the updater ZIP and publishes a stable DMG; a dependency-free site in `docs/site` is deployed by the official Pages Actions. A standard-library validation script pins the distribution and site contracts without adding dependencies.

**Tech Stack:** Swift 5, SwiftUI/AppKit, ServiceManagement, XCTest, XcodeGen, GitHub Actions, HTML5, CSS

**Spec:** `docs/superpowers/specs/2026-09-22-distribution-and-landing-design.md`

## Global Constraints

- Support macOS 14 and later on Apple silicon and Intel.
- Keep the native app and website free of third-party runtime dependencies.
- Preserve an existing user's explicit `Open at login` choice.
- Continue publishing the versioned ZIP and checksum used by the in-app updater.
- Deploy GitHub Pages with GitHub Actions from `main`; do not maintain a Pages branch.
- Use GitHub Releases as the only binary distribution source.

## Review Focus

- A persisted `false` login preference must survive upgrades and app relaunches; Task 1 tests it directly.
- UI tests must never register the development build as a system login item; Task 1 pins an explicit false UI-test default.
- `requiresApproval` must not cause repeated registration attempts but must remain removable; Task 1 tests both branches.
- The landing download link must resolve through the stable `Gitify.dmg` release asset name; Task 2 validates both ends of that contract.
- Pages must deploy only the site directory with the minimum Pages permissions; Task 3 validates the artifact path and permissions.

---

### Task 1: Login Item Default and Reconciliation

**Files:**
- Create: `Sources/App/LoginItemController.swift`
- Create: `Tests/GitifyTests/SettingsStoreTests.swift`
- Create: `Tests/GitifyTests/LoginItemControllerTests.swift`
- Modify: `project.yml`
- Modify: `Sources/Core/SettingsStore.swift`
- Modify: `Sources/Core/UITestMock.swift`
- Modify: `Sources/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `SettingsStore.openAtStartup`, `SMAppService.mainApp`
- Produces: `LoginItemController.init(service:)` and `reconcile(enabled:)`

- [ ] **Step 1: Add a unit-test target and write failing settings tests**

Add `GitifyTests` as a macOS unit-test bundle depending on `Gitify`, then test an
empty suite, stored false, and reset:

```swift
@MainActor
final class SettingsStoreTests: XCTestCase {
    func testOpenAtStartupDefaultsToEnabled() {
        XCTAssertTrue(SettingsStore(defaults: freshDefaults()).openAtStartup)
    }

    func testOpenAtStartupPreservesStoredFalse() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: "openAtStartup")
        XCTAssertFalse(SettingsStore(defaults: defaults).openAtStartup)
    }

    func testResetRestoresOpenAtStartupDefault() {
        let settings = SettingsStore(defaults: freshDefaults())
        settings.openAtStartup = false
        settings.reset()
        XCTAssertTrue(settings.openAtStartup)
    }
}
```

- [ ] **Step 2: Run the settings tests and verify the new-default tests fail**

Run: `xcodegen generate && xcodebuild test -project Gitify.xcodeproj -scheme Gitify -only-testing:GitifyTests/SettingsStoreTests`

Expected: stored false passes; empty defaults and reset fail because the existing default is false.

- [ ] **Step 3: Implement the new default and isolate UI tests**

Change both the initializer fallback and reset value to `true`. In
`UITestMock.makeDefaults()`, explicitly store `false` for `openAtStartup` before the
test app creates `SettingsStore`.

- [ ] **Step 4: Write failing login-item reconciliation tests**

Introduce test cases around a fake `LoginItemService` for these exact transitions:

```swift
func testEnabledNotRegisteredRegisters() throws
func testEnabledAlreadyEnabledDoesNothing() throws
func testEnabledRequiresApprovalDoesNothing() throws
func testDisabledEnabledUnregisters() throws
func testDisabledRequiresApprovalUnregisters() throws
func testDisabledNotRegisteredDoesNothing() throws
```

The fake records `registerCount` and `unregisterCount`; every test asserts both.

- [ ] **Step 5: Run the reconciliation tests and verify they fail to compile**

Run: `xcodebuild test -project Gitify.xcodeproj -scheme Gitify -only-testing:GitifyTests/LoginItemControllerTests`

Expected: FAIL because `LoginItemController` and `LoginItemService` do not exist.

- [ ] **Step 6: Implement the controller and connect it at launch**

Define an `@MainActor` protocol exposing `status`, `register()`, and `unregister()`,
conform `SMAppService`, and implement the tested transition table. In `AppDelegate`,
retain a controller and subscribe to `$openAtStartup` without `dropFirst()` so the
stored intent is reconciled immediately and on every distinct change.

- [ ] **Step 7: Run unit tests and the complete scheme**

Run: `xcodebuild test -project Gitify.xcodeproj -scheme Gitify -only-testing:GitifyTests`

Run: `xcodebuild test -project Gitify.xcodeproj -scheme Gitify`

Expected: all unit and UI tests pass.

### Task 2: Stable and Verified DMG Contract

**Files:**
- Create: `Tests/DistributionTests/validate_distribution.py`
- Modify: `.github/workflows/release.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: Release app at `build/Build/Products/Release/Gitify.app`
- Produces: `Gitify.dmg`, `Gitify.dmg.sha256`, and the permanent latest-download URL

- [ ] **Step 1: Write a failing distribution contract test**

Use Python's standard library to assert that `release.yml`:

```python
assert 'DMG="Gitify.dmg"' in release
assert 'hdiutil verify "$DMG"' in release
assert 'test -d "$MOUNT_POINT/Gitify.app"' in release
assert 'test -L "$MOUNT_POINT/Applications"' in release
assert '"Gitify.dmg"' in release
assert '"Gitify.dmg.sha256"' in release
```

Also assert that README contains the stable latest-download URL.

- [ ] **Step 2: Run the contract test and verify it fails**

Run: `python3 Tests/DistributionTests/validate_distribution.py`

Expected: FAIL because the workflow still names the DMG with the release version.

- [ ] **Step 3: Update packaging, verification, checksums, and release notes**

Create `Gitify.dmg`, sign/notarize that stable filename when configured, and add a
verification step which runs `hdiutil verify`, attaches read-only with a unique
mount point, checks `Gitify.app` and the Applications symlink, and detaches through
a shell trap. Publish only the stable DMG name while preserving
`Gitify-$VERSION.zip` and its checksum for the updater.

- [ ] **Step 4: Update README distribution behavior**

Link the landing page, add the stable direct download, explain drag installation,
and state that launch at login defaults on and remains configurable.

- [ ] **Step 5: Run the distribution contract test**

Run: `python3 Tests/DistributionTests/validate_distribution.py`

Expected: PASS.

### Task 3: Static Landing Page and Pages Actions

**Files:**
- Create: `docs/site/index.html`
- Create: `docs/site/styles.css`
- Create: `docs/site/app-icon.png`
- Create: `docs/site/.nojekyll`
- Create: `.github/workflows/pages.yml`
- Extend: `Tests/DistributionTests/validate_distribution.py`

**Interfaces:**
- Consumes: stable `Gitify.dmg` release asset from Task 2
- Produces: static Pages artifact from `docs/site` at `moreal.github.io/gitify-native`

- [ ] **Step 1: Extend the test with failing site and Pages checks**

Parse `index.html` with `html.parser.HTMLParser` and assert one main landmark, a
non-empty image alt, the stable DMG URL, repository and release links, `macOS 14+`,
and local `styles.css`/`app-icon.png` assets. Assert the CSS contains visible
`:focus-visible` rules and `@media (prefers-reduced-motion: reduce)`. Assert the
workflow uses `actions/configure-pages@v5`, `actions/upload-pages-artifact@v4`,
`actions/deploy-pages@v5`, `path: docs/site`, and the three required permissions.

- [ ] **Step 2: Run the test and verify it fails for missing site files**

Run: `python3 Tests/DistributionTests/validate_distribution.py`

Expected: FAIL because `docs/site/index.html` does not exist.

- [ ] **Step 3: Create the site asset and semantic HTML**

Convert the existing ICNS to a 256px PNG with `sips`, then build the approved hero,
CSS app preview, feature grid, installation steps, requirements, Gatekeeper note,
and footer. Use semantic header/main/sections/footer, meaningful link text, an icon
alt, and no script or external asset requests.

- [ ] **Step 4: Create responsive styling**

Use system fonts, semantic light/dark custom properties, a compact max-width layout,
fluid type, 44px controls, visible focus outlines, reduced-motion overrides, and
single-column mobile layouts. Keep motion limited to a short hero entrance and
button hover transforms.

- [ ] **Step 5: Add the Pages workflow**

Create a workflow triggered by relevant pushes to `main` and `workflow_dispatch`,
with `contents: read`, `pages: write`, `id-token: write`, a `github-pages`
environment, and concurrency cancellation. Checkout, configure Pages, upload only
`docs/site`, and deploy it.

- [ ] **Step 6: Run contract and local HTTP checks**

Run: `python3 Tests/DistributionTests/validate_distribution.py`

Run a temporary local server for `docs/site`, then request `/`, `/styles.css`, and
`/app-icon.png`; expect HTTP 200 and non-empty bodies.

### Task 4: Release Build and Final Verification

**Files:**
- Verify all files changed above

**Interfaces:**
- Consumes: Tasks 1-3
- Produces: a reviewable, release-ready working tree

- [ ] **Step 1: Run syntax and whitespace validation**

Run: `git diff --check`

Run: `python3 Tests/DistributionTests/validate_distribution.py`

- [ ] **Step 2: Run the full app test suite and Release build**

Run: `xcodegen generate && xcodebuild test -project Gitify.xcodeproj -scheme Gitify`

Run: `xcodebuild -project Gitify.xcodeproj -scheme Gitify -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- build`

- [ ] **Step 3: Exercise DMG creation locally**

Create `Gitify.dmg` from the ad-hoc Release app using the exact workflow packaging
commands, run `hdiutil verify`, mount it, assert the app and Applications link, then
detach and delete only the temporary image and mount directory.

- [ ] **Step 4: Inspect the final diff and commit trailers**

Confirm each commit contains exactly one `Assisted-by: Codex:gpt-5.6-sol` trailer,
no other user changes were touched, and no generated Xcode project or build output
is tracked.
