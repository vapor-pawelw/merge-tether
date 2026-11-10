# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Make Details discussion threads easier to scan with compact filenames, full-path hover descriptions, clearer comment hierarchy and separate published-reply and private-draft status for the current account.

- Index linked assistant history once per workflow projection to reduce board and history processing while preserving current execution results and account checks.

- Reduce repeated MR-board fingerprint work by preparing exact request bindings once per projection, preserving separate catalog and action evidence.

- Reuse prepared board rows, Inbox sections and Details membership during rendering, including preserved card order and shared discussion sections, to reduce repeated work when opening the command center.

- Recheck explicit write authorization at every native GitLab process launch, including draft publication, reactions, discussion resolution, review requests and todo acknowledgements, while preserving deliberate manual actions.

- Remove the retired menu-list interface and desktop plugin/listener sources while preserving manual assistant conversations, existing history and standalone verification helpers.

- Show the Mac's safety pause on iPhone while keeping refresh and manual checks available.

- Bind phone publication to the checked account, CLI and signed-in user, and stop selected Mac publication after an account round trip.

- Show the phone running-action indicator above the card action buttons.

- Reject stale phone commands and receipts after reconnects or account changes, retain write serialization across sessions, and discard disconnected thread-resolution previews.

- Offer guarded manual merge independently of automatic settings, support GitLab auto-merge and merge trains with verified pending states and persistent replay protection, and add explicit previews for resolving addressed, answered threads on Mac and compatible phones.
- Show every current unique approval, including 5/2, while preserving required-rule satisfaction and compatibility with older phones.
- Keep MR-card flow, blocker and error information above the final action row, including proposal and compact-run cards.

- Distinguish general discussion threads with a purple status label in MR Details, and group open, resolved and general threads while preserving GitLab order within each group.

- Prepare a reply in every actionable feedback thread even when another comment already led to the fix, linking the earlier explanation and keeping simple acknowledgements brief; retain remote verification and publication checks.

- Separate saved iOS pairing from connection progress and failure, bound the initial wait, and add an explicit Reconnect action alongside board refresh without forgetting trust or replaying commands.

- Escalate source-bound technical questions from comment verification to the configured feedback reviewer/fixer, keeping private hypotheses separate from original reviewer requirements and reusing the existing scoped recovery budget and permissions.

- Show lifetime MR usage in Details separately for verifiers and reviewer / work agents, with estimated costs, reported tokens and app-issued request counts including retries; retain explicit partial and unavailable states.

- Hold automatic merges until every dependency is merged and stack targets are safe, including after parent merges or restarts; recheck live evidence before merging and explain the rule beside Merge when ready.

- Recognize independently verified shared author replies as evidence of a delivered correction across discussion threads, while preserving each thread's own reply and reviewer acceptance requirements.

- Run affected verification checks by default with an explicit full-suite option, document agent test scope, and handle GitLab workflow fixtures in memory while retaining subprocess adapter coverage.
- Preserve completed re-review status when another catalog read finishes later, so a card does not remain stuck on Checking.

- Retain complete per-case test timing reports and failure diagnostics, separate build/runner time from execution, and replace avoidable test retry delays with controlled waits.

- Request re-review from earlier participating reviewers and reset approvers once all feedback is ready; show prioritized current, earlier and comment-only review status in the approvals hover list, sorted by recent activity.

- Show progress indicators and elapsed stage time on busy MR cards and in Details, while routine background polling and reviewer waits stay quiet.

- Recover sealed draft replies from blocked author follow-ups through independent current-source verification, without waiting for publication to mark the worker complete.

- Quote comments in Next step only when they support the displayed concern; keep general worker and publication blockers free of unrelated task comments.

- Confirm enabling Draft MR automation with an explanation of enabled work, existing permissions and persistent scope; group automation, pin and action controls more tightly on cards and in Details.

- Hide empty optional approvals, show received-only counts without a denominator, fill satisfied approval icons in green, and show approvers and assigned reviewers with avatars on hover.

- Expose draft replies and their threads below the Details publication button, default all current drafts to checked per window, publish the checked count, and keep direct MR publication as Publish all comments.

- Run up to four MR workers concurrently, retain persistent CLI login/quota banners, group toolbar actions and highlight clickable pin/automation controls.
- Retain headless worker output and validated completion checkpoints across restarts, wait for worker cleanup on Quit, and reconcile previous work on deliberate retries.
- Always show MR monitoring or current-check status instead of empty cards.

