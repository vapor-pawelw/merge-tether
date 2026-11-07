# iOS companion MVP

The iOS target is `MergeTetheriOS` (iOS 17+). It shows the Mac's three board lanes,
using the same `TodoMonitorService.boardSnapshot` as the desktop view, including
pinned ordering, proposals and agent jobs. It has pairing, card details and actions;
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
in the background and refresh every 25 seconds while foregrounded.

The QR contains the relay address, an operator invitation and a random 256-bit
pairing secret. HKDF derives directional AES-256-GCM keys; the room is a hash of the
secret. The relay sees IP addresses, timing, room IDs and ciphertext, but cannot
read tickets or commands. Credentials are stored in the native Keychain and are
never included in source code, request query strings or application logs. Protect
the QR like a password. Re-pairing on the Mac creates a different room; disabling
access deletes the saved pairing and disconnects the host.

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

Commands bind a host session, authenticated account, card, action and content token.
The Mac refreshes before checking the token. Approval pins the displayed commit;
publication checks the live commit and exact remaining draft content before each
individual checked draft ID. It rejects GitLab slash commands and discussion
resolution. A server-side edit can still race the final publication HTTP request,
which GitLab does not provide with an atomic content/head precondition.

The phone never automatically retries commands. The host serializes writes and
retains up to 512 receipts for the current session. Acceptance extends the phone deadline to two minutes; network heartbeats remain independent of GitLab action work. A known partial publication is reported explicitly. A lost acknowledgement is an
uncertain result: inspect GitLab before explicitly trying again. Restarting the
host creates a new session, so old commands are rejected. The MVP does not promise
exactly-once delivery across crashes or persist command receipts to disk.

Supported actions include checked comment publication, SHA-bound approval,
re-review confirmation, verification, pipeline handoff, marking a raw event done,
preparing feedback, running existing MR intents and retrying stopped agent jobs.
Proposals can be inspected and opened in GitLab; desktop adoption/ignore, settings,
merge controls and discussion resolution are outside this phone MVP.

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
