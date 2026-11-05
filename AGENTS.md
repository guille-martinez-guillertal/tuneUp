# TuneUp development

Native SwiftUI application; minimum deployment macOS 12 on Intel. Read README.md and VALIDATION.md before changing behavior.

- Use the existing checkout. Do not create a worktree unless requested.
- Build and type-check on macOS: `swift test --arch x86_64` then `./scripts/build-app.sh`.
- Linux syntax checks do not establish macOS compilation or runtime compatibility.
- Keep scan probes read-only, with fixed executable paths, fixed arguments and bounded timeouts. Never turn diagnostic output or report imports into shell code.
- Failed, timed-out, skipped and incomplete checks must not become passing findings.
- Destructive removal, OS installation, reboots and security weakening must never happen silently.
- No telemetry or automatic report uploads. Private baselines contain unredacted data; maintain that distinction from shareable reports.
- Preserve browser, Office, OneDrive, personal files and vendor updater data when implementing guided cleanup.
