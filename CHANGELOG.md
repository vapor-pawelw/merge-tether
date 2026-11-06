# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Open MergeTether as a regular macOS Dock application with a resizable three-column MR board, direct card actions and detailed MR views.
- Run assistant tasks headlessly through authenticated Codex CLI or Claude CLI, with local execution history, output, failure reporting and deliberate retries.
- Offer installed desktop assistants and CLIs as optional, manually selected MR destinations.
- Verify re-review readiness with independent Luna/Haiku defaults, comment-specific blockers and content-bound manual confirmation when automatic verification is off or unavailable.
- Offer CLI compatibility/sign-in checks, installation and Terminal login during assistant setup; preserve the prior selection on cancellation.
- Turn recognized GitLab to-dos into durable MR actions, acknowledge routed events, and keep unknown events or new-MR proposals in Other. Support explicit Add/Ignore and automatic adoption within enabled scope.
- Keep checked drafts, approvals, blockers and agent results on their MR cards and promote cards requiring attention.
- Browse Own and Reviewed MRs, add individual reviewed MRs by URL or repository/number, and control automatic approval per MR.
- Configure automation globally, per repository or per MR, with workflow preview, notification and execution modes.

### Changed

- Replace the menu-bar popover with the main window and remove automatic desktop chat creation, listener dispatch, chat-title synchronization, permission templates and plugin setup from the app.
- Require a working, signed-in selected CLI for assistant automation independently of the automatic re-review verification setting. Desktop applications are optional.
- Preserve legacy GUI history without automatically replaying uncertain pending work. Distinguish agent completion from verified GitLab effects.
- Keep assistant task results and user decisions in MergeTether; allow manual GitLab operations without an AI dependency.
- Keep follow-up push permission separate from conflict pushes. Verify the current account, remote head, committed file contents, discussion text and exact draft bodies before automatically publishing author-follow-up replies.
- Re-review author replies even without a new commit. Resolve only your own findings after verification when enabled.
- Publish eligible replies to verified GitLab Duo feedback or very-high-confidence AI comments selectively; keep uncertain replies private and reject automatic quick actions.
- Request another review only after relevant feedback is addressed and unpublished replies no longer block it. Bind manual confirmation to current content.
- Organize automation settings by checkpoints, assistant, scope and workflow; save scope immediately without later assistant changes overwriting it.
- Preserve the release bundle identifier, macOS 14 minimum and legacy GitLabTodos target/cask names.
- Refresh public documentation and use the retro painted-style MergeTether icon.

### Fixed

- Keep draft confirmations outside Ready when the current MR head or discussion content has not been checked. Refresh visible Inbox confirmations without waiting for the regular poll.
- Invalidate review verdicts after new or edited discussion text, while retaining them for resolution-only changes.
- Keep previous MR catalogs and clickable Inbox content when a GitLab source fails.
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
