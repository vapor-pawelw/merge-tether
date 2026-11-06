import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PhoneProbe } from '../public/phone.mjs';

function readyPhone(now) {
  const phone = new PhoneProbe(now);
  phone.transport('connected');
  const { challenge } = phone.hello();
  phone.receive({ type: 'snapshot', challenge, hostSession: 'current', lanes: [], executions: 0 });
  return phone;
}

test('R1/R3: only an authenticated snapshot enables a test command; duplicate taps cannot send twice', () => {
  const phone = readyPhone();
  assert.equal(phone.canAct, true);
  const command = phone.beginCommand();
  assert.equal(command.hostSession, 'current');
  assert.equal(command.action, 'probe');
  assert.equal(phone.canAct, false);
  assert.equal(phone.beginCommand(), undefined);
  phone.receive({ type: 'accepted', id: command.id });
  assert.equal(phone.result, 'accepted');
  phone.receive({ type: 'completed', id: command.id, executions: 1 });
  assert.equal(phone.result, 'completed');
  assert.equal(phone.canAct, true);
});

test('R3: a timeout keeps refresh available while preventing another action until a new snapshot', () => {
  const phone = readyPhone();
  const command = phone.beginCommand();
  phone.expireCommand();
  assert.equal(phone.result, 'uncertain');
  assert.equal(phone.canAct, false);
  assert.equal(phone.canRefresh, true);
  phone.receive({ type: 'completed', id: command.id, executions: 1 });
  assert.equal(phone.result, 'uncertain');
  phone.receive({ type: 'snapshot', challenge: phone.hello().challenge, hostSession: 'current', lanes: [], executions: 1 });
  assert.equal(phone.canAct, true);
});

test('R3: disconnect retains the snapshot and never resends an unconfirmed command', () => {
  const phone = readyPhone();
  phone.beginCommand();
  phone.transport('disconnected');
  assert.equal(phone.result, 'uncertain');
  assert.equal(phone.canAct, false);
  assert.equal(phone.canRefresh, false);
  assert.equal(phone.snapshot.hostSession, 'current');
  phone.transport('connected');
  assert.equal(phone.canAct, false);
  assert.equal(phone.canRefresh, true);
  assert.equal(phone.pending, undefined);
});

test('R2/R3: relay connectivity cannot establish readiness or complete an unrelated command', () => {
  const phone = new PhoneProbe();
  phone.transport('connected');
  assert.equal(phone.canAct, false);
  phone.receive({ type: 'completed', id: 'unsolicited', executions: 10 });
  assert.equal(phone.result, 'idle');
  assert.equal(phone.canAct, false);
});

test('R3: a silently lost host expires readiness even when the relay is still connected', () => {
  let now = 1000;
  const phone = readyPhone(() => now);
  assert.equal(phone.canAct, true);
  now += 45001;
  assert.equal(phone.canAct, false);
  assert.equal(phone.hostAvailable, false);
  assert.equal(phone.canRefresh, true);
});

test('R2/R3: old snapshots cannot restore readiness after a reconnect or refresh', () => {
  const phone = new PhoneProbe();
  phone.transport('connected');
  const old = phone.hello();
  const current = phone.hello();
  phone.receive({ type: 'snapshot', challenge: old.challenge, hostSession: 'current', lanes: [] });
  assert.equal(phone.canAct, false);
  phone.receive({ type: 'snapshot', challenge: current.challenge, hostSession: 'current', lanes: [] });
  assert.equal(phone.canAct, true);
  phone.transport('disconnected');
  phone.transport('connected');
  phone.receive({ type: 'snapshot', challenge: current.challenge, hostSession: 'current', lanes: [] });
  assert.equal(phone.canAct, false);
});
