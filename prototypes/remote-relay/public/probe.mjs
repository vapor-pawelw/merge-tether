const tokenPattern = /^[A-Za-z0-9_-]{43}$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class ProbeHost {
  session = crypto.randomUUID();
  executions = 0;
  results = new Map();

  handle(message) {
    if (message?.type === 'hello') return [{
      type: 'snapshot', challenge: message.challenge, hostSession: this.session, generatedAt: new Date().toISOString(),
      executions: this.executions,
      lanes: [
        { id: 'ready', cards: [{ id: 'connection', kind: 'connection' }] },
        { id: 'working', cards: [] },
        { id: 'done', cards: this.executions ? [{ id: 'result', kind: 'result', count: this.executions }] : [] },
      ],
    }];
    if (message?.type !== 'command') return [];
    const rejected = reason => [{ type: 'rejected', id: message.id, reason }];
    if (!uuidPattern.test(message.id ?? '') || message.action !== 'probe') return rejected('unsupported');
    if (message.hostSession !== this.session) return rejected('stale-session');
    if (this.results.has(message.id)) return this.results.get(message.id);
    if (this.results.size >= 256) return rejected('session-limit');
    const result = [
      { type: 'accepted', id: message.id },
      { type: 'completed', id: message.id, executions: ++this.executions, completedAt: new Date().toISOString() },
    ];
    // Keep every command ID for this host session; never evict and accidentally execute a retry twice.
    this.results.set(message.id, result);
    return result;
  }
}

export function relayOrigin(value) {
  const url = new URL(value);
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error('Invalid relay origin');
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))) {
    throw new Error('HTTPS is required outside localhost');
  }
  return url.origin;
}

export function pairingURL(origin, { secret, access }) {
  if (!tokenPattern.test(secret ?? '') || !tokenPattern.test(access ?? '')) throw new Error('Invalid pairing credentials');
  return `${relayOrigin(origin)}/#${new URLSearchParams({ v: '1', secret, access })}`;
}

export function parsePairingURL(value) {
  const url = new URL(value);
  const fragment = new URLSearchParams(url.hash.slice(1));
  const secret = fragment.get('secret');
  const access = fragment.get('access');
  url.hash = '';
  const origin = relayOrigin(url.href);
  if (fragment.get('v') !== '1' || !tokenPattern.test(secret ?? '') || !tokenPattern.test(access ?? '')) {
    throw new Error('Invalid pairing link');
  }
  return { origin, secret, access };
}
