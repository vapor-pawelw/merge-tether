# Automation and permissions

MergeTether is a local MR command center. Manual GitLab management works without a coding agent. All agent automation requires a compatible, signed-in Codex CLI or Claude CLI; the desktop applications are optional. Tasks run headlessly, with their progress, results and failures available in the main window.

## How a merge request moves through MergeTether

**When you are the reviewer**

1. A review request arrives. The selected CLI reviews the current MR and saves warranted findings as private GitLab drafts.
2. Drafts wait on the relevant MR card. Open **Review and confirm** to read the complete discussion and private drafts, then publish the reviewed set or edit it in GitLab. Publication can also run automatically under the selected profile and publication mode.
3. New commits or author replies trigger a new re-review task. The first poll establishes a baseline; later events are deduplicated across restarts.
4. With **Resolve my verified findings during re-review** enabled, the agent checks each concern against the current remote head and resolves only threads whose first non-system note belongs to you. Unaddressed or uncertain concerns stay open with private draft replies. Turning the option off leaves resolution to you.
5. Automatic approval requires a current no-objections verdict, no pending drafts and every discussion resolved, in addition to your automation scope and CLI readiness.

**When you are the author**

1. Review feedback arrives. The agent implements warranted fixes in an isolated worktree, tests, commits and pushes when follow-up push is enabled. It is instructed to keep work inside its run directory and leave other checkouts alone; this is a workflow rule, not a filesystem sandbox.
2. Before saving completion replies, the worker re-fetches the MR HEAD and verifies the remote source/test content. With push off, pending or failed, the proposal stays in the task result and no completion drafts are created.
3. Verified replies wait on the relevant MR card or qualify for the selected publication rule. MergeTether requests another review only when feedback is ready and unpublished replies no longer block it.
4. Failed pipelines and conflicts can become separate tasks. Unverified pipeline ownership requires your confirmation.
5. Automatic merge is enabled by Full automation and disabled by the other profiles. It checks ownership, scope, approvals, discussions, pipeline and the source commit.

Reviewing cards show the MR author by display name (hover for the account handle), the review-request source when known, and participation in your review threads. Historical replies in resolved threads do not count as pending work. Each card explains the next step and offers an action where needed; queued reviews and verification show automatic progress, while waits on other reviewers remain neutral. Without a recorded request source they say **Tracked for review**; missing discussion data is shown honestly rather than implying a first review. Proposals show the MR author and originating event.

When a current-head review verdict no longer covers the discussion text, the workflow can recheck it once for that evidence context, including after a restart. This uses the existing review-update rule and respects its execution mode and scope. Known published private drafts do not invalidate their own review, and resolution-only updates do not trigger another attempt. Once a fresh review covers the discussions, later text changes can start a new attempt even if they restore an earlier comment body. Automatic approval still requires the current verdict and all existing discussion and policy checks.

**Review and confirm** includes complete discussion threads and inline private drafts. An **AI** badge indicates a verified agent identity or a high-confidence assessment bound to the current note and its content. No badge does not prove manual authorship; the badge does not authorize publication or resolution.

An MR has local task history. A process reporting success does not prove that a fix reached GitLab, a review remains current or a pipeline passed.

## CLI setup and execution

Choose the provider in **Settings → Automation → Agent**. Setup verifies the executable, supported headless options and sign-in before accepting a selection. A missing or incompatible CLI can be installed through the provider’s official installer; sign-in opens Terminal. Cancelling or failing setup keeps the previous selection.

The CLI requirement applies even when automatic re-review verification is off. Desktop installation does not establish CLI readiness. Dependency checks run independently of GitLab polling, and missing CLI/sign-in is shown in the main app. Manual publication and other explicit GitLab actions remain available.

Codex review and re-review tasks use the configured review model and reasoning setting. Other Codex tasks use the CLI’s configured model. Claude full tasks use the model configured in Claude CLI. The lightweight re-review readiness assessment has its own model setting.

The optional starting folder applies to manually opened CLI sessions. Desktop destinations receive the MR prompt without a starting folder. Automated workers start in separate per-run directories and are instructed to keep clones and worktrees there. They have full read, write, command and network access, without a CLI filesystem sandbox or interactive approval prompts. The additional project-task setting controls which configured tasks may run; it does not grant or restrict the worker’s tools.

