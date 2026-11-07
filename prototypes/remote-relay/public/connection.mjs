import { channel, IgnoredFrameError } from './protocol.mjs';
import { relayOrigin } from './probe.mjs';

export async function connectPair({ origin, secret, access, role, onPayload = () => {}, onState = () => {}, onOpen = () => {},
  WebSocketImpl = globalThis.WebSocket, timers = globalThis }) {
  const secure = await channel(secret, role);
  const endpoint = new URL('/v1/connect', relayOrigin(origin));
  endpoint.protocol = endpoint.protocol === 'https:' ? 'wss:' : 'ws:';
  if (!/^[A-Za-z0-9_-]{43}$/.test(access ?? '')) throw new Error('Invalid invitation');
  let socket, stopped = false, retry = 0, retryTimer, heartbeat, pongTimer;
  let incoming = Promise.resolve();
  let resolveReady, rejectReady;
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  const initialTimeout = timers.setTimeout(() => { rejectReady(new Error('Relay connection timed out')); api.close(); }, 15000);
  const setState = state => { api.state = state; onState(state); };
  const clearHeartbeat = () => { timers.clearInterval(heartbeat); timers.clearTimeout(pongTimer); };
  const api = {
    ready, state: 'connecting',
    async send(payload) {
      const current = socket;
      if (stopped || current?.readyState !== WebSocketImpl.OPEN) throw new Error('Relay is not connected');
      const wire = await secure.seal(payload);
      if (stopped || current !== socket || current.readyState !== WebSocketImpl.OPEN) throw new Error('Relay is not connected');
      current.send(wire);
    },
    close() {
      stopped = true;
      timers.clearTimeout(initialTimeout); timers.clearTimeout(retryTimer); clearHeartbeat();
      rejectReady(new Error('Connection closed'));
      if (socket?.readyState === WebSocketImpl.OPEN || socket?.readyState === WebSocketImpl.CONNECTING) socket.close();
      setState('closed');
    },
  };
  function disconnect(current) {
    if (stopped || current !== socket) return;
    // Abandon dead connections without waiting for a TCP/WebSocket closing handshake.
    socket = undefined;
    clearHeartbeat();
    setState('disconnected');
    retryTimer = timers.setTimeout(open, Math.min(30000, 1000 * 2 ** Math.min(retry++, 5)) + Math.random() * 500);
    try { current.close(4000, 'Reconnect'); } catch { /* the socket may already be unusable */ }
  }
  function open() {
    if (stopped) return;
    setState('connecting');
    socket = new WebSocketImpl(endpoint, ['mt-v1', `access-${access}`, `room-${secure.room}`, `role-${role}`]);
    const current = socket;
    socket.addEventListener('open', () => {
      if (stopped || current !== socket) return;
      timers.clearTimeout(initialTimeout);
      resolveReady();
      setState('connected');
      Promise.resolve().then(() => onOpen(api)).catch(() => disconnect(current));
      heartbeat = timers.setInterval(() => {
        if (current.readyState !== WebSocketImpl.OPEN) return;
        current.send('ping');
        pongTimer = timers.setTimeout(() => disconnect(current), 10000);
      }, 25000);
    });
    socket.addEventListener('message', event => {
      if (stopped || current !== socket) return;
      if (event.data === 'pong') { timers.clearTimeout(pongTimer); return; }
      incoming = incoming.then(async () => {
        if (stopped || current !== socket) return;
        // Relay status is advisory. Only an authenticated payload can establish host readiness or completion.
        const envelope = JSON.parse(event.data);
        if (envelope?.relay === 'peer-offline') { setState('peer-offline'); return; }
        const payload = await secure.open(event.data);
        if (stopped || current !== socket) return;
        await onPayload(payload);
        if (!stopped && current === socket) retry = 0;
      }).catch(error => {
        if (stopped || current !== socket || error instanceof IgnoredFrameError) return;
        disconnect(current);
      });
    });
    socket.addEventListener('error', () => disconnect(current));
    socket.addEventListener('close', event => {
      if (current !== socket) return;
      clearHeartbeat();
      if (stopped) return;
      if ([4008, 4009, 4001].includes(event.code)) {
        stopped = true;
        timers.clearTimeout(initialTimeout);
        rejectReady(new Error('Relay rejected the connection'));
        setState('rejected');
        return;
      }
      disconnect(current);
    });
  }
  open();
  return api;
}
