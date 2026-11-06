# Automation and permissions

MergeTether is a local MR command center. Manual GitLab management works without an AI assistant. All assistant automation requires a compatible, signed-in Codex CLI or Claude CLI; the desktop applications are optional. Tasks run headlessly, with their progress, results and failures available in the main window.

## How a merge request moves through MergeTether

**When you are the reviewer**

1. A review request arrives. The selected CLI reviews the current MR and saves warranted findings as private GitLab drafts.
2. Drafts wait on the relevant MR card. Open **Review comments**, inspect the expanded draft preview and publish the reviewed set, or edit it in GitLab.
3. New commits or author replies trigger a new re-review task. The first poll establishes a baseline; later events are deduplicated across restarts.
4. With **Resolve my verified findings during re-review** enabled, the assistant checks each concern against the current remote head and resolves only threads whose first non-system note belongs to you. Unaddressed or uncertain concerns stay open with private draft replies. Turning the option off leaves resolution to you.
5. Automatic approval requires a current no-objections verdict, no pending drafts and every discussion resolved, in addition to your automation scope and CLI readiness.

**When you are the author**

1. Review feedback arrives. The assistant implements warranted fixes in an isolated worktree, tests, commits and pushes when follow-up push is enabled. Isolation protects other local checkouts and does not prohibit an authorized remote source-branch push.
2. Before saving completion replies, the worker re-fetches the MR HEAD and verifies the remote source/test content. With push off, pending or failed, the proposal stays in the task result and no completion drafts are created.
3. Verified replies wait on the relevant MR card or qualify for the selected publication rule. MergeTether requests another review only when feedback is ready and unpublished replies no longer block it.
4. Failed pipelines and conflicts can become separate tasks. Unverified pipeline ownership requires your confirmation.
5. Automatic merge is optional and off by default. It checks ownership, scope, approvals, discussions, pipeline and the source commit.

An MR has local task history. A process reporting success does not prove that a fix reached GitLab, a review remains current or a pipeline passed.

## CLI setup and execution

Choose the provider in **Settings → Automation → Assistant**. Setup verifies the executable, supported headless options and sign-in before accepting a selection. A missing or incompatible CLI can be installed through the provider’s official installer; sign-in opens Terminal. Cancelling or failing setup keeps the previous selection.

The CLI requirement applies even when automatic re-review verification is off. Desktop installation does not establish CLI readiness. Dependency checks run independently of GitLab polling, and missing CLI/sign-in is shown in the main app. Manual publication and other explicit GitLab actions remain available.

Codex review and re-review tasks use the configured review model and reasoning setting. Other Codex tasks use the CLI’s configured model. Claude full tasks use the model configured in Claude CLI. The lightweight re-review readiness assessment has its own model setting.

The optional starting folder applies to manually opened CLI sessions. Desktop destinations receive the MR prompt without a starting folder. Automated jobs always run in isolated per-run workspaces. The project-tool permission applies to tasks that explicitly require it; other tasks can still use tools permitted by the selected CLI sandbox.

CLI execution permissions still apply. Headless execution cannot answer an interactive permission prompt; a denied action or missing dependency must remain visible as a failed or blocked task. MergeTether does not change the provider’s private settings or silently grant broader permissions.

## Task history, failure and migration

MergeTether persists task instructions and execution state locally, including output and errors. Isolated working files are kept under the app’s local Assistant Runs directory and can be revealed from the run, so interrupted or local-only fixes remain inspectable. Concurrent work for the same MR is coordinated. Before ordinary MR work starts, the worker verifies the queued GitLab account and live MR state. Closed or merged MRs do not start review/fix work; failed state checks do not become false completions.

Failed, cancelled and interrupted work stays inspectable. A deliberate retry creates another execution attempt; restarting the app does not silently replay a task that may already have changed GitLab. If a retry is needed, inspect any remote effects first.

Old GUI handoffs and links remain decodable for migration, but are not automatically replayed. Automation does not create desktop assistant chats, append messages, synchronize chat titles, install desktop plugins, monitor listener heartbeats or register permission templates. Explicit manual desktop actions remain available. Previously configured external listeners are outside the app’s control; inspect and disable those schedules separately before using headless automation for the same MRs.

The app bundles standalone proof helpers under `Contents/Resources/Automation`: `evidence.py` and `author_follow_up.py`. They read GitLab state and store local evidence without an installed plugin, MCP configuration or listener. Historical sources under `plugins/merge-tether` are retained for compatibility tests and are not packaged in the app.

## Optional manual assistant actions

An MR’s **…** menu offers the installed assistant destinations detected on the Mac, including desktop applications and CLIs, plus **Copy MR context**. Desktop actions pass the MR prompt through a deep link; if it is too long, the app copies it and opens the destination for pasting. CLI actions open Terminal with the prompt. These actions do not switch the automation provider or enable automatic desktop dispatch, and MergeTether does not manage the external conversation.

Opening an external destination is not proof that its work completed. A manual session must coordinate ownership before fixing a pipeline already being handled elsewhere. MergeTether’s remote-evidence and publication rules still apply to drafts eligible for automatic publication.

