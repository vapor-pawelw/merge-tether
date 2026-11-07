# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Snap the iOS board to wider lanes with hidden scroll indicators and an adaptive landscape layout; keep connection status stable during refresh while preserving action freshness checks.

- Share Mac card text, status badges and primary CTAs with iOS, highlight attention in orange, and replace unexplained commit hashes with MR numbers.

- Add an iOS companion MVP with the Mac board, encrypted Cloudflare relay pairing and guarded remote actions.

### Added

- Recover known app-created reply drafts with fresh verification, and offer a direct retry when verification cannot finish.
- Automatically track eligible Draft review requests until ready and assess informational mentions before acknowledging them.
- Give headless workers private temporary directories and allow one fresh, guarded follow-up after a proven local temporary-file permission failure.

- Select individual private drafts for manual publication, with a persistent selection action while reading threads and unchanged Publish all support.

- Add an expandable per-MR automation event log with attempt timestamps, application decisions, exact failure reasons and optional raw diagnostics.

- Pin cards per account and animate card insertion, removal and reordering within each lane, respecting Reduce Motion.
- Offer brief, optional banners for automatically accepted GitLab events, enabled by default for existing installations as well.

- Distinguish the first board sync from background refreshes, dim restored work until catalogs are current, and offer a retry when the first sync fails.

- Let the lightweight verifier read live MR evidence through Codex CLI or Claude CLI tools while keeping GitLab actions in the app's policy checks.
- Show MR authors with compact avatars on Reviewing and proposal cards, explain proposal sources, and show factual review participation and reply context.
- Browse complete discussion threads with inline private drafts in Review and confirm, including AI badges for verified agent identities or high-confidence current-comment assessments.
- Proactively assess AI assistance in source-comment text through the lightweight verification model, including human-posted feedback; keep likely manual and uncertain results private and bind assessments to current comment bodies.
- Offer Full automation, With checkpoints and Manual only profiles with separate scope and publication controls; preserve existing settings until explicitly changed.
- Add optional publication conditions for repositories, MR authors, source-comment authors and current AI evidence, combined with AND, plus individual resets to profile defaults.

- Verify all expectations on your own MRs before resolving accepted feedback, with configurable thread resolution, generic reviewer acceptance and visible remaining blockers. Keep conditional advance approvals from bypassing follow-up work or automatic merge.
- Show a neutral or amber menu-bar attention indicator and notify about work needing a human decision, with in-app notification permission controls.

- Open MergeTether as a regular macOS Dock application with a resizable three-column MR board, direct card actions and detailed MR views.
- Run agent tasks headlessly through authenticated Codex CLI or Claude CLI, with local execution history, output, failure reporting and deliberate retries.
- Offer installed desktop agents and CLIs as optional, manually selected MR destinations.
- Verify re-review readiness with independent Luna/Haiku defaults, comment-specific blockers and content-bound manual confirmation when automatic verification is off or unavailable.
- Offer CLI compatibility/sign-in checks, installation and Terminal login during agent setup; preserve the prior selection on cancellation.
- Turn recognized GitLab to-dos into durable MR actions, acknowledge routed events, and keep unknown events or new-MR proposals in Other items. Support explicit Add/Ignore and automatic adoption within enabled scope.
- Keep checked drafts, approvals, blockers and agent results on their MR cards and promote cards requiring attention.
- Browse My merge requests and Reviewing, add individual reviewed MRs by URL or repository/number, and control automatic approval per MR.
- Configure automation globally, per repository or per MR, with workflow preview, event tracking and CLI execution modes.

### Changed

- Give empty lanes a centered icon and clear title, distinguish first-load placeholders from empty lists, and dim entire Draft cards consistently.

- Open card details by clicking anywhere on a board card, highlight cards on hover, show compact pin controls beside MR numbers and clarify whether automation is enabled or paused.

- Keep one MR automation history with expandable prompts, responses and linked runs; mark automatic events with a title icon and remove empty Automation sections.

