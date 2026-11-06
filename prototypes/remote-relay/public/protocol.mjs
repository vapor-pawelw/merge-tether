const encoder = new TextEncoder();
const decoder = new TextDecoder();
const credential = /^[A-Za-z0-9_-]{43}$/;
export const MAX_FRAME_BYTES = 16384;

function encode(bytes) {
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function decode(text) {
  return Uint8Array.from(atob(text.replaceAll('-', '+').replaceAll('_', '/')), char => char.charCodeAt(0));
}

export async function pairing(secret = encode(crypto.getRandomValues(new Uint8Array(32)))) {
  if (!credential.test(secret) || encode(decode(secret)) !== secret) throw new Error('Invalid pairing secret');
  const room = encode(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(`mt-probe-route-v1:${secret}`))));
  return { secret, room };
}

export async function channel(secret, role) {
  if (!['host', 'phone'].includes(role)) throw new Error('Invalid role');
  const { room } = await pairing(secret);
  const material = await crypto.subtle.importKey('raw', decode(secret), 'HKDF', false, ['deriveKey']);
  const keyFor = sender => crypto.subtle.deriveKey({
    name: 'HKDF', hash: 'SHA-256', salt: encoder.encode('MergeTether remote probe v1'),
    info: encoder.encode(sender),
  }, material, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const ownKey = await keyFor(role);
  const peer = role === 'host' ? 'phone' : 'host';
  const peerKey = await keyFor(peer);
  const seen = new Map();
  const aad = frame => encoder.encode(JSON.stringify([1, room, frame.sender, frame.at]));
  return {
    room,
    async seal(payload) {
      const plain = encoder.encode(JSON.stringify(payload));
      if (plain.byteLength > 8192) throw new Error('Payload too large');
      const nonce = crypto.getRandomValues(new Uint8Array(12));
      const frame = { v: 1, sender: role, at: Date.now(), nonce: encode(nonce) };
      const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: aad(frame) }, ownKey, plain);
      return JSON.stringify({ ...frame, data: encode(new Uint8Array(cipher)) });
    },
    async open(wire) {
      if (typeof wire !== 'string' || encoder.encode(wire).byteLength > MAX_FRAME_BYTES) throw new Error('Invalid frame');
      const frame = JSON.parse(wire);
      if (frame?.v !== 1 || frame.sender !== peer || !Number.isSafeInteger(frame.at)
          || Math.abs(Date.now() - frame.at) > 60000 || !/^[A-Za-z0-9_-]{16}$/.test(frame.nonce)
          || typeof frame.data !== 'string' || !/^[A-Za-z0-9_-]+$/.test(frame.data)) throw new Error('Invalid frame');
      for (const [nonce, at] of seen) if (Date.now() - at > 60000) seen.delete(nonce);
      if (seen.has(frame.nonce)) throw new Error('Replay rejected');
      if (seen.size >= 2048) throw new Error('Receiver rate exceeded');
      const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: decode(frame.nonce), additionalData: aad(frame) }, peerKey, decode(frame.data));
      const result = JSON.parse(decoder.decode(plain));
      // Another caller can finish decrypting this nonce while WebCrypto is awaited.
      if (seen.has(frame.nonce)) throw new Error('Replay rejected');
      seen.set(frame.nonce, Date.now());
      return result;
    },
  };
}
