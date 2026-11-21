# iOS companion MVP

The iOS target is `MergeTetheriOS` (iOS 17+). It shows the Mac's three board lanes,
using the same `TodoMonitorService.boardSnapshot` as the desktop view, including
pinned ordering, proposals and agent jobs. Managed MR cards use the Mac's shared
presentation for author, repository, attention message, status, badges and primary CTA
labels. Orange marks the same human-action state as the Mac. Read-only CTAs open card
details even when remote writes are unavailable; writes still require confirmation.
It has pairing, card details and actions;
GitLab credentials and automation settings remain on the Mac.

## Architecture decision

Direct LAN or a VPN tunnel would avoid a relay service but require inbound reachability
or a system network extension, which conflicts with the desired VPN compatibility.
A cloud database would keep the board online while the Mac sleeps, but adds identity,
persistence and reconciliation for actions that still need the Mac. The MVP uses an
opaque relay: a thin phone, a Mac adapter over the existing board/use cases, and a
shared protocol package with no GitLab dependencies. Cloud persistence can be added
later without moving GitLab credentials into the phone or Worker.

## Connection

Both apps initiate outbound HTTPS/WebSocket connections to a Cloudflare Worker.
The relay is the iOS app's only automatic network destination. The Mac handles
GitLab reads and writes and sends the resulting data through the encrypted relay.
Explicit links can open GitLab in the browser when tapped. Markdown images are
never loaded by the iOS app.
There is no system VPN, local network discovery, open inbound port or VPS. A company
proxy can still block the relay domain or WebSockets; HTTPS does not bypass an
organization's network policy. The Mac must remain awake and connected.

A SQLite Durable Object routes one host and one phone per random room. Each Mac
creates its own room, so several users can share the relay deployment. A new phone
connection replaces the previous phone for that pairing. Native clients disconnect
in the background and refresh every 25 seconds while foregrounded, renewing sooner after a slow reply
when needed to keep the host status current. The connection label remains stable
during an in-flight refresh; remote writes still require an unexpired snapshot.
These periodic and connection hellos are answered from the Mac's current board without
a GitLab read; the Mac waits at most a few seconds for a refresh already in progress and
starts a background refresh only when its data is older than two minutes. Commands still
refresh GitLab and re-check their token before any write.

After trusting a pairing, the pairing form closes as soon as it is saved, independently
of the first Mac response. The phone shows **Connecting to Mac…** for at most 45 seconds,
then **Mac unavailable** with a retry action if no fresh snapshot arrives. A detected
transport or snapshot error has its own **Connection failed** state. Saved pairing
never requires reopening the Mac's pairing window for an ordinary connection attempt;
the current Mac app starts its saved phone connection on launch. The Mac must be awake
and MergeTether running; Keychain authorization or a blocked relay can still prevent connection.

The circular toolbar arrow is **Refresh board**: it asks the Mac to read GitLab before
answering (the additive `refresh` hello field) and coalesces outstanding refreshes. **… → Reconnect** deliberately replaces
the phone transport, including its retry backoff, while keeping the saved pairing.
Reconnect is also offered directly when the Mac is unavailable, and repeated taps
coalesce while connecting. Returning from the background creates a fresh connection.
The last board for the same pairing remains visible with an offline notice, but actions
wait for a fresh authenticated snapshot. Replacing pairing clears that board and its
open details. Reconnect never repeats a GitLab command. The phone keeps its pending
command in Keychain and asks for its exact stored receipt after a fresh snapshot.
A missing or interrupted outcome stays uncertain; closing the connection cannot
cancel work already accepted by the Mac.

The Mac sends small avatar thumbnails separately from the board and MR details,
including avatars for reviewers, discussion authors and draft reply recipients.
The phone uses initials or a placeholder whenever the paired Mac has no thumbnail
to deliver. Both apps need thumbnail support.

The Mac reads saved pairing from Keychain in the background. A system permission
prompt does not prevent the main window or MR automation from starting. A late
read cannot override pairing details you edit or an explicit enable/disable action.

Native invitations and encrypted frames require protocol v2. Update both apps and
scan a fresh Mac code after upgrading from v1; v1 trust is not migrated. The opaque
relay still uses its independent `/v1/connect` and `mt-v1` transport contract, so
this native protocol change requires no Worker deployment.

