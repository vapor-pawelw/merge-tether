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

Recognized GitLab to-dos update an MR’s durable action and are then marked read. Unknown events stay in Other items; new foreign MRs can be added and handled or ignored, and matching enabled automation adopts them automatically. Agent completion remains a separate state. Optional brief in-app banners announce automatically accepted events; Settings → General controls them, independently of system notifications.

Open **Review and confirm** to read complete discussion threads alongside private drafts. Select individual drafts with checkboxes to **Publish selected**, or use **Publish all comments**. Selection is cleared for changed or removed drafts; manual publication does not depend on automation or AI-origin filters. An **AI** badge marks verified agent identities or a high-confidence assessment tied to the current comment; a comment without the badge may be likely manual, uncertain or unassessed.

Pin any card to keep it at the top of its column; pins are saved for your account. Within pinned and unpinned groups, cards requiring attention rise to the top and draft MRs stay at the bottom of Reviewing. Insertions, removals and reordering animate naturally and respect macOS Reduce Motion. Hover over the short repository name for its full path, or open a card for full repository details and execution history. **Activity** shows workflow events and agent results. **Settings → Automation → Scope** controls automation globally, by repository or by MR without losing history.

Use **Add merge request…** to add a reviewed MR by URL or repository and number. **Remove from my list** on a reviewed MR keeps it out of automatic adoption until you explicitly add it again.

Attention means a human action is required. Automatic work and verification show short stage labels, such as Checking replies or Handling feedback, without an attention marker; waiting for a reviewer stays neutral and never creates reminder comments. Cards, the menu-bar indicator and notifications use the same decision.
Each attention card explains what needs you and offers a matching action. Pending comments open expanded for review; stopped automation offers a direct retry, with its previous result and actual cause still available.

The menu-bar icon stays neutral while work is handled automatically and turns amber when something needs your attention. Optional macOS notifications bring those decisions to you without announcing every automatically handled update. Enable notification permission inside the app; if macOS has denied it, the app links to System Settings.

Polling, notifications and launch at login are configurable. Monitoring continues while the app is running, including when its window is closed. A failed GitLab request keeps the previous inbox usable. On launch, saved pending work can restore a partial board before the complete MR list arrives. Cards are dimmed during the first sync, with a progress indicator. An unsuccessful first sync keeps available work visible and offers a refresh; later background refreshes do not dim the board.

## Get started

