import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pairing, channel } from '../public/protocol.mjs';

test('R1: encrypted synthetic snapshot reaches only its paired receiver', async () => {
  const pair = await pairing();
  const host = await channel(pair.secret, 'host');
  const phone = await channel(pair.secret, 'phone');
  const snapshot = { type: 'snapshot', lanes: [{ title: 'Ready', count: 2 }] };
  const wire = await host.seal(snapshot);
  assert.equal(wire.includes('Ready'), false);
  assert.deepEqual(await phone.open(wire), snapshot);
});

test('R2: wrong pair and reflected sender cannot decrypt', async () => {
  const a = await pairing();
  const b = await pairing();
  const host = await channel(a.secret, 'host');
  const stranger = await channel(b.secret, 'phone');
  const wire = await host.seal({ type: 'snapshot' });
  await assert.rejects(stranger.open(wire));
  await assert.rejects(host.open(wire));
});

test('R3: replay is rejected but new receiver can recover after reopening', async () => {
  const pair = await pairing();
  const host = await channel(pair.secret, 'host');
  const phone = await channel(pair.secret, 'phone');
  const wire = await host.seal({ type: 'snapshot', revision: 1 });
  assert.equal((await phone.open(wire)).revision, 1);
  await assert.rejects(phone.open(wire), /replay/i);
  const reopened = await channel(pair.secret, 'phone');
  assert.equal((await reopened.open(await host.seal({ revision: 2 }))).revision, 2);
});

test('R2: routing key does not disclose the encryption secret', async () => {
  const pair = await pairing();
  assert.match(pair.secret, /^[A-Za-z0-9_-]{43}$/);
  assert.match(pair.room, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(pair.room, pair.secret);
  const host = await channel(pair.secret, 'host');
  const phone = await channel(pair.secret, 'phone');
  assert.equal(host.room, phone.room);
  assert.equal(pair.room, host.room);
});

test('R2: tampered ciphertext and invalid credentials fail closed', async () => {
  const pair = await pairing();
  const host = await channel(pair.secret, 'host');
  const phone = await channel(pair.secret, 'phone');
  const envelope = JSON.parse(await host.seal({ type: 'snapshot' }));
  envelope.data = (envelope.data[0] === 'A' ? 'B' : 'A') + envelope.data.slice(1);
  await assert.rejects(phone.open(JSON.stringify(envelope)));
  await assert.rejects(channel('short', 'host'));
  await assert.rejects(channel(pair.secret, 'invalid'));
});

test('R2/R3: concurrent delivery of the same encrypted message is accepted once', async () => {
  const pair = await pairing();
  const host = await channel(pair.secret, 'host');
  const phone = await channel(pair.secret, 'phone');
  const wire = await host.seal({ type: 'snapshot', revision: 1 });
  const attempts = await Promise.allSettled([phone.open(wire), phone.open(wire)]);
  assert.equal(attempts.filter(result => result.status === 'fulfilled').length, 1);
});
