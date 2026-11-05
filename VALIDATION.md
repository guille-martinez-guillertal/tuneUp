# Validation status

Implemented for macOS 12+ on Intel. The development environment is Linux, not the user's Mac.

Completed here:

- All Swift files parsed using the tree-sitter Swift grammar without syntax errors.
- Build shell script passed `bash -n`.
- Workflow YAML parsed; macOS job includes unit tests before packaging and fails if artifacts are absent.
- Build script correctly rejects Linux rather than creating a fake application.

Not run here:

- Swift compiler type checking, linking, XCTest suite (no Swift/macOS SDK installed).
- GitHub Actions result: source was pushed to `main`, triggering the configured workflow if Actions is enabled. Build status/log access is blocked here: `api.github.com` returns a proxy CONNECT 403; the unauthenticated web view returns 404. No passing build or downloadable app is claimed.
- Actual macOS command probes, administrator authorization, UI launch, Gatekeeper behavior, or Monterey runtime compatibility.

The repository includes 12 XCTest cases. Their presence is not a passing test result. The GitHub macOS workflow must succeed before downloading a build, followed by the actual-Mac checklist in README.md. The ZIP accompanying this source is a source archive, not a compiled app.
