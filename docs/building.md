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

Build and run the `GitLabTodos` scheme from Xcode. The app has `LSUIElement = true` and will appear as a menu bar item only — no Dock icon, no main window.

## Command-line build

```bash
tuist generate --no-open
xcodebuild \
  -project GitLabTodos.xcodeproj \
  -scheme GitLabTodos \
  -configuration Debug \
  -destination "platform=macOS" \
  build
```

The built `.app` bundle lives under the Xcode DerivedData path printed at the end of the build.

## If macOS blocks an otherwise enabled menu bar item

On macOS Tahoe, Control Center can block a bundle identifier even while the Menu Bar settings toggle is enabled. Look for `Moving host to blocked list` in the Control Center log before treating this as an app layout bug. If the same binary works under a fresh identifier, a local Debug build can use a separate `PRODUCT_BUNDLE_IDENTIFIER` supplied to the build command. Preserve the installed local identifier on later rebuilds and migrate the app's preferences once, excluding `NSStatusItem` keys. The release bundle identifier stays stable.

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

Tests use Swift Testing. Relay/helper tests run without live GitLab writes:

```bash
cd plugins/merge-tether
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
```

Remove scratch Derived Data and generated projects after validation. Preserve a
runnable app only when requested. Local debug rebuilds must retain the installed
identifier to keep that installation's preferences and permissions.

## Release builds

A release build script lives at `scripts/build-release.sh`. It invokes `xcodebuild archive`, exports the unsigned `.app`, and packages it into a DMG and a ZIP under `release/`. Releases are tag-driven: pushing a version tag triggers the release workflow. Only tag a release when explicitly requested.
