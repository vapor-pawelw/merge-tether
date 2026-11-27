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

The board defaults to manual ordering. Drag an MR above, between, or below cards in the same column, automation section, and pin group. On a paired iPhone, touch and hold a card to reorder it on both devices. Choose automatic ordering or turn off attention-based promotion in **Settings → Merge requests**.

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

GitHub Releases and Homebrew distribute the Mac app. The public build runs the GitLab inbox on its own. For iPhone or iPad pairing, build both apps with your own relay.

The board works with `glab` alone. To run agent actions or automation, select **Codex** or **Claude** during onboarding or in **Settings → Agent** and sign in to the selected CLI.

## Delegate a review or a follow-up

- **When you’re reviewing**, the agent can review the diff, save findings as private GitLab drafts, and revisit them when new commits or replies arrive. Open the drafts alongside the original discussion and publish the comments you choose.
- **When it’s your MR**, the agent can implement and test a fix in an isolated Git worktree. If push is enabled, it checks that the expected code is on the remote branch before drafting a reply that says the fix is in. Failed pipelines and merge conflicts can also become agent tasks.

Turn on **Enable merge request automation** in Settings, choose a profile as a starting point, then set the scope for your repositories and individual MRs. You can start reviews and GitLab actions yourself with automation off.

| Profile | What it handles |
| --- | --- |
| **Safe** | Automate analysis and preparation, including private drafts. Public GitLab actions stay manual. |
| **Trusted** | Allow verified follow-ups and delivery, including pushes, approvals, and publication of eligible replies to AI or bot feedback. You decide when to merge. |
| **Max** | Allow eligible automatic publication and merging. Auto-merge checks the current source commit, pipeline, approvals, discussions, and dependencies. |

Agent progress, results, and failures are visible on the Mac. Permissions for publishing, approving, pushing, and merging are individually configurable. [Automation and permissions](docs/automation.md)

## How it runs

MergeTether is built with **Swift 6 and SwiftUI**. The Mac app reads and writes GitLab through `glab`, starts the selected agent CLI in the background, and keeps settings and run history locally. Agent processes have file, command, and network access. The data they read can reach the selected provider. [Agent data and access](docs/automation.md#what-the-agent-sees)

### iPhone and iPad companion

The companion is available in this repository for **iOS 17+**. It mirrors the board and sends confirmed MR actions through a paired, online Mac. Both apps need the same relay address. The Mac handles GitLab requests and keeps your credentials. [Companion architecture](docs/remote.md)

1. Deploy the relay to your own Cloudflare account and keep its HTTPS URL and access token. [Relay deployment guide](docs/byo-relay.md#deploy-your-instance)
2. From your checkout, run `./scripts/setup-relay.sh` and enter the URL and token. Then run `mise exec -- tuist generate --no-open` and build the `MergeTether` scheme in Xcode. The URL is embedded in both local builds. The token stays in private storage on your Mac. [Relay configuration](docs/byo-relay.md#interactive-setup-for-an-existing-relay)
3. Run `./scripts/build-ios-ipa.sh` and sign and install the IPA on your iPhone or iPad. Open your locally built Mac app, choose **Enable phone access**, and scan its QR code with the companion. [Build an iOS IPA](docs/building.md#build-an-ios-ipa) · [Pair the apps](docs/byo-relay.md#pair-and-confirm-ownership)

## Contributing

Use the Tuist version pinned in `mise.toml` to generate the project. [Build and test guide](docs/building.md) · [Contributor notes](docs/contributing.md) · [Changelog](CHANGELOG.md)

MergeTether is [MIT-licensed](LICENSE).
