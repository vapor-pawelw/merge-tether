# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed

- Verify live MR state and queued account before Codex dispatch. Skip merged/closed MR work without creating chats or false delivery receipts, retain failed checks for retry, and preserve existing-chat title updates.

- Align content and trailing controls across to-dos, Inbox cards and MR lists; remove duplicate insets from nested Inbox actions.

- Render listener reports directly from the current relay snapshot, preserving exact MR roles, links and unpublished-comment counts instead of having the model reconstruct rows.

- Avoid a SwiftUI lazy-layout loop that can freeze Merge Requests.

### Changed

- Format listener MR reports as linked tables with readable statuses and a separate queue summary. Mark draft MRs consistently with a DRAFT badge and muted title, and keep the MR tab selector stationary when Add MR appears.

- Center to-do avatars beside MR status and title, align metadata and actions to the left, and move the read checkbox to the upper-right corner.

- Add an optional verified native Codex template for new GUI chats, preserve existing MR chat identities, and isolate scratch files for every dispatch. Return compact delivery results so large instructions cannot be lost to output truncation.

- Highlight each MR's automation scope, assistant chat and delivery status with larger, bold text and colored status icons.
- Combine to-dos and actionable MR blockers in one deduplicated Inbox. Count only items requiring user attention, keeping draft MRs last and retaining distinct publication and ownership decisions.
- Replace separate MR, managed and assistant tabs with Merge Requests → Own / Reviewed, read-only status and existing Codex/Claude chat links. Add specific reviewed MRs by URL or by repository and number.
- Move scope controls and grouped delivery/workflow history into Automation settings; save scope changes immediately without overwriting them when applying assistant settings.
- Preserve MR catalogs when an individual GitLab source fails and distinguish confirmed delivery from assistant completion.
- Show comments and approvals waiting for your OK in their own group at the top of Inbox.
- Add Merge Requests → Activity, and an Approve automatically switch on each reviewed MR.
- Organize automation settings in a sidebar, starting with a Checkpoints page for the three decisions that affect other people, with shorter explanations.
- Refresh at most every 30 seconds when opening the menu or switching tabs.

- Deliver complete assistant instructions through a hash-bound local snapshot instead of relying on the listener to copy long prompts. Clarify that native Codex chat creation does not expose an execution-permission override.

- Refresh public documentation, share concise agent instructions with Claude, and add a retro painted-style app icon.

- Recover a closed Codex MCP connection through the bundled relay transport without replacing native GUI chats or retrying an uncertain claim.

- Add unmanaged MRs to automation directly from Attention. Hide only reasons covered by an enabled workflow, retain manual decisions and failures, and reveal the original reasons when scope or settings change.
- Invalidate completed review verdicts when discussion content changes, including author replies at the same commit, while retaining verdicts for resolution-only changes.

- Re-review author replies even without a new commit, with restart-safe deduplication and a separate default-on setting for resolving only your own verified review findings.

- Require current remote-head, source-file and exact draft evidence before automatically publishing author follow-up replies; add an independent follow-up push permission and keep unfinished fixes in chat.

- Identify thread participants in draft reply previews, highlight repository names across MR and to-do lists, and align wrapped Managed MR titles to the left.

- Publish replies to verified GitLab Duo feedback or very-high-confidence AI comments automatically, with a separate default-on setting, content-bound assessments and selective draft publication.
- Clear published draft blockers across Attention and MR status immediately; check for browser publication every five seconds while Attention is open and promptly resume eligible re-review requests.

- Renamed the app to MergeTether. Existing settings and Homebrew upgrades keep working.

### General

#### Features