## To-dos become MR actions

To-dos are incoming events. A recognized update for an MR already on the board updates its action state and is acknowledged after that state is persisted. The card shows the resulting action, rather than a separate to-do row. The action and any running or failed agent task remain visible after the GitLab to-do disappears.

A new foreign MR is proposed in **Other items** with **Add and handle** or **Ignore this MR**. With matching enabled automation, active scope and a ready selected CLI, eligible MRs are adopted and handled automatically. Explicitly ignored or paused MRs are not silently re-adopted. Manual re-addition restores an ignored MR.

Events that cannot be classified safely remain in **Other items** for manual reading; they are never acknowledged as understood. Marking a routed event read does not prove a review finished, a fix was pushed or a draft can be published. Those outcomes keep their separate execution and remote-evidence checks.

## The recommended package

The optional recommended package watches failed pipelines, new commits after review, author replies, merge blocker changes, merged stack dependencies and overdue reviews. Configure these in **Settings → Automation → MR Events**. Choose **Off**, **Log a preview**, **Track event** or **Run with assistant CLI** for each rule. The two passive modes record activity without starting an assistant task; neither guarantees a system notification. Notifications follow the human-attention policy below. Repository, target branch and label filters constrain the rules.

The package enables follow-up push, verified resolution of your own review findings, selective AI-feedback reply publication and automatic approval. Publishing every comment, automatic merge and conflict-resolution pushes are separate settings. Opting out disables the assistant package; manual MR management remains available.

Manage global scope and repository/MR overrides in **Settings → Automation → Scope**. Scope changes save immediately. Other automation pages use **Apply Changes**, preserving scope edits made in the meantime. Paused and closed MR overrides remain editable.

## Attention and notifications

The menu-bar indicator is neutral when there is no human action waiting and amber when the board needs your attention. Running automation and read-only verification show progress; waiting only for a reviewer remains neutral. Each attention card explains the required decision and opens the relevant comments, run result or MR details. System notifications are optional and focus on new human actions; automatically handled updates do not create routine notification noise. Repeated polls do not repeat the same alert, and legacy periodic unread reminders are no longer delivered.

Use **Enable notifications** in the main window, onboarding or **Settings → General** to request macOS permission. The system prompt requires your choice. If permission was denied, use **Open System Settings**; returning to the app refreshes the displayed permission state. The app notification toggle and macOS authorization are separate controls.

## The human checkpoint

**Settings → Automation → Checkpoints** contains publication, approval and follow-up push settings.

- **Publish comments without asking me** is off by default. When enabled, the app waits until drafts stop changing across two refreshes and verifies current evidence before sending them. GitLab cannot identify which assistant created a draft, so this can include your own pending drafts on MRs the assistant worked on.
- **Automatically publish replies to AI feedback** is on by default, preserving an earlier opt-out. Verified GitLab Duo comments qualify directly. Human-posted comments require a very-high-confidence AI-origin assessment tied to the source note ID and exact body hash. This is a heuristic; uncertain cases remain private. Edited comments and new human follow-ups require new assessments.
- Automatic publication rejects slash-command lines and `resolve_discussion`. It publishes checked draft IDs individually, after another read. Unrelated or changed drafts remain private.
- **Review comments** on an MR card opens its draft preview. Explicit publication sends the previewed set only if it is unchanged. Publishing in GitLab is also supported; the board refreshes pending confirmations while it is open.

Draft readiness requires a check covering the current MR head and discussion content. New or edited comments invalidate it; resolution-only changes preserve it. Failed or missing checks leave the drafts visible with an explanation that they need review. Explicit manual publication remains available from the MR details.

## Remote proof for author follow-ups

**Let the assistant push fixes to my merge requests** is enabled by the recommended package and is independent of conflict-push permission. Turning it off is preserved across restarts. Installed MR skills can refine the work, but are not required for this sequence.

The worker runs the bundled `author_follow_up.py status` command at the start and immediately before pushing. Only an explicit author-follow-up run carries that permission; review, legacy and conflict tasks cannot inherit it. Before drafting it runs `author_follow_up.py verify` with the run ID, tested/pushed commit and an evidence file containing the assessed discussion fingerprint and SHA-256 hashes of committed source/test files. The verifier reads the authenticated user, owned MR, source branch and remote file contents.

Only after verification may the worker save/refetch reply drafts and bind their IDs and exact body hashes using `author_follow_up.py seal`. Preflight tokens are one-use. Existing user-created or legacy drafts cannot be silently adopted. A previous sealed draft can be rebound after fresh verification when a later stacked fix changes the remote head. The bundled standalone `author_follow_up.py` helper supports this evidence flow without desktop setup.

Automatic publication rechecks the account, current run, push permission, source branch, remote head, file content, discussion fingerprint and draft body. Missing or stale evidence keeps replies private even under publish-all. Existing drafts are never deleted or rewritten by this gate.

The verifier proves the selected committed files reached the remote revision. Meaningful tests, sufficient file selection and claims matching the changes remain the worker’s responsibility. GitLab has no conditional draft-publication endpoint, so a small race window remains after the final check; checks are repeated immediately before sending.

