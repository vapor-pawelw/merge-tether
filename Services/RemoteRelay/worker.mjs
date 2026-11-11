import { DurableObject } from 'cloudflare:workers';

const keyPattern = /^[A-Za-z0-9_-]{43}$/;
const securityHeaders = {
  'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
};

function admissionResponse(status, message) {
  return new Response(message, { status, headers: { 'Cache-Control': 'no-store', 'Retry-After': '60' } });
}

async function admit(request, env) {
  // These approximate, per-location counters reduce abuse; Workers Free is the billing boundary.
  if (!env.IP_ADMISSION || !env.DEPLOYMENT_ADMISSION) return admissionResponse(503, 'Relay admission is not configured');
  try {
    const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
    if (!(await env.IP_ADMISSION.limit({ key: ip })).success) return admissionResponse(429, 'Connection attempt limit reached');
    if (!(await env.DEPLOYMENT_ADMISSION.limit({ key: 'relay-connect' })).success) return admissionResponse(429, 'Relay connection limit reached');
  } catch {
    return admissionResponse(503, 'Relay admission is unavailable');
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/v1/connect') {
      if (request.method !== 'GET' || !env.ASSETS) return new Response('Not found', { status: 404 });
      const asset = await env.ASSETS.fetch(request);
      const response = new Response(asset.body, asset);
      for (const [name, value] of Object.entries(securityHeaders)) response.headers.set(name, value);
      return response;
    }
    const denied = await admit(request, env);
    if (denied) return denied;
    if (!keyPattern.test(env.RELAY_ACCESS_TOKEN ?? '')) return new Response('Relay invitation is not configured', { status: 503 });
    if (request.method !== 'GET' || request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('WebSocket required', { status: 426 });
    }
    const origin = request.headers.get('Origin');
    if (origin && origin !== url.origin) return new Response('Forbidden origin', { status: 403 });
    const protocols = (request.headers.get('Sec-WebSocket-Protocol') ?? '').split(',').map(value => value.trim());
    const access = protocols.find(value => value.startsWith('access-'))?.slice(7);
    const room = protocols.find(value => value.startsWith('room-'))?.slice(5);
    const role = protocols.find(value => value.startsWith('role-'))?.slice(5);
    if (!protocols.includes('mt-v1') || !keyPattern.test(access ?? '') || !keyPattern.test(room ?? '')
        || !['host', 'phone'].includes(role)) return new Response('Unauthorized', { status: 401 });
    // Compare hashes rather than revealing a prefix of the invitation through string timing.
    const hash = async value => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
    const actual = await hash(access);
    const expected = await hash(env.RELAY_ACCESS_TOKEN);
    let difference = 0;
    for (let index = 0; index < expected.length; index++) difference |= actual[index] ^ expected[index];
    if (difference !== 0) return new Response('Unauthorized', { status: 401 });
    return env.ROOMS.getByName(room).fetch(new Request(`https://room.internal/${role}`, { headers: { Upgrade: 'websocket' } }));
  },
};

export class RelayRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  fetch(request) {
    const role = new URL(request.url).pathname.slice(1);
    if (!['host', 'phone'].includes(role)) return new Response('Invalid role', { status: 400 });
    if (this.ctx.getWebSockets().length >= 8) return new Response('Reconnect limit reached', { status: 429 });
    // A reconnect replaces the stale socket for this role. The attachment persists through hibernation.
    for (const old of this.ctx.getWebSockets(role)) {
      old.serializeAttachment({ ...old.deserializeAttachment(), active: false });
      old.close(4001, 'Reconnected');
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({ role, active: true });
    return new Response(null, { status: 101, webSocket: client, headers: { 'Sec-WebSocket-Protocol': 'mt-v1' } });
  }

  webSocketMessage(socket, message) {
    const state = socket.deserializeAttachment();
    if (!state?.active) return;
    if (typeof message !== 'string' || new TextEncoder().encode(message).byteLength > 262144) {
      socket.close(4009, 'Frame too large');
      return;
    }
    const now = Date.now();
    const windowStart = now - (state.windowStart ?? 0) < 60000 ? state.windowStart : now;
    const messages = windowStart === state.windowStart ? state.messages + 1 : 1;
    if (messages > 120) {
      socket.close(4008, 'Message limit reached');
      return;
    }
    socket.serializeAttachment({ ...state, windowStart, messages });
    const peerRole = state.role === 'host' ? 'phone' : 'host';
    const peers = this.ctx.getWebSockets(peerRole).filter(peer => peer.deserializeAttachment()?.active);
    if (!peers.length) {
      socket.send(JSON.stringify({ relay: 'peer-offline' }));
      return;
    }
    for (const peer of peers) peer.send(message);
  }

  webSocketClose(socket, code) {
    const state = socket.deserializeAttachment();
    if (!state?.active) return;
    socket.serializeAttachment({ ...state, active: false });
    const peerRole = state.role === 'host' ? 'phone' : 'host';
    for (const peer of this.ctx.getWebSockets(peerRole)) {
      if (peer.deserializeAttachment()?.active) peer.send(JSON.stringify({ relay: 'peer-offline' }));
    }
    socket.close([1005, 1006, 1015].includes(code) ? 1000 : code);
  }

  webSocketError(socket) { socket.close(1011, 'Connection failed'); }
}