- Show Codex Desktop and Claude Desktop detection separately from the assistant and automation selections.
- Add manual actions to supported to-dos and prevent duplicate runs when a click overlaps polling.
- Show items needing attention as compact merge request cards.
- Show item counts on the menu tabs and reopen the last used tab after a relaunch.
- Add a short Undo window (⌘Z) after marking a to-do as done.
- Show the pipeline status of authored merge requests as a colored icon.
- Show a summary in the menu footer on every tab.
- Added Ready for your OK in Attention: preview the comments and replies the assistant drafted, publish them in one click, and approve reviewed merge requests at the checked commit.
- Added an opt-in setting to publish assistant comments without confirmation. It is off by default.
- Added a MergeTether plugin for Claude Code and one Claude session per merge request: the first event opens a new Claude draft that links itself to the MR, and later events reopen that session with the prompt copied.
- Approve reviewed merge requests automatically once the assistant has no objections to the current commit and every discussion is resolved, including other reviewers'. On by default; turn it off in Settings or for a single merge request in Managed MRs.
- Make Settings a larger, resizable window and split Automation settings into Assistant, Merge Workflow, My Merge Requests and To-Dos pages.

- Added durable desktop assistant handoffs and an opt-in Codex listener for native [MT] chats and reuse per merge request.
- Added an experimental local Codex plugin with a Setup action for desktop dispatch.
- Bundle the Codex plugin and offer installation in onboarding and settings. Show a menu bar warning when the listener stops checking the queue.
- Organize new Codex chats in `[MT] <repository>` sections and reserve MergeTether for the listener.
- Reuse the same Codex chat when a merge request moves from preparation to GitLab read access.
- Save warranted review drafts in GitLab and commit and push verified follow-up fixes to the author's MR branch.
- Request re-review after an assistant follow-up when all feedback on an authored MR is addressed and private drafts are published.
- Enable new assistant workflows during upgrade for users already using AI automations.
- Separate automation presets and advanced options from everyday assistant and MR settings.
- Set the automation scope globally, by repository, or for an individual MR. Show effective choices and existing Codex chats in Managed MRs.
- Keep MR links in assistant updates and route new chats into repository sections on older relay sessions.
- After merge, ask Codex to propose an update in the existing chat when GitLab identifies one clear work item.
- Add GitLab repository and MR links directly from Managed MRs and remove merged MR overrides automatically.
- Continue to re-review when observed author drafts become published replies, even without an earlier AI handoff.
- Include open authored and review-assigned merge request status in every Codex listener run.
- Mark a GitLab to-do as done when a manually selected action succeeds, including when an assistant task is queued.
- Open the existing Codex listener chat from Automation settings.
- Apply installed MR skills before the built-in review and follow-up instructions.
- Use `(Me)` for tasks on your own merge requests and ask assistants to summarize each update.
- Mark chats for merged MRs with `[MT] [Merged]` in Codex. Archive them manually when ready.
- Show each MR's stack position in assistant task titles and refresh it in existing Codex chats when the stack changes.
- Pinned unpublished GitLab comments, merge blockers, and pending pipeline handoffs in the inbox.

- Added an opt-in assistant package with six MR workflow rules, project and branch filters, a preview mode, and Workflow Activity.
- Added exclusive CI handoff and preparation mode with assistant tools disabled. Scoped permissions cover configured tools, scripts, conflict pushes and automatic merges.

- Added opt-in automation for merge request review requests and feedback on your own merge requests. Rules cover first reviews and re-reviews. They can use the selected assistant (Codex or Claude Code) or a custom shell command, and mark the to-do done after success.
- Added My Merge Requests to the menu with pipeline status, approvals, conflicts, and other merge blockers. It uses the configurable inbox refresh interval.
- Added separate opt-in actions to merge eligible authored MRs and send conflicts to the selected assistant. Auto-merge checks required approvals and resolved threads, and submits the verified source SHA to GitLab.

#### Bug Fixes

- Opening the menu no longer brings a Settings or Setup window that was left open behind other apps to the front.
- Prevent a second MergeTether process from polling GitLab or dispatching duplicate automation.
- Kept polling active when a manual refresh overlaps startup.
- Kept unread reminders on schedule when the inbox refreshes frequently.
- Kept a stale refresh from restoring an acknowledged to-do, and restored the row if marking it done failed.
- Prevented background child processes from blocking completion of their parent command.
- Fixed GitLab CLI pagination and recognition of the approver-added event.

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
