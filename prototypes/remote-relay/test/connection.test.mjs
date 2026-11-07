import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare } from 'miniflare';
import { readFile } from 'node:fs/promises';
import { connectPair } from '../public/connection.mjs';
import { pairing } from '../public/protocol.mjs';
import { ProbeHost } from '../public/probe.mjs';
import { PhoneProbe } from '../public/phone.mjs';

test('R1/R3: real WebSocket clients get a snapshot and completed test CTA through the relay', async () => {
  const runtime = new Miniflare({
    modules: true, script: await readFile(new URL('../worker.mjs', import.meta.url), 'utf8'),
    compatibilityDate: '2026-07-30', bindings: { RELAY_ACCESS_TOKEN: 'a'.repeat(43) },
    durableObjects: { ROOMS: { className: 'RelayRoom', useSQLite: true } },
  });
  let host, phone;
  try {
    const origin = (await runtime.ready).origin;
    const { secret } = await pairing();
    const config = { origin, secret, access: 'a'.repeat(43) };
    const receiver = [];
    const probe = new ProbeHost();
    const view = new PhoneProbe();
    host = await connectPair({ ...config, role: 'host', onPayload: async message => {
      for (const reply of probe.handle(message)) await host.send(reply);
    } });
    await host.ready;
    phone = await connectPair({ ...config, role: 'phone', onState: state => view.transport(state), onPayload: message => {
      view.receive(message); receiver.push(message);
    } });
    await phone.ready;
    await phone.send(view.hello());
    await waitUntil(() => receiver.some(message => message.type === 'snapshot'));
    const snapshot = receiver.find(message => message.type === 'snapshot');
    assert.equal(view.canAct, true);
    const command = view.beginCommand();
    assert.equal(command.hostSession, snapshot.hostSession);
    await phone.send(command);
    await waitUntil(() => receiver.some(message => message.type === 'completed'));
    assert.deepEqual(receiver.slice(1).map(message => message.type), ['accepted', 'completed']);
    assert.equal(receiver.at(-1).executions, 1);
    assert.equal(view.result, 'completed');
    await phone.send(command);
    await waitUntil(() => receiver.filter(message => message.type === 'completed').length === 2);
    assert.equal(receiver.at(-1).executions, 1);
    assert.equal(probe.executions, 1);
    phone.close();
    await waitUntil(() => host.state === 'peer-offline');
    await assert.rejects(phone.send(command), /not connected/i);
  } finally {
    host?.close(); phone?.close(); await runtime.dispose();
  }
});

async function waitUntil(check) {
  const deadline = Date.now() + 3000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error('Timed out waiting for end-to-end result');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
