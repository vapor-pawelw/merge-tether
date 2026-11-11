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

## Local relay configuration

The companion requires an operator-owned relay. Its origin-only build configuration
must live outside source control; see [Bring your own relay](byo-relay.md).
To keep local agents and repeated builds using that configuration, create an ignored
`.mise.local.toml` in the checkout:

```toml
[env]
TUIST_MERGETETHER_RELAY_CONFIG_FILE = "/absolute/private/relay-build.json"
```

The configured external file contains only `{"origin":"https://your-relay.example.org"}`.
Keep the operator invitation in its separate private runtime file and pairing/Keychain,
never in this build config. All documented `mise exec -- ...` / `mise x -- ...`
commands load the ignored local environment, including Tuist generation and the
rebuild/release helpers. Regenerate before building so both app Info.plist files
contain the intended origin. Verify those values in the finished Mac app and IPA.
A bare Tuist call outside mise does not guarantee this local environment is loaded.

Worktrees do not copy ignored files. Before building in one, create its own ignored
`.mise.local.toml` pointing to the same external JSON, or explicitly set
`TUIST_MERGETETHER_RELAY_CONFIG_FILE` for `mise exec -- tuist generate --no-open`.
Do not copy a personal origin or token into tracked files. A public checkout without
an operator's local configuration has no shared relay; companion access stays disabled.

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

## Installation-specific runtime data

Runtime files use `~/Library/Application Support/<actual-bundle-identifier>/` for
assistant runs/preparation, evidence, pipeline reservations, usage and worker
checkpoints. The release identity remains `com.vaporpw.GitLabTodos`. A development
copy with another identifier gets its own new writes, matching its preferences.
The app passes `MERGETETHER_STORAGE_ROOT` explicitly to bundled helpers; a helper
run directly from an app bundle can derive the same identity from `Info.plist`.
Unbundled helper use retains the release fallback unless an explicit root is set.

Existing run directories remain in place, referenced only by the installation's
known history; migration does not copy large clones or silently trust shared old
proof. Older shared usage is available separately as read-only legacy history,
with its attribution limits stated. Legacy pipeline locks/receipts are honored as
negative deduplication checks and are not deleted or promoted into new authority.
Known historical checkpoints still require the unchanged per-bundle HMAC key.

The interactive-instance lock deliberately remains shared across installed and
development copies. Signing identity, Keychain pairing records and the external
operator relay configuration are preserved independently of this runtime root.

## Running tests

Keep the test runner's home/preferences separate from a running installation so
test fixtures cannot use that installation's saved state. Injected XCTest hosts
use an invisible application without production windows, monitoring, notifications
or remote access. Ordinary installed and development launches share the same
single-instance lock regardless of bundle identifier.

```bash
mise exec -- tuist generate --no-open
python3 scripts/run-tests.py
```

The repository runner selects checks for the changed files by default. When app
tests are selected, it uses `xcodebuild build-for-testing` followed by
`test-without-building`, with a fresh isolated test home on every invocation.
It never launches or replaces the installed app. It requires Python 3 and Xcode
26+, and uses `xcresulttool` to retain results and diagnostic timing events.
Use this command for performance investigations: the installed XcodeBuildMCP test
wrapper currently exports only a summary and deletes its temporary result bundle.
Passing an additional result-bundle argument to that wrapper does not fix this.

### Choosing verification scope

```bash
python3 scripts/run-tests.py --plan  # inspect paths, reasons, suites and extra tasks
python3 scripts/run-tests.py         # run those checks
python3 scripts/run-tests.py --full  # all app and standalone repository tests
```

Default selection uses the merge base with local `main`, including committed
branch work, staged/unstaged changes and untracked files. On dirty `main`, local
edits define the current change; on clean `main`, it checks the latest commit
so a clean checkout does not silently verify nothing.
Use `--base REF` to choose another comparison. Renames include both paths;
deletions, missing mapped suites, unavailable Git history and unmapped changes
fall back to full verification. The runner prints its decision and retains it in
`report.json`; `--plan` prints JSON without creating results or starting tools.

| Change | Checks |
| --- | --- |
| Search, usage accounting, mapped presentation types/views | Feature suites and their mapped consumers |
| Author-feedback policy, verifier or router | Feedback, publication, merge, routing and presentation consumer suites |
| Existing top-level Swift test only | Changed suite |
| Test tooling or helper tests only | Corresponding Python tests, without Xcode |
| Remote package tests only | Swift package tests, without the app host |
| Documentation only | No executable checks |
| Shared models/settings, GitLab/process transport, test support, project graph, resources or unknown paths | Full verification |

