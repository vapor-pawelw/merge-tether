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

// Miniflare clears its counters at fixed wall-clock boundaries. Exercise
// the production bindings with one window's worth of requests.
async function inOneAdmissionWindow(t, exercise) {
  const windowIDs = () => {
    const now = Date.now();
    return Object.values(admissionLimits).map(({ simple }) => Math.floor(now / (simple.period * 1000))).join(',');
  };
  for (let attempt = 0; attempt < 2; attempt++) {
    const runtime = await runtimeFor(t);
    const before = windowIDs();
    const result = await exercise(runtime);
    if (windowIDs() === before) return result;
  }
  assert.fail('The admission test did not complete within a rate-limit window');
}

test('admission: failed authentication attempts are limited before room access', async t => {
  const { attempts, limited, other } = await inOneAdmissionWindow(t, async runtime => {
    const attempts = [];
    for (let i = 0; i < 30; i++) attempts.push((await connect(runtime, '192.0.2.1')).status);
    const limited = await connect(runtime, '192.0.2.1', 'a'.repeat(43));
    const other = await connect(runtime, '192.0.2.2');
    return { attempts, limited, other };
  });
  assert.deepEqual(attempts, Array(30).fill(401));
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  assert.equal(limited.headers.get('Cache-Control'), 'no-store');
  assert.equal(other.status, 401);
});

test('admission: forwarded headers cannot reset the trusted client budget', async t => {
  const limited = await inOneAdmissionWindow(t, async runtime => {
    for (let i = 0; i < 30; i++) await connect(runtime, '192.0.2.3', undefined, { 'X-Forwarded-For': `198.51.100.${i}` });
    return connect(runtime, '192.0.2.3', undefined, { 'X-Forwarded-For': 'different' });
  });
  assert.equal(limited.status, 429);
});

test('admission: rotating client addresses does not reset the deployment limiter', async t => {
  const { attempts, limited } = await inOneAdmissionWindow(t, async runtime => {
    const attempts = [];
    for (let i = 0; i < 120; i++) attempts.push((await connect(runtime, `192.0.2.${i}`)).status);
    const limited = await connect(runtime, '198.51.100.1');
    return { attempts, limited };
  });
  assert.deepEqual(attempts, Array(120).fill(401));
  assert.equal(limited.status, 429);
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
