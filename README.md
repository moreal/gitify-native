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

The version baked into the app comes from the tag. Downloads are not notarized, so first launch requires clearing quarantine: `xattr -dr com.apple.quarantine /Applications/Gitify.app`.

## Features

- Menu bar popover with GitHub notifications, grouped by repository or date
- Sign in with a Personal Access Token or the GitHub Device Flow
- Tokens stored in the macOS Keychain; multiple accounts with per-account sections
- PR / Issue / Discussion state enrichment (colored icons, numbers) with request caching
- Filters: subject type, state, reason, author type, and `org:` / `repo:` / `author:` search tokens (include & exclude)
- Mark as read / done, unsubscribe, mark repository as read
- Native notification banners with click-through, optional sound with volume control
- Launch at login, ⌘⇧G global hotkey, system-wake refresh, light/dark/system theme
- GitHub Enterprise Server hostnames

## License

[MIT](LICENSE) — same as upstream [Gitify](https://github.com/gitify-app/gitify) (Copyright © Emmanouil Konstantinidis), of which this project is a derivative.

All assets in `Resources/` are reused unmodified from the upstream MIT-licensed Gitify repository: the tray icons and app icon are the Gitify logo, and the notification sound is upstream's `clearly.mp3` (which appears to originate from ["Clearly" on notificationsounds.com](https://notificationsounds.com/notification-sounds/clearly-602), CC BY 4.0).
