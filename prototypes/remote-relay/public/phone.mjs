export class PhoneProbe {
  state = 'closed';
  result = 'idle';
  snapshot;
  pending;
  fresh = false;
  challenge;
  validUntil = 0;
  constructor(now = () => Date.now()) { this.now = now; }
  hello() {
    this.challenge = crypto.randomUUID();
    return { type: 'hello', challenge: this.challenge };
  }

  get hostAvailable() { return this.state === 'connected' && this.fresh && this.now() < this.validUntil; }
  get canAct() { return this.hostAvailable && !this.pending; }
  get canRefresh() { return this.state === 'connected'; }

  transport(state) {
    this.state = state;
    this.fresh = false;
    this.challenge = undefined;
    if (state !== 'connected' && state !== 'connecting') this.expireCommand();
  }

  beginCommand() {
    if (!this.canAct) return;
    this.pending = crypto.randomUUID();
    this.result = 'sending';
    return { type: 'command', id: this.pending, hostSession: this.snapshot.hostSession, action: 'probe' };
  }

  expireCommand() {
    if (!this.pending) return;
    this.pending = undefined;
    this.fresh = false;
    this.result = 'uncertain';
  }

  receive(message) {
    if (message?.type === 'snapshot' && this.challenge && message.challenge === this.challenge
        && typeof message.hostSession === 'string' && Array.isArray(message.lanes)) {
      this.snapshot = message;
      this.fresh = true;
      this.challenge = undefined;
      this.validUntil = this.now() + 45000;
      this.state = 'connected';
      return 'snapshot';
    }
    if (!this.pending || message?.id !== this.pending) return;
    if (message.type === 'accepted') this.result = 'accepted';
    if (message.type === 'completed' || message.type === 'rejected') {
      this.pending = undefined;
      this.result = message.type;
      if (message.type === 'rejected') this.fresh = false;
      if (message.type === 'completed') this.snapshot = { ...this.snapshot, executions: message.executions };
    }
    return message.type;
  }
}
