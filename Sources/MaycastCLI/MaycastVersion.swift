// Single source of truth for the release version.
//
// Bump `current` here, commit it, then tag the release (e.g. `git tag v0.1.0`).
// `make release` reads this constant to:
//   - stamp `CFBundleShortVersionString` / `CFBundleVersion` on the .app
//   - name the release artefacts (`Maycast-Studio-<v>.dmg`, etc.)
//   - drive the CLI's `--version` output
//
// One-off overrides for RC / nightly builds:
//   make release VERSION=0.1.0-rc1
enum MaycastVersion {
    static let current = "0.3.1"
}
