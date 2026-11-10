# MergeTether remote connection probe

An isolated connectivity experiment: a Node.js host on the Mac and a phone web
client exchange encrypted **synthetic data and a test action** through Cloudflare.
It does not read GitLab, execute shell commands, expose a Mac listener, modify
network settings, or change the installed MergeTether app. The Safari client is a
temporary transport probe, not the native iOS MVP.

The shared Worker source lives in `../../Services/RemoteRelay/worker.mjs` and also
serves the native app's production relay. This directory keeps only the probe
clients, pinned npm tooling and shared transport tests. Its Wrangler configuration
adds the browser assets to a separate probe deployment; the production
configuration in `Services/RemoteRelay` does not serve those assets.

## Local verification

Requires Node.js 22 or newer. Dependencies are pinned in `package-lock.json`.

```sh
cd prototypes/remote-relay
npm ci
npm test
npm run setup
npm run dev
```

In another terminal in the same directory:

```sh
npm run host
open pairing.html
```

Click **Connect this browser** in the private pairing page **on the Mac**, then
press the test action. The generated `pairing.png` is a QR code containing the same credentials.
The local server is bound to `127.0.0.1`; a phone cannot reach this address on the
Mac. Use a deployed HTTPS relay for a physical phone/LTE test. Do not expose the
development server to the internet.

`npm run setup` creates a private, ignored `.dev.vars` file without overwriting
an existing invitation. The host creates a fresh pair secret on each start. The
QR and HTML files are private, are never overwritten, and are removed on a normal
host exit. Credentials are never printed to stdout. After a crash, remove the old
pairing files before starting again. Use `--qr /another/path.png` to choose a
different output location for both files. `npm run host -- --help` describes the options.
Cleanup is best effort: force-killing a process group or interrupting startup can
leave pairing files behind. Remove those files before starting a new host.

## Cloudflare Free deployment

A Cloudflare account is required. No VPS, custom domain, paid subscription, or
Cloudflare account for the phone user is required. **Stay on Workers Free**; this
prototype does not enable or purchase a paid plan. It uses SQLite-backed Durable
Objects, which are supported on Free, and WebSocket Hibernation. It stores no
snapshots or commands in Cloudflare storage and has no application polling while
the phone page is hidden or closed. While visible, the phone checks the Mac every
25 seconds; host readiness expires after 45 seconds without a valid response.

Free quotas are shared by all users of the deployment. On the Free plan, quota
exhaustion causes errors, not usage overages. Free service is not unlimited;
neither a user count nor permanent future pricing is guaranteed. See the current
[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
and [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).

After reviewing the local probe, sign in and deploy from this directory:

```sh
npx wrangler login
npm run deploy
npx wrangler secret put RELAY_ACCESS_TOKEN
```

At the secret prompt, paste the 43-character invitation generated in `.dev.vars`.
Do not put it in source control, a URL query, or a public issue. Requests fail
closed until the invitation is configured. Use the generated HTTPS `workers.dev`
address to start the Mac host:

```sh
npm run host -- --relay https://mergetether-remote-probe.YOUR-SUBDOMAIN.workers.dev
```

The host reads the same local invitation from `.dev.vars` (or the
`RELAY_ACCESS_TOKEN` environment variable). Scan its QR with the iPhone camera.
Safari opens the relay page and connects automatically. Pairing credentials are
in the URL fragment, which is removed from the address bar after parsing. Nothing
is saved in browser storage; reloading requires scanning the QR again. Background
and foreground transitions reconnect while the page remains alive.

## Network verification on real devices

1. Keep the host running and verify the phone can receive a snapshot and a
   completed test action over Wi-Fi.
2. Enable the corporate VPN on the Mac. Disable Wi-Fi on the iPhone and repeat
   over LTE/5G. Confirm the corporate network still works normally on the Mac.
3. Lock/unlock the iPhone and switch between Wi-Fi and cellular. A reconnect
   should recover the snapshot; an unconfirmed action must never silently retry.
4. Stop the Mac host. The phone must retain the last view, show that the Mac is
   unavailable, and disable the test action. Restart the host and scan its new QR.

HTTPS/WebSockets use outbound connections and do not install a VPN or change
routes/DNS. A corporate firewall/proxy can still deny the destination or WebSocket
upgrade; this experiment is specifically intended to establish compatibility.

## Protocol and limits

- One host and one phone per room. Separate random pair secrets isolate rooms.
- A deployment-wide invitation gates access before a Durable Object is reached.
  This is **invite-only**, not production user registration. Invitation holders
  can create rooms; a malicious invited client can exhaust shared free quotas.
  Per-user registration, revocation, and admission quotas are future work.
- AES-256-GCM with HKDF-derived directional keys; the relay sees only a derived
  room identifier and opaque frames. Sender, room, and timestamp are authenticated.
  Frames expire after 60 seconds, so device clocks must be reasonably aligned.
- 256 KiB maximum relay frame (the diagnostic web probe retains its own 16 KiB limit); 120 application messages per minute per socket; at most
  eight attached sockets per room including closing sockets. Reconnect replaces
  the previous socket of the same role. Transport heartbeats use hibernation
  auto-responses; the visible phone's end-to-end checks wake the room briefly.
  These bounds reduce accidental load; they are not a global abuse-prevention system.
- Encrypted command IDs are deduplicated within the host process. A host-session
  ID rejects stale commands after restart. At 256 commands the host refuses new
  ones rather than forgetting IDs. There is no offline command queue.
- Relay status is advisory. Only an authenticated host message can establish
  readiness or completion. Each snapshot must echo a fresh phone challenge, so a
  prior snapshot cannot renew readiness after reconnect. The browser distinguishes
  accepted from completed.
- A missing transport pong abandons the old socket without waiting for its close
  handshake, then reconnects with backoff. Expired/replayed frames are ignored.
  Explicit relay policy codes 4008/4009 and role replacement 4001 end the session;
  local verification errors reconnect without executing or retrying a command.
- The relay serves the probe's JavaScript, so the web experiment trusts that
  delivered client code. A maliciously modified web client could leak keys.
  Production end-to-end protection requires independently trusted clients,
  such as the planned signed native applications.

The transport is not yet connected to MergeTether's real snapshots or CTA. That
integration must recheck live MR/draft state and preserve existing authorization
and verification gates. Do not use this synthetic command handler for real writes.

## Validation

`npm test` runs WebCrypto/probe behavior tests and real Worker/Durable Object
integration tests using Miniflare, including a two-client WebSocket round trip.
`npx wrangler deploy --dry-run` bundles the deployment locally without publishing.
Public LTE/corporate VPN compatibility requires the real-device check above.
