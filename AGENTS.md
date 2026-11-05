# MergeTether

macOS GitLab inbox and MR automation. Read [README.md](README.md) for behavior,
[docs/building.md](docs/building.md) for commands, and
[docs/automation.md](docs/automation.md) before changing assistant workflows.

## Compatibility

- Preserve the release bundle identifier, minimum macOS version, and legacy
  `GitLabTodos` target/cask names unless the task explicitly changes compatibility.
  A local installation may use a different identifier; preserve its settings on rebuild.
- Tuist owns the generated Xcode project. Use the version pinned in `mise.toml`;
  regenerate deliberately after project-graph changes. Do not commit generated projects.
- Keep dependencies in-tree and the app unsandboxed: authenticated `glab` is a subprocess.

## Expensive mistakes to avoid

- Isolate test-runner home/preferences from a running installation; otherwise the
  single-instance lock can make tests exit before running. See the build guide.
- `glab` subprocesses need an explicit environment containing `HOME` and `PATH`.
  Use the signed-in account and default host; never inherit the entire environment.
- Publishing Draft Notes executes GitLab quick actions. Automatic publishing must
  reject slash-command lines and `resolve_discussion`, and publish checked IDs
  individually. Bulk publishing can include unseen drafts created after verification.
- Author follow-ups: implement → verify → commit → authorized remote source-branch
  push → re-fetch remote HEAD and verify file content → save reply drafts. With
  follow-up push off, pending or failed, keep that run's result in chat. Require
  account/run/head/content/draft evidence for automatic publication. A detached
  worktree protects local checkouts; it does not prohibit an authorized remote push.
- Review-only work on someone else's MR must remain review-only. Keep conflict-push
  permission separate from follow-up push. Never resolve someone else's discussion
  without an explicit instruction. Preserve user-created drafts.
- Approval verdicts bind the current commit and discussion text; resolution-only
  changes preserve them, new or edited comments require re-review.
- GitLab errors retain the previous clickable inbox. Never clear it to represent failure.

## Changes and verification

- Keep `SettingsManager` persistence explicit with `save()`; avoid writes during view evaluation.
- User-facing strings belong in feature `.xcstrings` catalogs with manual extraction
  and generated symbols. Do not introduce raw localization keys.
- Test behavior and relevant failure/concurrency cases; verify build/tests before
  claiming success. Remove temporary builds after verification, retaining only a
  requested runnable installation.
- Keep commits focused, in English, without co-author trailers. Update `CHANGELOG.md`
  under Unreleased for user-facing changes. Keep personal notes, credentials,
  real customer payloads, and local agent configuration out of the public repository.
- Keep this file short. Add only durable constraints that prevent demonstrated mistakes;
  put task-specific procedures in the relevant documentation instead of a file map.
