import { channel } from './protocol.mjs';
import { relayOrigin } from './probe.mjs';

export async function connectPair({ origin, secret, access, role, onPayload = () => {}, onState = () => {}, onOpen = () => {} }) {
  const secure = await channel(secret, role);
  const endpoint = new URL('/v1/connect', relayOrigin(origin));
  endpoint.protocol = endpoint.protocol === 'https:' ? 'wss:' : 'ws:';
  if (!/^[A-Za-z0-9_-]{43}$/.test(access ?? '')) throw new Error('Invalid invitation');
  let socket, stopped = false, retry = 0, retryTimer, heartbeat, pongTimer;
  let incoming = Promise.resolve();
  let resolveReady, rejectReady;
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  const initialTimeout = setTimeout(() => { rejectReady(new Error('Relay connection timed out')); api.close(); }, 15000);
  const setState = state => { api.state = state; onState(state); };
  const clearHeartbeat = () => { clearInterval(heartbeat); clearTimeout(pongTimer); };
  const api = {
    ready, state: 'connecting',
    async send(payload) {
      const current = socket;
      if (stopped || current?.readyState !== WebSocket.OPEN) throw new Error('Relay is not connected');
      const wire = await secure.seal(payload);
      if (stopped || current !== socket || current.readyState !== WebSocket.OPEN) throw new Error('Relay is not connected');
      current.send(wire);
    },
    close() {
      stopped = true;
      clearTimeout(initialTimeout); clearTimeout(retryTimer); clearHeartbeat();
      rejectReady(new Error('Connection closed'));
      if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) socket.close();
      setState('closed');
    },
  };
  function open() {
    if (stopped) return;
    setState('connecting');
    socket = new WebSocket(endpoint, ['mt-v1', `access-${access}`, `room-${secure.room}`, `role-${role}`]);
    const current = socket;
    socket.addEventListener('open', () => {
      if (stopped || current !== socket) return;
      retry = 0;
      clearTimeout(initialTimeout);
      resolveReady();
      setState('connected');
      Promise.resolve(onOpen(api)).catch(() => current.close(1008, 'Client failed'));
      heartbeat = setInterval(() => {
        if (current.readyState !== WebSocket.OPEN) return;
        current.send('ping');
        pongTimer = setTimeout(() => current.close(4000, 'Heartbeat timeout'), 10000);
      }, 25000);
    });
    socket.addEventListener('message', event => {
      if (stopped || current !== socket) return;
      if (event.data === 'pong') { clearTimeout(pongTimer); return; }
      incoming = incoming.then(async () => {
        if (stopped || current !== socket) return;
        // Relay status is advisory. Only an authenticated payload can establish host readiness or completion.
        const envelope = JSON.parse(event.data);
        if (envelope?.relay === 'peer-offline') { setState('peer-offline'); return; }
        await onPayload(await secure.open(event.data));
      }).catch(() => {
        setState('invalid-message');
        current.close(1008, 'Invalid message');
      });
    });
    socket.addEventListener('error', () => { /* close drives the bounded reconnect delay */ });
    socket.addEventListener('close', event => {
      if (current !== socket) return;
      clearHeartbeat();
      if (stopped) return;
      if ([1008, 1009, 4001].includes(event.code)) {
        stopped = true;
        clearTimeout(initialTimeout);
        rejectReady(new Error('Relay rejected the connection'));
        setState('rejected');
        return;
      }
      setState('disconnected');
      retryTimer = setTimeout(open, Math.min(30000, 1000 * 2 ** Math.min(retry++, 5)) + Math.random() * 500);
    });
  }
  open();
  return api;
}
