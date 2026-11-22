<div align="center">

<img src="docs/images/mergetether-icon.png" alt="MergeTether app icon" width="128"/>

# MergeTether

**A native macOS command center for GitLab merge requests.**

See which reviews need you, what’s blocking your merges, and what Codex or Claude can take off your plate.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#get-started)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

</div>

## Your GitLab queue, at a glance

- **Triage in one place.** Track your own MRs and the ones you review on a single board. The inbox brings together GitLab to-dos, new MRs to track, and updates that need a look.
- **See what’s blocking a merge.** Check pipelines, approvals, open discussions, and merge dependencies, including stacked MRs, from the card. Open the MR for the discussion, private drafts, and activity history.
- **Catch the decisions that need you.** The menu bar flags work that needs your input, from a reply draft ready to publish to an automation run that needs a retry. Optional macOS notifications surface the same decisions.

The board defaults to manual ordering. Drag an MR above, between, or below cards in the same column, automation section, and pin group. On a paired iPhone, touch and hold a card to reorder it on both devices. Choose automatic ordering or turn off attention-based promotion in **Settings → General → Merge requests**.

## Get started

MergeTether runs on **macOS 14+** and uses your signed-in `glab` account. Self-managed GitLab instances are supported through the CLI’s default host.

```sh
brew install glab
glab auth login
```

This README describes the current source tree. To run it, install **Xcode 26+** and `mise`, then run these commands from the checkout.

```sh
mise install
mise exec -- tuist generate --no-open
open MergeTether.xcworkspace
```

Run the `MergeTether` scheme in Xcode. For downloadable builds, check the features listed in their release notes. [Build guide](docs/building.md) · [GitHub Releases](https://github.com/vapor-pawelw/merge-tether/releases)

The board works with `glab` alone. To delegate work, select a signed-in **Codex CLI** or **Claude CLI** during onboarding or in **Settings → Automation**.

## Delegate a review or a follow-up

- **When you’re reviewing**, the agent can review the diff, save findings as private GitLab drafts, and revisit them when new commits or replies arrive. Open the drafts alongside the original discussion and publish the comments you choose.
- **When it’s your MR**, the agent can implement and test a fix in an isolated Git worktree. If push is enabled, it checks that the expected code is on the remote branch before drafting a reply that says the fix is in. Failed pipelines and merge conflicts can also become agent tasks.

Choose a profile as a starting point, then set the scope for your repositories and individual MRs.

| Profile | What it handles |
| --- | --- |
| **Manual** | Start reviews and GitLab actions yourself. |
| **Safe** | Automate analysis and preparation, including private drafts. Public GitLab actions stay manual. |
| **Trusted** | Allow verified follow-ups and delivery, including pushes, approvals, and publication of eligible replies to AI or bot feedback. You decide when to merge. |
| **Max** | Allow eligible automatic publication and merging. Auto-merge checks the current source commit, pipeline, approvals, discussions, and dependencies. |

Agent progress, results, and failures are visible on the Mac. Permissions for publishing, approving, pushing, and merging are individually configurable. [Automation and permissions](docs/automation.md)

## How it runs

MergeTether is built with **Swift 6 and SwiftUI**. The Mac app reads and writes GitLab through `glab`, starts the selected agent CLI in the background, and keeps settings and run history locally. Agent processes have file, command, and network access. The data they read can reach the selected provider. [Agent data and access](docs/automation.md#what-the-agent-sees)

The optional **iPhone companion** mirrors the board and sends confirmed MR actions through a paired, online Mac. It requires **iOS 17+** and access to a MergeTether relay on Cloudflare. The Mac handles GitLab requests and keeps your credentials. [Companion architecture](docs/remote.md) · [Bring your own relay](docs/byo-relay.md)

If you already have a relay, run the interactive setup from your checkout before generating the Xcode project.

```sh
./scripts/setup-relay.sh
mise exec -- tuist generate --no-open
```

Enter your relay's HTTPS URL and access token. Project generation uses the saved URL for both the Mac and iPhone builds. The Mac keeps the token in private local storage and fills it in when you pair. After building, choose **Enable phone access** on the Mac and scan its QR code using the iPhone app. [Relay setup details](docs/byo-relay.md#interactive-setup-for-an-existing-relay)

## Contributing

Use the Tuist version pinned in `mise.toml` to generate the project. [Build and test guide](docs/building.md) · [Contributor notes](docs/contributing.md) · [Changelog](CHANGELOG.md)

MergeTether is [MIT-licensed](LICENSE).