Mappings live in `scripts/test_selection.py`. They are a reviewed allowlist,
not a Swift dependency analysis: add narrow mappings only after checking callers
and their failure/concurrency coverage. An unknown view is not automatically a
visual-only change, because views can dispatch remote actions. For a confirmed
layout/color/wording-only edit, explicitly use `--build-only` and inspect the UI.
For TDD or focused investigation, repeat `--only-testing` for the regression and
affected caller suites. These manual overrides are recorded in the report.

Use selected checks during local iteration. Use `--full` for shared-core changes
and integration/release checkpoints; do not repeatedly run the unchanged full
suite after every small edit. A selected run establishes only its recorded scope.
Xcode startup and compilation still cost seconds even when test bodies are fast.

Full verification includes the app suite, `Tests/TestTools`,
`Tests/AutomationHelpers` and `Packages/MergeTetherRemote`.
Standalone phases retain their own compressed logs and exit codes.
The Swift package uses an owned scratch build directory, cleaned with Derived
Data unless `--reuse-build` was requested.
Pairing-store tests inject an in-memory Security client and exercise the real
encoding, replacement/removal rules, Keychain query policy and failure handling.
They do not access the login Keychain or require interactive authorization.

Each timestamped app-test run under the ignored `.test-results/` directory contains:

- `timings.csv`: one row per execution, including parameterized cases and
  repetitions, with its test ID, suite, execution number, Xcode argument identity,
  outcome and numeric seconds. Parent totals are excluded to avoid double counting.
  Xcode 26.3's result APIs round case durations to whole seconds and omit many
  fast-case durations. The runner instead pairs start/finish events in exported
  diagnostic session logs, at millisecond resolution. These measure Xcode event
  receipt intervals, including event-delivery overhead; they are not CPU time.
  Argument identities may contain Xcode's abbreviated byte descriptions; occurrence
  numbers keep repeated cases distinct. `case_key` hashes the test ID, argument
  identity and occurrence within that identity for comparisons across runs.
  `repeated_identity_groups` records repeated opaque identities; use method totals
  for cross-run comparisons if different argument values have colliding byte descriptions.
  Overlapping identical identities are flagged as ambiguous rather than silently
  accepted. Missing durations, ambiguity, missing execution counts or a row-count mismatch
  against Xcode's per-device execution counts make reporting fail explicitly.
- `summary.txt`: total counts, phase durations, slowest cases and suites.
- `report.json`: commit/dirty state, tracked-diff and untracked-file hashes,
  runner hash, Xcode version, exact commands, exit codes,
  build/test wall times and summed case time. The Swift Testing execution span
  from the console and the remaining test-command overhead are separate fields.
  Summed case times may overlap and
  are **not** elapsed time. The raw result summary's elapsed interval is retained
  separately when available. `derived_data_preexisting` and `reuse_build_requested`
  distinguish incremental and clean builds. The generated project hash and pinned
  Tuist requirement are recorded; untracked nested repositories are listed separately.
- `summary.json`, `tests.json`, compressed build/test and diagnostic session logs,
  and `Tests.xcresult`.
  Test failures preserve their original nonzero exit code and still export
  available timings and diagnostics. Build failures retain their log and metadata.

Standalone-only and build-only runs retain `report.json` and their phase logs;
they do not produce an app test result bundle or per-case app timings.

By default the latest ten report directories and two result bundles are retained;
older owned runs are pruned, including failed runs. Copy important evidence outside
this directory before it ages out. `--keep-reports` and `--keep-bundles` adjust
retention (`--keep-bundles 0` retains only compact evidence). Logs are compressed;
raw bundles can be opened in Xcode while retained. The runner serializes access to
its results directory and removes its test home and scratch Derived Data on normal
exit and handled interruption. Ctrl-C, SIGTERM and SIGHUP stop the active command
and retain an interrupted, nonzero report. Cleanup ignores additional interrupts
until the process group has been stopped and evidence saved. Build/test deadlines default to 600/1200
seconds (`--build-timeout` / `--test-timeout`); expiry returns 124. SIGKILL cannot be
handled and may leave partial artifacts; inspect any surviving owned test processes
before removing those artifacts or starting another run against the same directory.

For a baseline and comparison, reuse the same owned Derived Data directory and
keep identical filters and runner settings. Separate clean-build time from the
test-command wall time; rebuilding unchanged code is usually much cheaper.

