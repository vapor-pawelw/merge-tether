# MergeTether

macOS GitLab inbox and MR automation. Read [README.md](README.md) for behavior,
[docs/building.md](docs/building.md) for commands, and
[docs/automation.md](docs/automation.md) before changing assistant workflows.

## Compatibility

- The macOS release bundle identifier is `com.vaporpw.MergeTether`. Preserve it
  and the minimum macOS version unless the task explicitly changes them.
  A local installation may use a different identifier; preserve its settings on rebuild.
  Paired local installations also need a stable certificate-backed signing identity;
  ad hoc rebuilds invalidate Keychain’s remembered approval.
- Local builds and worktrees use the macOS user's relay saved by `scripts/setup-relay.sh`
  when generated through `mise exec`. Preserve any explicit origin-only override.
  Follow the [local relay build guide](docs/building.md#local-relay-configuration),
  verify the origin in both app bundles, and keep operator credentials out of artifacts.
- Tuist owns the generated Xcode project. Use the version pinned in `mise.toml`;
  regenerate deliberately after project-graph changes. Open `MergeTether.xcworkspace`
  and use the `MergeTether` scheme for macOS or `MergeTetheriOS` for iOS.
  Do not commit generated projects.
- Keep dependencies in-tree and the app unsandboxed: authenticated `glab` is a subprocess.

## Expensive mistakes to avoid

- Run executable MR workers with full tool access in both Codex CLI and Claude CLI.
  Diagnostic, planning and semantic-verifier tasks need live tools too. The verifier
  only reads evidence; keep GitLab action permissions independent of tool access.
- Keep one interactive MergeTether instance across installed and development copies;
  inspect running bundle paths before relaunching and use the intended installation.
  Test hosts must stay headless without production services and use isolated
  home/preferences. See the build guide.
- `glab` subprocesses need an explicit environment containing `HOME` and `PATH`.
  Use the signed-in account and default host; never inherit the entire environment.
- Publishing Draft Notes executes GitLab quick actions. Automatic publishing must
  reject slash-command lines and `resolve_discussion`, and publish checked IDs
  individually. Bulk publishing can include unseen drafts created after verification.
- Author follow-ups: implement → verify → commit → authorized remote source-branch
  push → re-fetch remote HEAD and verify file content → save reply drafts. With
  follow-up push off, pending or failed, report the result in the run summary. Require
  account/run/head/content/draft evidence for automatic publication. A detached
  worktree protects local checkouts; it does not prohibit an authorized remote push.
- Review-only work on someone else's MR must remain review-only. Keep conflict-push
  permission separate from follow-up push. Never resolve someone else's discussion
  without an explicit instruction. Preserve user-created drafts.
- Approval verdicts bind the current commit and discussion text; resolution-only
  changes preserve them, new or edited comments require re-review.
- GitLab errors retain the previous clickable inbox. Never clear it to represent failure.

## Changes and verification

- After verifying app changes, run `./scripts/rebuild-and-relaunch.sh` against the
  user's installed Mac app so they can see the changes immediately.
- Keep `SettingsManager` persistence explicit with `save()`; avoid writes during view evaluation.
- New profile-managed permissions inherit missing defaults from the active preset on upgrade; preserve Custom and explicit values, update profile matching/snapshots, and test legacy settings across restart.
- App UI strings belong in feature `.xcstrings` catalogs with manual extraction and
  generated symbols. Add English and Polish values together, including every
  required plural form and format argument. Do not introduce raw localization
  keys. Keep repository documentation, scripts, and CLI messages in English.
- Test behavior and relevant failure/concurrency cases; verify build/tests before
  claiming success. Remove temporary builds after verification, retaining only a
  requested runnable installation.
- Keep commits focused, in English, without co-author trailers. Update `CHANGELOG.md`
  under Unreleased for user-facing changes. Keep personal notes, credentials,
  real customer payloads, and local agent configuration out of the public repository.
- Keep this file short. Add only durable constraints that prevent demonstrated mistakes;
  put task-specific procedures in the relevant documentation instead of a file map.

## Test scope

- Use `python3 scripts/run-tests.py --plan` to inspect the affected checks, then run
  `python3 scripts/run-tests.py`. It includes branch, staged, unstaged and untracked
  changes; shared or unmapped changes require the full suite. See [the build guide](docs/building.md#choosing-verification-scope).
- During iteration, use repeatable `--only-testing MergeTetherTests/SuiteName` for
  the regression and affected callers. Use `--build-only` only after confirming a
  change is purely visual; view actions and state changes need behavioral tests.
  Add `--reuse-build` during iteration; finish without it to remove scratch builds.
- Run `--full` for shared infrastructure changes and integration/release checkpoints,
  rather than after every local edit. Report the selected scope and any manual overrides.
- Workflow tests use `InMemoryGitLab` at the command boundary. Keep real local
  executables in transport/CLI adapter tests; never use installed service CLIs or live GitLab.
