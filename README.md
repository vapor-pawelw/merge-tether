<div align="center">

<img src="docs/images/mergetether-icon.png" alt="MergeTether — hand-painted connected branches" width="128"/>

# MergeTether

**Your GitLab inbox and merge requests, together in the macOS menu bar.**

Triage reviews, see what blocks a merge, and hand routine follow-ups to Codex or Claude — with control over each automation.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#get-started)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

</div>

## A desk for your merge requests

- **Inbox:** GitLab to-dos and additional actions requiring your attention, without repeating the same reason. Preview and publish drafts, confirm handoffs, or open the MR. Draft MRs stay at the bottom.
- **Merge Requests → Own:** all your open MRs, their merge readiness and blockers, and existing Codex or Claude chat links.
- **Merge Requests → Reviewed:** managed open MRs by other authors, with status and chat links. Add an MR by URL, or by its number and repository, to include it in automation.
- **Settings → Automation → Scope:** automate all relevant discovered MRs, selected repositories, individual MRs, or a mixture. Pause items without losing their assistant chats. Delivery and workflow history live here too.

The menu-bar count includes to-dos and additional actions requiring you, including assistant setup or manual delivery. Routine queued and delivered events do not increase it. A delivery receipt confirms that the chat received work; it does not mean the assistant finished it.

Polling, notifications, reminders and launch at login are configurable. A failed GitLab request keeps the previous inbox usable.

## Get started

You need **macOS 14+** and an authenticated [`glab`](https://gitlab.com/gitlab-org/cli) installation. Self-hosted GitLab uses your CLI's default host.

```sh
brew install glab
glab auth login
```

Build the current development version using [the build guide](docs/building.md), then launch MergeTether. Onboarding checks GitLab access, detects Codex and Claude separately, and offers an optional assistant package. You can keep an inbox-only setup and change your choice later.

**Release status:** this README describes the current development tree. Check [Releases](https://github.com/vapor-pawelw/merge-tether/releases) for the features in a published binary. The earlier inbox-only GitLab Todos release is [v1.1.0](https://github.com/vapor-pawelw/merge-tether/releases/tag/v1.1.0), with source on [`legacy/gitlab-todos`](https://github.com/vapor-pawelw/merge-tether/tree/legacy/gitlab-todos). Its Homebrew cask remains `vapor-pawelw/tap/gitlab-todos` for compatibility; installing that cask does not build unreleased features.

## Optional assistant workflows

Choose your assistant, scope and rules in **Settings → Automation**. Installed MR skills refine the work; MergeTether also supplies default instructions when no MR skill is installed.

| Workflow | Behavior |
| --- | --- |
| Review and re-review | Recheck new commits or author replies, verify earlier findings, resolve only your own addressed threads when enabled, and draft replies for anything still wrong. |
| Follow up on your MR | Implement justified fixes, test, commit, push when enabled, verify the remote HEAD and file content, then save response drafts. |
| Failed pipeline | Check whether another task already owns the fix; otherwise prepare a scoped diagnosis/fix. |
| Conflict resolution | Prepare an isolated resolution; pushing it has a separate permission from ordinary follow-ups. |
| Re-review requests | Request another review after feedback is addressed and no unpublished replies remain. |
| Approval | Approve a reviewed commit only after a no-objections verdict, no pending drafts and resolved discussions. |
| Merge | Optional; checks ownership, approvals, threads, pipeline and the source commit. Off by default. |

**Know the recommended defaults.** After opting in to the assistant package, follow-up pushes, resolution of your own verified review findings, eligible AI-feedback reply publication and automatic approval are enabled. Publishing every comment, automatic merge and conflict-resolution pushes remain separate choices. Each rule can be changed; opting out disables assistant/script automations.

**Local fixes are not delivered fixes.** With follow-up push off, pending or failed, that run stays in chat and does not create completion drafts. Automatic publication on your own MRs requires a fresh, sealed verification tied to the account, run, source branch, remote file hashes and exact draft bodies. Old local-only drafts are retained privately rather than silently trusted.

**AI-feedback publication is selective.** Verified GitLab Duo comments qualify; comments posted by people require a very-high-confidence AI-origin assessment bound to their current content. This is a heuristic. Uncertain cases remain private, and neither discussion resolution nor slash quick actions are automatically published. You can explicitly publish pending drafts from Inbox.

| Integration | Codex Desktop | Claude Desktop |
| --- | --- | --- |
| New chats | Local listener dispatches persistent GUI chats | Prefilled Code draft; you press Send |
| Reuse | Same MR chat, grouped by repository | Linked session, with follow-up prompt copied for pasting |
| Local tools | Bundled plugin and read-only verification helper | Bundled Claude Code plugin and the same helper |

The listener's health and missing setup appear in Inbox. Closing an assistant keeps queued work on your Mac. Assistant tool permissions still apply. See [all permissions, defaults and limits](docs/automation.md).

## Privacy

MergeTether runs locally, without a hosted MergeTether service or analytics. It uses your local `glab` credentials, stores settings and activity on your Mac, downloads avatars directly and checks GitHub for releases. Assistant tasks share the GitLab data needed for the task with the assistant/provider you choose. Preparation filters remove common credential patterns, not every possible secret; scope automation to repositories you are allowed to share.

## Contributing

Build and test with Swift 6, Xcode 26+ and the Tuist version pinned in `mise.toml`. Start with [docs/building.md](docs/building.md). [AGENTS.md](AGENTS.md) contains the project's short operating constraints; [CLAUDE.md](CLAUDE.md) imports that same guidance. [Contributor notes](docs/contributing.md) explain the public-data policy and the evidence behind keeping instructions concise.

The hand-painted icon and its generation prompt are included in [docs/branding](docs/branding/README.md).

## License

[MIT](LICENSE).
