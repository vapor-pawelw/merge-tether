import { writeFile, readFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';

if (process.argv.includes('--help')) {
  console.log('Usage: npm run setup\nCreates an ignored .dev.vars invitation for local development only.');
} else {
  try {
    const token = randomBytes(32).toString('base64url');
    await writeFile('.dev.vars', `RELAY_ACCESS_TOKEN=${token}\n`, { mode: 0o600, flag: 'wx' });
    console.log('Created local invitation in .dev.vars. Keep it private. Start the relay with npm run dev.');
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const existing = await readFile('.dev.vars', 'utf8');
    if (!/^RELAY_ACCESS_TOKEN=[A-Za-z0-9_-]{43}\s*$/.test(existing)) throw new Error('Existing .dev.vars is not a probe invitation; leave it intact and use a clean directory.');
    console.log('Local invitation already exists; preserved it.');
  }
}
