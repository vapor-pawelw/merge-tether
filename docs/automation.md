# Automation and permissions

Everything on this page is optional. Without it, MergeTether is a plain GitLab to-do inbox. With it, MergeTether hands the routine parts of the merge request process to your assistant (Codex or Claude) and stops only where other people are involved.

- [How a merge request moves through MergeTether](#how-a-merge-request-moves-through-mergetether)
- [The recommended package](#the-recommended-package)
- [The human checkpoint](#the-human-checkpoint)
- [Automatic approval](#automatic-approval)
- [Assistants: Codex and Claude](#assistants-codex-and-claude)
- [What each action may do](#what-each-action-may-do)
- [What the assistant sees](#what-the-assistant-sees)
- [Coordinating pipeline work with another session](#coordinating-pipeline-work-with-another-session)

## How a merge request moves through MergeTether

**When you are the reviewer**

1. A review request lands in your to-dos. The assistant reviews the MR and saves its findings as private GitLab drafts.
2. The drafts wait in **Inbox**. Preview them, then **Publish comments**, or edit them in GitLab.
3. New commits or new author replies after your comments trigger re-review in the same chat. The first poll establishes a baseline; each new reply is dispatched once, including across app restarts.
4. With **Resolve my verified findings during re-review** on (the recommended default), the assistant checks each earlier concern against the current remote head. It resolves only threads whose first non-system note belongs to you, after verifying the fix. Unaddressed or uncertain findings stay open with private draft replies. Turning this option off leaves all discussion resolution to you.
5. Once the assistant has no objections to the current commit and every discussion is resolved, MergeTether approves it.

**When you are the author**

1. Review feedback arrives. The assistant implements warranted fixes in an isolated worktree, tests, commits and pushes them when follow-up push is enabled. A detached worktree protects other local checkouts; it still permits an authorized remote source-branch push.
2. Before saving completion drafts, the assistant re-fetches the MR HEAD and verifies the actual remote source/test content. If follow-up push is off, pending or failed, that run's result stays in chat and no completion drafts are saved. After remote verification, replies wait in **Inbox** or qualify for your chosen publication rule.
3. MergeTether requests a re-review from the reviewers whose comments were addressed.
4. Failed pipelines and conflicts become assistant tasks. Pipeline fixes wait for your handoff confirmation.
5. When every merge check passes, MergeTether can merge the MR for you (off by default).

Each merge request gets one assistant chat that collects everything handled for it.

## The recommended package

The recommended package watches failed pipelines, new commits after review, new review discussions, merge blocker changes, merged stack dependencies and overdue reviews. The first poll establishes a baseline. Each rule can be turned off, previewed in Workflow Activity, set to notify, or set to prepare an assistant result. Project, target branch and label filters control where a rule applies. The package also handles review requests, feedback and conflicts, and requests re-review when an assistant follow-up has been addressed and all drafts are published. Settings let you restore the recommended defaults for the selected assistant.

Assistant tasks are saved locally before they are handed to the desktop. Codex preparation actions wait in the queue. With the listener enabled, it dispatches them into Codex. **Open draft in Codex** opens a projectless draft for manual preparation without the listener. **Open Claude** fills a Code draft in Claude Desktop. Send a manual draft in the assistant to create the chat. **Copy prompt** includes the available review evidence.

For native Codex dispatch, choose **Install MergeTether Plugin** in onboarding or **Settings → Automation**. MergeTether detects an existing installation so it does not install a second copy. The installer configures the local queue relay path. The bundled plugin uses Python 3 from Xcode or the macOS Command Line Tools.

In MergeTether, enable **Use a Codex listener for automatic GUI chats**, then choose **Open Setup Chat** from **Inbox**. Send the prepared message in Codex and confirm the proposed local schedule. The plugin checks the local queue every five minutes and places new chats in a sidebar section named `[MT] <repository>` when Codex makes its sidebar tools available. Sections are created on demand. The **MergeTether** section holds the listener. With reuse enabled, it appends related events to the same chat without changing its location. Review and follow-up chats use local glab to save private GitLab drafts. Verified follow-up fixes on your own MRs are committed from an isolated worktree and pushed to the source branch. Jobs wait while Codex is closed, and its tool permissions still apply. If a long-lived listener loses its MCP connection, it can use the installed relay’s JSON-RPC subprocess transport; chats still use native desktop tools, and uncertain claims are never retried.

MergeTether warns in the menu bar if Codex is closed, the plugin has never checked the queue, or its last check is over 15 minutes old. A handoff that remains unconfirmed for over 15 minutes also raises a warning. If you already use the copied-prompt listener, disable its schedule before migrating; the old listener does not report health.

## The human checkpoint

**Settings → Automation → Assistant → Human checkpoint**

- **Publish comments without confirmation** (off by default). When off, drafts wait in **Inbox**, except replies covered by the AI-feedback rule below. When on, MergeTether publishes drafts once they stop changing between two refreshes, then carries on with the MR. This also publishes your own pending drafts on MRs the assistant worked on, because GitLab cannot tell them apart.
- **Automatically publish replies to AI feedback** (on by default, including migration; a prior AI-package opt-out is preserved). Applies to managed MRs with assistant activity. Verified GitLab Duo feedback qualifies directly. Feedback posted by humans requires a very-high-confidence assessment from the assistant, with concrete evidence tied to the source comment ID and exact body hash. This is a heuristic, not proof of AI authorship; uncertain comments remain drafts. Editing the source invalidates the assessment. A new human follow-up in the same discussion needs its own assessment. Only individual replies are published; unrelated comments remain pending. Automatic publication, including publish-all, leaves drafts containing slash commands or discussion resolution for manual review. Publishing all comments overrides this narrower option. The setting also applies to your own replies on MRs the assistant worked on: GitLab cannot identify which assistant wrote a draft.
- Before publishing, MergeTether fetches the drafts again. If they changed since you looked, nothing is sent.
- Use **Publish comments** on the Inbox card to publish the displayed review and immediately remove its draft blocker. If you publish in GitLab instead, the open Inbox checks pending drafts every five seconds (plus request time), without waiting for the full polling interval. Other blockers keep the MR visible. Publication immediately rechecks eligibility for automatic re-review.

## Remote proof for author follow-ups

**Push verified follow-up fixes to my MR branches** is on by default, independently
of conflict-push permission. Turning it off is preserved across restarts. The
assistant package opt-out also turns it off. This default sequence is supplied by
MergeTether itself; installed MR skills are not required.

The worker checks `author_follow_up_status` at the start and immediately before
pushing, so changing the permission or replacing the run stops remote changes.
Only explicit author-follow-up runs carry this permission; legacy, review and
conflict handoffs cannot inherit it. Before drafting, it calls `verify_author_follow_up` with its exact run ID,
tested/pushed commit and SHA-256 hashes of committed source/test files. The local
verifier reads the authenticated user, owned MR, source branch and remote files.
Only after success may the worker save/refetch response drafts, then seal their
IDs and exact body hashes with `record_author_follow_up_drafts`. A preflight token
is one-use; unchanged legacy or user-created drafts cannot be adopted automatically.
Previously sealed drafts from the same run can be re-bound after fresh verification
when a later stacked fix changes the remote head.
Both assistants can use the bundled read-only `author_follow_up.py` helper when
their current session has not loaded the updated plugin tools.

Automatic publishers verify the account, latest run, current follow-up permission,
source branch, remote HEAD, file content and draft body again. New runs, edits,
head changes, missing evidence and local-only corrections keep replies private,
even with publish-all or AI-only publication enabled. Inbox explains when
remote verification is missing. Explicit manual publication remains available;
existing drafts are never deleted or rewritten by the gate. Review-only drafts
on other authors' MRs retain their existing publication rules.

The verifier proves the selected committed file content reached the checked
remote revision. Selecting sufficient files, running meaningful tests and matching
reply claims to that content remain the assistant's responsibility. GitLab does
not offer a conditional draft-publication endpoint, so another push/edit after the
last check remains a small race window; checks are repeated immediately before sending.

## What belongs in Inbox

The menu-bar count includes GitLab to-dos plus additional actions requiring you, with the same reason counted once. An unrelated to-do on an MR does not hide pending publication or ownership confirmation. Routine delivery history does not increase the count.

Unmanaged MRs have an **Add to managed** action. Inbox filters reasons, not
entire MRs: an enabled assistant workflow hides the reasons it handles while
manual publication, pipeline ownership confirmation, failed tasks and uncertain
re-review results remain visible. Conflicts are hidden only on managed, open,
non-draft MRs you author when conflict tasks are enabled. Pipeline and feedback
rules respect repository, target branch and label filters. The original reasons
are retained; pausing an MR or disabling the relevant rule reveals them again
without waiting for another GitLab poll. Merge Requests still shows the MR's status.

Review verdicts include a fingerprint of the discussion text. New or edited
comments require a fresh review even at the same commit; resolving an unchanged
discussion alone does not invalidate a finished review.

Merge Requests is a status browser: **Own** includes all your open MRs regardless of automation scope; **Reviewed** includes managed open MRs by other authors. Both offer existing assistant chat links. Proposed actions stay in Inbox. Add MR in Reviewed accepts a URL, or a number with an explicitly selected repository; adding it enables that MR under current automation settings.

Manage global scope, repository and MR overrides in **Settings → Automation → Scope**. These changes save immediately; other automation pages use **Apply Changes**. Paused, unavailable and closed MR overrides remain editable there. Merged MRs leave the active lists without archiving their assistant chats. History records delivery separately from execution: a confirmed GUI delivery is not a completion signal.

## Automatic approval

**Settings → Automation → Assistant → Human checkpoint → Approve automatically** (on by default). MergeTether approves a merge request you review only when all of these hold:

- the assistant recorded a **no objections** verdict for the MR's current commit,
- you have no pending drafts on it,
- every discussion is resolved, including other reviewers',
- you have not approved yet, and the MR is in your automation scope.

MergeTether checks this on every refresh, so an MR is approved as soon as someone else's thread gets resolved. Approval is pinned to the checked commit, so GitLab refuses it if new commits arrived in the meantime. Turn it off for a single merge request with the **Approve automatically** checkbox in **Merge Requests → Reviewed** (or **Settings → Automation → Scope**); that MR then shows an **Approve** button in **Inbox** instead. Publishing the assistant's own drafts doesn't invalidate its verdict, but a new comment from anyone else does. If GitLab refuses an automatic approval, MergeTether stops retrying that commit and shows the **Approve** button.

## Assistants: Codex and Claude

| | Codex Desktop | Claude Desktop |
|---|---|---|
| Plugin | **Install MergeTether Plugin** in onboarding or Settings | **Claude Code plugin → Install** in Settings |
| Delivering tasks | Automatic, through a listener chat that checks the queue every five minutes | You press **Send** on the first draft for an MR; later events reopen that session with the prompt copied |
| One chat per MR | Yes, grouped in `[MT] <repository>` sidebar sections | Yes, the session links itself to its MR |
| Review verdicts and MR reads | Plugin tools | Plugin tools |

Both plugins share a small local relay and use Python 3 from Xcode or the macOS Command Line Tools. Assistant tasks are saved locally before they are handed to the desktop, and they wait while the desktop app is closed.

**Codex listener.** Enable **Use a Codex listener for automatic GUI chats**, then choose **Open Setup Chat** from **Inbox**. Send the prepared message in Codex and confirm the proposed local schedule. MergeTether warns in the menu bar if Codex is closed, the plugin has never checked the queue, or its last check is over 15 minutes old. A handoff that remains unconfirmed for over 15 minutes also raises a warning. If you already use the copied-prompt listener, disable its schedule before migrating; the old listener does not report health.

**Claude.** Claude Desktop does not let other apps send a prompt on your behalf, so the first event for an MR opens a prefilled draft. When you send it, the session links itself to the MR, and later events for that MR reopen the same session with the prompt on the clipboard.

## What each action may do

| Action | Recommended behavior | What to consider when granting more access |
| --- | --- | --- |
| Review and feedback | Saves warranted comments as private GitLab drafts. Follow-ups on your own MR can commit and push verified fixes. | The assistant follows the applicable MR skill and uses your existing GitLab and Git permissions. |
| Stack follow-up | Prepares a plan when a parent MR merges. | The task reports the proposed target and changes to the stack. |
| Pipeline failure | Shows the latest failed pipeline and asks for handoff when ownership is unverified. Full CI traces stay out of the preparation prompt. | A retry consumes CI resources and can rerun deployment steps. The optional retry requires a listed project, a handoff, and verification of a failed runner-infrastructure job on the current MR head. |
| Conflict | The recommended package turns conflict tasks on; otherwise they are off. Preparation asks the assistant to suggest a resolution. | A source-branch push requires a separate toggle, tool access and a matching project. The assistant follows your configured permissions. A request to stop dispatching future tasks cannot revoke tools from a task already running. |
| Merge | Auto-merge is off. | It requires a listed project, your own MR, required approvals, resolved discussions enforced by GitLab, a green pipeline when one exists, and the checked source SHA. If configured tools or scripts can act on the project, or a conflict task was started on the MR, auto-merge also requires a verified approval-reset policy. |
| To-do acknowledgement and shell | Manual actions mark the to-do done when the action succeeds. The recommended assistant package also marks automatic to-dos done after delivery. | Scripts require listed projects and run with the macOS account's permissions. Unfinished attempts are recorded before dispatch to avoid rerunning an action after a restart. |
| Publication, approval and discussion resolution | Drafts wait in **Inbox**, except replies covered by the default AI-feedback publication rule. Approval happens automatically only after a no-objections verdict for the current commit, with no pending drafts and every discussion resolved. Requesting changes and resolving someone else's discussion are never automated. | **Publish comments without confirmation** sends drafts once they settle. Turn off automatic approval globally, or per MR in **Merge Requests → Reviewed**. The installed MR skill governs resolution of your own review discussions. |

## What the assistant sees

In preparation mode the selected assistant receives bounded GitLab diff and discussion excerpts after common credential patterns are removed. These filters do not identify every possible secret. Use project filters for code that can be shared with your selected AI provider. Workflow Activity stores recent metadata and preparation results locally. An entry prepared for the desktop means it is in the local assistant queue. The listener receipt confirms GUI chat dispatch, and a completed retry confirms GitLab accepted the retry. It does not establish that CI passed.

## Coordinating pipeline work with another session

A manually started Claude or Codex task can reserve the MR before attempting a fix by creating the same local directory atomically. Replace the host, GitLab project ID and MR IID with the actual values.

```sh
claim="$HOME/Library/Application Support/com.vaporpw.GitLabTodos/Pipeline Work/host-gitlab.example.org/project-123/mr-456/active"
mkdir -p "$(dirname "$claim")"
mkdir "$claim" || exit 1
# Keep the reservation until this task finishes.
rmdir "$claim"
```

Remove only a reservation created by the current task. The app recognizes cooperative reservations and keeps a separate receipt for each pipeline it hands off. Arbitrary assistant chats do not reliably expose which pipeline they are fixing. When a reservation is absent, Workflow Activity asks you to confirm the handoff. Interrupted runs may leave a reservation. Check the associated session before clearing it.

## Complete instructions and Codex approvals

The relay saves each claimed task’s complete prompt in an immutable local snapshot.
New and reused chats receive a short bootstrap with the file path and SHA-256, so
a dispatcher does not need to reconstruct a long prompt. The worker checks the
hash before following the full instructions; snapshots survive receipt cleanup.

Codex execution permissions are separate from MergeTether’s workflow switches.
The native chat-creation tool currently has no permission-mode argument. A
listener running without a sandbox, or a permissive CLI config, does not prove
that a new delegated chat inherits that mode. If Codex creates a chat in Ask for
approval, select the desired mode in that chat. MergeTether does not silently
change Codex’s private settings or replace a waiting chat to avoid its approvals.

## Verified Codex template (beta)

Codex can start delegated `create_thread` chats in a restricted runtime even when
its UI and saved defaults say Full access. The template route uses a clean native
GUI chat and `fork_thread` in the same directory for new MRs. It does not modify
Codex permission settings or grant access through the relay. Setup verifies the
selected effective runtime with a harmless read-only probe before recording the
native template ID. This is an experimental workaround, not a guarantee across
Codex updates; existing restricted chats keep their actual permissions.

Use **Settings → Automation → Assistant → Use a verified permission template for
new Codex chats (beta)** to opt out. Existing MR chats are reused without being
forked, moved or replaced. The template stays idle and contains no MR work.
A confirmed delivery remains distinct from successful execution.

A fresh listener heartbeat and an unconfirmed task delivery are separate states.
A claim whose delivery is uncertain is retained for inspection, never retried
blindly. The queue returns a short hash-bound instruction reference, so large
prompts are not lost through command-output truncation.

The native template registration is write-once: changing or repairing it requires **Reset template** in MergeTether settings. Reset removes only template routing metadata; it does not alter chat permissions or queued work. Every ordinary dispatch gets a separate scratch directory; source changes still use an isolated Git worktree.