The QR contains the relay address, operator invitation, a random pairing secret
and the Mac's public device key. Enrollment expires after ten minutes, checked by
the Mac. Each device keeps its own X25519 private key in Keychain. The Mac saves
the first authenticated phone key before accepting work and rejects replacement
keys; an established pairing continues after invitation expiry. Directional
DH/HKDF keys and AES-GCM authentication bind frames to the origin, protocol,
pairing session, sender and timestamp. The relay sees IP addresses, timing, room
IDs and ciphertext, but cannot read tickets or commands. Protect the QR like a
password and never publish its secrets. Generating a new code rotates device keys,
secret, room and sessions. Disabling access stops transport before deleting trust;
a Keychain deletion failure is reported and cannot promise revocation after a
restart. Already-started GitLab requests can still finish.

The relay is self-hosted: public source does not provide a shared hosted service.
Keep each operator invitation private, outside source control and application builds.
An endpoint URL is public information, not an authorization credential.

The operator invitation gates admission, not access to another user's inbox.
Sharing it broadly permits others to consume the deployment's free quota. This MVP
has no public self-service signup, account recovery or per-user quota service.
Rotate the operator invitation if it leaks; rotating only the pairing QR does not
revoke the deployment invitation. Clients then need the replacement invitation.

Before token hashing or room allocation, Cloudflare rate-limit bindings restrict
connection attempts to approximately 30 per client IP and 120 for the deployment
per minute, independently in each Cloudflare location. Missing or failing bindings
reject admission; HTTP 429/503 responses include a 60-second retry hint. Separate
production and diagnostic bindings use separate namespace IDs. Keep namespace IDs
unique within your account when deploying another instance. These limits reduce
unauthorized load but do not run before the Worker invocation and cannot guarantee
service availability or cap billing. A distributed attack can still exhaust Free
quotas. Existing per-socket message bounds are not per-user quotas and reset on
reconnect. Do not treat them as protection for a leaked invitation on a paid plan.

## Deploy on Cloudflare Free

The production Worker source and deployment configuration live in
`Services/RemoteRelay`. The diagnostic browser probe under
`prototypes/remote-relay` uses the same Worker source with a separate deployment
and static probe assets; its pinned npm tooling and integration tests cover both.

Use a Cloudflare account with Workers Free and SQLite Durable Objects Free.
Do not enable a paid subscription. Verify **Workers Free** in the Cloudflare
account dashboard; deployment configuration does not select or enforce that plan.
If the account is on Workers Paid, this relay cannot promise zero usage overages.
No shared token should be bundled into a public IPA or distributed to repository users.
Free quotas are shared across the deployment;
exhaustion interrupts service rather than guaranteeing unlimited free capacity.
The current limits and billing terms are maintained by Cloudflare:
https://developers.cloudflare.com/durable-objects/platform/pricing/
https://developers.cloudflare.com/workers/platform/limits/

From `prototypes/remote-relay`, install the pinned dependencies with `npm ci` and
sign in with `npx wrangler login`. Generate a 32-byte base64url invitation locally
and keep it in a private JSON file outside the checkout:

```json
{"RELAY_ACCESS_TOKEN":"<43-character random base64url invitation>"}
```

Deploy using:

```bash
npx wrangler deploy --config ../../Services/RemoteRelay/wrangler.jsonc \
  --secrets-file /absolute/private/path/operator.json
```

The config uses SQLite Durable Objects, no paid storage, no scheduled polling and
no request observability. The Worker is shared with the diagnostic prototype,
whose local end-to-end tests exercise the same relay code. The native relay has
no web assets or public pairing page.

On first deployment Wrangler may need to register a workers.dev subdomain. Check
the actual deployment and route if the first command reports a routing error after
uploading. A retry after registration completes may be sufficient.

On the Mac, open the phone button and enter the relay's HTTPS origin and invitation.
Click **Enable phone access**. The iOS app scans the private QR, shows the relay for confirmation, and remembers
the pairing. No GitLab or VPN configuration is needed on the phone. Each new Mac
creates a separate pairing; the relay address and operator invitation can be reused.

For the local operator, the setup can be prefilled from files outside the checkout:
`~/Library/Application Support/MergeTether/remote-relay/operator.json` and an
`origin.txt` containing only the HTTPS origin. This does not enable remote access
until the user clicks the Mac button.

## Action guarantees and limitations

Phone readiness requires an encrypted response to a fresh challenge, with a
45-second lease measured from the challenge. Previous data remains visible on a
connection failure. Initial catalog sync and GitLab errors disable writes.

The companion shows a notice when the Mac's safety data needs attention and automatic
actions are paused. Refreshing and manual checks remain available. Manual writes
still use the Mac's existing guards and required saved receipts. The notice never
grants action permission; both native clients must support protocol v2.

