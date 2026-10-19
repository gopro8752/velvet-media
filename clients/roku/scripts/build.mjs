import { readFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const root = fileURLToPath(new URL('../', import.meta.url));
process.chdir(root);
const output = path.join(root, 'dist/velvet-roku.zip');
// Remove a previous artifact first so a failed check cannot leave a deployable stale ZIP.
rmSync(output, { force: true });
rmSync(`${output}.sha256`, { force: true });
rmSync(path.join(root, 'dist/staging'), { recursive: true, force: true });
const manifest = readFileSync('manifest', 'utf8');
for (const match of manifest.matchAll(/^\w+=pkg:\/(.+)$/gm)) {
  if (!existsSync(match[1].trim())) throw new Error(`Missing manifest asset: ${match[1]}`);
}
const result = spawnSync(process.execPath, [require.resolve('brighterscript/dist/cli.js'), '--project', 'bsconfig.json'], {
  cwd: root, stdio: 'inherit'
});
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
if (!existsSync(output)) throw new Error('Compiler completed without creating dist/velvet-roku.zip');
const listing = spawnSync('unzip', ['-Z1', output], { encoding: 'utf8' });
if (listing.error || listing.status !== 0) throw new Error('Install unzip to verify the generated package.');
const entries = listing.stdout.trim().split(/\r?\n/);
const allowed = /^(manifest|(?:source|components)\/.+\.(?:brs|xml)|images\/.+\.(?:png|jpe?g)|fonts\/.+\.(?:ttf|otf)|fonts\/(?:Inter|Outfit)-OFL\.txt|locale\/.+\.(?:xml|ts))$/i;
for (const entry of entries) {
  const appDirectory = /^(?:source|components|images|fonts|locale)(?:\/[^/]+)*\/$/.test(entry);
  if ((!appDirectory && !allowed.test(entry)) || entry.split('/').some(part => part.startsWith('.'))) {
    rmSync(output, { force: true });
    throw new Error(`Unexpected package entry: ${entry}`);
  }
}
if (!entries.includes('manifest') || !entries.some(p => /^source\/.+\.brs$/i.test(p))) {
  rmSync(output, { force: true });
  throw new Error('Package needs a manifest and BrightScript entry source.');
}
const digest = createHash('sha256').update(readFileSync(output)).digest('hex');
mkdirSync('dist', { recursive: true });
writeFileSync(`${output}.sha256`, `${digest}  velvet-roku.zip\n`);
console.log(`Verified ${entries.filter(entry => !entry.endsWith('/')).length} package files: dist/velvet-roku.zip`);
console.log(`SHA256 ${digest}`);
