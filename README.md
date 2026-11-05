# TuneUp for Mac

A native, local-first macOS diagnostics app for Intel Macs running Monterey 12 or later. Built for the 2016 MacBook Pro discussed in this project. No Python, Homebrew, browser server, subscription, or Xcode is needed to **run the built app**.

## Get the app

The repository includes a GitHub Actions workflow that builds the app on macOS. Once this source is pushed to GitHub:

1. Open **Actions → Build and test Mac app**. The workflow runs on pushes; you can also run it manually.
2. Open the successful run and download **TuneUp-Monterey-Intel** under Artifacts (GitHub sign-in is required).
3. Extract the artifact, then extract `TuneUp-Monterey-Intel.zip`. Move `TuneUp.app` into Applications.
4. Open it. This personal build is ad-hoc signed, **not Apple notarized**. Monterey may require Finder → right-click → Open to approve it. Do not disable Gatekeeper globally. If macOS reports damage, an invalid signature, or malware, stop and investigate rather than bypassing that warning.
5. Click **Scan my Mac**, review Findings and Evidence, then export a report from Reports.

A macOS build and a launch test on Monterey are required before calling the app validated. The Linux development host cannot run AppKit, SwiftUI or macOS diagnostic tools. CI compilation on a newer macOS is also not a substitute for testing on Monterey.

## What it does

- Hardware, battery condition/cycles, physical disk SMART, APFS and available storage.
- Three CPU samples, memory pressure, swap, thermal restrictions and power assertions.
- FileVault, firewall, SIP, Gatekeeper, enrollment, system extensions and Apple protection package receipts.
- Apple update **availability**, optional online connectivity and DNS checks. No automatic update installation.
- Application versions/minimum OS metadata, third-party startup files and recent crash summaries.
- Network interfaces, routes, DNS, proxies and VPN services.
- Backup accessibility, reported separately from other findings.
- Evidence with exit status, timeout and collection time. Failed checks stay unverified.
- Shareable Markdown reports with optional redacted evidence; private JSON baselines and before/after attention-item comparison.
- Confirmed firewall enablement with the normal macOS administrator prompt; optional startup filesystem verification.
- Buttons to open update, security, network, startup, Applications and Disk Utility controls.

## Deliberate limits

This is **not an antivirus scanner** or a guarantee of security. A startup filename isn't a malware verdict. A successful SMART check isn't a full hardware test. No Apple updates offered does not imply supported macOS. App version metadata doesn't establish browser or Office support; use vendor update mechanisms. Monterey no longer has a current security baseline and the 2016 MacBook Pro cannot officially upgrade beyond it. This app doesn't install unofficial OS patches.

No cache purges, RAM cleaners, snapshot deletion, unattended software removal, security disabling, broad permission resets or automatic reboot. It does not collect browser history, documents, passwords, or full crash memory/thread dumps. It does collect process names, startup executable paths, hardware identifiers, crash metadata and network configuration locally. Inventory covers top-level apps in `/Applications` and `~/Applications`; it isn't a forensic inventory of every executable or login mechanism. Startup enumeration does not enumerate GUI login items or certify persistence is absent.

Default scans contact Apple for update checks and example.com for HTTPS/DNS checks. Disable online checks before scanning for a local-only scan. No reports are uploaded automatically. No scan history is automatically persisted. Temporary command output is created with mode 0600 and removed after each command. Exports remain wherever you save them.

Markdown exports omit raw command output by default. Optional evidence redacts common usernames in paths, serial numbers, hardware UUIDs, MAC addresses, IP addresses and emails on a best-effort basis. **Review exports before sharing**; hostnames, file names, proxy details and unusual identifiers can remain. Private JSON baselines are intentionally unredacted and saved with mode 0600. Findings may contain selected diagnostic details even in summary exports. No AI service receives data from the app.

