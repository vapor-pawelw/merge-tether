# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Bring review reasons closer to **Review required** on merge request cards on Mac, iPhone, and iPad.

- Show progress under the Comments heading in Mac merge request Details when comments first load or you refresh them.

- Align thread disclosure controls with the first row of status badges and match the side insets in Comments and replies on Mac.

- Recheck apparent discussion blockers on your MRs against the individual GitLab merge request when the discussion read confirms all threads are resolved.

- Ask Agent checks GitLab status and discussions before answering a question that names an MR number. Select and copy text across paragraphs and links in chat messages.

- Classify published comments below their text on Mac, iPhone and iPad. **Written with AI?** offers **Yes**, **No** and **Uncertain**. Comments that match MergeTether's original text show a **Created with MergeTether** badge. A compact **Auto-publishing** menu in each thread offers **Default**, **On** and **Off** for the AI publication rule.

- Hide the empty **Next step** panel in Mac merge request Details when no decision is available, including while waiting on open review threads.

- Trace MR activity from the Mac Event log and ask the agent about earlier events. See comment text, the people involved and links to the GitLab notes. Hover over a person's name for their profile.

## 2.0.0 - 2026-11-27


- The macOS 2.0.0 build is signed ad hoc. If macOS blocks the first launch, open **System Settings → Privacy & Security** and choose **Open Anyway** for MergeTether. [Apple's first-launch instructions](https://support.apple.com/en-us/102445)

- Prevent merge request Details from freezing while scrolling through discussions on Mac.

- See why a review is offered or running on the board and in merge request Details, including new commits, changed discussions and review requests.

- Stop the Mac **Launch at login** setting from switching itself on and off after macOS rejects a change, and keep it in sync with System Settings. Show comments published from a confirmation without waiting for the next refresh, keep draft controls attached to the right draft, and reduce redraws on the Mac board and on iPhone and iPad.

- Show linked issues as a repository name and number when the repository differs from the merge request's. Hover over the label on Mac or tap it on iPhone and iPad to see the full repository path.
- Resolve issue references from the merge request text through GitLab when they have no saved URL. Click the issue on Mac or choose **Open in GitLab** on iPhone or iPad.

- See assignees next to the author on merge request cards and in Details on Mac, iPhone, and iPad. Open the assignee count for the complete list.

- Show all open GitLab discussions in completed review summaries, with separate counts for your account and other authors.

- Keep replies to resolved GitLab threads private when publishing from MergeTether, and have review agents check whether later changes already address a comment before drafting a reply.

- Add a separate automatic publication permission for corrections in other reviewers’ threads, enabled by default only in Max.

- Turn merge request automation on or off with one switch in Mac Settings and onboarding. Choose Safe, Trusted or Max when it is on. Turning it off keeps your configuration for next time.

- Show auto-merge, auto-approve, and auto-publish defaults first in Mac automation preset summaries, with a note on customizing them.

- Show when MergeTether is checking a claim and when the assignment was confirmed. Refresh the assigned MR's feedback immediately when the current automation rules allow it.

- Remove **Start conversation with…** from merge request menus on iPhone and iPad.

- Find phone pairing and **Regenerate all drafts** in the Mac toolbar’s **More Actions** menu. A badge on the menu marks drafts ready to review.

- Place the merge request description label above its box on Mac, iPhone and iPad.

- Reduce SwiftUI layout work while scrolling the Mac and iOS boards, and give Mac automation headings distinct identities.

- Show Mac merge request statuses, blockers and next actions on paired iPhones and iPads, including claiming an assignment, stopping an agent run, publishing checked drafts, and merging.

- Align cards with lane headers and keep scroll bars beside them on the Mac board.

- Make **Claim merge request** the primary card action on Mac, iPhone and iPad when a claim is required. Stack and center groups of card actions on iPhone and iPad, and align the automation and Actions icons with the repository row.

- Use the installed automation guide to answer questions about MergeTether controls available in the current build.

- Open agent chat in a larger sheet with the active verification model and reasoning level. Show timeouts separately and retry the original question when a reply fails.

- Let per-MR On qualify an MR for auto-approval or auto-merge while keeping readiness requirements, including the configured approval threshold and readiness criteria from the active prompt.
- Remove obsolete handler completion controls from Automation settings.

- Keep reviewer feedback and discussion blockers visible when a completed assessment cannot be matched to the merge request’s current title and description.

- Let a new push reopen re-review eligibility after an older unconfirmed request, while still preventing duplicates on the first verified commit.

- Keep merge request automation preferences and write safeguards when you rename your GitLab account.
- Preserve successful agent transcripts after signing in again, and keep comment verdicts, hidden reviews, and approval state separate when a GitLab username changes owners.

- Auto-reply to comments based on style only after you confirm two AI comments from the same author and have marked none human. See author-trust publications in the MR Event log and manage trust in publication settings.
- Use **Reply (AI)** or **It's human** on unconfirmed reply drafts in Mac, iPhone and iPad Details.

- Organize Mac automation settings by task, with checkboxes, visible pause and permission states, and a clear distinction between immediate and pending changes.

- Ask the configured agent about merge request status, automation decisions and how MergeTether works from the Mac toolbar. The read-only conversation can use the event log and public source for context.

- Use verifier prompts for automatic approval and merge. The Event log records each decision and its reason.
- Claim assigned merge requests from Needs Attention before automation starts. Outside Max, this confirmation is enabled by default and automatic merge is limited to merge requests you authored.

- Show Play for active automation and Pause for suspended automation on the Mac and companion app.

- Keep hidden merge requests across restarts, closure and merge while you remain assigned as a reviewer. Restore open reviews at any time or leave the review in GitLab.
- Reclaim reproducible worker checkouts after one day for successful runs and seven days for other completed runs, including on open merge requests. Keep local changes, checkpoints and unsuccessful run logs available for recovery.
- Queue agent work based on free disk space on the Mac and show disk waits and failures on paired iPhones and iPads.
- Stop agent runs when required workspace directories disappear, record possible GitLab effects before retrying, and cap persistent worker output.

- Use assignees to determine which MRs are yours, falling back to the author when nobody is assigned. Author follow-ups check the remote branch and discussions immediately before pushing or drafting to avoid duplicating another assignee's work.
- Apply the same ownership rule in agent instructions for follow-up pushes. Give retried follow-ups access to prior worktrees so the agent can reuse local commits and uncommitted changes.
- Allow automatic merging of MRs with other assignees by default in Max. Other profiles leave this choice off. Change it separately under **Merge when ready**.

- Show **Review needed** again when new commits or a different target diff make your GitLab approval stale, including after restarting MergeTether.

- Restore hidden merge requests from a collapsed **Hidden** section under **Reviewing** on Mac, iPhone, and iPad. Hidden cards use the same dimming as drafts and offer GitLab and review actions from **Actions**, right-click, or touch and hold. The board shows counts beside lane and **Automation off** titles, with lane filters on the right.

- Limit older successful transcripts and read-only review history after an MR merges or stays closed for 30 days. Active runs and records used for automation remain available.

- Match Mac card actions on iPhone and iPad when drafts need review or unresolved feedback blocks a merge.

- Choose whether to send crash reports during setup or in Settings on Mac, iPhone and iPad. Reporting is off by default and is available in builds configured for Sentry.
- Show crash reporting as a dismissible card above the board on iPhone and iPad. Open the gear in the top-right corner for relay details, pairing, reconnecting, draft regeneration and crash reporting.

- Show why MergeTether started a re-review below the agent status on Mac board cards and in MR Details, and in the review update's Event log entry.

- Size the ChatGPT and Claude action icons to fit native menus, including **Run review**.

- Option-click a Mac board or Inbox card to open it in GitLab. The card menus show the gesture next to Open in GitLab.

- Keep review thread statuses and their waiting messages closer together on Mac cards.

- Choose **Leave review** next to **Hide** on Mac or iPhone to remove yourself from the reviewers in GitLab. The card leaves Reviewing and returns if you are assigned again.

- Launch MergeTether 2.0.0, a complete rebuild of GitLabTodos with a merge request board, automation, and a companion app for iPhone and iPad. The launch notes are available on GitHub.

- Show **(you)** next to your name in merge request statuses on Mac, iPhone and iPad.

- Update MergeTether from the Mac toolbar or **Settings → General**. Keep working while the update is prepared, restart when it is ready, and see what changed after relaunch.

- Apply coding agent changes from **Settings → Agent** with **Apply Changes**. A note under the picker explains when automation starts using the selected agent. Choose Codex or Claude, with recommended models for each role and an option to show all supported models.

- Add GPT-6.2 Sol and GPT-6.2 Astra in **Settings → Agent**. GPT-6.2 Sol is the default ChatGPT coding model when no choice has been saved.

- Restore hidden reviews for three days while they are open. Add an expired open review again with **+**, which now explains when an MR is already merged or closed.

- Keep completed reviews compact on Mac and iOS once the required approvals, including yours, are in place. Reviewing cards show missing approvals and discussions that block merge.

- Remember **Don't ask again** when hiding a merge request from the Reviewing menu on Mac.

- Show smaller ChatGPT and Claude glyphs on AI actions and activity on Mac and iOS. The ChatGPT provider uses Codex CLI.

- Match the ChatGPT and Claude icons in the Agent settings tab to the size of neighboring icons.

- Keep verification progress visible in Mac MR Details while **Verify feedback again** checks reviewer feedback.

- Turn verifier discovery of work items and Jira links on or off in **Settings → Merge requests**. It is on by default.

- Show GitLab and MergeTether events together in iPhone MR Details. Open the matching discussion from a comment event.

- Mark all read in the iPhone Inbox or acknowledge a standalone GitLab to-do from its card. Draft merge requests keep their draft styling when the paired Mac uses Polish.

- Show the author follow-up stage, the cause that needs attention, and the relevant verification or retry action in Mac and iPhone MR Details. Expand the step to see the original comments and diagnostics, including after a worker stops.

- Align Agent Usage cards, filters and cost rows, and let longer dashboard text wrap.

- Filter each board column by attention, pins and activity section on Mac, iPhone and iPad. Reviewing also supports new assignments. Combine choices through the filter icon in each column header.

- See new review assignments and mark them as seen on a paired iPhone or iPad. Restore hidden assignments from the board menu, including after dismissing their Inbox notices.

- Keep automatic review hides in Inbox until you mark them as seen or restore the merge request. Turn off future Inbox updates for autohides in filter settings.

- Filter incoming review requests with plain-language instructions and the configured lightweight verifier. The empty filter field shows examples for keeping and hiding requests. Unavailable or uncertain assessments let the merge request through with a note. A banner shows which merge requests were hidden and offers to restore them. They also appear under **Hidden merge requests**.

- Keep replies private when draft verification cannot find required files at the current commit. Back off transient evidence reads and avoid repeating the verification agent during those retries.
- Explain known merge blockers without starting an agent, and retire diagnostic tasks when their blocker clears.
- Show why verifier requests ran and distinguish incomplete, missing and unpriced agent usage.
- Record the old and new source commits when a branch moves during an agent run. A verified push by another account invalidates the stale run without pausing the merge request.

- Use the selected preset and approval threshold for automatic approval. Refresh the review when the MR target or diff base changes.

- Authenticate locally stored AI comment assessments, overrides and review evidence. Reuse a reply worker’s verified source assessment for automatic publication.

- Cancel queued agent jobs that lose permission to run so they release the merge request.

- Open the official coding CLI installation instructions from setup.

- Require full verification before release, including an iOS simulator build and production relay tests.

- Hold automatic actions for the affected MR while retrying an unavailable agent audit. Pause that MR when the audit detects unexpected changes.

- Offer fixed reply styles for remote draft regeneration. Keep temporary iPhone interruptions connected and show the paired phone's connection status on the Mac.

- Report GitLab action failures separately from inbox sync. Acknowledging an already absent to-do clears it locally.

- Group the app used for conversations, agent models, task time limits and power settings under Agent. Find the new review placement option under Merge requests.

- Identify Mac board cards by title and repository in VoiceOver.

- Keep to-do automation receipts when one GitLab refresh temporarily omits a pending item.

- Check coding agent availability less often during background GitLab refreshes.

- Show GitLab setup, sign-in and synchronization problems in the Mac menu bar, with an action to recover.

- Preserve a command's result when it exits just as the timeout fires, and prevent an already cancelled command from starting.

- Skip author feedback follow-ups when GitLab confirms every selected thread is resolved, including when the queue resumes after a CLI limit or a run is retried. The MR action can also complete without a configured coding agent.

- Add new review requests straight to Reviewing, marked **New**, instead of the inbox (Settings → General, on by default). Turn it off to keep them in the inbox, where **Add** tracks one and **Ignore this MR** discards it; automation does not pick up inbox candidates.

- Add **Start reviewing new merge requests automatically** to the automation profile: on for Safe, Trusted and Max, off for Manual. When off, a new review waits with its automation paused until you start it from its card.

- Fix a Reviewing card stuck on "Preparing review" with a running timer after its worker was cancelled or had already finished.

- Recheck agent access one minute after a reported usage-limit reset and resume eligible work when access returns. Back off to hourly checks and offer manual retry after three unsuccessful hourly checks.

- Recognize agent usage limits and sign-in problems from the CLIs' structured status instead of wording alone: Claude's API status, and Codex's account and rate-limit endpoints when a Codex run fails with an unrecognized message.

- Keep the Mac toolbar icon-only and add **Mark all as read** to the Inbox for standalone GitLab to-dos and finished merge request updates.

- Use **Hide** and **Restore** consistently for hidden review assignments. Explain which actions start an AI agent or run a read-only AI check when hovering over their controls.

- Combine agent configuration and usage in the **Agent** tab, reorder the settings tabs, and group startup and setup in **General**.

- Highlight new review assignments with a teal badge and a card outline on Mac. Click or tap a new review card to clear **New**. Open Details with the next click or tap, or choose **Show details** from the card menu to keep **New**. **Mark as seen** also clears the badge.

- Give merge request settings, notifications, and coding agent setup their own Mac settings tabs. Find hidden assignments in a collapsed section under Merge requests. Mark newly visible assignments on upgrade when Reviewing already contained cards.

- Keep the **Restore** button fully visible in expanded hidden merge request rows.

- Move **Run setup again** from GitLab to General settings.

- Stop asking for a review on merge requests you already approved: your current approval, given anywhere, accepts the code and discussions seen so far until the head or MR text changes.

- Edit or restore the AI comment assessment prompt in Advanced automation settings.

- Complete the Polish localization of the Mac and iPhone interfaces, including plural forms, setup, automation, and the iPhone camera permission prompt.

- Show all open GitLab reviewer assignments in Reviewing, including drafts. Mark new assignments as seen when you interact with the card, hide and restore individual assignments, and optionally require confirmation before starting a review automatically.

- Let Mac users finish setup without selecting a coding agent. Save the verified agent selection and close setup when users finish. Add the agent picker to Settings, offer setup from actions that require a CLI, and show how to resume agent work on the affected merge request. Restore Polish labels in setup and on the board.

- Simplify Swift expressions that can hit compiler type-checking limits when building the Mac or iPhone app from source.

- Add **Full review** to the Mac MR menu. Codex or Claude can review the entire current change and prepare private drafts using your existing GitLab sign-in.

- Require a task ID, a link or an explicit task label before displaying a task from MR text.
- Open or copy work-item links from the tag menu on Mac and iPhone, including on draft cards.
- Assess issue scope across the board in one background verifier request, including drafts, GitLab's related work items and references in the MR description. Refresh one MR independently and show each accepted issue once.
- Match the MR details header to board cards on Mac and iPhone, with linked tasks beside the MR number and the author, approvals and branches under the title.

- Show the tasks a merge request implements beside its number on Mac and iPhone. Open a single linked task directly or browse multiple tasks in a popover. Read closing issues from GitLab and use the configured assistant to assess external references in the MR.

- Refresh GitLab after the Mac wakes. Keep the Mac awake during active agent tasks on external power, with an option in Automation settings.

- Bind comment review completion to its account and revision across Mac, iPhone and automatic publication. Recheck comments and drafts before opening the path to re-review.

- Preselect **Safe** during automation setup so new users start with private drafts and confirm public GitLab actions.

- Pin and unpin a merge request from the Mac board card's More or context menu. Both menus show the same actions and group agent actions separately. Pinned cards show an unpin button next to automation, and selecting the card opens Details.

- Show unexpected public GitLab changes observed during an agent run in its task history.

- For ordinary merge requests, wait for running CI before automatic merge and recheck feedback before submitting. **Merge when ready** still lets you schedule the merge in GitLab.

- Keep merge request messages beside the approvals and tags when they overlap vertically, and let messages below them use the full card width. Place bottom actions below both areas on Mac and iPhone.

- Give the Mac card's More menu the same 24 pt square as the other action buttons. Center the action row vertically with the repository reference.

- Align approvals with the author at the right edge of Mac and iPhone merge request cards. Put Draft and Blocked beside the merge request number when they fit, and below approvals on narrower cards. Use about 12 pt of visible space between the repository reference, title and author.

- Add or remove reviewers from the approvals popover on Mac and iPhone. Search by name or GitLab username. Make the iPhone approvals badge more compact and keep its tap area within the badge.

- Show avatars and prioritize recently active project members in reviewer suggestions. Select several reviewers for your merge request and save them together when you close the approvals popover on Mac or iPhone.

- Add an iPhone merge request card menu for copying or opening links, pinning, refreshing and other available actions. Show pinned cards even with automatic sorting, and edit merge request and repository automation from the card's lightning button.

- Put the repository and MR number above the title and the author below it on Mac and iPhone board cards. The Blocked badge opens a popover with links to blocking MRs and shows whether each one is earlier in the stack, an explicit GitLab dependency, or both.

- Drop merge request cards above, between or below other cards on Mac and iPhone. The insertion line marks valid positions in the card's current column, automation section and pin group.

- Touch and hold anywhere on an iPhone board card, then drag it to reorder merge requests while connected to the Mac. The Mac saves moves within each automation and pin group, and the iPhone immediately displays the confirmed order.

- Configure an existing companion relay with one interactive Bash command. Local Mac and iPhone builds use the saved HTTPS URL, and the Mac privately prefills the token when pairing.

- Use 50% opacity for the author, title, repository reference, status content, background, and border of draft merge request cards on the Mac board. Give the Draft badge a subtle violet tint.

- Keep the author and repository popovers available on hover on Mac draft cards.

- Match the Mac draft merge request styling on iPhone cards, including the 50% opacity and violet Draft badge.

- Use 16 pt insets beside and below the content of Mac board merge request cards, matching the inset above the avatar.

- Swap the Mac board and merge request card background colors in light and dark modes.

- Show Refresh from GitLab and Open in GitLab as icons in the Mac merge request details header, with Open next to Copy link.

- Give the merge request description its own card in Details on Mac and iPhone.

- Hide empty Feedback verification sections and tighten spacing between merge status, actions, and comments in Mac merge request details.

- Render Markdown headings, lists, quotes, and code blocks in merge request descriptions and comments on Mac and iPhone.

- Approve or remove your approval from an MR’s approvals popover on Mac and iPhone. The removal confirmation explains that it will turn off automatic approval for that MR.

- Update the approvals badge as soon as GitLab confirms automatic approval.

- Expand or collapse **Automation off** in each Mac board column and restore that choice after restarting. The header shows the total number of merge requests and how many need attention.

- Drag Mac merge request cards from anywhere on their surface to reorder them within Automation on or Automation off on Mac. Manual ordering is the default and saves positions across launches. Cards that start needing attention move to the top of their pin group unless you turn off that preference in Settings. The iPhone board follows the Mac order on refresh.

- Highlight merge requests that need attention with a padded inline callout, give MR cards a clearer border, and bring MR titles and repository labels closer together on Mac and iPhone.

- Give the information below attention messages more room and bring action buttons closer to the rest of the merge request card.

- Explain when an interrupted review needs to run on the latest commit.

- Show how long ago an Inbox update arrived in gray beside **Seen** on Mac and iPhone. Click or tap its timestamp to switch between relative time and the full date and time.

- Use MergeTether for the macOS app, Xcode project and schemes, release downloads, and Homebrew cask. New macOS installations use the bundle identifier `com.vaporpw.MergeTether`. Local rebuilds retain the installed bundle identity and pairing.

- Prepare a standard private reply when verified feedback on your MR only needs acknowledgement. Reuse current feedback verification during re-review and after a verified reply is published.

- Copy a GitLab merge request link using the link icon beside the pin on Mac cards and in Details, with a brief confirmation.

- Show source and target branches 4 pt below the merge request title in Details on Mac and iPhone. Click or tap the description or the hint below it to switch between a three-line Markdown preview and the full description.

- Put merge status in a card and show **Verify feedback again** near the top of Details. **Comments and replies** starts expanded, and section headers toggle when clicked or tapped.

- Explain multi-step actions before running them from an MR card or Details. **Don't ask again** applies to the confirmed action.

- Start a T3 Code draft with `Regarding <MR link>,` and continue typing. ChatGPT, Claude Desktop, and terminal conversations receive only the link as MR context.

- Shorten the pending draft summary and group it with the attention message. Add more room around the repository line and distinguish card backgrounds from the Mac board in both appearances.

- Show short repository names on merge request cards and in details. Hover over the name on Mac or tap it on iPhone to see the full path.

- Fix the full repository path popover when hovering over the short name in Mac merge request details.

- Show the full repository path in the same hover popover on Mac merge request cards.

- On someone else’s merge request, draft replies in other people’s threads only to correct a verified error that matters to a technical or review decision.

- Show **Proposed solution** beside agent recommendations in drafts and published discussions on Mac and iPhone. Open the label to read the agent’s reasoning and assumptions.

- Show discussion feedback badges for concrete outcomes on Mac and iPhone.

- Show GitLab activity and MergeTether actions together in a compact **Event log** above **Details** on Mac. Comments can jump to their discussion. App actions show their source, with an **Automated** badge for autonomous actions. Move agent usage to its own section.

- Open GitLab profiles from MR people labels on Mac and iPhone. Both apps show the people a draft replies to and render MR descriptions with inline Markdown.

- Move the Mac Activity view from the board toolbar to **Window → Automation Activity** for troubleshooting across merge requests.

- Retry a failed GitLab refresh directly from the warning banner on Mac.

- On iPhone, give discussion threads distinct backgrounds, align the chevron with the tags, and reveal the full file path when you tap the filename.

- Remove the Activity and agent runs shortcut from the iPhone board action row. Run history remains available in MR Details.

- Display current standalone re-review results on discussions.

- Use 16 pt insets and section gaps on iPhone merge request cards, with 8 pt between rows within each section.

- Remove dotted underlines from tappable person names on iPhone and show review status as an icon at the end of the person's row.

- Deliver iPhone avatars on the board and in MR details through the paired Mac. The iOS app connects only to the relay for automatic data loading.

- Name the authors of open review threads and replies on Mac and iPhone. Review and feedback statuses show up to two people and count the rest. Hover or tap a name to see the person's avatar and GitLab username.

- Recover an unverified automated review once after its drafts are handled, focusing on uncovered code or active discussion changes. Surface the reason when a review still needs attention.

- Drag the sheet handle down to dismiss iPhone MR Details and refresh with the toolbar button.

- Simplify the iPhone pairing sheet and show the full relay address beneath its caption.

- Make iPhone discussion cards easier to distinguish from the section background in MR Details.

- Expand or collapse iPhone discussion threads by tapping the comment card, including the area around the chevron.

- Rebuild and relaunch the local Mac installation from a script, and build an iPhone IPA for signing with a separate command.

- Keep newly tracked merge requests on **Default** when automation adds them to the board.

- Drop the `[MT]` prefix from new agent runs and remove the old desktop automation queue, settings and chat links. Move existing CLI evidence into `Automation Evidence` on launch.

- Confirm app-wide automation changes from the Mac toolbar, with the option to skip future confirmations.

- Resume automatic merge for a new, eligible revision after GitLab confirms that a previous merge train pipeline failed.

- Highlight who still needs to resolve addressed feedback on Mac and iPhone MR cards and in Details. Hover or tap a person's name for their avatar and GitLab username.

- Use standard text colors in the person popover when a name is highlighted on an MR card.

- Keep unanswered review findings in the verdict and draft follow-ups only when a substantive incoming reply warrants an answer.

- Show approval badges in gray at zero approvals, muted orange below half of the required approvals, and muted yellow from halfway. Show green when the approval count meets or exceeds the requirement or GitLab confirms the rules are satisfied.

- Show reset approvals with a filled orange checkmark badge in the approval people list on Mac and iOS.

- Regenerate private drafts on Mac or iPhone for one comment, one MR, or all tracked MRs. Add optional instructions, compare the proposals, and save the ones you choose.

- Highlight merge train, queued auto-merge, and active merge progress below the MR title on Mac cards and in Details.

- In Mac draft review, show the surrounding code with the commented line highlighted and put the original discussion above reply drafts.

- On iPhone and Mac, show a slim loading banner in MR Details and put action progress on the button that started the work.
- Mark merged and closed updates as **Seen** directly from the iPhone Inbox. Acknowledging an update uses the Mac's saved receipt without polling GitLab.
- Reuse downloaded avatars on iPhone and show initials while a photo is unavailable.
- Within each activity group, put MRs ready for manual merge immediately below pinned cards. Cards needing attention come before MRs eligible for automatic merge.

- On iPhone, pull to refresh gets the latest data from the Mac. The board and MR Details toolbar buttons request a GitLab refresh for their respective scope.

- Show saved iPhone MR details immediately and refresh them in the background. Manual refresh shows progress while keeping the details visible.

- On Mac MR cards, show the repository name before the MR number on the line below the title.

- Show when verified feedback is waiting for a reviewer whose re-review is already pending, even if GitLab still reports requested changes. Reuse the current feedback assessment for re-review and offer a retry or a link to the outstanding comment.

- Use **Default**, **On**, and **Off** for MR automation, comment publication, auto-approval, and auto-merge on Mac. The lightning panel remembers the choices saved under **On**.
- Tint the Mac automation bolt orange when an MR uses a manual On or Off override.

- Restore the Mac main window to its last size and position on the same display after relaunch. If that display is disconnected, fit the window on the primary display.

- Show the usual approval wait on cards and in Details when a green pipeline follows a confirmed departure from the merge queue and required approvals are still missing.

- Recheck the project’s discussion policy before automatic merge. Require a current review of the MR title and description before automatic approval.
- Use the same GitLab approval rules for automatic and manual merge. This lets automation submit eligible MRs with Developer access to the project.
- Explain on MR cards and in Details when GitLab’s discussion policy holds automatic merge.
- Stop iPhone draft publication when the checked discussion has changed. Reconcile an unconfirmed re-review request when GitLab shows that the reviewer has started.
- Use verified replies in closed findings from the same review to reconcile a blocked follow-up. Resume failed-pipeline checks after temporary read failures before claiming work.

- Set auto-merge to **Default**, **On** or **Off** for an individual MR from its lightning menu. **On** overrides the global auto-merge defaults for that MR.

- Show when a merge request was automatically approved with findings still open in the approvals popover and the local automation event log.
- On iPhone and iPad, show when an MR was automatically approved with findings still open inside the approval popover and the People and Rules sheet.

- Resume verification and bounded repair of owned reply drafts when another follow-up is blocked on independent work. Recheck reply claims after writing tasks change, preserve existing rejection and Stop decisions, and keep publication waiting for current evidence.

- Show the current publication policy before starting queued Mac reviews. On iPhone, retry author feedback, draft checks, and re-review readiness independently.
- Count a verified published reply in a resolved finding toward the overview of the same review, avoiding a duplicate reply request.

- Keep the confirmed merge mode through the GitLab submission and ask for a new confirmation when the available mode changes. Show when the selected assistant may check feedback before merging.
- Bind Mac and iPhone task buttons to the exact retry or feedback work they describe. Show the effective draft publication policy before starting a review, remaining findings beside Mac approval, and the readiness decision before requesting re-review from iPhone.
- Identify individual automation opt-ins and let an MR follow its repository default. Save permission reductions without requiring assistant sign-in.

- Choose when automatic approval can proceed. The default allows minor issues. Stricter choices require no code-related issues or no issues at all. All three consider feedback from every participant and skip resolved threads, which the verifier also skips.
- Allow automatic approval when a fresh review disproves a GitLab Duo concern, even while that thread is open. Optional replies link to the evidence and state when the concern requires no change.
- Resume reviews after temporary GitLab read failures, including timeouts checking the signed-in account before a worker starts and failed reviewer or approval checks before a re-review request. Keep queued re-reviews across restarts and when the workflow queue fills. Resume re-reviews interrupted during preparation and reconnect any already saved job to its original entry.
- Resume the final comment-review check after successful automatic draft publication when a GitLab read fails. Match the saved publication evidence against the current account, merge request, discussions and draft list before closing the checkpoint.
- Schedule re-review after a completed review without findings, including when the author pushes before the next poll. Re-review when a branch returns to an earlier commit that the latest verdict no longer covers.
- Retry conflict preparation after a worker temporarily holds the merge request. Allow repair of a confirmed conflict after a GitLab merge queue disappears while preserving the merge submission checkpoint.
- Diagnose new failed jobs in the same pipeline after a confirmed infrastructure retry, with the original single-retry limit intact.

- Resume eligible failed or interrupted agent work automatically with three persisted retries and increasing delays, rechecking the current account, MR, permissions and selected CLI before every fresh run. Resume policy-cancelled reply repairs after a fresh assessment without resetting their two-attempt budget; preserve explicit Stop across profile and provider changes. Recognize current failed merge-train pipelines through verified merge content so eligible pipeline repairs reach an agent.

- Keep repair and conflict summaries for your own MRs in task history instead of creating self-review discussions. Automatic publication and reply repair require an incoming reviewer exchange on your own MR, even in publish-all mode; preserve standalone drafts for manual decisions. Complete report-only fixes without an empty draft seal. Prioritize outstanding feedback over merge readiness on Mac cards, keep human decisions accessible without an assistant, and retain recovery controls in Details.

- Assess author-feedback obligations per thread, so one reviewer's unresolved concern no longer blocks independent corrections or accepted threads. Treat verified conditional fixes according to their original scope instead of inventing a stronger external-contract requirement. Escalate genuinely essential external decisions with full context, verified facts, missing evidence, a precise question and merge impact on Mac and iPhone; keep those concerns open without repeatedly assigning them to coding workers. Refresh cached assessments under the updated policy.

- Open iPhone MR Details by tapping anywhere on a card outside its controls, and remove redundant Show details buttons. Show current approvers and the signed-in user's current or reset approval on cards and Details, matching macOS.
- Show inherited copies of the same feedback concern only once in suggestion actions and feedback lists, while preserving distinct source comments and concerns. Keep the concern readable above its short decision button.

- Pull to refresh iPhone board columns and Inbox. Automatically refresh GitLab and open Details after actions, recover stale reads without a manual Refresh board step, and preserve reads and confirmed actions across presentation-only updates. Keep Details open with the action result inline. Coalesce fast detail requests and keep unrelated board changes from invalidating an accepted action.

- Mark your own Draft MRs ready from iPhone cards and Details using the Mac's current-account and commit checks. Keep existing feedback and comment-review CTAs available, negotiate the action independently with older phones, and move Details refresh and section navigation into the toolbar with a compact title and branches inside the header.

- Rename the Mac board's Inactive section to **Automation off**, count cards needing attention in its header, and keep attention icons and explanations prominent on muted cards.

- Resume unfinished author feedback once after a fresh assessment, using the selected Codex or Claude CLI. Preserve already delivered fixes and drafts, and finish missing replies after an interrupted run instead of treating the earlier attempt as completed work.

- Make iPhone card buttons open their intended section or confirm the exact advertised action, preserving distinct primary and secondary destinations in the board and inbox.

- Show the original comment and expandable conversation beside iPhone reply drafts, and display draft reply bodies directly in their discussion threads.

- Retain discussion context when a large feedback-check input only needs its diff omitted. Name the exact omitted fields and allow a bounded ten-minute check for live evidence reads, avoiding repeated three-minute timeouts without an assessment.

- Improve macOS board and MR-detail responsiveness by reusing presentation snapshots and sanitized comment Markdown, rendering discussion threads lazily, and avoiding unchanged history serialization during settings saves.

- Keep no-findings reviews and acknowledgements informational, while retaining questions and conditions in general comments. Mark large verifier inputs as deliberately omitted and fetch live discussions instead of treating them as an empty snapshot; refresh earlier assessments under the corrected policy.

- Explain agent run failures with localized messages and recovery steps instead of internal error names such as `disabledPermission`, including saved run and automation history.

- Fix continuous iPhone toolbar updates that keep the main thread busy and make scrolling stutter, including while MR details are open.

- Keep remote message encryption, decoding and iPhone comment Markdown parsing off the UI thread.
- Show iPhone suggestion decisions with short buttons and separate descriptions, and avoid rebuilding action labels every second.

- Assess all feedback concerns together, distinguishing verified upstream corrections from justified rejections in the evidence. Show a pending draft or a reply verified to cover all required answers; informational acknowledgements do not make that reply stale.

- Show a fixed **Bot** origin badge for known automation accounts on Mac and iPhone, preserving ordinary AI/Human assessment underneath and keeping bot publication permission separate. Prevent manual comment-origin edits for bots and tighten author-row spacing.

- Add a separate permission for automatic replies to bot accounts, enabled by Trusted and Max, with fresh account checks before publication. New settings inherit the active profile on upgrade while customized and explicitly saved choices are preserved.
- Recognize explicit AI generation footers before probabilistic classification, and show the signed-in user's display name on drafts plus reliable username hints on discussion authors.

- Name Codex CLI or Claude CLI and show the matching agent or AI-check action icon during agent work, including feedback, reply and authorship assessments on Mac and iOS. Keep AI icons visible beside running-action spinners.

- Stop offering to publish a reply draft that repeats a reply already in its thread, for example when the agent saved the same reply twice. Such a draft is never published automatically or by **Publish all**, starts unchecked in MR Details, and the card asks you to delete it instead. You can still select it deliberately.
- Say what failed instead of "Couldn’t refresh status": the card and MR Details now name the check, such as "Couldn’t check reviewer comments: AI CLI unavailable" or "Couldn’t refresh merge requests from GitLab". When several checks fail, the card shows how many and lists each one with its technical cause on hover.
- Rename the "Checking feedback" status to "Checking whether reviewer comments are addressed", which is what it does on your own MRs.

- Keep MR Details open when Escape dismisses its automation panel.
- Click the lightning button on a Mac MR card or in MR Details to open an automation panel instead of switching automation straight away. It shows whether automation is on for the MR and what decides that, a **Pause for this MR** / **Turn on for this MR** button, the Auto / Always on / Always off choice, the per-MR automatic actions, the MR's automation rules and holds, and the repository default. Option-click the button to switch automation without opening the panel. Turning automation on for a Draft still asks for confirmation. The Automation menu in the card's … and context menus stays, and the duplicate Automation menu in card Details sheets is removed. iOS MR Details show the same state read-only above the automation rules, for example "Automation enabled · Decided by: Repository"; switching stays on the Mac. Older phones ignore it.
- Show unpublished drafts directly on Mac MR cards: "2 unpublished drafts · no reply published yet to Alice, Bob" names the people whose threads only have a draft reply so far, like the "Feedback addressed, waiting for…" line. iOS cards show the same line; older phones keep their current card.
- Show draft reply recipients by name with their avatar in Ready for your OK and MR Details instead of their @username. iOS draft cards name who a reply answers instead of showing its thread ID.
- Correct a comment's origin by clicking its **AI**, **AI uncertain** or **Human** badge on the Mac, or tapping it on iOS. A thread badge changes every published comment in the thread after a confirmation, and **Use automatic assessment** removes the correction. Your verdict replaces the automatic assessment, including for AI-reply publication, until the comment is edited. When a change would let automation publish drafts, a banner offers **Undo** or **Continue now** for 10 seconds before automation continues. Older phones do not receive the badge menus.
- Show the first comment of a thread like its replies on Mac and iOS: author, origin badge and a right-aligned date on one line below the thread's tags and file, instead of the badge dropping to its own line.
- Make MR cards on the Mac and iOS shorter and clearer. Merge requirements now show as a list with a lock icon, one per line: who still needs to resolve threads, how many approvals are still needed ("Needs 1 more approval" instead of repeating the badge's count), and any other blocker. Cards no longer repeat a blocker that is already in that list. MRs waiting on another MR now say "Required merge requests must merge first." instead of the generic "Merge is blocked". The comment-review chain ("Comment review › Re-review readiness › Merge checks") highlights the current step. Saved automation rules such as "Merge waits for you" moved from every card into the lightning button's tooltip; holds that stop work still show on the card. While MergeTether is working on an MR, the card hides merge and thread actions that could not be used yet. Older phones keep the single-line status.
- Tidy MR Details on the Mac and iOS the same way: the requirement list replaces the waiting sentence and its repeated lock line, saved automation rules move to the lightning button's tooltip and under Details (iOS: under Overview), and merge and thread actions are hidden while a check runs. The result of an earlier feedback check ("Could not verify feedback…" with Verify again and Settings) is hidden while a new check runs. Several queued tasks of the same kind, such as two "Feedback to address" rows, show as one row.
- Fix overlapping text when expanding Technical details in Feedback verification, and remove the empty gaps that hidden sections left in MR Details. Quoted comments and draft bodies now show their Markdown (bold, code, links) collapsed as well as expanded, on the Mac and iOS.
- Keep cards unchanged during quiet background refreshes, such as the periodic refresh or bringing the app to the front: a waiting MR keeps its requirement list instead of briefly showing "Monitoring MR". Only a refresh you start shows progress.
- Let MergeTether's agent attach optional **Extra context** to the draft replies and review findings it writes: a Markdown explanation for you with simpler wording, background on the code involved, why it matters and the trade-offs, so the GitLab comment can stay concise. Open it from the **Extra context** button beside the draft, or beside the comment after it is published, in Mac MR Details (popover) and iOS MR Details (sheet). It is stored only on your Mac and is never posted to GitLab; most comments have none. Older phones ignore it.
- Show GitLab people by name with their avatar everywhere: board cards, MR Details, approvals, discussion threads, cited comments, feedback findings and the account footer. On the Mac, hover a name to see the @username; on iOS, names are links that show the @username when tapped. Status lines such as "Awaiting confirmation from…" use names for people the MR already knows and keep the @username for others. Older phones keep showing names without avatars.
- Connect the iOS app to the Mac faster: the Mac answers from its current board instead of reading GitLab first, and reads GitLab only when you tap Refresh or its data is over two minutes old. iOS MR Details scroll more smoothly: details are matched once per update, long discussions and history load lazily, and the previous details stay visible while they are re-read.
- Stop asking for a second reply to a review overview comment (such as GitLab Duo's "I left one recommendation…") when it was posted with an inline finding you already answered. The verified reply in the finding's thread now covers the overview. Standalone general comments and separate findings still need their own reply.
- Label your comments published from MergeTether-generated drafts as **AI · MergeTether** in MR Details instead of **AI uncertain**. Replies in diff threads were never matched to their published comment; they now are, and comments already published from recorded drafts are linked when Details next loads. Merged and closed MRs drop this local record, and records untouched for 180 days are removed.
- Add MR controls to iOS details: publish a single draft comment, run an agent review, stop a running agent, and ignore or restore an author-feedback suggestion. Drafts with quick actions or thread resolution still need the Mac. Older phones do not receive the new actions.
- Show your own approval on MRs you review: the approvals badge adds your avatar with a check when you approved, or an orange reset mark when your earlier approval no longer counts (for example after a push), and the approvers popover lists you first. Your own MRs are unchanged.
- Show each MR explanation once on iOS: the card no longer repeats the merge blocker as both explanation and status, Actions no longer repeat the header text, and policy lines already stated on the card are hidden. iOS MR Details now follow the Mac order: decisions and actions first, then policy, feedback and discussions, with approvals, overview, history and usage below.
- Mark merge request actions by effect: sparkles for agent runs, a magnifying sparkle for read-only AI checks and a bolt when automation resumes, with the same icons on matching Settings. Hovering an action explains what runs now and what may follow.
- Show agent usage split by Codex CLI and Claude CLI on the usage dashboard, in the MR cost ranking, and in Mac and iOS MR Details, so usage stays attributable after switching agents.
- Keep worker permissions (follow-up push, conflict push, tool access, resolving your own verified review threads) for jobs you start yourself, also with the Manual preset or with automation switched off. Switching to Manual no longer clears them, and they stay editable in Manual. Automatic publication, approval and merge still require automation.
- Review each comment and each review pass once: later author-feedback checks may cite earlier comments but raise no new concerns about ones already assessed, re-reviews of others' MRs cover only code changed since the reviewed head and new or edited notes, and a rebase that keeps the MR's changes neither repeats the feedback check nor reopens the code review. A hidden "Reset review state and recheck everything" action at the bottom of Details runs a full check from scratch.
- Check author feedback less often: an unchanged, settled merge request is not re-read on every refresh until its head, discussions, drafts, approvals, jobs or settings change (or ten minutes pass), and verified assessments survive app restarts, the global automation switch and settings that do not affect the verifier.
- Add a global automation switch next to Add and Refresh that stops all automatic work app-wide without changing presets, per-MR choices or how MRs look, with a top banner to turn it back on and confirmation banners for the global and per-MR lightning toggles.
- Choose the coding model and reasoning effort for Claude CLI workers in Settings, as already available for Codex.

- Identify bot authors independently of AI-assisted text, resolve their verified and answered feedback under the existing automation gates, and name the human authors whose threads still await resolution.
- Add a local bot-account list scoped to the GitLab host and signed-in account, with reversible stable-ID declarations and separate bot badges on Mac and iOS.

- Preserve author-feedback cooldown identity and keep its three-attempt retry budget from multiplying inside provider verification or queued refreshes.

- Improve MR card and Details hierarchy with readable status labels, policy pills and feedback citations above action controls.

- Add Copy link to merge request menus on cards, in Details and in Inbox.
- Limit re-review requests to currently assigned GitLab reviewers and recheck membership before sending.
- Derive reviewer and approval waiting summaries consistently for MR cards, Mac Details and iOS from current feedback and approval evidence.
- Respect reviewer participation opt-outs and explicit account-scoped exclusions from automatic replies and review invitations without waiving unrelated code feedback.
- Authenticate resumable follow-up assessments before reusing them as semantic evidence for signed publication proofs.
- Update message and thread AI-origin labels in open iOS Details after assessments complete, without reloading discussions or renewing action permissions.
- Keep feedback recovery available alongside other merge blockers and explain which open threads the resolution action checks.
- Clarify that verified review-summary coverage exempts a repeated report from a duplicate reply, while independent feedback still requires its own answer.

- Preserve each message's AI, AI uncertain or Human label in expanded threads and classify published roots and replies in viewed MR details using separate, cached display results.
- Distinguish dependency checks skipped behind earlier merge blockers from failed checks, while requiring fresh dependency evidence before submission.
- Classify review-summary purpose independently of whether its feedback is addressed, preserving verified cross-thread coverage without waiving independent requests.

- Bind automatic review approval to the current account and app-authenticated completed run, and authenticate fresh follow-up verification records before publication.
- Separate runtime storage by installation identity, retain read-only legacy history and recover only provably stopped, precisely owned pipeline reservations.
- Configure coding-worker time limits with exact repository overrides while retaining the 30-minute default.
- Flag potential quick actions and thread resolution in manual draft previews, and explain inactive CI retry permissions without changing saved choices.
- Put thread, feedback, reply and AI-origin status together above file/date metadata, avoid repeated expanded author headers and show source-to-target branches near the Details summary on Mac and iOS.

- Put automation profiles above their editable permissions, fill controls immediately on selection, recognize matching presets and remember the last Custom configuration for later reuse.

- Publish only the explicitly reviewed draft IDs for manual Publish all, stop publication while an agent is preparing drafts and share the final automatic-publication safety checks.
- Distinguish a successful automation-settings save from a separate safety-data hold, allowing Custom history to save without misreporting a failed write.

- Offer Manual, Safe, Trusted and Max automation profiles with clear permission summaries, enforce private-only automatic work in Safe, and preserve existing customized permissions until explicitly changed.

- Add touch-friendly iOS MR details with on-demand descriptions, metadata, approval people and rules, discussions, feedback, agent history and usage, with explicit offline and partial-data states.

- Show current feedback reply and verification obligations consistently on Mac and iPhone instead of neutral monitoring, and explain merge blockers without hiding the next review action.
- Configure a separate operator-owned relay for each native build using an external origin-only file, and reject pairing with another relay while keeping credentials out of app artifacts.

- Limit connection attempts before relay authentication, fail closed when admission checks are unavailable, and document the Workers Free boundary for avoiding usage overages.

- Avoid duplicate author replies to verified review summaries with no new requirement, and show specific feedback merge blockers with recheck or review actions.
- Show compact GitLab connection warnings with retry or targeted setup actions and expandable diagnostics, preserving the previous inbox during network failures.
- Recognize exactly recorded app-generated comments and their AI-only threads without reclassification, while keeping manual comments and publication permissions separate.

- Restore manual merge actions when GitLab's list omits permissions or pipeline details, using the matching checked MR status and explaining remaining blockers.
- Keep routine background revalidation from flashing verification warnings, distinguish missing automation consent and link directly to Automation settings.
- Simplify automation controls with explicit publication modes, preserved advanced filters and clearer independent delivery permissions.
- Show consistent AI, AI uncertain and Human badges on comments and fully classified threads; keep mixed or unclassified thread origins unstated.
- Share pending-draft polling between Board and Inbox, decode its responses off the main actor, avoid unchanged evidence updates and lazily build list rows.
- Reduce repeated discussion indexing and timestamp parsing, and give iOS cards, Details and private drafts a clearer visual hierarchy.
- Require remote cryptographic protocol v2 and a fresh pairing on both apps, with expiring invitations, device-key trust, durable command recovery and explicit phone approval confirmation.
- Use consistent 1.2.0 version metadata and separate platform artifacts, with explicit distribution signing, notarization and release verification.

- Recognize source- and target-bound merge train rebase failures even when GitLab reports a mergeable MR; show the server cause, hold repeat submissions and route separately authorized conflict preparation without losing uncertain-attempt protection.

- Give MR Details a clearer hierarchy, more readable conversation text and a grouped discussion list, with quieter section surfaces and dependency information above header actions.

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

- Choose Automation off (default) or Drafts for the lower board section, with matching ordering and title/status muting; turning all automation off temporarily uses Drafts without forgetting the saved choice.

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

- Show one board lane at narrow Mac window widths with a switch between owned and reviewed merge requests. On iPhone, make both lane names and counts visible and keep swipe navigation.

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
- Preserve the release bundle identifier, macOS 14 minimum and the previous target/cask names.
- Refresh public documentation and use the retro painted-style MergeTether icon.

### Fixed

- Use the same duplicate-filtered **Publish all** selection on Mac and iPhone, while keeping individual draft selection available.

- Refresh feedback status when a thread is resolved or reopened without rerunning its assessment. Refresh only the affected merge request after a suggestion decision from Mac or iPhone.

- Use the same verified scope for **Run review** and **Retry**. Keep pipeline diagnoses separate from code review in review history and verify that the original failed pipeline is still current before retrying a diagnosis.

- Preserve configured review constraints and pipeline diagnosis when retrying a task. Limit a review retry to discussion changes and earlier findings when a verified review already covers the current commit.

- Refresh the discussion scope when retrying a review, including when the commit stays the same. Preserve an explicit review from scratch across retries and subsequent pushes.

- Recheck that at least one required approval rule remains before submitting an automatic merge. Remember GitLab queue entries even when discussion reads fail or an earlier commit was rejected from the train, so removing a queue entry still stops automatic resubmission.

- Limit **Add and handle** acknowledgements to the selected merge request. Show feedback verification separately from a running worker and restore dispatch or retry when verification finishes.

- Bind re-review diff evidence and instructions to the commit they assessed, refresh review scope when retrying on a newer commit, and inspect changed binary diffs. Preserve review checkpoints through temporary GitLab read failures and defer new workflow events while another worker is active on that merge request.

- Stop repeating automatic pipeline preflights for failures with an existing claim receipt.

- Open draft warnings from the Mac board before publishing comments that can change a merge request or resolve a discussion.
- Show when an iPhone approval confirmation expires and let the reviewer reload the current commit before confirming again.
- Show when the inbox is unavailable and offer a retry on Mac and iPhone. Show the empty state after a successful sync.
- Show the number of assigned reviewers in parentheses on compact approval badges. Indicate pending required approvals in VoiceOver and in the Mac tooltip.

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
