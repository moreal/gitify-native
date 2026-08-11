# Gitify Native

A lightweight, unofficial native macOS port of [Gitify](https://gitify.io/) — GitHub notifications on your menu bar — written in Swift/SwiftUI with zero third-party dependencies (no Electron). Not affiliated with the upstream [gitify-app](https://github.com/gitify-app/gitify) project.

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

## Releases

Tagged releases are built and published automatically by [GitHub Actions](.github/workflows/release.yml) as a universal (Apple silicon + Intel) ad-hoc-signed app. To cut a release, either:

- push a tag: `git tag v0.2.0 && git push origin v0.2.0`, or
- run the **Release** workflow manually from the Actions tab with a version number (it creates the tag for you).

The version baked into the app comes from the tag.

### Code signing

By default releases are **ad-hoc signed**: macOS Gatekeeper reports downloads as "damaged", and the first launch requires clearing quarantine (`xattr -dr com.apple.quarantine /Applications/Gitify.app`). This is an Apple policy limitation — passing Gatekeeper requires a paid Apple Developer membership; no CI configuration can work around it.

To ship properly signed and notarized releases, configure all five repository secrets — the workflow then switches to Developer ID signing with hardened runtime, notarizes with `notarytool`, and staples the ticket:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of a Developer ID Application certificate export (`base64 -i cert.p12`) |
| `MACOS_CERTIFICATE_PASSWORD` | password of the `.p12` export |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password from appleid.apple.com |

If any secret is missing, the workflow falls back to ad-hoc signing.

## Features

- Menu bar popover with GitHub notifications, grouped by repository or date
- Sign in with a Personal Access Token or the GitHub Device Flow
- Tokens stored in the macOS Keychain; multiple accounts with per-account sections
- PR / Issue / Discussion / Commit / Release subject enrichment (colored icons, numbers, authors) with request caching
- Filters: subject type, state, reason, author type, and `org:` / `repo:` / `author:` search tokens (include & exclude)
- Mark as read / done, unsubscribe, mark repository as read
- Native notification banners with click-through, optional sound with volume control
- Launch at login, ⌘⇧G global hotkey, system-wake refresh, light/dark/system theme
- GitHub Enterprise Server hostnames

## License

[MIT](LICENSE) — same as upstream [Gitify](https://github.com/gitify-app/gitify) (Copyright © Emmanouil Konstantinidis), of which this project is a derivative.

All assets in `Resources/` are reused unmodified from the upstream MIT-licensed Gitify repository: the tray icons and app icon are the Gitify logo, and the notification sound is upstream's `clearly.mp3` (which appears to originate from ["Clearly" on notificationsounds.com](https://notificationsounds.com/notification-sounds/clearly-602), CC BY 4.0).
