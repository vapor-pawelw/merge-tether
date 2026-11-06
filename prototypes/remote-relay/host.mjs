import { readFile, writeFile, rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import QRCode from 'qrcode';
import { pairing } from './public/protocol.mjs';
import { ProbeHost, pairingURL } from './public/probe.mjs';
import { connectPair } from './public/connection.mjs';

const args = process.argv.slice(2);
if (args.includes('--help')) {
  console.log(`Usage: npm run host -- [--relay https://worker.account.workers.dev] [--qr /path/pairing.png]
Starts a synthetic Mac host. Default relay: http://127.0.0.1:8787.
Set RELAY_ACCESS_TOKEN for a deployed relay; local development reads .dev.vars.
Private QR and HTML pairing files are removed when the host exits. Credentials are never printed.
No GitLab reads or writes. Stop with Ctrl-C.`);
  process.exit(0);
}
const options = { relay: 'http://127.0.0.1:8787', qr: resolve('pairing.png') };
for (let index = 0; index < args.length; index++) {
  const key = args[index];
  if (!['--relay', '--qr'].includes(key) || !args[index + 1]) throw new Error('Unknown or missing option. Run npm run host -- --help.');
  options[key.slice(2)] = args[++index];
}

let access = process.env.RELAY_ACCESS_TOKEN;
if (!access) {
  try { access = (await readFile('.dev.vars', 'utf8')).match(/^RELAY_ACCESS_TOKEN=([A-Za-z0-9_-]{43})$/m)?.[1]; }
  catch { /* actionable validation below */ }
}
if (!/^[A-Za-z0-9_-]{43}$/.test(access ?? '')) throw new Error('Missing invitation. Run npm run setup locally, or set RELAY_ACCESS_TOKEN for the deployed relay.');
const { secret } = await pairing();
const link = pairingURL(options.relay, { secret, access });
const qrPath = resolve(options.qr);
const htmlPath = /\.png$/i.test(qrPath) ? qrPath.replace(/\.png$/i, '.html') : `${qrPath}.html`;
await writeFile(qrPath, await QRCode.toBuffer(link, { width: 560, margin: 3 }), { mode: 0o600, flag: 'wx' });
const escapeHTML = text => text.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
try {
  await writeFile(htmlPath, `<!doctype html><meta charset="utf-8"><meta name="referrer" content="no-referrer"><title>MergeTether pairing</title><h1>MergeTether connection probe</h1><p>This private file contains pairing credentials. Do not share it.</p><a href="${escapeHTML(link)}">Connect this browser</a>`, { mode: 0o600, flag: 'wx' });
} catch (error) {
  await rm(qrPath, { force: true });
  throw error;
}
const cleanup = () => Promise.all([qrPath, htmlPath].map(path => rm(path, { force: true })));
process.once('beforeExit', () => {
  void cleanup().catch(() => { console.error('Could not remove pairing files; remove them manually.'); process.exitCode = 1; });
});
console.log(`Pairing QR: ${qrPath}`);
console.log(`Local pairing page: ${htmlPath}`);
const probe = new ProbeHost();
let connection;
try {
  connection = await connectPair({
    origin: options.relay, secret, access, role: 'host',
    onState: state => {
      console.log(`Relay: ${state}`);
      if (state === 'rejected') {
        console.error('Relay closed this session permanently. Check verification, clock alignment, rate limits or a replacement host.');
        process.exitCode = 1;
      }
    },
    onOpen: client => client.send({ type: 'host-ready' }),
    onPayload: async message => {
      for (const reply of probe.handle(message)) {
        await connection.send(reply);
        if (reply.type === 'completed') console.log(`Test command completed. Executions: ${reply.executions}`);
      }
    },
  });
  const stop = async () => { connection.close(); await cleanup(); process.exit(0); };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  process.once('SIGHUP', stop);
  await connection.ready;
} catch {
  connection?.close();
  await cleanup();
  console.error('Could not connect. Check the relay URL, invitation and network; no GitLab action was executed.');
  process.exitCode = 1;
}
