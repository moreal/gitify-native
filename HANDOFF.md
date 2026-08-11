# HANDOFF — Feature-parity backlog

Remaining work to close the gap with upstream Gitify v7.3.2, from the full parity
audit on 2026-08-12. Work through the items below **one at a time, one commit per
item** (sub-items marked as separate commits get their own). Check items off in
this file as part of the same commit that implements them.

## Workflow (required for every item)

1. Implement the item. Keep to the project constraints below.
2. Build: `xcodegen generate && xcodebuild -project Gitify.xcodeproj -scheme Gitify -configuration Debug build`
   (the `.xcodeproj` is gitignored — regenerate freely, never commit it).
3. If the change touches the popover, status item, or notification list, also run
   the UI tests: `xcodebuild test -project Gitify.xcodeproj -scheme Gitify`.
4. Run `/simplify` and apply its cleanups **before committing**.
5. Commit with the existing style: imperative sentence-case subject
   (e.g. "Keep the popover anchored while marking notifications done"), ending with
   the trailer `Assisted-By: Claude Code:<model-id>`.
   Note: the user's commits are GPG-signed; if `git commit` fails from the sandboxed
   shell because gpg-agent can't prompt, ask the user to run the commit via `!`.

## Project constraints

- **Scope**: GitHub only (no Gitea/Bitbucket). Auth = PAT + Device Flow only.
- **Zero third-party dependencies.** macOS 14+, Swift 5, XcodeGen (`project.yml`).
- **Native look**: system semantic colors and materials (see `Sources/UI/StatePalette.swift`),
  never GitHub web (Primer) hex colors. Grouped Forms use `.scrollContentBackground(.hidden)`.
- `gitify/` is a read-only local reference checkout of upstream (gitignored). Cite it,
  never modify it. All upstream paths below are relative to `gitify/`.
- Settings keys/defaults mirror `gitify/src/renderer/stores/defaults.ts` naming where sensible.

---

## 1. Add-account entry point — ✅ high priority

- [x] Allow adding a second account after first sign-in.

Multi-account is fully modeled (per-account fetch, sections, Keychain), but
`Sources/UI/PopoverRootView.swift` shows `LoginView` only when zero accounts exist,
so there is no way to add a second account. Add an "Add account" button to the
Accounts section of `Sources/UI/SettingsView.swift` that presents `LoginView` as a
route (`PopoverRoute.login`), give `LoginView` completion/cancel closures, and
return to notifications on success.

Upstream reference: `src/renderer/routes/Accounts.tsx` (Add new account footer menu).

Acceptance: with one account signed in, Settings → Add account → PAT or Device Flow
sign-in adds the account; list shows both account sections; Cancel returns to Settings.

## 2. Error classification and per-account errors — ✅ high priority

- [x] (commit 1) Classify API errors in `Sources/Core/GitHubClient.swift` /
      `NotificationsStore`: bad credentials (401), rate limited (403/429 with
      `X-RateLimit-Remaining: 0` or `retry-after`), missing scopes, network vs offline,
      unknown. Show a distinct full-pane state per class (icon + title + guidance;
      bad credentials should offer a "Sign out" / re-auth path).
- [x] (commit 2) Per-account error isolation: a failing account renders an inline
      error block inside its own section while other accounts' notifications stay
      visible. Full-pane error only when every account fails.

Currently any error replaces the whole list with one generic pane
(`NotificationsListView.content`), hiding healthy accounts' notifications.

Upstream reference: `src/renderer/utils/core/errors.ts`, `src/renderer/utils/api/errors.ts`,
per-account blocks in `src/renderer/components/notifications/AccountNotifications.tsx`.

## 3. Commit and Release enrichment

- [x] (commit 1) Enrich `Commit` subjects: fetch `subject.url` (commit → `author.login`,
      `author.avatar_url`) and `subject.latest_comment_url` (commit comment → commenter)
      so author/author-type filters and avatars apply to commits.
- [x] (commit 2) Enrich `Release` subjects: fetch `subject.url` → release `author`.

Add to `Sources/Core/Enrichment.swift` alongside the PR/Issue/Discussion REST path;
reuse the `subjectURL|updatedAt` cache. No state derivation needed (upstream shows none).

Upstream reference: `src/renderer/utils/forges/github/enrich.ts` (REST-only branch),
`client.test.ts` commit/release cases.

## 4. Action failure feedback

- [x] Undo the optimistic removal when mark-read/done/unsubscribe fails: restore the
      thread into the list (and `seenIDs`), and surface the failure on the row's
      action button (danger tint + tooltip with the error; clicking retries).

Currently `NotificationsStore` removes the thread immediately and a failed PATCH/DELETE
is silently lost until the next poll.

