import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connectPair } from '../public/connection.mjs';
import { pairing, channel } from '../public/protocol.mjs';

class Clock {
  now = 0; next = 1; jobs = new Map();
  setTimeout(fn, delay) { const id = this.next++; this.jobs.set(id, { fn, at: this.now + delay }); return id; }
  clearTimeout(id) { this.jobs.delete(id); }
  setInterval(fn, delay) { const id = this.next++; this.jobs.set(id, { fn, at: this.now + delay, delay }); return id; }
  clearInterval(id) { this.jobs.delete(id); }
  tick(duration) {
    const end = this.now + duration;
    while (true) {
      const entry = [...this.jobs.entries()].filter(([, job]) => job.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!entry) break;
      const [id, job] = entry;
      this.now = job.at;
      if (job.delay) job.at += job.delay; else this.jobs.delete(id);
      job.fn();
    }
    this.now = end;
  }
}

function socketType() {
  return class Socket extends EventTarget {
    static OPEN = 1; static CONNECTING = 0; static all = [];
    readyState = 0; sent = [];
    constructor() { super(); this.constructor.all.push(this); }
    send(wire) { this.sent.push(wire); }
    close(code = 1000) { this.readyState = 2; this.closeCode = code; } // intentionally no closing-handshake response
    emit(type, fields = {}) { this.dispatchEvent(Object.assign(new Event(type), fields)); }
    open() { this.readyState = 1; this.emit('open'); }
  };
}

async function fixture(onPayload = () => {}) {
  const WebSocketImpl = socketType();
  const timers = new Clock();
  const { secret } = await pairing();
  let opens = 0;
  const client = await connectPair({ origin: 'http://127.0.0.1:8787', secret, access: 'a'.repeat(43), role: 'phone',
    WebSocketImpl, timers, onPayload, onOpen: () => { opens++; } });
  client.ready.catch(() => {});
  assert.equal(WebSocketImpl.all.length, 1, 'The transport should use its injected WebSocket adapter');
  WebSocketImpl.all[0].open();
  await client.ready;
  return { client, WebSocketImpl, timers, secret, opens: () => opens };
}

test('R3: missing pong reconnects without waiting for the dead socket close event', async () => {
  const f = await fixture();
  try {
    f.timers.tick(35000);
    assert.equal(f.client.state, 'disconnected');
    f.timers.tick(2000);
    assert.equal(f.WebSocketImpl.all.length, 2);
    f.WebSocketImpl.all[1].open();
    await until(() => f.opens() === 2);
    assert.equal(f.opens(), 2);
    f.WebSocketImpl.all[0].emit('close', { code: 4000 });
    assert.equal(f.client.state, 'connected');
  } finally { f.client.close(); }
});

test('R3: stale or replayed frames are ignored without ending a healthy pairing', async () => {
  let deliveries = 0;
  const f = await fixture(() => { deliveries++; });
  try {
    const host = await channel(f.secret, 'host');
    const wire = await host.seal({ type: 'snapshot' });
    const socket = f.WebSocketImpl.all[0];
    socket.emit('message', { data: wire });
    await until(() => deliveries === 1);
    socket.emit('message', { data: wire });
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.equal(f.client.state, 'connected');
    assert.equal(deliveries, 1);
    const now = Date.now;
    let expired;
    try { Date.now = () => now() - 61000; expired = await host.seal({ type: 'snapshot' }); }
    finally { Date.now = now; }
    socket.emit('message', { data: expired });
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.equal(f.client.state, 'connected');
    assert.equal(deliveries, 1);
  } finally { f.client.close(); }
});

test('R3: local verification failure reconnects but explicit relay policy rejection is terminal', async () => {
  const f = await fixture();
  try {
    f.WebSocketImpl.all[0].emit('message', { data: '{}' });
    await until(() => f.client.state !== 'connected');
    assert.equal(f.client.state, 'disconnected');
    f.timers.tick(2000);
    assert.equal(f.WebSocketImpl.all.length, 2);
    const current = f.WebSocketImpl.all[1];
    current.open();
    current.emit('close', { code: 4008 });
    assert.equal(f.client.state, 'rejected');
    f.timers.tick(60000);
    assert.equal(f.WebSocketImpl.all.length, 2);
  } finally { f.client.close(); }
});

test('R4: repeated local failures grow the reconnect delay instead of resetting on every open', async () => {
  const f = await fixture();
  try {
    f.WebSocketImpl.all[0].emit('message', { data: '{}' });
    await until(() => f.client.state === 'disconnected');
    f.timers.tick(1500);
    assert.equal(f.WebSocketImpl.all.length, 2);
    f.WebSocketImpl.all[1].open();
    f.WebSocketImpl.all[1].emit('message', { data: '{}' });
    await until(() => f.client.state === 'disconnected');
    f.timers.tick(1500);
    assert.equal(f.WebSocketImpl.all.length, 2);
    f.timers.tick(1100);
    assert.equal(f.WebSocketImpl.all.length, 3);
  } finally { f.client.close(); }
});

test('R4: an authenticated payload restores the short retry delay after recovery', async () => {
  let deliveries = 0;
  const f = await fixture(() => { deliveries++; });
  try {
    f.WebSocketImpl.all[0].emit('message', { data: '{}' });
    await until(() => f.client.state === 'disconnected');
    f.timers.tick(1500);
    f.WebSocketImpl.all[1].open();
    f.WebSocketImpl.all[1].emit('message', { data: '{}' });
    await until(() => f.client.state === 'disconnected');
    f.timers.tick(2600);
    const recovered = f.WebSocketImpl.all[2];
    recovered.open();
    const host = await channel(f.secret, 'host');
    recovered.emit('message', { data: await host.seal({ type: 'snapshot' }) });
    await until(() => deliveries === 1);
    recovered.emit('message', { data: '{}' });
    await until(() => f.client.state === 'disconnected');
    f.timers.tick(1500);
    assert.equal(f.WebSocketImpl.all.length, 4);
  } finally { f.client.close(); }
});

async function until(check) {
  const deadline = Date.now() + 2000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error('State transition timed out');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}
