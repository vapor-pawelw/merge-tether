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
There is no system VPN, local network discovery, open inbound port or VPS. A company
proxy can still block the relay domain or WebSockets; HTTPS does not bypass an
organization's network policy. The Mac must remain awake and connected.

A SQLite Durable Object routes one host and one phone per random room. Each Mac
creates its own room, so several users can share the relay deployment. A new phone
connection replaces the previous phone for that pairing. Native clients disconnect
in the background and refresh every 25 seconds while foregrounded, renewing sooner after a slow reply
when needed to keep the host status current. The connection label remains stable
during an in-flight refresh; remote writes still require an unexpired snapshot.

After trusting a pairing, the pairing form closes as soon as it is saved, independently
of the first Mac response. The phone shows **Connecting to Mac…** for at most 45 seconds,
then **Mac unavailable** with a retry action if no fresh snapshot arrives. A detected
transport or snapshot error has its own **Connection failed** state. Saved pairing
never requires reopening the Mac's pairing window for an ordinary connection attempt;
the current Mac app starts its saved phone connection on launch. The Mac must be awake
and MergeTether running; Keychain authorization or a blocked relay can still prevent connection.

The circular toolbar arrow is **Refresh board**: it requests data over the current
connection and coalesces outstanding refreshes. **… → Reconnect** deliberately replaces
the phone transport, including its retry backoff, while keeping the saved pairing.
Reconnect is also offered directly when the Mac is unavailable, and repeated taps
coalesce while connecting. Returning from the background creates a fresh connection.
The last board for the same pairing remains visible with an offline notice, but actions
wait for a fresh authenticated snapshot. Replacing pairing clears that board and its
open details. Reconnect never repeats a GitLab command: a pending command becomes
an unconfirmed outcome, since closing the connection cannot cancel work already accepted
by the Mac. Inspect the actual outcome before deliberately retrying it.

The Mac reads saved pairing from Keychain in the background. A system permission
prompt does not prevent the main window or MR automation from starting. A late
read cannot override pairing details you edit or an explicit enable/disable action.

The QR contains the relay address, an operator invitation and a random 256-bit
pairing secret. HKDF derives directional AES-256-GCM keys; the room is a hash of the
secret. The relay sees IP addresses, timing, room IDs and ciphertext, but cannot
read tickets or commands. Credentials are stored in the native Keychain and are
never included in source code, request query strings or application logs. Protect
the QR like a password. Re-pairing on the Mac creates a different room; disabling
access deletes the saved pairing and disconnects the host. Pairing has no automatic
expiry or rotation. A copied QR remains a bearer secret until it is replaced or
access is disabled; reconnecting does not revoke it.

The operator invitation gates admission, not access to another user's inbox.
Sharing it broadly permits others to consume the deployment's free quota. This MVP
has no public self-service signup, account recovery or per-user quota service.

## Deploy on Cloudflare Free

Use a Cloudflare account with Workers Free and SQLite Durable Objects Free.
Do not enable a paid subscription. Free quotas are shared across the deployment;
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
still use the Mac's existing guards and required saved receipts. Older phones can
ignore the additive notice field; it never grants action permission.

Commands bind a host session, authenticated account, card, action and content token.
The Mac refreshes before checking the token. Approval pins the displayed commit;
publication checks the live commit and exact remaining draft content before each
individual checked draft ID. It rejects GitLab slash commands and discussion
resolution. A server-side edit can still race the final publication HTTP request,
which GitLab does not provide with an atomic content/head precondition.

The phone never automatically retries commands. The host serializes writes and
retains up to 512 receipts for the current session. Acceptance extends the phone deadline to two minutes; network heartbeats remain independent of GitLab action work. A known partial publication is reported explicitly. A lost acknowledgement is an
uncertain result: inspect GitLab before explicitly trying again. Reconnecting or restarting the
host creates a new session, so old commands and their receipts cannot confirm a new
session. Changing accounts also invalidates the session, even when the account later
returns to the same username and host. Disconnecting invalidates an action still
waiting for its acceptance send; an already started write keeps the host write lock
until it finishes. Prepared thread-resolution IDs must be checked again after a
reconnect. Pairing trust is retained through ordinary reconnects. The MVP does not promise
exactly-once delivery across crashes or persist command receipts to disk.

Supported actions include checked comment publication, SHA-bound approval,
re-review confirmation, verification, pipeline handoff, marking a raw event done,
preparing feedback, running existing MR intents and retrying stopped agent jobs.
Phones advertising `merge-actions-v1` can also merge, enqueue supported auto-merge
requests and check then confirm concrete thread-resolution IDs. These commands call
the same manual Mac executors: merge checks current account, source/target,
dependencies, semantic feedback, published replies, drafts, unfinished work and
submission receipts; resolution rechecks the confirmed IDs before each write.
Proposals can be inspected and opened in GitLab; adoption/ignore and settings remain
on the desktop.

Full snapshot plaintext is capped at 128 KiB and the relay envelope at 256 KiB.
Oversized snapshots disable readiness instead of truncating a comment preview.
Offline state is retained in memory while the app stays open; it is not a durable
cloud copy of the inbox. The Mac remains the source of truth.

## Verification

Generate the Tuist project, build the `GitLabTodos` and `MergeTetheriOS` schemes,
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

### Merge actions compatibility

Phones advertising `merge-actions-v1` can explicitly merge owned ready MRs, set supported auto-merge/train requests, and prepare a bounded thread-resolution preview before confirming its exact IDs. Host-side live guards remain authoritative. Queued and in-train results do not claim a finished merge. Older phones receive the same readable board with these action cases filtered out before encoding.

Approval metadata keeps the legacy `completed` field bounded for older decoders. The additive `received` field carries every current unique approver, including 5/2, and `requirementsSatisfied` preserves the distinction between total approvals and satisfaction of specific required rules. Updated phones use those fields for text, help and badge state.
