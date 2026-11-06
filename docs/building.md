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

Manual GitLab management requires authenticated `glab`. Assistant automation additionally requires a compatible, signed-in Codex CLI or Claude CLI. Desktop assistant applications and their listener/plugin setup are not prerequisites.

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

`scripts/rebuild-and-relaunch.sh` regenerates, builds and launches a Debug app from its build directory. It stops processes matching the legacy executable name and uses the project’s default bundle identifier; it is not an installer for an existing custom-identifier app. Use an explicit build and copy step when preserving such an installation.

## Running tests

Keep the test runner's home separate from a running installation. MergeTether has a
single-instance lock; sharing its home can make the test host exit before tests run.

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

Tests use Swift Testing. The standalone proof helpers have separate tests that run without live GitLab writes:

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
