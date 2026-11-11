import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare } from 'miniflare';
import { readFile } from 'node:fs/promises';
import { admissionLimits } from './rate-limits.mjs';

async function runtimeFor(t, ratelimits = admissionLimits, failedBinding) {
  const script = await readFile(new URL('../../../Services/RemoteRelay/worker.mjs', import.meta.url), 'utf8');
  const code = failedBinding ? { modules: [
    { type: 'ESModule', path: 'entry.mjs', contents: `
      import relay from './worker.mjs';
      export { RelayRoom } from './worker.mjs';
      export default { fetch(request, env) {
        return relay.fetch(request, { ...env, ${failedBinding}: { limit() { throw new Error('Admission unavailable'); } } });
      } };
    ` },
    { type: 'ESModule', path: 'worker.mjs', contents: script },
  ] } : { modules: true, script };
  const runtime = new Miniflare({
    ...code,
    compatibilityDate: '2026-07-30', bindings: { RELAY_ACCESS_TOKEN: 'a'.repeat(43) },
    durableObjects: { ROOMS: { className: 'RelayRoom', useSQLite: true } }, ratelimits,
  });
  t.after(() => runtime.dispose());
  await runtime.ready;
  return runtime;
}
function connect(runtime, ip, token = 'z'.repeat(43), extra = {}) {
  return runtime.dispatchFetch('https://relay.test/v1/connect', { headers: {
    Upgrade: 'websocket', 'CF-Connecting-IP': ip,
    'Sec-WebSocket-Protocol': `mt-v1, access-${token}, room-${'b'.repeat(43)}, role-host`, ...extra,
  } });
}

test('admission: failed authentication attempts are limited before room access', async t => {
  const runtime = await runtimeFor(t);
  for (let i = 0; i < 30; i++) assert.equal((await connect(runtime, '192.0.2.1')).status, 401);
  const limited = await connect(runtime, '192.0.2.1', 'a'.repeat(43));
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  assert.equal(limited.headers.get('Cache-Control'), 'no-store');
  assert.equal((await connect(runtime, '192.0.2.2')).status, 401);
});

test('admission: forwarded headers cannot reset the trusted client budget', async t => {
  const runtime = await runtimeFor(t);
  for (let i = 0; i < 30; i++) await connect(runtime, '192.0.2.3', undefined, { 'X-Forwarded-For': `198.51.100.${i}` });
  assert.equal((await connect(runtime, '192.0.2.3', undefined, { 'X-Forwarded-For': 'different' })).status, 429);
});

test('admission: rotating client addresses does not reset the deployment limiter', async t => {
  const runtime = await runtimeFor(t);
  for (let i = 0; i < 120; i++) assert.equal((await connect(runtime, `192.0.2.${i}`)).status, 401);
  assert.equal((await connect(runtime, '198.51.100.1')).status, 429);
});

test('admission: missing limiter configuration fails closed without accepting a socket', async t => {
  for (const limits of [{}, { IP_ADMISSION: admissionLimits.IP_ADMISSION }, { DEPLOYMENT_ADMISSION: admissionLimits.DEPLOYMENT_ADMISSION }]) {
    const runtime = await runtimeFor(t, limits);
    const response = await connect(runtime, '192.0.2.4', 'a'.repeat(43));
    response.webSocket?.accept(); response.webSocket?.close();
    assert.equal(response.status, 503);
    assert.equal(response.webSocket, null);
  }
});

test('admission: a limiter outage fails closed instead of bypassing authentication admission', async t => {
  for (const binding of ['IP_ADMISSION', 'DEPLOYMENT_ADMISSION']) {
    const runtime = await runtimeFor(t, admissionLimits, binding);
    const response = await connect(runtime, '192.0.2.5', 'a'.repeat(43));
    response.webSocket?.accept(); response.webSocket?.close();
    assert.equal(response.status, 503);
    assert.equal(response.webSocket, null);
    assert.equal(response.headers.get('Retry-After'), '60');
  }
});