- Always move merged and closed MR updates to Inbox until Seen, removing obsolete board-cleanup and completion visibility switches.

- Put MR numbers and merge dependencies directly below card titles, restore compact header menus, link queued follow-ups to their exact reviewer comments, and explain why automatic follow-up is waiting.

- Show a compact received/required approval counter on Mac and iOS, using GitLab's required-approval progress and an explicit unknown state when counts cannot be read.

- Show exact comment quotations and links for open feedback and re-review blockers, distinguish unverified concerns and missing replies from confirmed corrections, and keep verified reviewer-waiting states neutral without dismissing independent GitLab change requests.

- Share MR card actions between right-click and a compact top-right ellipsis menu. Configure the default conversation app, hold Option for a one-time alternative, and open desktop conversations with a minimal MR context attachment and an empty message field.

- Move transient proposals, unmatched GitLab to-dos, assistant runs and completion updates from the board into a spacious toolbar Inbox popover, keeping My merge requests and Reviewing as the board's persistent lanes.

- Choose Without automation (default) or Drafts for the lower board section, with matching ordering and title/status muting; turning all automation off temporarily uses Drafts without forgetting the saved choice.

- Snap the iOS board to wider lanes with hidden scroll indicators and an adaptive landscape layout; keep connection status stable during refresh while preserving action freshness checks.

- Share Mac card text, status badges and primary CTAs with iOS, highlight attention in orange, and replace unexplained commit hashes with MR numbers.

- Add an iOS companion MVP with the Mac board, encrypted Cloudflare relay pairing and guarded remote actions.

### Added

- Explain effective automation on MR cards and Details, including saved-data holds, manual delivery choices and GitLab queue status, without changing action permissions.

- Delete individual private drafts with confirmation on macOS and iOS. Finish comment review directly on an MR card, with a persistent account-scoped checkpoint and live commit, discussion and draft checks.
- Explain which approval, re-review and merge steps are waiting for comment review in MR details.

- Rank the five highest-cost MRs within the Agent Usage date range and show each MR’s all-time tracked cost, preserving account identity and explicitly unattributed historical records.
- Quote and link the exact feedback comment behind a decision; save precise ignored suggestions with confirmation, a conditional Details list, Restore and Reset, and current-context prompts for verifiers and coding agents.
- Offer independent per-MR automatic publication, merge and approval opt-outs, with ready-only checkpoints and fresh automatic resumption when restored to Auto.
- Keep merged/closed completion updates in Inbox until Seen, independently of banners, and automatically remove finished MRs from the board.

- Track MR lifecycle changes independently of coding automation, announce merged, closed and Draft/Ready transitions, and retain completion feedback until Seen independently of automatic lane cleanup.
- Mark your own Draft merge requests ready from their card, menu and Details, with fresh account, ownership and revision checks.
- Add Auto/Always on/Always off per-MR automation and a migrated default-on Draft pause; track paused Drafts, retain ordinary manual actions, and hide automation controls when all automatic features are off.
- Apply Draft policy across agent checks, feedback, publication, CI and conflicts, retain pending events while paused, and keep Draft/Ready changes from overriding forced choices. Drafts still never merge automatically.

- Add a simple per-MR Automation switch and repository-default toggles, preserving inherited scope and existing action permissions.
- Avoid spinner churn during cached background checks while retaining factual status text and showing startup, explicit global and per-MR refresh progress without weakening action freshness checks.
- Keep cards at normal opacity and mute only titles/statuses according to the selected lower-section grouping.

- Compare app-owned coding-agent and verification usage in a dedicated Settings tab, with persistent USD estimates, daily averages/history, hourly through monthly Codex/Claude bars and precise hover details; retain reported tokens and explicit unknown or partial runs.

- Return unsupported app-created reply claims to the configured coding agent for a bounded correction, followed by independent verification and the existing publication policy.

- Refresh tracked GitLab data from MR menus and Details, with shared card actions and pinning available in Details.

- Show one combined MR dependency row with open prerequisites and verified linear-stack positions on Mac and iOS, retaining marked last-known data when reads fail.
- Acknowledge explicitly verified purely informational review threads with an idempotent thumbs-up and resolve them under the accepted-feedback automation setting, without courtesy replies.

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