- Use regular-weight primary card messages and move authors, badges and MR numbers above titles.

- Separate publish-all automation from conditional publication, default Full automation to all checked comments and With checkpoints to AI replies, and simplify the filter fields and profile-aware resets.

- Show MR authors by display name, with their account handle available on hover.

- Place the repository name inline after card titles, show author and MR metadata above titles and full repository paths in hover help and details, and standardize card menus and icons.

- Show one main action per MR card, keep comments in a stable detail layout, and collapse metadata and run/activity history until requested.
- Use Agent and coding agent terminology throughout the interface and documentation, with an explicit Start a conversation with an agent action for manual CLI or desktop sessions.
- Replace the menu-bar popover with the main window and remove automatic desktop chat creation, listener dispatch, chat-title synchronization, permission templates and plugin setup from the app.
- Require a working, signed-in selected CLI for agent automation independently of the automatic re-review verification setting. Desktop applications are optional.
- Preserve legacy GUI history without automatically replaying uncertain pending work. Distinguish agent completion from verified GitLab effects.
- Keep agent task results and user decisions in MergeTether; allow manual GitLab operations without an AI dependency.
- Keep follow-up push permission separate from conflict pushes. Verify the current account, remote head, committed file contents, discussion text and exact draft bodies before automatically publishing author-follow-up replies.
- Re-review author replies even without a new commit. Resolve only your own findings after verification when enabled.
- Publish eligible replies to verified GitLab Duo feedback or high-confidence AI comments selectively; keep uncertain replies private and reject automatic quick actions.
- Request another review only after relevant feedback is addressed and unpublished replies no longer block it. Bind manual confirmation to current content.
- Organize automation settings by checkpoints, agent, scope and workflow; save scope immediately without later agent changes overwriting it.
- Preserve the release bundle identifier, macOS 14 minimum and legacy GitLabTodos target/cask names.
- Refresh public documentation and use the retro painted-style MergeTether icon.

### Fixed

- Keep independent incoming reviewer feedback moving while unrelated private replies await verification, preserving existing drafts and publication safeguards.
- Prevent review jobs on the current user’s own merge requests, including restored runs, while retaining scoped feedback handling and failed-pipeline fixes.

- Avoid requesting replies or coding follow-ups for informational review comments.
- Label the latest recorded Scope event with its timestamp so historical triggers do not read as current MR status.
- Reduce repeated work when updating the menu-bar attention indicator.
- Keep active verification in progress and prevent reconciled historical failures from replacing current draft actions on Mac or iPhone.
- Keep rejected reply checks stable across restarts and partial publication, and retain owed author replies on Draft MR cards.
- Recover unlinked finished CI claims through one separately verified assessment while preserving original history and excluding recorded execution effects.
- Keep optional iOS pairing reads off the main thread so a Keychain prompt cannot freeze Mac startup or automation.
- Let Full automation claim unowned failed pipelines, including earlier failures skipped without starting work, validate merged-result commits against source and target parents, and request fresh CI when the target has advanced.
- Reconcile completed follow-ups from current feedback and published replies, including deferred Draft MRs, while retaining historical diagnostics.

- Keep reviewer waiting local: never create reminder comments or drafts, migrate legacy agent rules, and retire queued reminder jobs.
- Attribute background reconciliation to automation independently of how an earlier worker was launched.

- Calibrate AI-assisted review detection using combined content and style signals, accept high confidence, and re-assess cached nonqualifying results when criteria change.

- Retain sealed publication evidence across successor runs, revalidate each draft against its original authorized run, and keep likely manual or unclassified sources private under AI-only publication.

- Complete independently verified no-work feedback follow-ups without requiring a publication receipt, reconcile them as soon as verification finishes, and keep stale results from overwriting newer retries. Retain exact application failures and retry history.

- Align discussion disclosure arrows with the first header row and add space between the control and conversation text.

- Explain the next step on Reviewing cards, stop presenting resolved author replies as pending work, and recheck outdated current-head review evidence once per discussion context under the configured workflow rule.