```bash
python3 scripts/run-tests.py --full --reuse-build
# Make the scoped change, then run affected suites (the flag is repeatable):
python3 scripts/run-tests.py --reuse-build \
  --only-testing GitLabTodosTests/AssistantJobCoordinatorTests
# Comparable full run, then automatically remove the reused scratch build:
python3 scripts/run-tests.py --full
```

`--results-dir PATH` selects a directory owned by this runner, including its
`DerivedData` child. A new location must be empty; the runner records an ownership
marker and refuses nonempty, unmarked directories. The default always belongs to
the repository, even when the command is invoked elsewhere. Project
generation remains explicit. Run `python3 scripts/run-tests.py --help` for options.
The report/retention tests run without Xcode or GitLab:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/TestTools
```

Workflow tests inject `InMemoryGitLab` through `GlabService`'s command runner.
The real command construction, JSON decoding, workflow logic and authorization
checks still execute; API state and rendezvous barriers are in memory. Evidence
store and restart tests keep isolated persistence where that is the behavior
under test. Production uses the existing `ProcessRunner` by default. This small
transport seam avoids a broad service-protocol rewrite and lets adapter tests
continue testing the real subprocess boundary independently.

Adapter tests inject temporary `glab` scripts returning synthetic local data, or
leave the executable unset. Paths to installed CLIs in settings tests are only
persistence fixtures. Assistant CLI tests likewise inject local scripts/probes.
Real shell/Python processes remain in adapter tests to cover pipe capture, exit
codes, timeouts, cancellation and descendant cleanup. No live GitLab account or
installed `glab` is required. Debug test hosts reject direct launches of `glab`,
`codex` and `claude` outside the temporary fixture directory, including symlinked
paths. The runner also marks its isolated HOME explicitly to permit classifier
fixtures installed there. Discovery does not probe installed `glab` or a login
shell in a test host, and assistant discovery considers only its isolated HOME
fixture rather than desktop bundles or global binaries. Guard rejections make the runner fail even if application
code catches the launch error. Ordinary application launches retain their existing behavior.

Tests use Swift Testing. Evaluate mutating struct methods into local values before passing their results to
`#expect` or `#require`. The macros can otherwise capture an immutable argument and
fail to compile. Construct throwing fixtures before value assertions; use
`#expect(throws:)` for the throwing operation being tested.

The standalone proof helpers have separate tests that run without live GitLab writes:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Helpers/Automation \
  python3 -m unittest discover -s Tests/AutomationHelpers
```

The app packages `Helpers/Automation` as `Contents/Resources/Automation`, containing `evidence.py` and `author_follow_up.py`. They provide read-only GitLab verification and local proof records independently of desktop plugins or MCP setup. Their coverage lives in `Tests/AutomationHelpers`; the retired desktop plugin package and its queue tests have been removed.

Remove scratch Derived Data and generated projects after validation. Preserve a
runnable app only when requested. Local debug rebuilds must retain the installed
identifier to keep that installation's preferences and permissions.

## Release builds

`Project.swift` supplies shared `MARKETING_VERSION` (`1.2.0`) and `CURRENT_PROJECT_VERSION` (`1`) defaults. Both app targets bind their Info.plist version fields to these settings. The release script passes the selected version and build number to every build/archive without rewriting source files or signed bundles. Regenerate the project deliberately when integrating this project configuration. The local `sync-version-from-tag.sh` helper updates these shared defaults while preserving both plist bindings; it does not commit or tag.

`scripts/build-release.sh --help` lists the options. Run it through the pinned toolchain. Its default is a signed, notarized **macOS** release; `--platform all` additionally exports a separate iOS distribution IPA. Distribution credentials must already be installed and valid. The script does not issue certificates or create a notary credential profile.

```bash
mise exec -- bash scripts/build-release.sh 1.2.0 --build-number 1 --platform all \
  --signing-identity 'Developer ID Application: Example (TEAMID)' \
  --ios-signing-identity 'Apple Distribution: Example (TEAMID)' \
  --team-id TEAMID --notary-profile existing-notary-profile \
  --ios-export-options /absolute/path/ExportOptions.plist \
  --relay-config /absolute/private/relay-build.json
