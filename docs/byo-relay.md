# Bring your own relay

Each operator deploys a relay in their own Cloudflare account before building the native apps. The public server source is [Services/RemoteRelay](../Services/RemoteRelay); it is deployed separately from the Mac app and iOS IPA. MergeTether does not supply a common relay or default endpoint.

The relay origin is **public metadata**: it is embedded in both apps' Info.plist and is visible in the UI and extractable from an IPA. It neither authenticates users nor prevents resource consumption. Its operator is the person or organization controlling that deployment; the displayed origin is not proof of a person's identity. Build from your own configuration and verify the address before accepting pairing.

## Account and cost boundary

Use a **Workers Free** account for this relay and confirm the Workers subscription in the Cloudflare dashboard before deployment. A free website/domain plan alone does not establish the Workers subscription. The server uses SQLite Durable Objects supported on Workers Free. When a Free quota is exhausted, the relevant operations fail and access can stop. Do not enable a Paid subscription to keep the relay running if zero overage cost is required. Other services on the same account can also consume shared quotas. [Cloudflare documents Free quota failures and Paid usage billing](https://developers.cloudflare.com/durable-objects/platform/pricing/), with separate [Workers plan pricing](https://developers.cloudflare.com/workers/platform/pricing/).

A public endpoint can receive unwanted requests even when no one knows the invitation. Authentication, pairing encryption and rate limiting cannot promise zero cost on a Paid account. Pre-authentication admission limits reduce abuse; Cloudflare's rate-limiting counters are best effort and location-scoped, not an account-wide spending cap. Free quota exhaustion can still interrupt your own access. Keep the deployment private in use, use a unique random invitation, and do not share its invitation or pairing QR publicly.

## Deploy your instance

Install the build prerequisites from [building.md](building.md). Wrangler's pinned tooling lives in `prototypes/remote-relay`; Node.js 22 or newer is required there. Install dependencies using `npm ci` and sign in to your own account using `npx wrangler login`. These are operator steps; the native apps do not contain Cloudflare API credentials.

Create an operator secret outside the checkout. This command writes a random 32-byte invitation without printing it:

```bash
mkdir -p "$HOME/.config/mergetether"
python3 - <<'PYTHON'
import json, os, pathlib, secrets
path = pathlib.Path.home() / '.config/mergetether/operator.json'
if path.exists():
    raise SystemExit('Operator file already exists; keep it unless deliberately rotating the invitation.')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as target:
    json.dump({'RELAY_ACCESS_TOKEN': secrets.token_urlsafe(32)}, target)
PYTHON
```

Deploy the production Worker with that secret after checking the selected account and its Workers Free subscription:

```bash
cd prototypes/remote-relay
npm ci
npx wrangler login
npx wrangler deploy --config ../../Services/RemoteRelay/wrangler.jsonc \
  --secrets-file "$HOME/.config/mergetether/operator.json"
```

Use the HTTPS origin reported for **your** deployment. Register a workers.dev subdomain if Cloudflare requires it. The server has no public pairing page and does not serve the diagnostic browser prototype. Keep the operator file private; it is runtime authentication material, not app configuration.

## Configure and build both native apps

Create a second external JSON file, such as `$HOME/.config/mergetether/relay-build.json`, containing exactly one field. Replace this illustrative address with your deployment's origin:

```json
{"origin":"https://your-relay.example.org"}
```

Do not add `RELAY_ACCESS_TOKEN`, Cloudflare API credentials, signing keys or other fields. The file is deliberately outside Git. An origin is a scheme, host and optional port: HTTPS is required, and credentials, paths, queries and fragments are rejected. Host casing and the default HTTPS port are normalized; a different host or nondefault port remains a different relay. HTTP loopback origins are not supported by the native build configuration.

Generate the Xcode project from the repository root:

```bash
TUIST_MERGETETHER_RELAY_CONFIG_FILE="$HOME/.config/mergetether/relay-build.json" \
  mise exec -- tuist generate --no-open
```

Open the generated workspace and build the Mac `GitLabTodos` and iOS `MergeTetheriOS` schemes using your normal signing settings. Generation embeds only the validated origin in `MergeTetherRelayOrigin` in both app Info.plist files. Re-run generation after changing the external file; editing it does not update an existing binary. Generated projects are ignored by Git. No runtime invitation or operator key is packaged in either app.

For the release helper, add `--relay-config "$HOME/.config/mergetether/relay-build.json"` to your otherwise configured command. For example, this explicit inspection command builds unsigned artifacts without notarization or distribution export:

```bash
mise exec -- bash scripts/build-release.sh 1.2.0 --platform all --unsigned \
  --relay-config "$HOME/.config/mergetether/relay-build.json"
```

Distribution builds still require the signing, provisioning and notarization setup described in [building.md](building.md#release-builds). iOS distribution requires a valid relay config; there is no shared-origin fallback. Mac-only builds may omit it. `--unsigned` is explicit inspection mode and may omit it too; its iOS device ZIP is not installable. An inspection app with no origin shows the setup message and cannot pair. Tests and previews inject a synthetic configuration and local transports, without live relay services.

If you use the repository's signed release workflow in your own fork, configure `MERGETETHER_RELAY_CONFIG_JSON` as a repository secret containing exactly the same origin-only JSON. The workflow requires it for its iOS distribution artifact, writes a temporary file with mode `0600` under `RUNNER_TEMP`, passes `--relay-config`, and removes the file during cleanup. Its other signing/notarization secrets remain separate. No personal endpoint is committed or supplied by default; marking this origin as a CI secret is a configuration convenience, not a promise that an origin embedded in an IPA remains secret. Configuring CI does not itself authorize a tag push or publication.

## Pair and confirm ownership

On the Mac, open phone access. The app shows the configured origin and explains that its operator controls the address. Confirm it is your instance, enter the matching operator invitation in the secure field, then choose **Enable phone access**. The existing private local `remote-relay/operator.json` and `origin.txt` prefill is used only when that origin matches the build; it never enables access automatically.

Build the iOS app for the same origin, scan the Mac QR, and confirm the displayed address. The runtime QR contains the invitation and temporary pairing material; treat the QR and copied link as secrets. Both devices keep their established pairing in Keychain. The existing protocol, device-key pinning, encrypted frames and action guards remain in use. The public origin alone grants no pairing or GitLab access.

A missing or invalid origin disables companion access without stopping the Mac inbox. A QR for a different origin is rejected before saving trust or connecting. If a rebuild selects another origin, an old saved pairing stays untouched and is not connected or silently migrated. Rebuild for the previous origin to use that saved trust, or explicitly confirm a new matching pairing to replace it. Changing only the build config does not rotate the runtime invitation or remove old relay sessions; deliberate credential rotation and revocation remain separate operator actions.
