# Building MergeTether from source

## Requirements

- macOS 14+
- Xcode 26+ (Swift 6 and generated string-catalog symbols)
- [mise](https://mise.jdx.dev) — `brew install mise`
- [glab](https://gitlab.com/gitlab-org/cli) — `brew install glab`, then run `glab auth login`

## First-time setup

From the repo root:

```bash
mise install           # installs the pinned Tuist version from mise.toml
mise exec -- tuist generate --no-open  # generates GitLabTodos.xcodeproj
open GitLabTodos.xcworkspace
```

`GitLabTodos.xcodeproj` is generated — it is intentionally git-ignored. Re-run `tuist generate` whenever `Project.swift`, `Sources/**`, `Resources/**`, or `Tests/**` change in a way that affects the project graph (new files, new targets, new resources).

## Running

Build and run the `GitLabTodos` scheme from Xcode. MergeTether is a regular Dock application with a resizable main window. Closing the window keeps background monitoring active until the app is quit. The release bundle identifier and legacy target/scheme names remain unchanged.

Manual GitLab management requires authenticated `glab`. Agent automation additionally requires a compatible, signed-in Codex CLI or Claude CLI. Desktop agent applications and their listener/plugin setup are not prerequisites.

## Command-line build

```bash
mise exec -- tuist generate --no-open
xcodebuild \
  -project GitLabTodos.xcodeproj \
  -scheme GitLabTodos \
  -configuration Debug \
  -destination "platform=macOS" \
  build
```

The built `.app` bundle lives under the Xcode DerivedData path printed at the end of the build.

## Local installation identity

A development installation may use a separate `PRODUCT_BUNDLE_IDENTIFIER` supplied to the build command. Preserve that identifier on later rebuilds so preferences and permissions stay attached to the same installation. Keep the release identifier unchanged. The main window replaces the old popover; the menu bar now provides an attention indicator and app actions.

For a local installation paired with iOS, also keep a consistent certificate-backed signing identity, such as Apple Development, across rebuilds. An ad hoc signature uses a changing code hash as its designated requirement, so Keychain’s Always Allow does not carry across changed builds. Switching from an ad hoc build to a certificate-signed build can require one new Keychain approval; keep the existing pairing and its Keychain access controls.

`scripts/rebuild-and-relaunch.sh` regenerates, builds and launches a Debug app from its build directory. It refuses while a MergeTether app or app-hosted test is running and prints the running executable paths; finish active work/tests and quit the intended app before retrying. It never kills another process or forces an additional instance. Use `--help` for its options. The helper uses the project's default bundle identifier and is not an installer for a custom-identifier app. Use an explicit build and copy step when preserving an existing installation, including its bundle identifier, certificate-backed signing identity and installation path. Launch that installed path once rather than also opening a scratch build.

## Running tests

Keep the test runner's home/preferences separate from a running installation so
test fixtures cannot use that installation's saved state. Injected XCTest hosts
use an invisible application without production windows, monitoring, notifications
or remote access. Ordinary installed and development launches share the same
single-instance lock regardless of bundle identifier.

```bash
test_home="$(mktemp -d)"
TEST_RUNNER_HOME="$test_home" TEST_RUNNER_CFFIXED_USER_HOME="$test_home" \
xcodebuild \
  -project GitLabTodos.xcodeproj \
  -scheme GitLabTodos \
  -destination "platform=macOS" \
  test
rm -rf "$test_home"
```

Tests use Swift Testing. Evaluate mutating struct methods into local values before passing their results to
`#expect` or `#require`. The macros can otherwise capture an immutable argument and
fail to compile. Construct throwing fixtures before value assertions; use
`#expect(throws:)` for the throwing operation being tested.

The standalone proof helpers have separate tests that run without live GitLab writes:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Helpers/Automation \
  python3 -m unittest discover -s Tests/AutomationHelpers
```

The app packages `Helpers/Automation` as `Contents/Resources/Automation`, containing `evidence.py` and `author_follow_up.py`. They provide read-only GitLab verification and local proof records independently of desktop plugins or MCP setup. Historical plugin sources and tests remain under `plugins/merge-tether` for compatibility, but that package is no longer bundled or required for app setup.

Remove scratch Derived Data and generated projects after validation. Preserve a
runnable app only when requested. Local debug rebuilds must retain the installed
identifier to keep that installation's preferences and permissions.

## Release builds

A release build script lives at `scripts/build-release.sh`. Run it through the pinned toolchain with `mise exec -- bash scripts/build-release.sh [version]`. It generates the project, runs an unsigned Release `clean build`, and packages the `.app` into a DMG and ZIP with SHA-256 files under `release/`. Without a version argument it reads `CFBundleShortVersionString` from `Project.swift`. It replaces and then removes the repository’s scratch `build/` directory.

Releases are tag-driven: pushing a `v*` tag triggers the Release workflow. `scripts/release-interactive.sh` promotes Unreleased notes and pushes their commit and an annotated tag; it is a publication command, not a local build helper. Only publish or tag a release when explicitly requested. Legacy `GitLabTodos` artifact names remain in use.
