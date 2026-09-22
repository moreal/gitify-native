# Sparkle Updater Design

## Goal

Replace Gitify's custom GitHub Releases update checker and in-place installer
with Sparkle 2's standard updater while keeping GitHub Releases as the source of
truth for releases and downloads.

Success means:

- Gitify checks for updates automatically and exposes a manual **Check for
  Updates** action from both the status menu and Settings.
- When an update is found, Sparkle presents its standard update UI and performs
  the download, verification, installation, and relaunch.
- The existing Developer ID signing, notarization, DMG, ZIP, and checksum
  artifacts remain part of every release.
- Each GitHub Release also contains a Sparkle `appcast.xml` whose update archive
  is signed with a dedicated EdDSA key.
- No standalone update server or GitHub Pages feed is introduced.

## User Experience

Gitify enables automatic update checks without presenting Sparkle's opt-in
question. Automatic checks may present Sparkle's standard update window when a
new release is available. Installation remains a user-confirmed action;
background installation is not enabled by default.

The existing **Check for updates** entries remain in the tray context menu and
the Settings footer. They invoke Sparkle's foreground check, which presents the
standard Sparkle result UI for an available update, an up-to-date result, or an
error. Gitify no longer maintains a parallel update state machine or sends its
own update-available system notification.

The version link in Settings continues to open the corresponding GitHub
Release page.

## Runtime Architecture

Sparkle is added as a Swift Package Manager dependency through `project.yml`.
The application owns one `SPUStandardUpdaterController` for its lifetime. The
controller starts Sparkle and provides the updater used by both manual-update
entry points.

Static Sparkle configuration lives in the generated application Info.plist:

- `SUFeedURL` is
  `https://github.com/moreal/gitify-native/releases/latest/download/appcast.xml`.
- `SUPublicEDKey` contains the repository's non-secret Ed25519 public key.
- `SUEnableAutomaticChecks` is `YES`.
- `SUAutomaticallyUpdate` is `NO`.

The custom `UpdateChecker`, GitHub API request, SHA-256 verification, bundle
replacement, signature inspection, relaunch shell process, update-specific
notification callback, and custom update phase UI are removed. Sparkle is
responsible for update scheduling, download verification, installation,
relaunch, authorization, app translocation handling, and user-facing errors.

UI tests continue to receive the shared updater dependency, but update checks
must not start while the deterministic UI-test mode is active. This prevents
network access and update windows from disturbing app capture and UI tests.

## GitHub Release Feed

GitHub Releases remains the release catalog and artifact host. Every release
publishes:

- `Gitify.dmg`
- `Gitify.dmg.sha256`
- `Gitify-<version>.zip`
- `Gitify-<version>.zip.sha256`
- `appcast.xml`

The application's feed URL uses GitHub's stable
`releases/latest/download/appcast.xml` redirect. The appcast enclosure uses the
versioned GitHub Release download URL for `Gitify-<version>.zip`. Consequently,
the latest non-prerelease GitHub Release determines what Sparkle offers, while
the versioned enclosure URL remains immutable.

The first Sparkle-enabled release remains installable by existing versions:
their custom updater downloads the same versioned ZIP from GitHub Releases.
After that migration release is installed, subsequent checks use Sparkle.

## Release Pipeline

The release workflow continues to build a universal app, apply Developer ID
signing when the existing signing secrets are present, notarize and staple the
app and DMG, and package the versioned ZIP.

After packaging, the workflow runs Sparkle's `generate_appcast` tooling against
the ZIP and supplies the final GitHub Release download URL prefix. The generated
appcast is uploaded with the other release assets. Delta updates are not
generated or retained initially because the workflow only has the current
release archive; full ZIP updates keep the migration small and deterministic.

Sparkle archive signing uses a new GitHub Actions secret containing the Ed25519
private key. The workflow passes it through standard input to Sparkle tooling so
the key is never written to the repository or printed in logs. The matching
public key is committed in `project.yml` as `SUPublicEDKey`.

Releases must fail before publication when the Sparkle private key is absent or
appcast generation fails. Unlike Developer ID's existing optional fallback,
there is no unsigned Sparkle feed fallback because shipped clients require a
valid EdDSA signature.

## Security Model

Developer ID and Sparkle EdDSA signatures remain separate trust layers:

- Developer ID signing and notarization authenticate the application bundle to
  macOS and Gatekeeper.
- The Sparkle public key embedded in Gitify authenticates the update archive
  referenced by the appcast.

The existing public SHA-256 assets remain available for manual verification,
but they are not part of Sparkle's trust decision. HTTPS is used for the feed
and all enclosure URLs.

The private Sparkle key must be backed up outside GitHub. Losing it prevents
publishing updates accepted by installed Sparkle-enabled versions unless a
signed key-rotation release can first be shipped.

## Error Handling

Manual checks use Sparkle's standard UI for connectivity, invalid-feed,
signature, installation, and up-to-date outcomes. Automatic-check failures stay
non-disruptive according to Sparkle's normal behavior. Gitify does not duplicate
or translate Sparkle errors into its own update state.

If GitHub's `latest` redirect or release asset is temporarily unavailable,
Sparkle leaves the installed application unchanged and retries on its normal
schedule or on the next manual check.

## Testing and Validation

Host-safe tests and checks cover:

- `project.yml` declares the pinned Sparkle package and required Info.plist
  keys.
- Both manual UI entry points call the shared Sparkle updater.
- Deterministic UI-test mode does not start automatic Sparkle checks.
- The release workflow creates and uploads `appcast.xml`, uses a private key
  supplied through standard input, and preserves all existing artifacts.
- The appcast feed URL and enclosure download URL follow the agreed GitHub
  Releases contract.

Static checks and compilation may run on the host. In accordance with
`AGENTS.md`, the complete suite runs only through `scripts/run-in-tart.sh test`;
there is no fallback to host UI automation if Tart is unavailable.

## Documentation

The README describes Sparkle-backed updates, the GitHub-hosted appcast, the
required Sparkle key secret, and the one-time public/private key setup. The old
description of the custom installer and its ad-hoc fallback is removed.
