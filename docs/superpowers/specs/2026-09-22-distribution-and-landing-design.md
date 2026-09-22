# Gitify Native Distribution and Landing Design

## Goal

Make Gitify Native easy to discover, install, and keep available: new installs
open at login by default, every release includes a drag-to-Applications DMG,
and `moreal.github.io/gitify-native` provides a small first-party download page.

## Constraints

- Support macOS 14 and later on Apple silicon and Intel.
- Keep the native app and website free of third-party runtime dependencies.
- Preserve an existing user's explicit `Open at login` choice.
- Continue publishing the versioned ZIP and checksum used by the in-app updater.
- Deploy GitHub Pages with GitHub Actions from `main`; do not maintain a Pages branch.
- Use GitHub Releases as the only binary distribution source.

## Login at Launch

`SettingsStore` will default `openAtStartup` to `true` only when the preference
has never been stored. Existing `true` and `false` values remain unchanged. Resetting
settings restores the new default of `true`.

At application launch, `AppDelegate` will reconcile the desired setting with
`SMAppService.mainApp.status`. It will register the main app only when enabled and
not already enabled, and unregister it only when disabled and currently enabled.
Changes from the Settings toggle and Reset Settings use the same reconciliation
path. UI-test defaults explicitly disable the login item so automated tests never
change the developer machine's system login items.

Registration failures remain non-fatal and are logged. The stored preference stays
as the user's intent so macOS can surface approval requirements and the app can try
again on a later launch.

## Release Packaging

The existing universal Release build, app signing, notarization, and versioned ZIP
remain intact. The DMG contains `Gitify.app` and an `Applications` symlink so the
standard Finder drag installation works.

The published disk image has the stable asset name `Gitify.dmg`. This gives the
landing page a permanent latest-release URL:

`https://github.com/moreal/gitify-native/releases/latest/download/Gitify.dmg`

The matching checksum is `Gitify.dmg.sha256`. CI verifies the completed image with
`hdiutil verify`, mounts it, and confirms that `Gitify.app` and the Applications
symlink are present before creating the GitHub Release. When Developer ID secrets
are available, the DMG is signed, notarized, stapled, and Gatekeeper-assessed after
content verification. Without those secrets, the release continues to state the
one-time quarantine removal required by macOS.

## Landing Page

The site lives in `docs/site/` as plain HTML and CSS. It uses the existing app icon
and an actual app screenshot produced during XCUITest from the live popover view at
a fixed 2× resolution. It has no JavaScript, external fonts, analytics, package
manager, or web build step.

The page contains:

- a hero with the app icon, a short native-macOS value proposition, a direct
  `Download for macOS` link to the stable latest-release DMG, and a source link;
- the real menu-bar notification panel populated with deterministic, fictional
  GitHub notifications and captioned as test data;
- concise feature cards for native SwiftUI, automatic login launch, multiple
  accounts, filtering, notifications, and automatic updates;
- a three-step install guide and the macOS 14+ requirement;
- a restrained note linking to release information for unsigned-build Gatekeeper
  instructions; and
- repository, license, and upstream-attribution links.

The layout is responsive, keyboard navigable, uses visible focus styles, maintains
readable contrast, and honors `prefers-reduced-motion`. Copy is in English to match
the application and repository documentation.

## GitHub Pages Deployment

`.github/workflows/pages.yml` uses a macOS runner to launch the app with the
landing-page UI fixture, render the live popover into an 840×1120 bitmap, and
replace the committed fallback image before it deploys `docs/site/` with the
official Pages Actions. The export rejects any other dimensions instead of scaling
a 1× capture. It runs on
relevant pushes to `main` and on manual dispatch, uses `contents: read`, `pages:
write`, and `id-token: write`, and serializes deployments with a Pages concurrency
group. The deployment environment exposes the resulting page URL.

The repository must have Pages Source set to GitHub Actions. The workflow does not
write to a branch and does not run for unrelated application-only commits.

## Documentation and Validation

The README links to the website, documents DMG installation and the stable download
path, and explains that launch at login is enabled by default but can be disabled in
Settings.

Validation covers:

- the stored/default/reset behavior of `openAtStartup`;
- Debug app compilation and the existing UI suite;
- YAML parsing and inspection of workflow permissions, triggers, and artifact path;
- local serving plus HTTP checks of the landing page and its local assets;
- the screenshot fixture, fixed 2× app rendering, XCUITest attachment export, and
  committed fallback image;
- HTML link, accessibility landmark, image-alt, and reduced-motion checks; and
- shell syntax and a local ad-hoc Release build followed by DMG creation, verification,
  mount-content inspection, and cleanup when the environment permits it.