## Re-review readiness

**Settings → Automation → Assistant → Re-review verification** is on for the recommended package unless explicitly disabled. It uses an independent verification model: Luna for Codex and Haiku for Claude by default.

The verifier receives bounded, credential-filtered current diff and discussion evidence. It classifies every external non-system comment, including general comments, and returns reasons tied to note IDs. Informational summaries require no answer. A concern blocks its reviewer; unrelated feedback need not block another reviewer whose concerns are addressed. Unsupported author claims are not proof, and missing evidence stays uncertain.

These assessments support re-review requests and the accepted-feedback checks below; they never themselves authorize a GitLab write. The output schema requires one result for every external comment ID, including resolved comments, and the app independently rejects duplicates or missing evidence. Tool-free verification gets at most one retry after a provider failure or incomplete output; no MR task or remote write is replayed by this retry. Results are reused for unchanged inputs during the app session and invalidated by account, head, discussion, provider or model changes. A failure after those attempts remains visible for deliberate retry instead of running on every refresh.

When verification fails or is unavailable, the MR shows the reason and **Verify again**. If no other feedback or draft blocker is known, **Confirm readiness and request re-review** allows explicit manual confirmation. That confirmation binds the displayed head/discussion content; the app rechecks the live account, scope, MR state and drafts before notifying reviewers. With automatic verification off, manual confirmation remains available, but other assistant automation still requires a signed-in CLI.

## Accepted feedback on your own merge requests

**Settings → Automation → Checkpoints → Resolve addressed feedback after reviewer acceptance** defaults to on for new and migrated settings. Explicitly disabling it is preserved. It applies only to your own open, non-draft MRs within the enabled automation scope and requires the signed-in selected CLI.

This switch controls automatic thread resolution. Turning it off still permits semantic verification and configured author follow-ups; it does not remove the feedback check required for automatic merge.

The verifier checks the current diff and every external comment, including general comments and conditions in other threads. A reviewer's current approval is consent to close their verified addressed threads; it is never proof that their requests were fulfilled. An advance approval such as “approved, but still do X” remains blocked until the request is implemented or substantively answered with a justified explanation. Warranted work enters the configured author-follow-up workflow, with its existing push and publication permissions.

A later explicit acceptance comment by the same reviewer can also provide consent. It may be a general summary covering several findings. The verifier must tie it to the current code and concerns; the app checks the cited note's author and chronology. Generic thanks, another person's approval, stale acceptance and account-specific exceptions do not qualify. Every actionable participant in a thread must be satisfied, and missing evidence prevents resolution.

Before each resolution the app rechecks the live account, owned MR, source head, entire discussion text, current approvals, drafts, settings and scope. Pending replies must be published first. The MR detail shows remaining corrections or explanations, unpublished replies, verification failures and reviewers whose acceptance is missing. A reviewer who has already accepted is not asked to review the same unchanged feedback again.

Each automatic follow-up attempt records the reviewer note ID and content revision separately from visible job history. An assistant reply, new commit or cleared history alone cannot replay that attempt; edited or new reviewer feedback can start new work, and explicit manual retries remain available. Large sets are handled in bounded batches. Stale live evidence triggers a fresh poll; actual verification/API failures remain visible for deliberate retry rather than automatically repeating uncertain remote work.

Automatic merge also requires a fresh complete semantic assessment when external feedback exists. A remaining condition in a general comment blocks it even when GitLab's approval rules are satisfied and every resolvable thread is closed. Turning off thread resolution does not bypass this merge check.

## Automatic approval

**Approve merge requests automatically** is enabled by the recommended package. Approval requires:

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
| Conflict resolution | Prepare a resolution. A push requires its separate toggle, tool access and matching project. |
| Merge | Off by default. Requires a listed project, your own MR, required approvals, resolved discussions, an eligible pipeline and the checked source SHA. Configured tools/scripts or conflict work can also require a verified approval-reset policy. |
| To-do events | A recognized event is marked read only after its MR action is durably recorded and the live MR refreshed. This acknowledges the event, not the agent’s work. Unknown events remain unread in Other. Explicitly ignored MR events are acknowledged without running a task. |
| Legacy shell rules | Retained for reference and compatibility. They do not run automatically or get replaced by an AI task. Choose the selected assistant CLI in Settings to migrate the handler. |

Saving automation policy or scope changes synchronizes proof permissions immediately. Scope changes cancel only automatic work for targets that are now inactive, preserving unrelated and manually started work. Other automation policy changes cancel active app-owned assistant work. Historical script execution remains internally compatible, but is not an available MR automation mode. Remote actions are rechecked at their relevant boundaries; actions already accepted by GitLab cannot be undone by cancellation. Manual actions remain explicitly user initiated.

## What the assistant sees

Tasks receive bounded diff and discussion excerpts after common credential patterns are removed. These filters do not identify every secret. Scope automation to repositories you may share with the chosen provider. Settings, task history and results stay on the Mac; necessary task content is sent to the provider used by the CLI.

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
