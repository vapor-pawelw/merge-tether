import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare } from 'miniflare';
import { readFile } from 'node:fs/promises';

const access = 'a'.repeat(43);
const room = 'b'.repeat(43);
let runtime;
before(async () => {
  runtime = new Miniflare({
    modules: true, script: await readFile(new URL('../worker.mjs', import.meta.url), 'utf8'),
    compatibilityDate: '2026-07-30', bindings: { RELAY_ACCESS_TOKEN: access },
    durableObjects: { ROOMS: { className: 'RelayRoom', useSQLite: true } },
  });
  await runtime.ready;
});
after(async () => { await runtime?.dispose(); });

async function connect(role, key = room, token = access) {
  const response = await runtime.dispatchFetch('https://relay.test/v1/connect', {
    headers: { Upgrade: 'websocket', 'Sec-WebSocket-Protocol': `mt-v1, access-${token}, room-${key}, role-${role}` },
  });
  response.webSocket?.accept();
  return response;
}

function nextMessage(socket) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); reject(new Error('Message timeout')); }, 2000);
    const onMessage = event => { cleanup(); resolve(event.data); };
    const cleanup = () => { clearTimeout(timer); socket.removeEventListener('message', onMessage); };
    socket.addEventListener('message', onMessage);
  });
}

test('R1: authenticated peers exchange opaque frames in both directions', async () => {
  const host = await connect('host');
  assert.equal(host.status, 101);
  const phone = await connect('phone');
  assert.equal(phone.status, 101);
  const toPhone = nextMessage(phone.webSocket);
  host.webSocket.send('encrypted snapshot');
  assert.equal(await toPhone, 'encrypted snapshot');
  const toHost = nextMessage(host.webSocket);
  phone.webSocket.send('encrypted command');
  assert.equal(await toHost, 'encrypted command');
  host.webSocket.close(); phone.webSocket.close();
});

test('R2: wrong invitation and missing credentials cannot connect', async () => {
  assert.equal((await connect('host', room, 'z'.repeat(43))).status, 401);
  const missing = await runtime.dispatchFetch('https://relay.test/v1/connect', { headers: { Upgrade: 'websocket' } });
  assert.equal(missing.status, 401);
});

test('R2: a different pair receives no frame from another room', async () => {
  const host = await connect('host', 'c'.repeat(43));
  const phone = await connect('phone', 'd'.repeat(43));
  const incoming = [];
  phone.webSocket.addEventListener('message', event => incoming.push(event.data));
  const status = nextMessage(host.webSocket);
  host.webSocket.send('private frame');
  assert.deepEqual(JSON.parse(await status), { relay: 'peer-offline' });
  assert.deepEqual(incoming, []);
  host.webSocket.close(); phone.webSocket.close();
});

test('R3: reconnect replaces the old role without forwarding it later messages', async () => {
  const key = 'e'.repeat(43);
  const host = await connect('host', key);
  const oldPhone = await connect('phone', key);
  const closed = new Promise(resolve => oldPhone.webSocket.addEventListener('close', resolve, { once: true }));
  const phone = await connect('phone', key);
  assert.equal((await closed).code, 4001);
  const message = nextMessage(phone.webSocket);
  host.webSocket.send('fresh snapshot');
  assert.equal(await message, 'fresh snapshot');
  host.webSocket.close(); phone.webSocket.close();
});

test('R4: oversized frames close the sender', async () => {
  const host = await connect('host', 'f'.repeat(43));
  const closed = new Promise(resolve => host.webSocket.addEventListener('close', resolve, { once: true }));
  host.webSocket.send('x'.repeat(262145));
  assert.equal((await closed).code, 4009);
});

test('native snapshots up to 256 KiB pass through without truncating draft previews', async () => {
  const key = 'n'.repeat(43);
  const host = await connect('host', key);
  const phone = await connect('phone', key);
  const frame = 'x'.repeat(200000);
  const received = nextMessage(phone.webSocket);
  host.webSocket.send(frame);
  assert.equal(await received, frame);
  host.webSocket.close(); phone.webSocket.close();
});

test('R2: browser connections from another origin are rejected', async () => {
  const response = await runtime.dispatchFetch('https://relay.test/v1/connect', {
    headers: { Upgrade: 'websocket', Origin: 'https://other.test', 'Sec-WebSocket-Protocol': `mt-v1, access-${access}, room-${room}, role-host` },
  });
  assert.equal(response.status, 403);
});

test('R4: excessive messages close the sender instead of allowing unlimited relay traffic', async () => {
  const host = await connect('host', 'g'.repeat(43));
  const closed = new Promise(resolve => host.webSocket.addEventListener('close', resolve, { once: true }));
  for (let index = 0; index < 121; index++) host.webSocket.send('frame');
  const timeout = setTimeout(() => host.webSocket.close(1000), 1500);
  const result = await closed;
  clearTimeout(timeout);
  assert.equal(result.code, 4008);
});
