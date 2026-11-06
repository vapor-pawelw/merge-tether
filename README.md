<div align="center">

<img src="docs/images/mergetether-icon.png" alt="MergeTether — hand-painted connected branches" width="128"/>

# MergeTether

**A native macOS command center for your GitLab merge requests.**

Triage reviews, see what blocks a merge, and run routine follow-ups through Codex or Claude CLI — with progress, results and decisions in one window.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#get-started)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

</div>

## A desk for your merge requests

MergeTether opens a resizable main window and appears in the Dock. Its board keeps your work in three columns:

- **My merge requests:** your open MRs, with blockers, drafts, to-dos and follow-up actions directly on each card.
- **Reviewing:** MRs you review, with review, publication and approval actions beside the relevant MR.
- **Other items:** unmatched GitLab to-dos and work outside the current MR set. Add an MR to bring its work onto the board.

Recognized GitLab to-dos update an MR’s durable action and are then marked read. Unknown events stay in Other; new foreign MRs can be added and handled or ignored, and matching enabled automation adopts them automatically. Agent completion remains a separate state.

Cards requiring attention rise to the top of their column; draft MRs stay at the bottom of Reviewing. Open a card for its full details and execution history. **Activity** shows workflow events and assistant results. **Settings → Automation → Scope** controls automation globally, by repository or by MR without losing history.

The menu-bar icon stays neutral while work is handled automatically and turns amber when something needs your attention. Optional macOS notifications bring those decisions to you without announcing every automatically handled update. Enable notification permission inside the app; if macOS has denied it, the app links to System Settings.

Polling, notifications and launch at login are configurable. Monitoring continues while the app is running, including when its window is closed. A failed GitLab request keeps the previous inbox usable.

## Get started

You need **macOS 14+** and an authenticated [`glab`](https://gitlab.com/gitlab-org/cli) installation. Self-hosted GitLab uses your CLI's default host.

```sh
brew install glab
glab auth login
```

Build the current development version using [the build guide](docs/building.md), then launch MergeTether. Onboarding checks GitLab access and offers optional automation. All assistant automation requires a compatible, signed-in **Codex CLI or Claude CLI**. Their desktop applications are optional. You can keep manual inbox/MR management and change your choice later.

**Release status:** this README describes the current development tree. Check [Releases](https://github.com/vapor-pawelw/merge-tether/releases) for the features in a published binary. The earlier inbox-only GitLab Todos release is [v1.1.0](https://github.com/vapor-pawelw/merge-tether/releases/tag/v1.1.0), with source on [`legacy/gitlab-todos`](https://github.com/vapor-pawelw/merge-tether/tree/legacy/gitlab-todos). Its Homebrew cask remains `vapor-pawelw/tap/gitlab-todos` for compatibility; installing that cask does not build unreleased features.

## Optional assistant workflows

Choose your assistant, scope and rules in **Settings → Automation**. Installed MR skills refine the work; MergeTether also supplies default instructions when no MR skill is installed.

| Workflow | Behavior |
| --- | --- |
| Review and re-review | Recheck new commits or author replies, verify earlier findings, resolve only your own addressed threads when enabled, and draft replies for anything still wrong. |
| Follow up on your MR | Implement justified fixes, test, commit, push when enabled, verify the remote HEAD and file content, then save response drafts. |
| Accepted feedback on your MR | Verify all reviewer expectations, then close addressed threads after that reviewer approves or explicitly confirms acceptance. Advance approval never overrides remaining conditions. Enabled by default; configurable in Checkpoints. |
| Failed pipeline | Check whether another task already owns the fix; otherwise prepare a scoped diagnosis/fix. |
| Conflict resolution | Prepare an isolated resolution; pushing it has a separate permission from ordinary follow-ups. |
| Re-review requests | Request another review after feedback is addressed and no unpublished replies remain. |
| Approval | Approve a reviewed commit only after a no-objections verdict, no pending drafts and resolved discussions. |
| Merge | Optional; checks ownership, approvals, threads, pipeline and the source commit. Off by default. |

**Know the recommended defaults.** After opting in to the assistant package, follow-up pushes, resolution of your own verified review findings, eligible AI-feedback reply publication and automatic approval are enabled. Publishing every comment, automatic merge and conflict-resolution pushes remain separate choices. Each rule can be changed; opting out disables assistant automation. Saved legacy shell rules remain available for reference but do not run as MR automation; choose the assistant CLI to migrate them.

**Local fixes are not delivered fixes.** With follow-up push off, pending or failed, the proposal stays in the task result and does not create completion drafts. Automatic publication on your own MRs requires a fresh, sealed verification tied to the account, run, source branch, remote file hashes and exact draft bodies. Old local-only drafts are retained privately rather than silently trusted.

**AI-feedback publication is selective.** Verified GitLab Duo comments qualify; comments posted by people require a very-high-confidence AI-origin assessment bound to their current content. This is a heuristic. Uncertain cases remain private, and neither discussion resolution nor slash quick actions are automatically published. You can explicitly publish pending drafts from the MR card.

Tasks run headlessly through the selected CLI. MergeTether stores their lifecycle, output and errors locally. A completed agent process is distinct from verified remote changes, review evidence or a passing pipeline. Failed and interrupted runs remain inspectable and require a deliberate retry; uncertain work is not silently replayed after a restart. Legacy desktop handoffs are retained without automatic replay.

Assistant setup checks CLI compatibility and sign-in before accepting your choice. It offers CLI installation and sign-in in Terminal; cancelling keeps the previous selection. Turning off automatic re-review verification does not remove the CLI requirement for assistant automation. CLI execution permissions still apply. No desktop listener, scheduled dispatcher, plugin installation or permission-template setup is required.

You can also choose an installed desktop assistant or CLI from an MR’s manual action menu. These actions are optional, explicitly selected destinations; opening one does not enable automatic desktop dispatch or establish that its work completed. See [all permissions, defaults and limits](docs/automation.md).

## Privacy

MergeTether runs locally, without a hosted MergeTether service or analytics. It uses your local `glab` credentials, stores settings and activity on your Mac, downloads avatars directly and checks GitHub for releases. Assistant tasks share the GitLab data needed for the task with the assistant/provider you choose. Preparation filters remove common credential patterns, not every possible secret; scope automation to repositories you are allowed to share.

## Contributing

Build and test with Swift 6, Xcode 26+ and the Tuist version pinned in `mise.toml`. Start with [docs/building.md](docs/building.md). [AGENTS.md](AGENTS.md) contains the project's short operating constraints; [CLAUDE.md](CLAUDE.md) imports that same guidance. [Contributor notes](docs/contributing.md) explain the public-data policy and the evidence behind keeping instructions concise.

The hand-painted icon and its generation prompt are included in [docs/branding](docs/branding/README.md).

## License

[MIT](LICENSE).
