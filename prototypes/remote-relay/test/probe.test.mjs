import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ProbeHost, pairingURL, parsePairingURL } from '../public/probe.mjs';
import { pairing } from '../public/protocol.mjs';

test('R1/R3: test CTA returns accepted and a separate completed result exactly once', () => {
  const host = new ProbeHost();
  const hello = host.handle({ type: 'hello' });
  assert.equal(hello[0].type, 'snapshot');
  const command = { type: 'command', id: crypto.randomUUID(), hostSession: hello[0].hostSession, action: 'probe' };
  const first = host.handle(command);
  assert.deepEqual(first.map(message => message.type), ['accepted', 'completed']);
  assert.equal(first[1].executions, 1);
  assert.deepEqual(host.handle(command), first);
  const second = host.handle({ ...command, id: crypto.randomUUID() });
  assert.equal(second[1].executions, 2);
});

test('R3: stale host session and unknown actions do not execute', () => {
  const host = new ProbeHost();
  const command = { type: 'command', id: crypto.randomUUID(), hostSession: 'old-session', action: 'probe' };
  assert.equal(host.handle(command)[0].type, 'rejected');
  const snapshot = host.handle({ type: 'hello' })[0];
  assert.equal(host.handle({ ...command, hostSession: snapshot.hostSession, action: 'publish' })[0].type, 'rejected');
  assert.equal(host.handle({ ...command, hostSession: snapshot.hostSession })[1].executions, 1);
});

test('R2/R5: pairing keeps secrets in fragment and rejects insecure remote origins', async () => {
  const { secret } = await pairing();
  const access = 'a'.repeat(43);
  const url = pairingURL('https://relay.example', { secret, access });
  assert.equal(new URL(url).search, '');
  assert.equal(url.split('#')[0].includes(secret), false);
  assert.deepEqual(parsePairingURL(url), { origin: 'https://relay.example', secret, access });
  assert.throws(() => pairingURL('http://remote.example', { secret, access }), /HTTPS/);
  assert.doesNotThrow(() => pairingURL('http://127.0.0.1:8787', { secret, access }));
});

test('R2: pairing rejects credentials in origin and arbitrary paths', async () => {
  const { secret } = await pairing();
  const config = { secret, access: 'a'.repeat(43) };
  assert.throws(() => pairingURL('https://user:password@relay.example', config));
  assert.throws(() => pairingURL('https://relay.example/other', config));
  assert.throws(() => parsePairingURL('https://relay.example/#bad'));
});