Full tool access does not change the task’s GitLab authorization. Publication, approval, merge, thread resolution, author-follow-up push and conflict push keep their separate instructions and live app/helper checks. Missing dependencies or failed commands remain visible as failed or blocked work. The separate lightweight re-review verifier has full CLI tool access with a read-only task: it can fetch live MR evidence through `glab`, but does not publish, resolve, push or merge. The app performs those actions under their configured policies.

## Task history, failure and migration

Each MR has one collapsible **Automation event log** in its details. It combines numbered worker attempts, workflow events and persisted application decisions with exact timestamps. A gear icon identifies automatic activity; hover for its meaning. Expand an event for its blocker, error and evidence identifiers, or open the linked run for its recorded prompt, response, transcript and run actions. A successful worker can still have a later application rejection; both results remain visible. Application events are bounded to 100 per MR and 1,000 total, and are scoped to the signed-in account.

A feedback follow-up that finds no remaining work can complete without creating duplicate replies only after an independent, current-content assessment verifies the selected notes and required published responses. While a verification of the exact current content is running, the follow-up stays neutral. Its completion immediately reconciles the intent without waiting for a global refresh. Older observations cannot overwrite a replacement attempt. This does not waive the proof required to publish new drafts.

MergeTether persists task instructions and execution state locally, including output and errors. Isolated working files are kept under the app’s local `Assistant Runs` directory and can be revealed from the run, so interrupted or local-only fixes remain inspectable. Concurrent work for the same MR is coordinated. Before ordinary MR work starts, the worker verifies the queued GitLab account and live MR state. Closed or merged MRs do not start review/fix work; failed state checks do not become false completions.

Failed, cancelled and interrupted work stays inspectable. A deliberate retry creates another execution attempt; restarting the app does not silently replay a task that may already have changed GitLab. If a retry is needed, inspect any remote effects first.

Old GUI handoffs and links remain decodable for migration, but are not automatically replayed. Automation does not create desktop agent chats, append messages, synchronize chat titles, install desktop plugins, monitor listener heartbeats or register permission templates. Explicit manual desktop actions remain available. Previously configured external listeners are outside the app’s control; inspect and disable those schedules separately before using headless automation for the same MRs.

The app bundles standalone proof helpers under `Contents/Resources/Automation`: `evidence.py` and `author_follow_up.py`. They read GitLab state and store local evidence without an installed plugin, MCP configuration or listener. Historical sources under `plugins/merge-tether` are retained for compatibility tests and are not packaged in the app.

## Optional manual agent actions

An MR’s **… → Start a conversation with an agent…** menu offers the installed destinations detected on the Mac, including desktop applications and CLIs, plus **Copy MR context**. Desktop actions pass the MR prompt through a deep link; if it is too long, the app copies it and opens the destination for pasting. CLI actions open Terminal with the prompt. These actions do not switch the automation provider or enable automatic desktop dispatch, and MergeTether does not manage the external conversation.

Opening an external destination is not proof that its work completed. A manual session must coordinate ownership before fixing a pipeline already being handled elsewhere. MergeTether’s remote-evidence and publication rules still apply to drafts eligible for automatic publication.

## To-dos become MR actions

To-dos are incoming events. A recognized update for an MR already on the board updates its action state and is acknowledged after that state is persisted. The card shows the resulting action, rather than a separate to-do row. The action and any running or failed agent task remain visible after the GitLab to-do disappears.

A new foreign MR is proposed in **Other items** with **Add and handle** or **Ignore this MR**. With matching enabled automation, active scope and a ready selected CLI, eligible MRs are adopted and handled automatically. Explicitly ignored or paused MRs are not silently re-adopted. Manual re-addition restores an ignored MR.

A submitted review is handled by its event type and live MR evidence, regardless of the reviewer identity. Open threads on your MR enter the configured follow-up action. General reviewer comments are assessed by the shared semantic verifier before it starts warranted follow-up work; informational summaries do not require code changes. Reviews with no open threads refresh the durable MR state. A failed evidence read leaves the event unread.

Events that cannot be classified safely remain in **Other items** for manual reading; they are never acknowledged as understood. Marking a routed event read does not prove a review finished, a fix was pushed or a draft can be published. Those outcomes keep their separate execution and remote-evidence checks.

## Automation profiles

Choose a profile in **Settings → Automation → Profile & permissions**, then adjust individual permissions. Choosing a profile is explicit; the app preserves existing settings across upgrades. New automation setup offers **Full automation**.