Commands bind a host session, authenticated account, card, action and content token.
Most commands refresh GitLab before the Mac checks the token. **Seen** in Inbox
checks and acknowledges the Mac's saved completion receipt. Approval pins the displayed commit.
Publication checks the live commit and exact remaining draft content before each
individual checked draft ID. It rejects GitLab slash commands and discussion
resolution. A server-side edit can still race the final publication HTTP request,
which GitLab does not provide with an atomic content/head precondition.

The phone never automatically retries commands. The host serializes writes and
persists admission before acceptance or side effects, then persists the result
before delivery. Its Keychain archive retains up to 512 receipts within a 1 MiB
bound for the cryptographic pairing; it never evicts receipts to admit more work.
Capacity or storage failure blocks new commands. Completed results survive host
restart; a recorded running command recovers as uncertain and is not executed
again. Acceptance extends the phone deadline to two minutes, independently of
network heartbeats. A fresh snapshot showing the same accepted draft batch
still saving extends the wait for that save.

Reconnecting, restarting or changing accounts creates a new command session and
invalidates old execution permission. An authenticated receipt query can recover
only the exact original command under the current account and pairing, with a
fresh challenge; it cannot execute anything. The phone retains its pending ID
until explicit acknowledgement successfully removes it from Keychain. Rotating
pairing keys revokes the old receipt namespace. An already-started write keeps
the host write lock until it finishes. Prepared thread-resolution IDs require a
fresh check after reconnect. Durable receipts do not promise exactly-once GitLab
effects when an external request has an uncertain outcome.

Phone approval requires an explicit confirmation of the displayed MR, account and
commit. Its single-use confirmation expires after thirty seconds and is invalid
after target, action, account, session or connection changes. This consent is not
restored by a phone restart or receipt recovery.

Supported actions include checked comment publication, SHA-bound approval,
re-review confirmation, verification, pipeline handoff, marking a raw event done,
preparing feedback, running existing MR intents and retrying stopped agent jobs.
Phones advertising `merge-actions-v1` can also merge, enqueue supported auto-merge
requests and check then confirm concrete thread-resolution IDs. These commands call
the same manual Mac executors: merge checks current account, source/target,
dependencies, semantic feedback, published replies, drafts, unfinished work and
submission receipts; resolution rechecks the confirmed IDs before each write.
Phones advertising `mr-controls-v1` can also publish one draft at a time, start an
agent review, stop a running agent job, and ignore or restore an author-feedback
suggestion. Single-draft publication uses the Mac's manual publication path; drafts with
potential quick actions or thread resolution get no phone button and stay a Mac decision.
Ignoring a suggestion rereads the discussions and requires the conversation fingerprint
the assessment was made on.
Proposals can be inspected and opened in GitLab; adoption/ignore and settings remain
on the desktop.

Full snapshot plaintext is capped at 128 KiB and the relay envelope at 256 KiB.
Oversized snapshots disable readiness instead of truncating a comment preview.
Offline state is retained in memory while the app stays open; it is not a durable
cloud copy of the inbox. The Mac remains the source of truth.

## Verification

Generate the Tuist project, build the `MergeTether` and `MergeTetheriOS` schemes,
and isolate the macOS test runner as described in [building.md](building.md).

```bash
swift test --package-path Packages/MergeTetherRemote
cd prototypes/remote-relay
npm ci
npm test
```

The native WebSocket integration test is opt-in: set `MT_RELAY_TEST_URL` to the
local Worker origin and `MT_RELAY_TEST_ACCESS` to the matching invitation. It tests
actual native peers exchanging an encrypted 100 KiB snapshot through the real
Worker. Without an origin it is skipped. Keep real invitations out of shell
history and logs. GitLab action tests use disposable local fixtures, never live
publication or approval.

To install on a physical iPhone, use an Apple Development signing team and select
the device in Xcode. A free Personal Team can be used for local development subject
to Apple's provisioning restrictions; wider App Store/TestFlight distribution has
separate Apple account requirements and is not provided by Cloudflare Free.

Debug-only UI fixtures use `--remote-preview` (synthetic board),
`--remote-preview-connecting`, `--remote-preview-offline` and `--remote-preview-failed`.
They inject an in-memory pairing/transport and never open Keychain or the network.
The board fixture delays a manually reconnected snapshot to expose reconnect progress.
`RemotePhoneModelTests` compiles the same iOS model into the isolated macOS test target;
its memory transport and clock cover lifecycle, stale callbacks, trust changes and
pending-command safety without a live relay or GitLab.

### Merge action capabilities

Within cryptographic protocol v2, `merge-actions-v1` names the independent action capability. Advertising it enables explicit merge, supported auto-merge/train requests and bounded thread-resolution previews. Host-side live guards remain authoritative. Queued and in-train results do not claim a finished merge. A v2 client without this capability receives snapshots with these action cases filtered out; native v1 pairing is unsupported.

