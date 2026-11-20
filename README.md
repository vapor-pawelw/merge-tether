<div align="center">

<img src="docs/images/mergetether-icon.png" alt="MergeTether — painted-style connected branches" width="128"/>

# MergeTether

**A native macOS command center for your GitLab merge requests.**

Triage reviews, see what blocks a merge, and run routine follow-ups through Codex or Claude CLI — with progress, results and decisions in one window.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#get-started)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

</div>

## A desk for your merge requests

MergeTether opens a resizable main window and appears in the Dock. Its board keeps your long-lived merge request lists in two columns:

- **My merge requests:** your open MRs, with blockers, drafts, to-dos and follow-up actions directly on each card.
- **Reviewing:** MRs you review, with the author’s avatar, the reason they are tracked, discussion activity and direct review actions.
- **Inbox:** a toolbar popover with a pending-item count opens unmatched GitLab to-dos, MR proposals, assistant runs needing attention, and saved merged/closed updates waiting for **Seen**. Proposals show their author and source; add or ignore the proposed MR.

Recognized GitLab to-dos update an MR’s durable action and are then marked read. Unknown events stay in Inbox; new foreign MRs can be added and handled or ignored, and matching enabled automation adopts them automatically. Agent completion remains a separate state. Optional brief in-app banners announce automatically accepted events and observed merged, closed or Draft/Ready changes, including while coding automation is paused. Settings → General controls these independently of system notifications and Inbox updates.

Thread headers group thread state, current feedback assessment, your published/draft reply state and classified AI origin before file/date metadata. A published reply does not imply the feedback is fixed. Details shows source → target branch near the title, with the same scan order on iPhone.

Expanded messages keep their own **AI**, **AI uncertain** or **Human** labels independently of the whole-thread label. With automation consent and the current scope permissions, reading Details schedules missing authorship assessments for published messages, including replies and general comments. Unchanged results are cached; expanding a thread does not start another model request. Display assessments grant no publication or merge permission, and an unassessed message is not assumed human.

Open **Review and confirm** to read complete discussion threads alongside private drafts. Drafts and their expanded discussion context appear immediately below **Publish X comments**. All current drafts start checked in Details; selection belongs only to the open window and resets on reopening. The MR card’s **Publish all comments** action publishes the exact displayed draft IDs individually; drafts arriving later are never included automatically. Publication waits while an agent is preparing drafts. Changed, removed or newly arriving drafts do not silently acquire selection while the window is open; manual publication does not depend on automation or AI-origin filters. Details quotes and links the exact source comment behind a feedback decision. **Ignore this suggestion** confirms one precise concern, while other requests in that comment remain in scope. Saved decisions appear only when present, with **Restore** and **Reset all**; future verifier and coding-agent prompts use the current applicable list. Edited source comments are reassessed. **AI · MergeTether** marks your comments published from drafts a recorded MergeTether run generated, matched by thread and exact text; this local record is dropped when the MR is merged or closed. When the agent judges it useful, an **Extra context** button beside its draft or published comment opens its app-only Markdown explanation (a popover on Mac, a sheet on iOS); this explanation stays on your Mac and is never sent to GitLab. An **AI** badge marks verified agent identities or a high-confidence assessment tied to the current comment; **Human** and **AI uncertain** show their separate assessed outcomes; no authorship label means no current assessment is available.

Pin a card to keep it at the top of its activity group; pins are saved for your account. In **Settings → Automation → Scope**, choose the lower section: **Automation off** (default) or **Drafts**. The choice controls grouping and gray titles/statuses. The **Automation off** header counts cards requiring your attention; their attention icons, explanations and action buttons stay prominent. With all automation off, Drafts is used temporarily and the saved choice is retained. Pins and attention ordering apply within groups. Insertions, removals and reordering animate naturally and respect macOS Reduce Motion. Hover over the short repository name for its full path, or open a card for details and history.

Merged and closed MRs leave the active board automatically. Their updates always remain in Inbox until **Seen**, independently of automation profiles, system notifications and brief event banners. Draft/Ready changes remain banners only.

The small **Automation** lightning button on a Mac MR card or in Details opens a panel with the MR's automation state, what decides it, saved rules and holds. Use **Pause for this MR** or **Turn on for this MR**, choose **Default**, **Always on** or **Always off**, or change the repository default. Option-click the lightning button to switch directly. Forced scope choices survive Draft/Ready changes. Pausing keeps the MR tracked. **Settings → Automation → Scope** controls the same scope without losing history. iOS Details shows the state read-only under Overview.

