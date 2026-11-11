import { readFileSync } from 'node:fs';
const config = JSON.parse(readFileSync(new URL('../../../Services/RemoteRelay/wrangler.jsonc', import.meta.url), 'utf8'));
export const admissionLimits = Object.fromEntries(config.ratelimits.map(({ name, ...limit }) => [name, limit]));