Upstream reference: `src/renderer/stores/useNotificationActionFailuresStore.ts`,
`src/renderer/components/notifications/NotificationRow.tsx` (danger button + retry).

## 5. Global hotkey: disable toggle + custom recorder

- [ ] (commit 1) Settings toggle "Global shortcut" (default on) that
      registers/unregisters the ⌘⇧G hotkey (`Sources/App/GlobalHotKey.swift`).
- [ ] (commit 2) Key recorder in Settings to change the accelerator: capture via a
      local `NSEvent` monitor, require ⌘ plus a non-modifier key, persist keycode +
      modifiers, revert with an error message if `RegisterEventHotKey` fails.

Upstream reference: `src/renderer/components/settings/SystemSettings.tsx` (live recorder UX),
`src/main/handlers/system.ts` (failure → revert + banner).

## 6. Fetch behavior refinements

- [ ] (commit 1) `fetchAllNotifications` setting (default true): off = first page only;
      on = paginate all pages (drop the current hard 10-page cap).
- [ ] (commit 2) Honor GitHub's `X-Poll-Interval` response header: effective poll
      interval = `max(fetchInterval, serverInterval)`.
- [ ] (commit 3) Fetch interval: replace the 4-preset picker with a stepper
      (1 min – 60 min, step 1 min, matching upstream's bounds) and restart the running
      poll loop when the value changes (today it only applies on the next tick).

Upstream reference: `src/renderer/utils/notifications/pollInterval.ts`,
`src/renderer/components/settings/NotificationSettings.tsx`.

## 7. Notification list UI

- [ ] (commit 1) Row author avatars (from enriched author; fall back to type icon),
      click → open the author's profile. Requires enrichment to also capture `avatar_url`.
- [ ] (commit 2) Repository header: owner avatar + make the repo name a button that
      opens the repository in the browser.
- [ ] (commit 3) Collapse/expand per repository section (chevron, matching upstream's
      click-to-collapse header), and per account section when account headers show.
- [ ] (commit 4) Account header extras: avatar click → profile; hover quick-links
      "My issues" and "My pull requests" opening the host pages.
- [ ] (commit 5) Render backtick-wrapped title segments as monospace chips.
- [ ] (commit 6) `wrapNotificationTitle` setting (default false): off = 1-line
      truncated title, on = wrap fully (today titles are fixed at 2 lines).
- [ ] (commit 7) `showNumber` setting (default true) gating the `#N` in row captions.

Upstream reference: `src/renderer/components/notifications/{NotificationRow,RepositoryNotifications,AccountNotifications}.tsx`,
`src/renderer/components/notifications/NotificationTitle.tsx`.

## 8. Settings chrome

- [ ] (commit 1) "Reset settings" button (confirmation alert → restore `SettingsStore`
      defaults; leave accounts/filters intact).
- [ ] (commit 2) Settings footer showing `Gitify v<CFBundleShortVersionString>` as a
      link to that tag's GitHub release notes, plus a Quit button.

Upstream reference: `src/renderer/components/settings/{SettingsReset,SettingsFooter}.tsx`.

## 9. GitHub Enterprise Cloud data residency (`*.ghe.com`)

- [ ] Detect hostnames ending in `.ghe.com` and use `https://api.<hostname>/` as the
      API base (device flow endpoints stay on `https://<hostname>/`). Today
      `Sources/Core/Models.swift` treats them as GHES (`https://<hostname>/api/v3`),
      which is wrong for these hosts.

Upstream reference: `src/renderer/utils/auth/platform.ts`,
`src/renderer/utils/forges/github/auth.ts` (`getGitHubAuthBaseUrl`).

## 10. Tray menu + full reset

- [ ] Extend the status-item context menu (`Sources/App/StatusItemController.swift`):
      "Open Gitify" (toggle popover), Refresh, separator, "Reset Gitify…" (confirmation
      alert; deletes all accounts + Keychain tokens, settings, filters, caches, then
      returns to the login screen), separator, Quit.

Upstream reference: `src/main/menu.ts`, `src/main/lifecycle/reset.ts`.

---

## Out of scope (do NOT implement without the user asking)

Per user decision: Gitea/Forgejo/Codeberg and Bitbucket support, OAuth App web flow
(`gitify://` protocol), metric pills (comments/reactions/reviews/labels/milestone/
linked-issues/stacked-PRs/issue-type), in-app single-key shortcuts and the sidebar,
`keepWindowOnBlur`, foreground/background link opening, `delayNotificationState`,
zoom, the electron-updater-style update checker, and Glass/Primer theming (this port
deliberately uses native materials and system semantic colors).