In the lightning panel and **… → Automation** menu, set **Auto-merge** for your own MR to **Default**, **On** or **Off**. **Default** follows the global auto-merge setting and its repository list. **On** enables automatic merge for that MR within its automation scope and under the normal merge checks. **Off** pauses automatic merge on that MR. Publication and approval keep their own checkboxes. Restoring a default or turning on auto-merge rechecks whether the corresponding action can run.

Use **Add merge request…** to add a reviewed MR by URL or repository and number. **Remove from my list** on a reviewed MR keeps it out of automatic adoption until you explicitly add it again.

Attention means a human action is required. Automatic work and verification show short stage labels, such as Checking replies or Handling feedback, with a progress indicator and elapsed stage time on cards and in Details, without an attention marker; waiting for a reviewer stays neutral and never creates reminder comments. Cards, the menu-bar indicator and notifications use the same decision.
Each attention card explains what needs you and offers a matching action. Pending comments open expanded for review; stopped automation offers a direct retry, with its previous result and actual cause still available.

The menu-bar icon stays neutral while work is handled automatically and turns amber when something needs your attention. Optional macOS notifications bring those decisions to you without announcing every automatically handled update. Enable notification permission inside the app; if macOS has denied it, the app links to System Settings.

Polling, notifications and launch at login are configurable. Monitoring continues while the app is running, including when its window is closed. A failed GitLab request keeps the previous inbox usable. On launch, saved pending work can restore a partial board before the complete MR list arrives. Cards are dimmed during the first sync, with a progress indicator. An unsuccessful first sync keeps available work visible and offers a refresh. Later background refreshes, including returning to the app, remain silent; visible refresh progress follows startup or your explicit refresh action. Refreshing one MR shows progress for that card while retaining its last confirmed attention state. Cards keep normal opacity. Muted titles and statuses identify inactive MRs when automation is enabled, and Drafts when all automation is off.

## Get started