- Align card pin and menu controls, emphasize the reason a card needs attention, and keep full repository paths in hover help and MR details instead of card footers.

- Ingest submitted-review summaries into durable MR actions without leaving handled events in Other items, and assess general feedback before starting fixes.

- Offer Try again directly on stopped agent-run cards while keeping the run result available as a secondary action.
- Keep discussion expansion responsive by avoiding repeated board-wide attention calculations and deferring collapsed section contents.
- Include the current MR description in feedback verification and recheck its context before resolving feedback, requesting re-review or automatically merging.
- Keep cancelled conflict preparation retryable, freeze automatic publication to checked draft IDs, and preserve readable discussion caches during authentication errors.
- Advance verified conflict plans to a newly authorized push stage once, keeping automatic preparation neutral while preserving stopped push attempts for manual review.
- Give CLI workers full tool access instead of falling back to text-only preparation, while retaining task-specific GitLab action checks and the read-only verifier role.
- Align documentation and interface wording with the MR board, CLI automation, current checkpoints and manual review actions.
- Recheck GitLab authentication on refresh after a startup connection failure.
- Explain the specific human action on each attention card and open pending comments or a stopped run directly, replacing generic blocker labels.
- Keep automatic processing and reviewer waits neutral, share human-attention decisions across cards and the menu bar, and require complete verifier output with a bounded read-only retry.
- Keep draft MRs at the bottom of Reviewing even when they have pending actions.
- Keep Activity and agent history in the main window, removing the nested tabs from Automation Scope settings.

- Keep drafts marked as needing review when the current MR head or discussion content has not been checked. Refresh visible MR confirmations without waiting for the regular poll.
- Invalidate review verdicts after new or edited discussion text, while retaining them for resolution-only changes.
- Keep previous MR catalogs and clickable board content when a GitLab source fails.
- Preserve private user-created drafts and require checked draft IDs for automatic publication.
- Align wrapped MR titles, avatars, metadata and action controls, and avoid a SwiftUI lazy-layout loop in MR lists.
- Coordinate failed pipeline ownership and isolated follow-up work to avoid duplicate fixes.

## 1.1.0 - 2026-08-13


### General

#### Features

- Added periodic unread to-do reminders, defaulting to every 5 minutes until the menu is opened.
- Made unseen to-dos more apparent in the menu bar with a pulsing unread indicator.
- Added an optional reminder sound picker, disabled by default.

#### Bug Fixes

- Prevented concurrent or timed-out `glab` commands from accumulating and exhausting system memory.


## 1.0.0 - 2026-04-24


### General

#### Features

- Initial project scaffold: Tuist-generated SwiftUI `MenuBarExtra` app targeting macOS 14, Swift 6, localized via per-feature string catalogs.
- Menu bar inbox with rich dropdown rendering avatar, author, action description, project path, state badge (Draft / Open / Merged / Closed) and relative time for each to-do; click a row to open in browser, checkbox to mark as done (optimistic with rollback on failure).
- GitLab-branded menu bar icon with the active to-do count always shown (including 0) and a red dot when unseen to-dos exist; the dot clears the moment the dropdown is opened.
- Hybrid notification delivery: up to three new to-dos become individual banners, four or more collapse into one "N new GitLab to-dos" summary.
- Configurable refresh interval (1 minute to 1 hour) with a manual refresh button and a non-destructive error banner that keeps the last known list clickable when glab fails.
- Four-step guided onboarding (install glab, sign in, notifications, launch at login) with re-check, wrong-default-host detection and copy-paste install commands.
- Self-hosted aware: "Open in browser" and all host-dependent UI use `glab config get host`, falling back to parsing the first to-do's URL.
- Background fetch at app launch so the menu bar count and unseen dot are correct before the user opens the dropdown.
- Homebrew cask distribution with tag-triggered GitHub Actions release workflow, CHANGELOG-sourced release notes and optional automatic tap update.
- "What's New" window that surfaces the latest changelog section after an upgrade.