You need **macOS 14+** and an authenticated [`glab`](https://gitlab.com/gitlab-org/cli) installation. Self-hosted GitLab uses your CLI's default host.

```sh
brew install glab
glab auth login
```

Build the current development version using [the build guide](docs/building.md), then launch MergeTether. Onboarding checks GitLab access and offers optional automation. All agent automation requires a compatible, signed-in **Codex CLI or Claude CLI**. Their desktop applications are optional. You can keep manual inbox/MR management and change your choice later.

**Release status:** this README describes the current development tree. Check [Releases](https://github.com/vapor-pawelw/merge-tether/releases) for the features in a published binary. The earlier inbox-only GitLab Todos release is [v1.1.0](https://github.com/vapor-pawelw/merge-tether/releases/tag/v1.1.0), with source on [`legacy/gitlab-todos`](https://github.com/vapor-pawelw/merge-tether/tree/legacy/gitlab-todos). Its Homebrew cask remains `vapor-pawelw/tap/gitlab-todos` for compatibility; installing that cask does not build unreleased features.

Cards combine open GitLab prerequisites and branch-stack relationships into one dependency line, with links to MRs that must merge first. A position such as **Stack 2/3** appears only for a complete, unambiguous linear stack. Incomplete or inaccessible metadata is marked explicitly, and a prerequisite mentioned by both sources appears once. The same read-only information is available in the iOS companion; it does not change automation permissions.

## Optional agent workflows

Choose a profile, coding agent and scope in **Settings → Automation**. Installed MR skills refine the work; MergeTether also supplies default instructions when no MR skill is installed.

| Workflow | Behavior |
| --- | --- |
| Review and re-review | Recheck new commits or author replies, verify earlier findings, resolve only your own addressed threads when enabled, and draft replies for anything still wrong. |
| Follow up on your MR | Implement justified fixes, test, commit, push when enabled, verify the remote HEAD and file content, then save response drafts. |
| Accepted feedback on your MR | Verify all reviewer expectations, then close addressed threads after that reviewer approves or explicitly confirms acceptance. Advance approval never overrides remaining conditions. Enabled by Full automation; configurable separately. |
| Failed pipeline | Full automation checks ownership and diagnoses unclaimed failures. If a merged-result pipeline tested an older target commit, request fresh MR CI before attempting a code fix. Other profiles retain the ownership checkpoint. |
| Conflict resolution | Prepare an isolated resolution; pushing it has a separate permission from ordinary follow-ups. |
| Re-review requests | Request another review after feedback is addressed and no unpublished replies remain. |
| Approval | Approve a reviewed commit only after a no-objections verdict, no pending drafts and resolved discussions. |
| Merge | Full automation enables it; checks ownership, approvals, threads, pipeline and the source commit. |

**Choose how much to automate.** **Full automation** runs reviews and follow-ups, publishes eligible comments, approves, resolves verified findings, pushes fixes and merges within the active scope. **With checkpoints** reviews and prepares local proposals automatically, publishes eligible replies to AI feedback, and waits for your other publication and delivery decisions. **Manual only** disables automatic work; you can still start a review yourself. Existing settings are preserved until you choose a profile, and individual permissions remain adjustable. Publication can be set to all eligible comments, eligible replies to AI feedback, or **Private drafts only** for manual confirmation. Saved legacy shell rules remain available for reference; choose the coding agent CLI to migrate them.

Optional publication filters can require matching repositories, MR authors, source-comment authors and verified or high-confidence AI-assisted feedback. **All eligible comments** ignores these filters; in conditional modes, all selected conditions must match (AND). Comments that do not qualify remain private. Explicit manual **Publish all** bypasses automation filters. Individual reset controls restore that setting to the chosen profile’s defaults without discarding other customization.

**Local fixes are not delivered fixes.** With follow-up push off, pending or failed, the proposal stays in the task result and does not create completion drafts. Automatic publication on your own MRs requires a fresh, sealed verification tied to the account, run, source branch, remote file hashes and exact draft bodies. Known app-created drafts with older evidence receive a bounded fresh verification of their provenance, current code and discussion context. Each reply is checked separately: a refreshed or uncertain sibling does not block independently verified replies. Unknown or changed drafts stay private; failed verification offers a retry on the MR card.

**In AI-feedback mode, publication is selective.** AI feedback means content written or substantially assisted by AI, including comments posted from a person’s account. An account name alone neither qualifies nor excludes it. Verified GitLab Duo comments qualify; other sources require a high-confidence assessment bound to the individual comment’s current body. This is a probabilistic judgment based on text and discussion context. When an AI condition applies, the configured lightweight verification model proactively assesses source comments that lack a current result. Unassessed, likely manual or uncertain sources keep their replies private. Edited comments and later follow-ups need their own assessments. Neither discussion-resolution commands nor slash quick actions are automatically published. Review pending drafts in the MR details before explicitly publishing them.

Tasks run headlessly through the selected CLI. MergeTether stores their lifecycle, output and errors locally. A completed agent process is distinct from verified remote changes, review evidence or a passing pipeline. Failed and interrupted runs remain inspectable; uncertain work is not silently replayed after a restart. A proven local temporary-file permission failure can receive one fresh automatic follow-up with current account, commit, discussion and permission checks. The new attempt reconciles existing remote work before acting, and preserves the original failure in history. Legacy desktop handoffs are retained without automatic replay.

A finished CI claim without any recorded execution can receive one separately logged assessment of the current failure. It retains the original claim, checks for active or recorded work, and uses fresh account, source, target and permission evidence before a new run.

Eligible review requests for Draft MRs enter Reviewing automatically and wait until the author marks them ready. Informational mentions can be assessed and marked read automatically; ambiguous or actionable events remain available to read. The optional handled-event banner reports accepted events without keeping a permanent attention item.

Agent setup checks CLI compatibility and sign-in before accepting your choice. It offers CLI installation and sign-in in Terminal; cancelling keeps the previous selection. Turning off automatic re-review verification does not remove the CLI requirement for agent automation. Workers run non-interactively with full file, command and network access; publication, approvals and pushes still follow the configured policy. The lightweight verifier uses the same CLI tools to read live MR evidence through `glab`; the app performs the configured GitLab actions after its checks. No desktop listener, scheduled dispatcher, plugin installation or permission-template setup is required.

Choose **Start a conversation with an agent…** from an MR’s **…** menu to select an installed desktop app or CLI. MergeTether passes an MR context prompt through a desktop deep link or opens the CLI in Terminal; very long desktop prompts are copied for pasting instead. These actions do not enable automatic desktop dispatch or track the resulting conversation. See [all permissions, defaults and limits](docs/automation.md).

## Privacy

MergeTether runs locally, without a hosted MergeTether service or remote analytics. It uses your local `glab` credentials, stores settings and activity on your Mac, downloads avatars directly and checks GitHub for releases. Agent workers can read local files, run commands and access the network; task content and data they read can reach the provider you choose. Credential filtering applies to prepared excerpts, not every live tool read. Scope automation to repositories you are allowed to share.

Settings compares local usage estimates for coding-agent work and verification. Tracking starts with new app-owned runs; these estimates are not billing receipts. The usage ledger stores numeric metadata without prompts or transcripts. See [how estimates work](docs/automation.md#agent-usage-estimates).

## Contributing

Build and test with Swift 6, Xcode 26+ and the Tuist version pinned in `mise.toml`. Start with [docs/building.md](docs/building.md). [AGENTS.md](AGENTS.md) contains the project's short operating constraints; [CLAUDE.md](CLAUDE.md) imports that same guidance. [Contributor notes](docs/contributing.md) explain the public-data policy and the evidence behind keeping instructions concise.

The hand-painted icon and its generation prompt are included in [docs/branding](docs/branding/README.md).

## License

[MIT](LICENSE).

## iOS companion MVP

The optional iOS companion mirrors the Mac board and offers guarded actions over an encrypted outbound Cloudflare relay connection. See [pairing, deployment and limitations](docs/remote.md).
