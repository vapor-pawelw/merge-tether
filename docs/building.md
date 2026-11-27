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
mise exec -- tuist generate --no-open  # generates MergeTether.xcodeproj
open MergeTether.xcworkspace
```

`MergeTether.xcodeproj` is generated — it is intentionally git-ignored. Re-run `tuist generate` whenever `Project.swift`, `Sources/**`, `Resources/**`, or `Tests/**` change in a way that affects the project graph (new files, new targets, new resources).

## Running

Build and run the `MergeTether` scheme from Xcode. MergeTether is a regular Dock application with a resizable main window. Closing the window keeps background monitoring active until the app is quit.

Manual GitLab management requires authenticated `glab`. Agent automation additionally requires a compatible, signed-in Codex CLI or Claude CLI.

## Local relay configuration

The companion requires an operator-owned relay. Its origin-only build configuration
must live outside source control; see [Bring your own relay](byo-relay.md).
Run `./scripts/setup-relay.sh` once for your macOS user before generating the project.
It accepts only an HTTPS origin without credentials, path, query or fragment (the
same rules project generation enforces) and keeps the existing configuration otherwise.
Run generation through `mise exec` to load the saved URL for both local app targets.
For a per-checkout or distribution override, create an ignored
`.mise.local.toml` in the checkout.

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

The user-level default works in local worktrees too. Worktrees do not copy ignored
files, so set any per-checkout override there or pass it explicitly when generating.
Use an empty `TUIST_MERGETETHER_RELAY_CONFIG_FILE` to generate without a relay.
Distribution builds use their explicit release configuration. Keep personal
relay files outside source control.

## Crash reporting

MergeTether can send reports to a private Sentry Cloud project. On macOS it reads the app's system crash reports after relaunch. On iOS it uses Apple's MetricKit. Create a dedicated project for macOS and another if you distribute a configured iOS build. For the public macOS workflow, set the following GitHub Actions configuration:

| Setting | Location | Purpose |
| --- | --- | --- |
| `MERGETETHER_MACOS_CRASH_DSN` | Repository variable | Public client key and ingestion address embedded in the Mac app |
| `MERGETETHER_SENTRY_ORG` | Repository variable | Sentry organization slug for symbol uploads |
| `MERGETETHER_SENTRY_MACOS_PROJECT` | Repository variable | Sentry macOS project slug for symbol uploads |
| `SENTRY_AUTH_TOKEN` | Repository secret | CI authentication to upload debug symbols |

When the DSN is configured, the release workflow uploads the matching Mac dSYM before publishing. Keep the DSN limited to event intake, set a DSN rate limit in Sentry, and enable IP scrubbing there. Leave public issue sharing disabled. The relay and GitLab credentials are separate from Sentry configuration.

For local builds, set `TUIST_MERGETETHER_MACOS_CRASH_DSN` or `TUIST_MERGETETHER_IOS_CRASH_DSN` when running `mise exec -- tuist generate --no-open` or a build script that generates the project. The values must be public Sentry Cloud DSNs. Empty values disable reporting for the respective target, including in forks by default. In a configured test build, use a Sentry project dedicated to testing and confirm an opted-in crash arrives from a Mac or physical iPhone with readable app frames. MetricKit delivery and timing are OS-dependent.

For local releases and sideload builds made with `scripts/build-release.sh` or `scripts/build-ios-ipa.sh`, set `MERGETETHER_CRASH_SYMBOLS_DIR` to a private absolute directory to retain the corresponding dSYMs outside the distributable archives. The release script stores symbols in `MergeTether-<version>-<build>-<platform>/` and refuses to replace an existing directory. Upload the dSYM corresponding to the installed build using `sentry-cli debug-files upload --wait` with the token and the matching Sentry organization and project in the CLI environment. [Sentry symbol upload guide](https://docs.sentry.io/platforms/apple/guides/macos/dsym/)

### Crash reporting privacy

Reporting is optional and starts after you choose **Send crash reports**. If you opt in, MergeTether uses crash diagnostics made available by the operating system to help the [MergeTether maintainer](https://github.com/vapor-pawelw) fix crashes. Sentry processes those reports and keeps crash events for 30 or 90 days depending on the plan. The HTTPS connection also exposes your source IP to Sentry. [Sentry retention](https://www.sentry.help/en/articles/13964336-why-does-the-event-count-in-my-issue-not-match-up-with-the-count-in-the-all-events-tab-of-the-issue) · [Sentry privacy policy](https://sentry.io/privacy/)

The report includes the crash time and type, the app and system versions, addresses and build symbols' identifiers for MergeTether's stack frames, and a random installation ID. The ID groups reports from the same installation. Raw OS reports, GitLab and relay details, agent output, and local paths are excluded from the upload.

To withdraw consent, turn off **Send crash reports** in **Settings → General** on the Mac or open the gear menu on iPhone or iPad. MergeTether cancels pending uploads and removes the local identifier. Reports already received follow Sentry's retention period. [Contact the maintainer](https://github.com/vapor-pawelw) with questions about reporting or data requests. For a separately distributed build, the operator of its configured Sentry project handles those requests.

## Command-line build

```bash
mise exec -- tuist generate --no-open
xcodebuild \
  -project MergeTether.xcodeproj \
  -scheme MergeTether \
  -configuration Debug \
  -destination "platform=macOS" \
  build
```

The built `.app` bundle lives under the Xcode DerivedData path printed at the end of the build.

## Local installation identity

A development installation may use a separate `PRODUCT_BUNDLE_IDENTIFIER` supplied to the build command. Preserve that identifier on later rebuilds so preferences and permissions stay attached to the same installation. The macOS release uses `com.vaporpw.MergeTether`. The main window replaces the old popover; the menu bar now provides an attention indicator and app actions.

For a local installation paired with iOS, also keep a consistent certificate-backed signing identity, such as Apple Development, across rebuilds. An ad hoc signature uses a changing code hash as its designated requirement, so Keychain’s Always Allow does not carry across changed builds. Switching from an ad hoc build to a certificate-signed build can require one new Keychain approval; keep the existing pairing and its Keychain access controls.

### Rebuild and relaunch macOS

The local build scripts use the `xcodebuildmcp` CLI (XcodeBuildMCP) and the repository's pinned Tuist.
`mise.toml` pins only Tuist; install `xcodebuildmcp` separately and keep it on `PATH`.

```bash
./scripts/rebuild-and-relaunch.sh
./scripts/rebuild-and-relaunch.sh --app "$HOME/Applications/MergeTether.app"
```

The script builds Debug in a temporary directory and verifies the replacement before
requesting that the interactive app quit. It waits up to 15 seconds for shutdown,
then force quits an unresponsive instance. It opens the updated installation and
restores the previous bundle if launch fails.

The default path is `~/Applications/MergeTether.app`. The script also looks for
`/Applications/MergeTether.app`. Use `--app` for other
paths or to select a particular installation. An existing installation supplies
its bundle ID and signing identity. Keep that identity available in Keychain so
the rebuild retains access to existing settings and pairing.

### Build an iOS IPA

```bash
./scripts/build-ios-ipa.sh
./scripts/build-ios-ipa.sh --build-number 35
```

With the [local relay configured](#local-relay-configuration), the script builds
Release for iPhoneOS and uses the next build number from existing local iOS IPAs
unless you supply one. It writes the IPA, SHA-256 checksum and build manifest to
`release/ios`. The script verifies the device executable and signature after
extracting the final archive. You can sign the IPA yourself before installing it.

## Installation-specific runtime data

Runtime files use `~/Library/Application Support/<actual-bundle-identifier>/` for
assistant runs/preparation, evidence, pipeline reservations, usage and worker
checkpoints. The release identity is `com.vaporpw.MergeTether`. A development
copy with another identifier gets its own new writes, matching its preferences.
The app passes `MERGETETHER_STORAGE_ROOT` explicitly to bundled helpers; a helper
run directly from an app bundle can derive the same identity from `Info.plist`.
Unbundled helper use retains the release fallback unless an explicit root is set.

On the first launch after the storage rename, the app moves the CLI evidence
stores to `Automation Evidence` under the instance lock. It keeps the remaining
desktop records in `Retired Desktop Automation`. Each store moves by an exclusive
rename. A restart can continue a partial move, and a destination collision stops
startup before automation can run against incomplete evidence. Launch the updated
app once before running its bundled proof helpers directly.

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
npm ci --prefix prototypes/remote-relay  # relay Worker test dependencies (Node.js 22+)
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
python3 scripts/run-tests.py --full  # all app, standalone and relay tests plus the iOS build
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
| Usage accounting, mapped presentation types/views | Feature suites and their mapped consumers |
| Author-feedback policy, verifier or router | Feedback, verdict, readiness, publication, merge, routing and presentation consumer suites |
| Existing top-level Swift test file only | Every suite declared in that file, plus suites using its shared top-level fixtures |
| Test tooling or helper tests only | Corresponding Python tests, without Xcode |
| Remote package tests only | Swift package tests, without the app host |
| Relay Worker (`Services/RemoteRelay`) or relay prototype/tests | Node relay tests, without Xcode |
| `CHANGELOG.md` | Changelog structure checks (bundled What's New resource and release input) |
| iOS sources, resources or shared files listed for `MergeTetheriOS` in `Project.swift` | Also builds the iOS app (`MergeTetheriOS`, simulator, unsigned) |
| Documentation only | No executable checks |
| Shared models/settings, GitLab/process transport, test support, project graph, resources or unknown paths | Full verification |

Mappings live in `scripts/test_selection.py`. They are a reviewed allowlist,
not a Swift dependency analysis: add narrow mappings only after checking callers
and their failure/concurrency coverage. A tooling test requires every suite that
names a type declared only in a mapped file to belong to that mapping's group;
record deliberate exceptions in its explicit allowlist. An unknown view is not automatically a
visual-only change, because views can dispatch remote actions. For a confirmed
layout/color/wording-only edit, explicitly use `--build-only` and inspect the UI.
For TDD or focused investigation, repeat `--only-testing` for the regression and
affected caller suites. These manual overrides are recorded in the report.

Use selected checks during local iteration. Use `--full` for shared-core changes
and integration/release checkpoints; do not repeatedly run the unchanged full
suite after every small edit. A selected run establishes only its recorded scope.
Xcode startup and compilation still cost seconds even when test bodies are fast.

Full verification includes the app suite, `Tests/TestTools`,
`Tests/AutomationHelpers`, `Packages/MergeTetherRemote`, the relay Worker tests
in `prototypes/remote-relay` and an unsigned simulator build of `MergeTetheriOS`.
Missing relay dependencies or an older Node.js fail the run with an install hint;
they are never skipped. Before any Xcode phase the runner checks that every Swift
file under `Sources/`, `Tests/`, `iOS/` and the remote package sources appears in
the generated project, and stops with a regeneration hint when it does not.
Standalone phases retain their own compressed logs and exit codes.
The Swift package and iOS build use owned scratch build directories, cleaned with
Derived Data unless `--reuse-build` was requested.
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
  --only-testing MergeTetherTests/AssistantJobCoordinatorTests
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

The app packages `evidence.py` and `author_follow_up.py` from `Helpers/Automation` under `Contents/Resources/Automation`. They provide read-only GitLab verification and local proof records. Their tests live in `Tests/AutomationHelpers`.

Remove scratch Derived Data and generated projects after validation. Preserve a
runnable app only when requested. Local debug rebuilds must retain the installed
identifier to keep that installation's preferences and permissions.

## Release builds

`Project.swift` supplies shared `MARKETING_VERSION` (`2.0.0`) and `CURRENT_PROJECT_VERSION` (`1`) defaults. Both app targets bind their Info.plist version fields to these settings. The release script passes the selected version and build number to every build/archive without rewriting source files or signed bundles. Regenerate the project deliberately when integrating this project configuration. The local `sync-version-from-tag.sh vX.Y.Z` helper updates the shared `MARKETING_VERSION` while preserving both plist bindings; it changes `CURRENT_PROJECT_VERSION` only with an explicit `--build-number N`. Distribution build numbers come from the Release workflow run number. The helper does not touch `CHANGELOG.md`, commit or tag; `release-interactive.sh` owns changelog promotion and the annotated tag.

`scripts/build-release.sh --help` lists the options. Run it through the pinned toolchain. Its default is a signed, notarized **macOS** release. The GitHub workflow uses `--platform macos --no-relay`. For private builds with your own relay, use `--platform all --ios-sideload` with `--relay-config FILE`. Distribution credentials must already be installed and valid. The script does not issue certificates or create a notary credential profile.

```bash
mise exec -- env TUIST_MERGETETHER_RELAY_CONFIG_FILE= \
  bash scripts/build-release.sh 2.0.0 --build-number 1 --platform macos --no-relay \
  --signing-identity 'Developer ID Application: Example (TEAMID)' \
  --team-id TEAMID --notary-profile existing-notary-profile
```

The signed macOS path **uploads the ZIP and DMG to Apple for notarization**. Run it only after that upload is authorized. It checks the available Developer ID identity and notary credentials before building, enables hardened runtime and a secure timestamp, verifies bundle metadata and signatures, requires an Accepted notarization result, staples and validates tickets, and checks Gatekeeper. A local Apple Development identity supports development and stable pairing; it cannot replace Developer ID distribution signing. Missing identities, rejected notarization, invalid signatures or Gatekeeper failures exit nonzero before new artifacts are copied to the release directory.

Release builds require a relay origin source: `--relay-config FILE` (or a nonempty `TUIST_MERGETETHER_RELAY_CONFIG_FILE`), or an explicit `--no-relay` for a macOS-only build without iPhone pairing. The script then checks that `MergeTetherRelayOrigin` in the Mac app and the iOS bundle equals the normalized configured origin (or is empty with `--no-relay`) without printing it. An unsigned build without either option leaves the generation environment untouched, so the saved user relay or an explicit origin-only override still applies.

With `--ios-sideload`, the script builds for arm64 iPhoneOS, packages an ad-hoc signed IPA, and verifies the executable and signature from the final ZIP. You can sign the IPA yourself before installing it. The flag also works with `--platform ios` to build the companion on its own without distribution credentials or notarization.

For a separately provisioned Apple export, omit `--ios-sideload`. That iOS path requires an existing Apple Distribution identity and installed distribution provisioning profile for `com.vaporpw.MergeTether.iOS`. Supply a real `ExportOptions.plist` with matching `teamID`, `signingStyle=manual`, a `provisioningProfiles` entry for that bundle, and an explicit method: `app-store-connect`, `release-testing`, or `enterprise`. These methods require the corresponding Apple program and provisioning eligibility; an App Store Connect IPA is for upload, and release-testing/enterprise eligibility determines who can install the export. The script checks metadata in both the archive and exported IPA, verifies their team and distribution signature, and rejects zero or multiple exported IPAs. Xcode export supplies the provisioning validation; the script never downloads or creates profiles automatically.

The selected artifact inventory is exactly two macOS archives, one iOS archive, or three for `--platform all`:

| Platform | Distribution artifacts |
| --- | --- |
| macOS | `MergeTether-<version>.dmg`, `MergeTether-<version>.zip` |
| iOS for sideloading | `MergeTetheriOS-<version>-Sideload.ipa` |
| iOS for Apple distribution | `MergeTetheriOS-<version>.ipa` |

Each artifact has a `.sha256` file. `release/release-manifest.json` records the version, build, platform inventory and SHA-256 hashes after every selected platform passes. The script uses and removes an owned `.release-build.*` scratch directory, preserving other build directories and previous artifacts. Read the command exit status and manifest version/build before using outputs; preserved artifacts from an earlier run are not evidence that a failed run succeeded.

For local inspection without distribution credentials or network notarization, opt in explicitly:

```bash
mise exec -- bash scripts/build-release.sh 1.2.0 --build-number 1 --platform all --unsigned
```

These outputs go under `release/unsigned`, with `distributable=false` in their manifest. The iOS output is `MergeTetheriOS-<version>-unsigned-device.zip`, **not an installable IPA**. Unsigned macOS outputs are also inspection artifacts. This mode cannot be combined with distribution identities or export options and is not used by the publication workflow.

### Release workflow configuration

For an explicitly approved macOS release without Apple notarization, set the repository variable `MERGETETHER_MACOS_AD_HOC_TAG` to the exact release tag. The workflow signs that build ad hoc, records the notarization status in the manifest, and still requires the Sparkle keys. For a local build of this kind, pass `--platform macos --no-relay --macos-ad-hoc` to the release helper. macOS may require **Open Anyway** in **System Settings → Privacy & Security** on first launch. [Apple's first-launch instructions](https://support.apple.com/en-us/102445)

Pushing a `v*` tag triggers the Release workflow. Configure these GitHub secrets for Developer ID signing and notarization:

- `APPLE_CERTIFICATES_P12_BASE64`: an exported PKCS#12 containing the existing Developer ID Application identity and its private key.
- `APPLE_CERTIFICATES_PASSWORD`: that PKCS#12 password.
- `NOTARY_API_PRIVATE_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`: an eligible App Store Connect notarization API key and its identifiers.

Both signing modes require Sparkle:

- `MERGETETHER_SPARKLE_PRIVATE_KEY`: the Sparkle EdDSA private key. Generate a dedicated key once with Sparkle 2.10.1's `bin/generate_keys --account mergetether-release`. Save its public key as the `MERGETETHER_SPARKLE_PUBLIC_KEY` repository variable. Use `bin/generate_keys --account mergetether-release -x` with a private temporary file to transfer the private key to this secret. Remove the temporary file after the transfer and keep a protected backup of the key.

Configure repository variables `APPLE_TEAM_ID` and `MACOS_RELEASE_IDENTITY` (the exact certificate name or SHA-1 fingerprint). The workflow fails with the missing configuration name without printing its value. It imports only into its temporary runner keychain, injects the tag version and workflow run number through build settings, verifies the two macOS archives and their hashes, and removes temporary credential files/keychain on exit. It publishes `MergeTether.dmg` and `MergeTether.zip` on GitHub with matching names in the manifest and checksums, alongside the signed `appcast.xml`. The public Mac app has an empty relay origin. Pairing uses local builds of both apps with your own relay. Before the build job touches any secret, the Release workflow runs the reusable Verify workflow (`.github/workflows/verify.yml`) on the tagged commit: it installs the pinned toolchain, Node.js from the relay package's `engines` field and the locked relay dependencies, generates the project without a relay origin, and runs `python3 scripts/run-tests.py --full`. The same workflow runs on pull requests and pushes to `main`.

The `update-cask` job of the Release workflow publishes the `mergetether` cask and registers the previous token as an upgrade alias. It runs only when the repository variable `HOMEBREW_TAP_ENABLED` is `true` and then needs the `HOMEBREW_TAP_TOKEN` secret with push access to the tap. It downloads the published DMG with HTTP failure detection and retries, and refuses to update the cask unless its SHA-256 matches the digest recorded by the build job.

### Mac in-app updates

The release build embeds the public Sparkle key and the repository's `releases/latest/download/appcast.xml` HTTPS URL. The workflow signs and verifies the feed and the final release ZIP. It attaches the feed alongside the archives in a draft release, then publishes the complete release as Latest. The feed links to the version-specific ZIP, and its internal version is the increasing Release workflow run number. Keep published feed and ZIP assets together.

The Mac app checks for updates in the background when enabled under **Settings → General**. A download and preparation happen with the app open. The restart action waits for active automation so it can finish and save its results. After relaunch, the app opens the bundled **What's New** for the installed version. A prepared update can also install on ordinary Quit.

Local builds opt into an update feed by supplying `TUIST_MERGETETHER_UPDATE_FEED` and `TUIST_MERGETETHER_UPDATE_PUBLIC_KEY` together when generating through `mise`. Use an isolated HTTPS feed and signing key for update verification. Confirm the first build can find, stage, install and relaunch into a higher build, and check the What's New content and the relay origin after relaunch. Install the first Sparkle-enabled public release through the DMG or Homebrew to receive future updates.

`scripts/release-interactive.sh` is a **publication command**: it promotes Unreleased notes, commits and pushes them, and pushes an annotated tag. Run it only when publication is explicitly requested. Before any commit, tag or push, HEAD must equal the remote branch head, `CHANGELOG.md` must have no local edits, and `.test-results` must hold a passing, clean `--full` report for HEAD; when none exists the script runs `python3 scripts/run-tests.py --full` and stops on failure. With `--yes`, a branch other than `main` or any uncommitted change is a hard failure rather than a confirmation. If the changelog push fails, the local changelog commit is removed. Noninteractive invocation requires both `--version X.Y.Z` and `--yes`. Every published release requires both macOS archives and the signed `appcast.xml`. It waits for the workflow and verifies a matching, published release record, its repository/tag URL, exactly one nonempty copy of each required asset, and a matching distributable `release-manifest.json` with the selected version, successful workflow run number, artifact inventory and SHA-256 evidence. A draft release, missing asset, missing release or pushed tag alone is incomplete and exits nonzero with a release URL and inspection command. Inspect the existing tag/run before retrying; do not restart publication by pushing the tag again. Optional Homebrew verification remains controlled by `MERGETETHER_HOMEBREW_TAP_REPO`.
