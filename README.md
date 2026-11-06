<div align="center">

<img src="docs/images/mergetether-icon.png" alt="MergeTether — painted-style connected branches" width="128"/>

# MergeTether

**A native macOS command center for your GitLab merge requests.**

Triage reviews, see what blocks a merge, and run routine follow-ups through Codex or Claude CLI — with progress, results and decisions in one window.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#get-started)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

</div>

## A desk for your merge requests

MergeTether opens a resizable main window and appears in the Dock. Its board keeps your work in three columns:

- **My merge requests:** your open MRs, with blockers, drafts, to-dos and follow-up actions directly on each card.
- **Reviewing:** MRs you review, with the author’s avatar, the reason they are tracked, discussion activity and direct review actions.
- **Other items:** unmatched GitLab to-dos and MR proposals showing the author and the event that brought them here. Add or ignore a proposed MR.

Recognized GitLab to-dos update an MR’s durable action and are then marked read. Unknown events stay in Other items; new foreign MRs can be added and handled or ignored, and matching enabled automation adopts them automatically. Agent completion remains a separate state.

Open **Review and confirm** to read complete discussion threads alongside private drafts. An **AI** badge marks verified agent identities or a very-high-confidence assessment tied to the current comment; an unbadged comment is unclassified.

Cards requiring attention rise to the top of their column; draft MRs stay at the bottom of Reviewing. Open a card for its full details and execution history. **Activity** shows workflow events and agent results. **Settings → Automation → Scope** controls automation globally, by repository or by MR without losing history.

Use **Add merge request…** to add a reviewed MR by URL or repository and number. **Remove from my list** on a reviewed MR keeps it out of automatic adoption until you explicitly add it again.

Attention means a human action is required. Automatic work and verification show progress without an attention marker; waiting for a reviewer stays neutral. Cards, the menu-bar indicator and notifications use the same decision.
Each attention card explains what needs you and offers a matching action. Pending comments open expanded for review; stopped automation offers a direct retry, with its previous result and actual cause still available.

The menu-bar icon stays neutral while work is handled automatically and turns amber when something needs your attention. Optional macOS notifications bring those decisions to you without announcing every automatically handled update. Enable notification permission inside the app; if macOS has denied it, the app links to System Settings.

Polling, notifications and launch at login are configurable. Monitoring continues while the app is running, including when its window is closed. A failed GitLab request keeps the previous inbox usable.

## Get started