| Profile | Automatic preparation | Publication and delivery |
| --- | --- | --- |
| **Full automation** | Review, re-review, feedback verification, pipeline and conflict work, and follow-up fixes. | Publish eligible comments, approve, resolve verified findings, push author fixes and conflict resolutions, and merge eligible owned MRs within active scope. |
| **With checkpoints** | Review, re-review, verification and local proposals. | Eligible replies to AI feedback can publish automatically; other comments wait for confirmation. Automatic approval, thread resolution, follow-up/conflict push and merge are off; you deliver proposals and choose remote actions. |
| **Manual only** | Automatic task rules and verification are off. | Automatic publication, approval, resolution, pushes and merge are off. Explicit **Run review** and manual GitLab actions remain available. |

Waiting for review never creates a comment or a draft. After the configured waiting period, the rule can track a local event or stay off. Older settings that ran an agent for this event are migrated to local tracking; queued reminder jobs are retired.

**Automatically publish all comments** is on by default in Full automation. It bypasses the optional automation filters. With it off, automatic publication uses the AI-reply option and selected repository/author conditions; nonmatching comments remain drafts. With checkpoints enables AI replies by default; Manual only disables automatic publication. Checked-content, account and remote-evidence checks still apply. Existing saved custom choices are preserved.

Automatic re-review in With checkpoints can continue after you deliver fixes or publish the pending replies. Local preparation is not evidence that a proposal reached the remote branch.

MR event rules watch failed pipelines, new commits after review, author replies, merge blocker changes, merged stack dependencies and overdue reviews. Configure these in **Settings → Automation → MR Events**. Choose **Off**, **Log a preview**, **Track event** or **Run with agent CLI** for each rule. The two passive modes record activity without starting an agent task; notifications follow the human-attention policy below. Repository, target branch and label filters constrain event rules.

Scope is always required. Empty additional project lists mean all repositories permitted by the active scope; nonempty lists restrict the corresponding tool tasks, conflict pushes or automatic merges to exact repository paths.

Manage global scope and repository/MR overrides in **Settings → Automation → Scope**. Scope changes save immediately. Other automation pages use **Apply Changes**, preserving scope edits made in the meantime. Paused and closed MR overrides remain editable.

## Attention and notifications

The menu-bar indicator is neutral when there is no human action waiting and amber when the board needs your attention. Running automation and read-only verification show progress; waiting only for a reviewer remains neutral. Each attention card explains the required decision and opens the relevant comments, run result or MR details. System notifications are optional and focus on new human actions; automatically handled updates do not create routine notification noise. Repeated polls do not repeat the same alert, and legacy periodic unread reminders are no longer delivered.

**Settings → General → In-app event banners** controls brief banners for automatically accepted GitLab events. This is enabled by default for new and existing installations, while an explicit opt-out is preserved. Banners identify the received update, expire automatically and do not repeat on polling or acknowledgement retries. They contain repository/MR context without the review body; the durable action stays on the MR card. This setting is independent of macOS notifications.

Use **Enable notifications** in the main window, onboarding or **Settings → General** to request macOS permission. The system prompt requires your choice. If permission was denied, use **Open System Settings**; returning to the app refreshes the displayed permission state. The app notification toggle and macOS authorization are separate controls.

## The human checkpoint

**Settings → Automation → Profile & permissions** contains the **Comment publication** selector plus separate approval, push and thread-resolution permissions.

- **All eligible comments** is selected by Full automation. In this mode, the app waits until drafts stop changing across two refreshes and verifies current evidence before sending them. GitLab cannot identify which agent created a draft, so this can include your own pending drafts on MRs the agent worked on.
- **Replies to AI feedback** limits automatic publication to eligible replies to content written or substantially assisted by AI, including comments posted from a person’s account. An account name alone neither qualifies nor excludes a source. Verified GitLab Duo comments qualify directly; other sources require a high-confidence assessment tied to the source note ID and exact body hash. This is a probabilistic judgment based on text and discussion context. Missing assessments mean unclassified, rather than human-authored. Likely manual, unassessed and uncertain sources keep their replies private. Edited comments and later follow-ups require their own assessments.
- **Private drafts only** leaves comments private until you explicitly publish them.
- Automatic publication rejects slash-command lines and `resolve_discussion`. It publishes checked draft IDs individually, after another read. Unrelated or changed drafts remain private.
- **Review and confirm** on an MR card opens its discussions and draft preview. Checkboxes select exact draft versions for **Publish selected**; **Publish all comments** remains available. Selection starts empty, never includes newly arriving drafts, and is cleared for edited or removed drafts. The selected action stays available at the bottom while browsing long threads. Only selected IDs are published, individually, after current-account and body checks. Changes to unrelated drafts do not enlarge the selected set. These explicit manual actions work without the agent CLI or automation and bypass automatic publication filters. Explicit publication sends the previewed set only if it is unchanged. Publishing in GitLab is also supported; the board refreshes pending confirmations while it is open.