```

The signed macOS path **uploads the ZIP and DMG to Apple for notarization**. Run it only after that upload is authorized. It checks the available Developer ID identity and notary credentials before building, enables hardened runtime and a secure timestamp, verifies bundle metadata and signatures, requires an Accepted notarization result, staples and validates tickets, and checks Gatekeeper. A local Apple Development identity supports development and stable pairing; it cannot replace Developer ID distribution signing. Missing identities, rejected notarization, invalid signatures or Gatekeeper failures exit nonzero before new artifacts are copied to the release directory.

The iOS path requires an existing Apple Distribution identity and installed distribution provisioning profile for `com.vaporpw.MergeTether.iOS`. Supply a real `ExportOptions.plist` with matching `teamID`, `signingStyle=manual`, a `provisioningProfiles` entry for that bundle, and an explicit method: `app-store-connect`, `release-testing`, or `enterprise`. These methods require the corresponding Apple program and provisioning eligibility; an App Store Connect IPA is for upload, and release-testing/enterprise eligibility determines who can install the export. The script checks metadata in both the archive and exported IPA, verifies their team and distribution signature, and rejects zero or multiple exported IPAs. Xcode export supplies the provisioning validation; the script never downloads or creates profiles automatically.

The selected artifact inventory is exactly two macOS archives, one iOS archive, or three for `--platform all`:

| Platform | Distribution artifacts |
| --- | --- |
| macOS | `GitLabTodos-<version>.dmg`, `GitLabTodos-<version>.zip` |
| iOS | `MergeTetheriOS-<version>.ipa` |

Each artifact has a `.sha256` file. `release/release-manifest.json` records the version, build, platform inventory and SHA-256 hashes after every selected platform passes. Legacy macOS artifact names and bundle identifiers remain unchanged. The script uses and removes an owned `.release-build.*` scratch directory, preserving other build directories and previous artifacts. Read the command exit status and manifest version/build before using outputs; preserved artifacts from an earlier run are not evidence that a failed run succeeded.

For local inspection without distribution credentials or network notarization, opt in explicitly:

```bash
mise exec -- bash scripts/build-release.sh 1.2.0 --build-number 1 --platform all --unsigned
```

These outputs go under `release/unsigned`, with `distributable=false` in their manifest. The iOS output is `MergeTetheriOS-<version>-unsigned-device.zip`, **not an installable IPA**. Unsigned macOS outputs are also inspection artifacts. This mode cannot be combined with distribution identities or export options and is not used by the publication workflow.

### Release workflow configuration

Releases are tag-driven: pushing a `v*` tag triggers the Release workflow. Configure these GitHub secrets before an authorized publication:

- `APPLE_CERTIFICATES_P12_BASE64`: an exported PKCS#12 containing the existing Developer ID Application and Apple Distribution identities and their private keys.
- `APPLE_CERTIFICATES_PASSWORD`: that PKCS#12 password.
- `IOS_PROFILE_BASE64`: the existing distribution `.mobileprovision` for the iOS bundle.
- `NOTARY_API_PRIVATE_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`: an eligible App Store Connect notarization API key and its identifiers.

Configure repository variables `APPLE_TEAM_ID`, `MACOS_RELEASE_IDENTITY`, `IOS_RELEASE_IDENTITY` (exact certificate names or SHA-1 fingerprints), and `IOS_EXPORT_METHOD` (one of the supported distribution methods). The workflow fails with the missing configuration name without printing its value. It imports only into its temporary runner keychain, derives export options from the configured profile, injects the tag version and workflow run number through build settings, verifies the three-artifact inventory and hashes, and removes temporary credential files/keychain on exit. It retains `GitLabTodos.dmg`/`.zip` names on GitHub for the existing Homebrew cask; the published manifest and checksums use those same names. The iOS IPA remains a separate versioned asset. Relay deployment is separate from both app artifacts.

`scripts/release-interactive.sh` is a **publication command**: it promotes Unreleased notes, commits and pushes them, and pushes an annotated tag. Run it only when publication is explicitly requested. Noninteractive invocation requires both `--version X.Y.Z` and `--yes`; `--platform all` is the default release inventory, while `--platform macos` supports an explicitly macOS-only release. It waits for the workflow and verifies a matching, published release record, its repository/tag URL, exactly one nonempty required asset per platform, and a matching distributable `release-manifest.json` with the selected version, successful workflow run number, artifact inventory and SHA-256 evidence. A draft release, missing IPA, missing release or pushed tag alone is incomplete and exits nonzero with a release URL and inspection command. Inspect the existing tag/run before retrying; do not restart publication by pushing the tag again. Optional Homebrew verification remains controlled by `GITLABTODOS_HOMEBREW_TAP_REPO`.