You need **macOS 14+** and an authenticated [`glab`](https://gitlab.com/gitlab-org/cli) installation. Self-hosted GitLab uses your CLI's default host.

```sh
brew install glab
glab auth login
```

Build the current development version using [the build guide](docs/building.md), then launch MergeTether. Onboarding checks GitLab access and offers optional automation. All agent automation requires a compatible, signed-in **Codex CLI or Claude CLI**. Their desktop applications are optional. You can keep manual inbox/MR management and change your choice later.

**Release status:** this README describes the current development tree. Check [Releases](https://github.com/vapor-pawelw/merge-tether/releases) for the features in a published binary. The earlier inbox-only GitLab Todos release is [v1.1.0](https://github.com/vapor-pawelw/merge-tether/releases/tag/v1.1.0), with source on [`legacy/gitlab-todos`](https://github.com/vapor-pawelw/merge-tether/tree/legacy/gitlab-todos). Its Homebrew cask remains `vapor-pawelw/tap/gitlab-todos` for compatibility; installing that cask does not build unreleased features.

## Optional agent workflows

Choose a profile, coding agent and scope in **Settings → Automation**. Installed MR skills refine the work; MergeTether also supplies default instructions when no MR skill is installed.

| Workflow | Behavior |
| --- | --- |
| Review and re-review | Recheck new commits or author replies, verify earlier findings, resolve only your own addressed threads when enabled, and draft replies for anything still wrong. |
| Follow up on your MR | Implement justified fixes, test, commit, push when enabled, verify the remote HEAD and file content, then save response drafts. |
| Accepted feedback on your MR | Verify all reviewer expectations, then close addressed threads after that reviewer approves or explicitly confirms acceptance. Advance approval never overrides remaining conditions. Enabled by Full automation; configurable separately. |
| Failed pipeline | Check whether another task already owns the fix; otherwise prepare a scoped diagnosis/fix. |
| Conflict resolution | Prepare an isolated resolution; pushing it has a separate permission from ordinary follow-ups. |
| Re-review requests | Request another review after feedback is addressed and no unpublished replies remain. |
| Approval | Approve a reviewed commit only after a no-objections verdict, no pending drafts and resolved discussions. |
| Merge | Full automation enables it; checks ownership, approvals, threads, pipeline and the source commit. |

**Choose how much to automate.** **Full automation** runs reviews and follow-ups, publishes eligible comments, approves, resolves verified findings, pushes fixes and merges within the active scope. **With checkpoints** reviews and prepares local proposals automatically, then waits for your publication and delivery decisions. **Manual only** disables automatic work; you can still start a review yourself. Existing settings are preserved until you choose a profile, and individual permissions remain adjustable. Publication can be set to all eligible comments, eligible replies to AI feedback, or **Private drafts only** for manual confirmation. Saved legacy shell rules remain available for reference; choose the coding agent CLI to migrate them.

Optional advanced publication conditions can require matching repositories, MR authors, source-comment authors and verified or very-high-confidence AI feedback. The conditions combine with AND and only narrow the selected publication mode. Comments that do not qualify remain private. Individual reset controls restore that setting to the chosen profile’s defaults without discarding other customization.

**Local fixes are not delivered fixes.** With follow-up push off, pending or failed, the proposal stays in the task result and does not create completion drafts. Automatic publication on your own MRs requires a fresh, sealed verification tied to the account, run, source branch, remote file hashes and exact draft bodies. Old local-only drafts are retained privately rather than silently trusted.

**In AI-feedback mode, publication is selective.** Verified GitLab Duo comments qualify; comments posted by people require a very-high-confidence AI-origin assessment bound to their current content. This is a heuristic. Uncertain cases remain private, and neither discussion-resolution commands nor slash quick actions are automatically published. Review pending drafts in the MR details before explicitly publishing them.

Tasks run headlessly through the selected CLI. MergeTether stores their lifecycle, output and errors locally. A completed agent process is distinct from verified remote changes, review evidence or a passing pipeline. Failed and interrupted runs remain inspectable and require a deliberate retry; uncertain work is not silently replayed after a restart. Legacy desktop handoffs are retained without automatic replay.

Agent setup checks CLI compatibility and sign-in before accepting your choice. It offers CLI installation and sign-in in Terminal; cancelling keeps the previous selection. Turning off automatic re-review verification does not remove the CLI requirement for agent automation. Workers run non-interactively with full file, command and network access; publication, approvals and pushes still follow the configured policy. The lightweight verifier uses the same CLI tools to read live MR evidence through `glab`; the app performs the configured GitLab actions after its checks. No desktop listener, scheduled dispatcher, plugin installation or permission-template setup is required.

Choose **Start a conversation with an agent…** from an MR’s **…** menu to select an installed desktop app or CLI. MergeTether passes an MR context prompt through a desktop deep link or opens the CLI in Terminal; very long desktop prompts are copied for pasting instead. These actions do not enable automatic desktop dispatch or track the resulting conversation. See [all permissions, defaults and limits](docs/automation.md).

## Privacy

MergeTether runs locally, without a hosted MergeTether service or analytics. It uses your local `glab` credentials, stores settings and activity on your Mac, downloads avatars directly and checks GitHub for releases. Agent workers can read local files, run commands and access the network; task content and data they read can reach the provider you choose. Credential filtering applies to prepared excerpts, not every live tool read. Scope automation to repositories you are allowed to share.

## Contributing

Build and test with Swift 6, Xcode 26+ and the Tuist version pinned in `mise.toml`. Start with [docs/building.md](docs/building.md). [AGENTS.md](AGENTS.md) contains the project's short operating constraints; [CLAUDE.md](CLAUDE.md) imports that same guidance. [Contributor notes](docs/contributing.md) explain the public-data policy and the evidence behind keeping instructions concise.

The hand-painted icon and its generation prompt are included in [docs/branding](docs/branding/README.md).

## License

[MIT](LICENSE).