When an AI condition applies, the configured lightweight verification model proactively assesses current source comments that lack a matching result, including while reply drafts or remote verification are pending. It considers text and discussion context, regardless of the posting account, and treats comment instructions as untrusted data. Only a high-confidence AI-assisted assessment can qualify a source; likely manual or uncertain results leave its replies private. Oversized or unavailable text remains uncertain. The app re-fetches current source bodies before saving assessments and reuses unchanged results. Failed and uncertain checks are cached by source body, provider, model and criteria version to avoid repeating them on every refresh. Assessment does not publish anything or relax scope, draft-content or remote-evidence checks.

The content heuristic combines precise references across code locations or detailed implementation-to-test reasoning with consistent code quoting, author-written line references, polished language and repeated review structure. Em dashes, sentence-ending periods and other punctuation are weak supporting cues and never sufficient alone. Repository knowledge is not evidence of manual authorship. Multiple corroborating signals without meaningful counterevidence can support `ai_assisted` at `high`; `very_high` is also accepted. A likely manual or uncertain classification never qualifies, regardless of its confidence label. Automatic diff anchors are not author-written line references. These are workflow heuristics, not verified authorship or universal probabilities.

Assessments record their criteria version. After a criteria change, older nonqualifying results are assessed again once under the current provider/model; unchanged current results remain cached. Current qualifying content-bound evidence is retained. This does not change publication mode, scope, remote-fix proofs or other publication checks.

### Optional publication conditions

Expand **Publication filters** in Profile & permissions to restrict repositories, MR authors, source-comment authors or require verified/high-confidence AI-assisted feedback. **All eligible comments** ignores these filters. In conditional modes, all active conditions must match (AND). Within an author or repository list, any selected identity qualifies; an empty list adds no restriction. Explicit manual **Publish all** bypasses automation filters. Active scope and the other execution and publication checks still apply to automatic actions.

Repository and user entries are verified through GitLab and stored as host plus stable project/user IDs; their labels are display text. Source-comment conditions check every external comment since your latest published reply in that thread. An unknown author, missing discussion evidence or a nonqualifying follow-up keeps the response private. A new finding without a source comment cannot satisfy source-author or AI conditions. AI assessments remain bound to the current source note and exact body.

The board’s automatic-publication preview and the last live check use the same policy. Changing the mode or any condition invalidates the old preview immediately. Publication still uses exact checked draft IDs and all existing draft-content, remote-proof and account checks.

Reset arrows beside the publication mode and checkpoint permissions restore only that setting using the profile you last explicitly chose. For legacy or custom settings without a known profile, the reset menu lets you choose **Full automation**, **With checkpoints** or **Manual only** defaults for that setting. Resetting one condition restores only that condition; **Reset publication filters** restores the selected profile’s filter defaults. Other permissions, scope, agent choice, custom task instructions and drafts remain as configured. **Apply Changes** saves the policy and immediately starts a fresh MR check; publication follows when the current evidence passes. These conditions apply only to automation: an explicit manual **Publish all** action ignores them.

Draft readiness requires a check covering the current MR head and discussion content. New or edited comments invalidate it; resolution-only changes preserve it. Failed or missing checks leave the drafts visible with an explanation that they need review. Explicit manual publication remains available from the MR details.

## Remote proof for author follow-ups

**Let the agent push fixes to my merge requests** is enabled by Full automation and is independent of conflict-push permission. Turning it off is preserved across restarts. Installed MR skills can refine the work, but are not required for this sequence.

The worker runs the bundled `author_follow_up.py status` command at the start and immediately before pushing. Only an explicit author-follow-up run carries that permission; review, legacy and conflict tasks cannot inherit it. Before drafting it runs `author_follow_up.py verify` with the run ID, tested/pushed commit and an evidence file containing the assessed discussion fingerprint and SHA-256 hashes of committed source/test files. The verifier reads the authenticated user, owned MR, source branch and remote file contents.

