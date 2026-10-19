import { readFileSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { createInterface } from 'node:readline';
import { Writable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const root = fileURLToPath(new URL('../', import.meta.url));
if (process.argv.includes('--help')) {
  console.log('ROKU_HOST=<device IP> npm run deploy\nPassword: hidden terminal prompt, ROKU_PASSWORD, or private ROKU_PASSWORD_FILE.\nBuilds and tests before replacing the developer app. Does not activate developer mode.');
  process.exit(0);
}
async function password() {
  if (process.env.ROKU_PASSWORD_FILE) {
    const file = process.env.ROKU_PASSWORD_FILE;
    const stat = statSync(file);
    if (!stat.isFile() || (process.platform !== 'win32' && (stat.mode & 0o077) !== 0)) {
      throw new Error('ROKU_PASSWORD_FILE must be a private file (chmod 600).');
    }
    return readFileSync(file, 'utf8').replace(/\r?\n$/, '');
  }
  if (process.env.ROKU_PASSWORD) return process.env.ROKU_PASSWORD;
  if (!process.stdin.isTTY) throw new Error('Set ROKU_PASSWORD_FILE or use a terminal for the hidden password prompt.');
  const muted = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
  const rl = createInterface({ input: process.stdin, output: muted, terminal: true });
  process.stderr.write('Roku developer password (hidden): ');
  return new Promise((resolve, reject) => {
    rl.once('SIGINT', () => { rl.close(); reject(new Error('Canceled.')); });
    rl.question('', answer => { rl.close(); process.stderr.write('\n'); resolve(answer); });
  });
}
try {
  const host = process.env.ROKU_HOST;
  if (!host || !/^[a-zA-Z0-9.-]+$/.test(host)) throw new Error('Set ROKU_HOST to the explicitly selected Roku IP address or hostname.');
  for (const script of ['build.mjs', 'test.mjs']) {
    const result = spawnSync(process.execPath, [path.join(root, 'scripts', script)], { cwd: root, stdio: 'inherit' });
    if (result.error || result.status !== 0) throw new Error('Build or logic tests failed; nothing was installed.');
  }
  const response = await fetch(`http://${host}:8060/query/device-info`, { signal: AbortSignal.timeout(5000) });
  const device = await response.text();
  if (!response.ok || !/<developer-enabled>\s*true\s*<\/developer-enabled>/i.test(device)) {
    throw new Error('This Roku is not reporting developer mode enabled. Follow the private sideload setup in README.md first.');
  }
  const secret = await password();
  if (!secret) throw new Error('A nonempty developer password is required.');
  console.log(`Installing the verified ZIP on ${host}. This replaces the single developer app and opens Velvet.`);
  // publish() uploads the existing ZIP; unlike deploy(), it does not delete the previous app first.
  await require('roku-deploy').publish({
    host, password: secret, username: 'rokudev', rootDir: root,
    outDir: path.join(root, 'dist'), outFile: 'velvet-roku',
    failOnCompileError: true, deleteInstalledChannel: false, remoteDebug: false,
    autoLaunch: true
  });
  console.log('Velvet installed successfully. Verify its UI and playback on the Roku.');
} catch (error) {
  // Request errors may embed credentials or authorization headers. Never print the object/stack/body.
  const safe = /^(Set ROKU_HOST|Build or logic|This Roku is not|ROKU_PASSWORD_FILE|Set ROKU_PASSWORD_FILE|A nonempty|Canceled\.)/.test(error.message ?? '');
  console.error(safe ? error.message : 'Roku deployment failed. Check developer mode, connectivity, password, and the device debug console; credentials were not logged.');
  process.exitCode = 1;
}