- Group automation permissions into preparation, publication, delivery and completion, keeping existing choices and saved legacy handlers available in Advanced.

- Default feedback, draft-claim and AI-assistance verification to High reasoning for Codex and Claude, with a shared Low, Medium or High setting independent of coding reasoning.

- Identify rejected prepared replies by their exact text and source discussion, with a direct review action and expandable technical evidence.

- Separate plain-language attention explanations from technical verifier evidence, keep diagnostics collapsed in Details, and use readable fallbacks for older cached results.

- Name current automation stages on MR cards and in Details, distinguish queued agents from running work, and show merge dependencies below status.

- Give empty lanes a centered icon and clear title, distinguish first-load placeholders from empty lists, and mute board titles/statuses according to the selected lower section.

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

- Put the requested version in local release archives and report incomplete publication as a failure when workflow verification cannot finish after a tag push.

- Require explicit automation consent before automatic GitLab writes or worker push/resolution grants, including fresh and legacy installations after a manual review; keep manual actions available.

- Keep feedback launch failures tied to their account and checked discussion context, and distinguish an admitted task from a rejected preflight without replaying earlier work.

- Keep private MR checkpoints bound to their checked source while showing newer catalog metadata consistently on Mac and phone.

- Keep workflow history linked to the current retry, show worker outcomes directly from their execution records, and label unavailable records without repeating uncertain work.

- Keep newer MR catalog facts when comments or review state update, bind retained action evidence to its checked context and account revision, and prevent background presentation checks from admitting retained-only rows to automation.

- Preserve unreadable settings and action journals, report persistence failures without resetting saved policy, and pause automatic writes until safety records are recovered; keep read-only checks and fresh manual actions available within their required evidence boundaries.

- Keep the workflow paused after drafts are handled in GitLab or deleted in the app, until comment review is explicitly finished. Successful publication can complete the checkpoint after checking the reviewed context and remaining drafts.
- Include pending and unavailable draft checks in automatic merge readiness, and keep existing paired phones compatible with the new comment actions.

- Keep app-hosted tests invisible and separate from production monitoring, notifications and remote access; refuse development relaunches while another app or test host is running instead of stopping it or forcing an extra copy.

- Distinguish later deployment approvals from unfinished MR corrections, and retire obsolete blocked feedback attention only with fresh proof for the exact run while preserving genuine verification failures and execution history.
- Keep AI and source-author publication checks tied to the latest incoming exchange after your own clarification replies, while retaining checks for every new contributor.

- Reassess completed author follow-ups before handing residual work to a person; distinguish observed defects from suggested remedies and allow one proof-bound, scoped reconciliation of concrete omitted work with a durable retry budget.

- Reconcile stopped feedback follow-ups against current remote evidence without replaying them, retiring obsolete retry prompts and unfinished-work blockers while retaining execution history and live merge checks.

- Skip courtesy reactions on unclear comment purposes and automatically generated artifact-status reports, including those posted from regular GitLab accounts.

- Correlate review summaries with answered findings across threads without requiring duplicate replies, while preserving outstanding conditions and reviewer consent.

- Keep courtesy thumbs-ups for human feedback, including AI-assisted comments, while skipping generic bot and automated workflow reports; concrete bot review feedback remains eligible without affecting safe thread closure.

- Preserve pending verifier decisions across restarts and defer automatic publication during active agent work without discarding unrelated reply evidence.

- Show verified, addressed change requests as waiting for the reviewer, preserving GitLab's merge restrictions.

- Recover transient read-only assessment and preflight failures with bounded retries, retain completed semantic decisions through transport errors, and reconcile uncertain approval responses without duplicate submissions.

- Keep each MR’s last confirmed attention state, explanation and priority during read-only refreshes; show progress separately until a new result is confirmed.

- Recheck known reply drafts after a failed follow-up was superseded by its recorded successful manual retry, retaining fresh claim verification and publication filters.

- Reconcile obsolete pipeline failures against current GitLab status and refresh stale retries without suggesting an unrelated CLI problem.

- Automatically reverify existing app-created reply drafts after a new MR commit, bind successful checks to the current source, and publish only replies allowed by the current publication policy.
- Keep normal branching MR stacks free of ambiguity warnings while retaining their merge prerequisites.

- Let both headless coding agents recover required installed local runtimes before treating a stopped service as a blocker, with bounded readiness checks and unchanged GitLab permissions.

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