Only after verification may the worker save/refetch reply drafts and bind their IDs and exact body hashes using `author_follow_up.py seal`. Preflight tokens are one-use. Sealed receipts are archived separately per verification, so a later task cannot replace proof for earlier unpublished replies. Publication rechecks each reply against its exact known origin, current source and draft body; newer unfinished work still blocks automatic publication. Known older sealed run artifacts can be recovered, while unknown or unsealed drafts remain private. Existing user-created or legacy drafts cannot be silently adopted. A previous sealed draft can be rebound after fresh verification when a later stacked fix changes the remote head. The bundled standalone `author_follow_up.py` helper supports this evidence flow without desktop setup.

Automatic publication rechecks the account, current run, push permission, source branch, remote head, file content, discussion fingerprint and draft body. Missing or stale evidence keeps replies private even under publish-all. Existing drafts are never deleted or rewritten by this gate. These are local app/helper records accessible to a full-access worker; filesystem isolation does not make them tamper-proof.

The verifier proves the selected committed files reached the remote revision. Meaningful tests, sufficient file selection and claims matching the changes remain the worker’s responsibility. GitLab has no conditional draft-publication endpoint, so a small race window remains after the final check; checks are repeated immediately before sending.

## Re-review readiness

**Settings → Automation → Coding agent → Re-review verification** is on for Full automation and With checkpoints, and off for Manual only unless explicitly changed. It uses an independent verification model: Luna for Codex and Haiku for Claude by default.

The verifier receives the MR target, expected commit, source note IDs and semantic context, with bounded, credential-filtered title, description, diff and discussion evidence when available. It can use `glab` to read the current MR, paginated discussions, diffs and relevant files. Large inputs can use target metadata instead of failing only because inline evidence exceeds the limit. It classifies every external non-system comment, including general comments, and returns reasons tied to note IDs. Informational summaries require no answer. A concern blocks its reviewer; unrelated feedback need not block another reviewer whose concerns are addressed. Unsupported author claims are not proof, and missing evidence stays uncertain.

These assessments support re-review requests and the accepted-feedback checks below; they never themselves authorize a GitLab write. The output schema requires one result for every external comment ID, including resolved comments, and the app independently rejects duplicates or missing evidence. Tool-free verification gets at most one retry after a provider failure or incomplete output; no MR task or remote write is replayed by this retry. Results are reused for unchanged inputs during the app session and invalidated by account, head, discussion, provider or model changes. A failure after those attempts remains visible for deliberate retry instead of running on every refresh.

When verification fails or is unavailable, the MR shows the reason and **Verify again**. If no other feedback or draft blocker is known, **Confirm readiness and request re-review** allows explicit manual confirmation. That confirmation binds the displayed head/discussion content; the app rechecks the live account, scope, MR state and drafts before notifying reviewers. With automatic verification off, manual confirmation remains available, but other agent automation still requires a signed-in CLI.

## Accepted feedback on your own merge requests

**Settings → Automation → Profile & permissions → Resolve addressed feedback after reviewer acceptance** is enabled by Full automation and disabled by With checkpoints and Manual only. Existing explicit settings are preserved until a profile or permission is changed. It applies only to your own open, non-draft MRs within the enabled automation scope and requires the signed-in selected CLI.

This switch controls automatic thread resolution. Turning it off still permits semantic verification and configured author follow-ups; it does not remove the feedback check required for automatic merge.

The verifier checks the current MR title, description, diff and every external comment, including general comments and conditions in other threads. A reviewer's current approval is consent to close their verified addressed threads; it is never proof that their requests were fulfilled. An advance approval such as “approved, but still do X” remains blocked until the request is implemented or substantively answered with a justified explanation. Warranted work enters the configured author-follow-up workflow, with its existing push and publication permissions.

A later explicit acceptance comment by the same reviewer can also provide consent. It may be a general summary covering several findings. The verifier must tie it to the current code and concerns; the app checks the cited note's author and chronology. Generic thanks, another person's approval, stale acceptance and account-specific exceptions do not qualify. Every actionable participant in a thread must be satisfied, and missing evidence prevents resolution.

Before each resolution the app rechecks the live account, owned MR, source head, MR title and description, entire discussion text, current approvals, drafts, settings and scope. Pending replies must be published first. The MR detail shows remaining corrections or explanations, unpublished replies, verification failures and reviewers whose acceptance is missing. A reviewer who has already accepted is not asked to review the same unchanged feedback again. Changes to the MR title or description invalidate semantic assessments even when the source commit and comments are unchanged.

