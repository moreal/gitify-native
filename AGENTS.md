# Repository Agent Instructions

## macOS UI isolation

- Agents must not run macOS UI tests directly on the host because Gitify opens
  a menu-bar popover and can interrupt the developer's active session.
- Run the complete suite with `scripts/run-in-tart.sh test`.
- Regenerate the landing-page app capture with
  `scripts/run-in-tart.sh screenshot`.
- Unit tests and static checks that do not launch an application may run on the
  host.
- If Tart cannot run, report the blocking condition instead of falling back to
  host UI automation.