You need **macOS 14+** and an authenticated [`glab`](https://gitlab.com/gitlab-org/cli) installation. Self-hosted GitLab uses your CLI's default host.

```sh
brew install glab
glab auth login
```

Generate the Xcode project using [the build guide](docs/building.md), open `MergeTether.xcworkspace`, and run the `MergeTether` scheme. Onboarding checks GitLab access and offers optional automation. All agent automation requires a compatible, signed-in **Codex CLI or Claude CLI**. Their desktop applications are optional. You can keep manual inbox/MR management and change your choice later.

**Release status:** this README describes the current development tree. Check [Releases](https://github.com/vapor-pawelw/merge-tether/releases) for the features in a published binary. Starting with the first release after the rename, the macOS download is `MergeTether.dmg` and the Homebrew cask is `vapor-pawelw/tap/mergetether`. The earlier inbox-only release is [v1.1.0](https://github.com/vapor-pawelw/merge-tether/releases/tag/v1.1.0).

Cards combine open GitLab prerequisites and branch-stack relationships into one dependency line, with links to MRs that must merge first. A position such as **Stack 2/3** appears only for a complete, unambiguous linear stack. Incomplete or inaccessible metadata is marked explicitly, and a prerequisite mentioned by both sources appears once. The same information is available in the iOS companion. **Merge when ready** independently rechecks live dependencies and stack targets: every required MR must be merged, and a child remains on hold while targeting a parent MR branch, even after the parent merges. Historical MRs on a reused target branch conservatively require target review. The existing stack follow-up prepares a plan; target changes stay with the user. Missing or uncertain evidence keeps automatic merging on hold.

## Optional agent workflows

Owned MR cards and Details offer **Merge now** independently of automatic merge settings. Projects using merge trains offer **Set to auto-merge**; ordinary projects can use it while a supported, active pipeline is still running. Queued and in-train requests remain visible until GitLab reports an actual merge. **Resolve addressed threads…** first checks the exact threads and published replies, then asks you to confirm the eligible IDs; unverified or unanswered feedback stays open. Approval counters show every current unique approver, including **5/2**.

Choose a profile, coding agent and scope in **Settings → Automation**. Installed MR skills refine the work; MergeTether also supplies default instructions when no MR skill is installed.

| Workflow | Behavior |
| --- | --- |
| Review and re-review | Recheck new commits or author replies, verify earlier findings, resolve only your own addressed threads when enabled, and draft replies for anything still wrong. |
| Follow up on your MR | Implement justified fixes, test, commit, push when enabled, verify the remote HEAD and file content, then save response drafts. |
| Accepted feedback on your MR | Verify all reviewer expectations, then close addressed threads after that reviewer approves or explicitly confirms acceptance. Advance approval never overrides remaining conditions. Enabled by Trusted and Max; configurable separately. |
| Failed pipeline | Trusted and Max check ownership and diagnose unclaimed failures. If a merged-result pipeline tested an older target commit, request fresh MR CI before attempting a code fix. Safe keeps external CI actions manual. |
| Conflict resolution | Prepare an isolated resolution; pushing it has a separate permission from ordinary follow-ups. |
| Re-review requests | Request another review after feedback is addressed and no unpublished replies remain. |
| Approval | Approve a reviewed commit when its active findings meet your approval threshold and comment review is complete. The default allows minor issues. |
| Merge | Max enables it; checks ownership, approvals, threads, pipeline and the source commit. |

**Choose how much to automate.** Each profile explains what it handles and what remains yours:

| Profile | Behavior |
| --- | --- |
| **Manual** | Start each task and GitLab action yourself. Automatic work is off. |
| **Safe** | Analyze, review and prepare private drafts and local proposals automatically. Publishing, approvals, pushes, thread resolution, review requests, to-do acknowledgements, CI mutations and merging stay manual. |
| **Trusted** | Enable supported preparation and delivery, including approvals, pushes and verified thread resolution. Publish only eligible replies to AI-assisted feedback; other comments and every merge wait for you. |
| **Max** | Enable all supported automation, including eligible comment publication and merging, within the selected scope and existing safety checks. |

The profile selector sits above its summary and detailed permission controls. Choosing a profile immediately updates the form; **Apply Changes** saves it. Individual permissions remain adjustable. A matching profile reflects the current permissions rather than the last selected defaults. **Custom** appears after you create your own configuration and lets you return to it after using a preset. It restores automation permissions while preserving your current models, instructions, scope and repository filters. Upgrades preserve saved permissions, including the older **With checkpoints** configuration. Saved legacy shell rules remain available for reference; choose the coding agent CLI to migrate them.

When the full feedback check is ready and replies are published, re-review requests also bring back earlier participating reviewers and people whose approvals were reset. Current approvals and outstanding review requests are respected. Hover over the approval counter to see current approvals, earlier approvals and comment-only participation, in that order, with the most recent activity first within each group.

Optional publication filters can require matching repositories, MR authors, source-comment authors and verified or high-confidence AI-assisted feedback. **All eligible comments** ignores these filters; in conditional modes, all selected conditions must match (AND). Comments that do not qualify remain private. Explicit manual **Publish all** bypasses automation filters. Individual reset controls restore that setting to the chosen profile’s defaults without discarding other customization.

**Author replies use verified remote evidence.** With follow-up push off, pending or failed, the proposal stays in the task result. For a single verified correction that only needs acknowledgement, MergeTether can prepare a standard private reply tied to the account, source head, discussion and exact draft body. Agent-written replies need independent verification tied to the account, run, source branch, remote file hashes and exact draft bodies. Known agent drafts with older evidence receive a bounded fresh verification of their provenance, current code and discussion context. Each reply is checked separately. Unknown or changed drafts stay private, and failed verification offers a retry on the MR card.

**In AI-feedback mode, publication is selective.** AI feedback means content written or substantially assisted by AI, including comments posted from a person’s account. An account name alone neither qualifies nor excludes it. Verified GitLab Duo comments qualify; other sources require a high-confidence assessment bound to the individual comment’s current body. This is a probabilistic judgment based on text and discussion context. When an AI condition applies, the configured lightweight verification model proactively assesses source comments that lack a current result. Unassessed, likely manual or uncertain sources keep their replies private. Edited comments and later follow-ups need their own assessments. Neither discussion-resolution commands nor slash quick actions are automatically published. Review pending drafts in the MR details before explicitly publishing them.

Tasks run headlessly through the selected CLI. MergeTether stores their lifecycle, output and errors locally. A completed agent process is distinct from verified remote changes, review evidence or a passing pipeline. Failed and interrupted runs remain inspectable; uncertain work is not silently replayed after a restart. A proven local temporary-file permission failure can receive one fresh automatic follow-up with current account, commit, discussion and permission checks. The new attempt reconciles existing remote work before acting, and preserves the original failure in history.

Up to four different MR workers run concurrently; each MR has one live worker. Provider login and usage-limit failures show a persistent banner and pause that provider's unstarted work. Sign in opens the CLI login command in the default terminal; explicit retry releases queued work without replaying failed runs.

Each worker keeps private `cli-output/stdout` and `stderr` files while running. After validating the provider's complete result, the app saves an authenticated completion checkpoint outside the worker folder before updating preferences. Startup can recover that checkpoint without rerunning the CLI. Ordinary Quit stops worker process trees and waits for cleanup; incomplete work stays Interrupted with its files and partial output. CLI sessions themselves are ephemeral and are not resumed. A deliberate retry inspects previous work and re-fetches current GitLab commits, replies and drafts before acting. Force Quit bypasses graceful cleanup; partial files alone never count as success.

A finished CI claim without any recorded execution can receive one separately logged assessment of the current failure. It retains the original claim, checks for active or recorded work, and uses fresh account, source, target and permission evidence before a new run.

Eligible review requests for Draft MRs enter Reviewing automatically. In **Default**, **Pause automation for Draft MRs** is on by default, including for existing settings: tracking continues, while automatic agent checks and actions wait. **Always on** or turning that default off permits normal configured work on a Draft, including feedback fixes, CI, conflicts and publication; Drafts are never merged automatically or marked ready by a worker. Manual CTAs remain available. On your own Draft, **Mark ready** is available on the card, in its menu and in Details. Your own MRs still offer the auto-merge setting when automatic public actions are permitted. Informational mentions can be assessed and marked read automatically; ambiguous or actionable events remain available to read. The optional handled-event banner reports accepted events without keeping a permanent attention item.

Agent setup checks CLI compatibility and sign-in before accepting your choice. It offers CLI installation and sign-in in your default terminal. Cancelling keeps the previous selection. Workers run non-interactively with full file, command and network access. Publication, approvals and pushes follow the configured policy. The lightweight verifier uses the same CLI tools to read live MR evidence through `glab`. The app performs the configured GitLab actions after its checks.

Right-click an MR or choose its **Actions** button, then **Start conversation in…** to open your default app. Set it under **Settings → General → MR conversations**. Hold **Option** on the menu action to choose another installed app or CLI for just that conversation. ChatGPT and Claude Desktop attach the MR link and title as a text file and leave the message field empty. T3 Code puts them in an unsent draft. CLI actions ask for your message before opening Terminal with it and the MR context. MergeTether does not track these separate conversations. See [all permissions, defaults and limits](docs/automation.md).

## Agent usage

**Settings → Agent Usage** shows only CLI runs started by MergeTether, with estimated costs split between coding agents and verifiers, provider breakdowns and a chart by hour, day, week or month. Its top-five MR ranking follows the selected date range. Each MR's Details shows its all-time tracked cost, reported tokens and **Agent requests** separately for the verifier and reviewer / work agent. Requests count app-started CLI jobs, including retries, rather than internal model turns; cached checks add no request. Estimates are not subscription consumption or invoices; unknown and partial measurements remain labelled. Older records without an MR identity contribute to overall totals but are not assigned to an MR retrospectively.

## Privacy

MergeTether runs locally, without a hosted MergeTether service or remote analytics. It uses your local `glab` credentials, stores settings and activity on your Mac, downloads avatars directly and checks GitHub for releases. Agent workers can read local files, run commands and access the network; task content and data they read can reach the provider you choose. Credential filtering applies to prepared excerpts, not every live tool read. Scope automation to repositories you are allowed to share.

Settings compares local usage estimates for coding-agent work and verification. Tracking starts with new app-owned runs; these estimates are not billing receipts. The usage ledger stores counts, estimates and optional MR identity, title and URL, without prompts or transcripts. See [how estimates work](docs/automation.md#agent-usage-estimates).

## Contributing

Build and test with Swift 6, Xcode 26+ and the Tuist version pinned in `mise.toml`. Start with [docs/building.md](docs/building.md). [AGENTS.md](AGENTS.md) contains the project's short operating constraints; [CLAUDE.md](CLAUDE.md) imports that same guidance. [Contributor notes](docs/contributing.md) explain the public-data policy and the evidence behind keeping instructions concise.

The hand-painted icon and its generation prompt are included in [docs/branding](docs/branding/README.md).

## License

[MIT](LICENSE).

## iOS companion MVP

The optional iOS companion mirrors the Mac board and offers guarded actions through **your own relay deployment**. The server source is public in [`Services/RemoteRelay`](Services/RemoteRelay). Deploy your instance first, keep its origin in a private file outside the checkout, and build both apps for that origin. MergeTether provides no default shared relay. A build without relay configuration keeps the Mac inbox working and disables phone access.

The origin is public metadata visible in the app and IPA, not a credential. Use a unique private runtime invitation and confirm the relay origin when pairing; never put operator tokens or private keys in build configuration. The relay operator owns availability and usage. To avoid paid overages, keep that deployment on **Workers Free**, where quota exhaustion interrupts service; the relay cannot guarantee zero cost on a Paid account. Rate limiting reduces abuse but is not a billing cap. See the [BYO relay setup](docs/byo-relay.md), [Cloudflare Free/Paid behavior](https://developers.cloudflare.com/durable-objects/platform/pricing/), and [pairing guarantees and limitations](docs/remote.md).