Each automatic follow-up attempt records the reviewer note ID and content revision separately from visible job history. An agent reply, new commit or cleared history alone cannot replay that attempt; edited or new reviewer feedback can start new work, and explicit manual retries remain available. Large sets are handled in bounded batches. Stale live evidence triggers a fresh poll; actual verification/API failures remain visible for deliberate retry rather than automatically repeating uncertain remote work.

Automatic merge also requires a fresh complete semantic assessment when external feedback exists. A remaining condition in a general comment blocks it even when GitLab's approval rules are satisfied and every resolvable thread is closed. Turning off thread resolution does not bypass this merge check.

## Automatic approval

**Approve merge requests automatically** is enabled by Full automation and disabled by With checkpoints and Manual only. Approval requires:

- a no-objections verdict for the current MR head and discussion content;
- no pending drafts;
- every discussion resolved, including other reviewers’;
- an open, non-draft MR you review, within automation scope, which you have not approved yet;
- the selected CLI ready for automation.

Approval is pinned to the checked source SHA. A new or edited comment invalidates the verdict; resolution-only changes preserve it. If GitLab refuses automatic approval, the app stops retrying that commit and retains the manual **Approve** action. Disable approval for an individual reviewed MR in its detail controls or automation scope settings. On someone else's MR, resolution remains limited to your own verified review findings; accepted-feedback resolution applies only when you own the MR.

## What each action may do

| Action | Default boundary |
| --- | --- |
| Review | Inspect other authors’ code and save private findings; never modify their branches. |
| Author follow-up | Isolate edits, test, commit and push only under its own follow-up permission; verify remote content before completion drafts. |
| Stack follow-up | Prepare a plan and identify the proposed target and changes. |
| Pipeline failure | Coordinate ownership before fixing. Full CI traces stay out of the preparation prompt. Infrastructure retries need a listed project, current-head evidence and a confirmed handoff. |
| Conflict resolution | Prepare a resolution. A push requires its separate toggle, the additional project-task permission and the active scope plus any configured project restriction. |
| Merge | Enabled by Full automation. Requires active scope plus any configured project restriction, your own MR, required approvals, resolved discussions, an eligible pipeline and the checked source SHA. Advanced task configurations or conflict work can also require a verified approval-reset policy. |
| To-do events | A recognized event is marked read only after its MR action is durably recorded and the live MR refreshed. This acknowledges the event, not the agent’s work. Unknown events remain unread in Other. Explicitly ignored MR events are acknowledged without running a task. |
| Legacy shell rules | Retained for reference and compatibility. They do not run automatically or get replaced by an AI task. Choose the selected agent CLI in Settings to migrate the handler. |

Saving automation policy or scope changes synchronizes proof permissions immediately. Scope changes cancel only automatic work for targets that are now inactive, preserving unrelated and manually started work. Other automation policy changes cancel active app-owned agent work. Historical script execution remains internally compatible, but is not an available MR automation mode. Remote actions are rechecked at their relevant boundaries; actions already accepted by GitLab cannot be undone by cancellation. Manual actions remain explicitly user initiated.

## What the agent sees

Prepared diff and discussion excerpts filter common credential patterns. Worker tasks can also read files and live GitLab data through their full tool access; these later reads are not covered by the preparation filter. The verifier can also read live evidence through its CLI tools; those reads share the same provider and data-sharing considerations. Scope automation to repositories you may share with the chosen provider. Settings, task history and results are stored on the Mac; task content and data read by the worker can be sent to the CLI’s provider.

## Coordinating pipeline work with another session

A manually started task can reserve an MR before attempting a fix by creating the same local directory atomically. Replace the host, project ID and MR IID:

```sh
claim="$HOME/Library/Application Support/com.vaporpw.GitLabTodos/Pipeline Work/host-gitlab.example.org/project-123/mr-456/active"
mkdir -p "$(dirname "$claim")"
mkdir "$claim" || exit 1
# Keep the reservation until this task finishes.
rmdir "$claim"
```

Remove only a reservation created by the current task. External sessions do not reliably expose which pipeline they are fixing. Unverified ownership requires confirmation. Interrupted runs can leave a reservation; inspect the associated execution before clearing it.