Stopping a scan waits for the current command's bounded timeout. It does not terminate already started repairs or roll back settings. Enabling the firewall can affect incoming app connections and is reversible in Security & Privacy. Disk verification may briefly freeze the interface; it does not request repair. Apple updates and other installers remain under your control.

## Build locally (developers only)

On a Mac with a Swift 5.7+ toolchain and macOS SDK:

```bash
swift test --arch x86_64
./scripts/build-app.sh
open dist/TuneUp.app
```

The script creates an Intel macOS 12+ app and ZIP in `dist/`. Re-running overwrites only generated app outputs. Apple Silicon builds can use Rosetta to run the Intel artifact. For public distribution, use your own Developer ID signing and notarization instead of ad-hoc signing; do not embed signing credentials in this repository.

## Validation checklist on the actual Mac

1. Run a scan; verify UI responsiveness and that unsupported/permission-denied checks are unverified.
2. Inspect hardware, firewall, OS and storage evidence against System Information/System Preferences.
3. Export summary and evidence reports; inspect redaction before sharing.
4. Save a baseline, make one deliberate change, restart, rescan and compare.
5. Verify Office and OneDrive still launch; look for new crashes after restart.
6. Test offline scan, Stop, canceled save dialogs and denied administrator authorization.
7. Run disk verification only after saving work. Review the actual output; do not infer filesystem health from a PID or exit code alone.

Tests cover analysis of failures/timeouts, firewall states, low storage, unsupported-OS update interpretation, crash signatures, redaction, baseline round trips, export privacy, offline catalog selection and real process failure/timeout capture.


## Targeted startup cleanup script

`scripts/Clean-Unused-Startup.command` addresses the nine specific Adobe, Sony,
Skype and Company Portal startup entries reviewed in the user's reports. It is
not a general cleaner or a complete vendor uninstaller.

Download `TuneUp-startup-cleanup.zip` from the repository root, extract it, then
right-click `Clean-Unused-Startup.command` → Open. It previews the exact files and
requires typing `CLEAN` before requesting administrator authorization. Run it as
your normal account, not with sudo. If macOS refuses to open a downloaded script,
review it and run it from Terminal with `bash` followed by its quoted file path;
do not disable Gatekeeper globally.

- Missing files are harmless. Related installed apps cause that vendor to be
  skipped. Company Portal is skipped unless enrollment is confirmed absent.
- Only explicitly listed startup plists are moved. Documents, application support
  files, helper binaries, other vendors and historical crash reports stay intact.
- Loaded services in the current GUI session or system domain are unloaded first.
  A service that remains loaded is left in place and reported as failed. Other
  logged-in users must sign out or restart to unload their own sessions.
- Files are archived with original ownership under the root-owned, mode-700
  `/Library/Application Support/TuneUp/StartupBackups/` directory. The script
  prints a backup ID. Nothing is permanently deleted.
- Restore from the same account using `bash /path/to/Clean-Unused-Startup.command
  --restore BACKUP_ID` (one line). Restore asks for `RESTORE`, refuses overwrites,
  and does not load services or change pre-existing service-disable flags.
- Restart and run TuneUp again afterward. The cleanup script doesn't certify the
  absence of malware or a complete removal of all vendor files.

For a noninteractive preview (no changes or admin access):

```bash
bash scripts/Clean-Unused-Startup.command --preview
```

The six fixture tests (`python3 scripts/test-startup-cleanup.py`) exercise preview,
cancellation, unload/archive/restore, idempotence, failed unloading, related-app and
enrollment guards, symlinks, unexpected labels, verified vendor label aliases and path traversal. They use a fake
Mac filesystem and simulated tools; real launchctl and authorization still need
validation on macOS.

Cleanup updates save a private `TuneUp-startup-cleanup-*` log in your home folder for apply/restore (preview stays read-only). If any item is skipped, share that log rather than repeatedly rebooting. Legitimate vendor labels that differ from filenames are accepted only for the reviewed Adobe/Company Portal executable paths and vendor-scoped labels.