`mr-controls-v1` follows the same rule for `publishDraft`, `runReview`, `stopJob`, `ignoreSuggestion` and `restoreSuggestion`: clients that do not advertise it never receive those cases. Actions may carry an additive `label` for per-item buttons.

`mark-ready-v1` independently enables `markReady` for your own open Draft MRs. The Mac uses the same account, ownership, source-commit and result checks as its local button. Confirmation explains that configured automation may resume. Phones without this capability receive neither the new action nor its bound CTA. Update both apps to use it; existing v2 pairing remains valid.

The `draft-regeneration-v1` capability lets the phone start and review a batch for a draft, an MR, or all tracked MRs. The paired Mac runs the configured CLI with its current local skills. Progress remains available after closing the form. Starting and saving use the existing command receipts. The phone sends extra instructions in the encrypted command and the receipt keeps their digest. Proposal bodies travel in bounded pages tied to the host session, account and batch. Previews larger than 2 MiB are available on the Mac. Older clients continue to receive the existing board.

`board-order-v1` lets the iPhone reorder the Mac's manual board. Touch and hold a card, then drag it above, between or below cards in the same column, automation section and pin group. The insertion line marks the valid position. Each move includes the source card, destination and the order of their group as seen when the drag started, identified by a digest. The Mac checks the current account, session and group before saving, then returns a snapshot for that request. If a Mac move, an attention promotion or a membership change has changed the group, the phone shows the current order and lets you try again. Moving cards uses local settings and the paired connection. Both apps need the capability and can use their existing pairing.

### Refresh and open Details

Pull down a board column or the Inbox list to get the latest data available on the Mac. The Mac's own schedule refreshes GitLab. Use the board toolbar arrow to refresh the whole GitLab board. In MR Details, use the toolbar arrow to fetch just that MR directly from GitLab, or drag the sheet handle down to dismiss. Concurrent refresh requests share one operation. A terminal result for the phone's pending action, including a recovered receipt, requests the Mac's current board with a new challenge. A pre-action heartbeat cannot satisfy that request or overwrite its response. Open Details show the result inline, so the board's result alert cannot dismiss the sheet. Actions are never replayed as part of refreshing.

An outdated Details response reconciles with the board on the Mac and retries the detail read. During an action, the read waits for its result. Recovery is bounded to two automatic board reloads per failed read sequence. Use the Details toolbar arrow to retry after a failure. Existing details stay visible during background and manual refreshes, including failed refreshes, and are never carried across account or session changes. Manual refresh shows progress. Closing Details cancels its subscription and prevents subsequent board refreshes from reopening it.

Hosts advertising `detail-cache-v1` can answer a cached Details request from the Mac's catalog and recent discussions. For a live read, `detail-preview-v1` lets the Mac send available details while it waits for GitLab. Only current details support actions that depend on the discussion data. The one-second read limit applies to live GitLab reads.

Hosts advertising `detail-context-v1` accept an additive `contentDigest` on detail requests. It binds the card's content, action evidence, drafts, source and context revision while excluding presentation labels, attention decoration and CTA placement. The full `cardDigest` remains for older hosts; phones send the additive digest only after negotiation. This affects read-only display matching, not command authorization. Command confirmations still bind the displayed identity, title, source, MR context, drafts and exact advertised action token. After acceptance, unrelated cards or presentation changes cannot invalidate that action; account, session, partial-data and target-action checks remain mandatory.

More frequent polling alone would retain the same races. Embedding a new authoritative board in every action result would add another snapshot-admission path. The existing challenge/response flow instead provides ordered post-action synchronization and keeps its freshness and command-receipt rules in one place.

Approval metadata keeps the legacy `completed` field bounded for older decoders. The additive `received` field carries every current unique approver, including 5/2, and `requirementsSatisfied` preserves the distinction between total approvals and satisfaction of specific required rules. Updated phones use those fields for text, help and badge state.

Card approval presentation also carries optional `approvalPeople` and `viewerApprovalID`. Details carry the same viewer identity. The host projects both from the Mac approval model; only current or previously reset approvals qualify for the viewer marker, and own MRs omit it. Tapping the badge shows people, with the viewer first. These display fields are inside presentation, so they do not change the stable detail context; legacy full-card digest matching accepts clients that omit them.

The entire iPhone card opens its overview except for independent links and buttons. Plain overview CTAs are omitted because they duplicate the card tap; section links and bound actions remain. Feedback presentation collapses inherited findings only when source comment, summarized concern and reason match. Raw findings and workflow gates remain intact, so this never dismisses a concern or resolves a GitLab discussion.
