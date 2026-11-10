import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Miniflare } from 'miniflare';
import { connectPair } from '../public/connection.mjs';
import { parsePairingURL } from '../public/probe.mjs';

test('R2/R3: host pairs without logging credentials and removes private pairing artifacts on rejection', { timeout: 15000 }, async () => {
  const runtime = new Miniflare({
    modules: true, script: await readFile(new URL('../../../Services/RemoteRelay/worker.mjs', import.meta.url), 'utf8'),
    compatibilityDate: '2026-07-30', bindings: { RELAY_ACCESS_TOKEN: 'a'.repeat(43) },
    durableObjects: { ROOMS: { className: 'RelayRoom', useSQLite: true } },
  });
  const directory = await mkdtemp(join(tmpdir(), 'mt-probe-test-'));
  const qr = join(directory, 'pairing.png');
  let child, replacement;
  try {
    const origin = (await runtime.ready).origin;
    child = spawn(process.execPath, ['host.mjs', '--relay', origin, '--qr', qr], {
      cwd: new URL('..', import.meta.url), env: { RELAY_ACCESS_TOKEN: 'a'.repeat(43) },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const exit = new Promise(resolve => child.once('exit', code => resolve(code)));
    let output = '';
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Host startup timed out')), 10000);
      child.stdout.on('data', data => {
        output += data.toString();
        if (output.includes('Relay: connected')) { clearTimeout(timer); resolve(); }
      });
      child.once('error', reject);
    });
    const htmlPath = qr.replace(/\.png$/, '.html');
    const page = await readFile(htmlPath, 'utf8').catch(() => undefined);
    assert.ok(page, 'A private pairing page must exist instead of logging credentials');
    const config = parsePairingURL(page.match(/href="([^"]+)"/)[1].replaceAll('&amp;', '&'));
    assert.equal(output.includes(config.secret), false);
    assert.equal(output.includes(config.access), false);
    replacement = await connectPair({ ...config, role: 'host' });
    await replacement.ready;
    const code = await exit;
    assert.equal(code, 1);
    await assert.rejects(access(qr), { code: 'ENOENT' });
    await assert.rejects(access(htmlPath), { code: 'ENOENT' });
  } finally {
    child?.kill(); replacement?.close();
    await runtime.dispose(); await rm(directory, { recursive: true, force: true });
  }
});
