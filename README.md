# Gitify Native

A lightweight, unofficial native macOS port of [Gitify](https://gitify.io/) — GitHub notifications on your menu bar — written in Swift/SwiftUI with no Electron. [Sparkle](https://sparkle-project.org/) provides native software updates. Not affiliated with the upstream [gitify-app](https://github.com/gitify-app/gitify) project.

Visit [moreal.github.io/gitify-native](https://moreal.github.io/gitify-native/) or [download the latest DMG](https://github.com/moreal/gitify-native/releases/latest/download/Gitify.dmg).

For development, the upstream Electron source can be cloned into `gitify/` for reference (the directory is gitignored).

## Requirements

- macOS 14+
- Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & Run

```sh
xcodegen generate
xcodebuild -project Gitify.xcodeproj -scheme Gitify -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Gitify-*/Build/Products/Debug/Gitify.app
```

### Isolated macOS tests with Tart

UI tests launch the menu-bar app and can steal focus on the development Mac.
The Tart runner uses the official Cirrus Labs macOS Sequoia/Xcode 16.4 image,
pinned by digest, and runs the tests in a disposable VM without opening a VM
window. Install [Tart](https://tart.run/) before using it. The first run downloads
the large Xcode image and needs roughly 100 GiB of free disk space; later runs
reuse Tart's OCI cache.

Each command clones that base with APFS copy-on-write, mounts a temporary copy
of the checkout read-only, runs the work with graphics/audio/clipboard disabled,
and deletes the clone afterward:

```sh
# Full unit and UI test suite
scripts/run-in-tart.sh test

# Regenerate the landing-page capture using the real app
scripts/run-in-tart.sh screenshot
```

Set `GITIFY_TART_IMAGE` to use another compatible Tart image or local VM name.
Failed runs preserve their temporary artifacts and Tart log under the printed
path.

## Releases

Tagged releases are built and published automatically by [GitHub Actions](.github/workflows/release.yml) as a universal (Apple silicon + Intel) ad-hoc-signed app. To cut a release, either:

- push a tag: `git tag v0.2.0 && git push origin v0.2.0`, or
- run the **Release** workflow manually from the Actions tab with a version number (it creates the tag for you).

The version baked into the app comes from the tag.

For installation, open `Gitify.dmg`, drag `Gitify.app` onto the Applications
shortcut, then launch Gitify from Applications. New installations open at login by
default; this can be disabled at any time in Settings.

### Auto-update

Sparkle checks the signed `appcast.xml` attached to the latest GitHub Release
automatically and on demand from the tray right-click menu or Settings footer.
When a newer version is available, Sparkle presents its standard update window;
for background checks Gitify also posts a system notification so a dockless
menu-bar app does not hide the alert behind other applications. After
confirmation Sparkle downloads the versioned release ZIP, verifies both its
Ed25519 update signature and Developer ID code signature, installs it safely,
and relaunches Gitify. GitHub Releases remains the source of truth for both the
feed and update archives.

### Code signing

By default releases are **ad-hoc signed**: macOS Gatekeeper reports downloads as "damaged", and the first launch requires clearing quarantine (`xattr -dr com.apple.quarantine /Applications/Gitify.app`). This is an Apple policy limitation — passing Gatekeeper requires a paid Apple Developer membership; no CI configuration can work around it.

To ship properly signed and notarized releases, configure the five Apple
repository secrets below. The workflow then switches to Developer ID signing
with hardened runtime, notarizes with `notarytool`, and staples the ticket.
`SPARKLE_ED_PRIVATE_KEY` is always required because unsigned update archives
are never published:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of a Developer ID Application certificate export (`base64 -i cert.p12`) |
| `MACOS_CERTIFICATE_PASSWORD` | password of the `.p12` export |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password from appleid.apple.com |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle Ed25519 private key exported by `generate_keys` |

If an Apple secret is missing, the workflow falls back to ad-hoc code signing.
If the Sparkle secret is missing, appcast generation fails and the release is
not published.

Generate the Sparkle key once after resolving the pinned package. The private
key remains in the login Keychain under account `dev.moreal.gitify`; only the
public key printed by the tool belongs in `project.yml` as `SUPublicEDKey`:

```sh
xcodegen generate
xcodebuild -resolvePackageDependencies \
  -project Gitify.xcodeproj -scheme Gitify -derivedDataPath build

SPARKLE_KEYS=build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
"$SPARKLE_KEYS" --account dev.moreal.gitify
umask 077
"$SPARKLE_KEYS" --account dev.moreal.gitify -x /secure/path/gitify-sparkle-key
gh secret set SPARKLE_ED_PRIVATE_KEY < /secure/path/gitify-sparkle-key
```

Store the exported private key in an encrypted password manager or offline
backup and remove any unencrypted temporary copy. Never commit it. GitHub does
not allow secret values to be downloaded again, and losing both the Keychain
item and backup makes future key rotation substantially harder.

## Features

- Menu bar popover with GitHub notifications, grouped by repository or date
- Sign in with a Personal Access Token or the GitHub Device Flow
- Tokens stored in the macOS Keychain; multiple accounts with per-account sections
- PR / Issue / Discussion / Commit / Release subject enrichment (colored icons, numbers, authors) with request caching
- Filters: subject type, state, reason, author type, and `org:` / `repo:` / `author:` search tokens (include & exclude)
- Mark as read / done, unsubscribe, mark repository as read
- Native notification banners with click-through, optional sound with volume control
- Launch at login, configurable global hotkey (default ⌘⇧G), system-wake refresh, light/dark/system theme
- GitHub Enterprise Server hostnames

## License

[MIT](LICENSE) — same as upstream [Gitify](https://github.com/gitify-app/gitify) (Copyright © Emmanouil Konstantinidis), of which this project is a derivative.

All assets in `Resources/` are reused unmodified from the upstream MIT-licensed Gitify repository: the tray icons and app icon are the Gitify logo, and the notification sound is upstream's `clearly.mp3` (which appears to originate from ["Clearly" on notificationsounds.com](https://notificationsounds.com/notification-sounds/clearly-602), CC BY 4.0).
