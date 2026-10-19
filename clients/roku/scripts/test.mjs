import { readFileSync, readdirSync, mkdtempSync, mkdirSync, copyFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
const root = fileURLToPath(new URL('../', import.meta.url));
function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const next = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(next) : [next];
  });
}
const specs = walk(path.join(root, 'tests')).filter(p => p.endsWith('.spec.brs')).sort();
if (!specs.length) throw new Error('No tests/*.spec.brs found. Add a production-logic spec before validating.');
const sources = JSON.parse(readFileSync(path.join(root, 'tests/logic-files.json'), 'utf8'));
if (!Array.isArray(sources) || !sources.length) throw new Error('tests/logic-files.json must list production helper paths.');
// Isolate pure logic from SceneGraph: the interpreter is not a Roku UI runtime.
const sandbox = mkdtempSync(path.join(tmpdir(), 'velvet-roku-logic-'));
let failures = 0;
try {
  copyFileSync(path.join(root, 'manifest'), path.join(sandbox, 'manifest'));
  for (const source of sources) {
    if (typeof source !== 'string' || !/^(source|components)\/.+\.brs$/.test(source) || source.includes('..')) {
      throw new Error('Invalid production helper path in tests/logic-files.json');
    }
    const target = path.join(sandbox, source);
    mkdirSync(path.dirname(target), { recursive: true });
    copyFileSync(path.join(root, source), target);
  }
  for (const spec of specs) {
    const relative = path.relative(root, spec);
    const target = path.join(sandbox, relative);
    mkdirSync(path.dirname(target), { recursive: true });
    copyFileSync(spec, target);
    const result = spawnSync(process.execPath, [require.resolve('@rokucommunity/brs/bin/cli.js'),
      '--root', sandbox, '--no-color', ...sources.map(p => path.join(sandbox, p)), target], {
      cwd: sandbox, encoding: 'utf8', timeout: 20000, maxBuffer: 1024 * 1024
    });
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    const passed = !result.error && result.status === 0 && !result.stderr.trim() &&
      /^VELVET_TEST_PASS\s*$/m.test(result.stdout) && !/VELVET_TEST_FAIL/.test(result.stdout);
    console.log(`${passed ? 'PASS' : 'FAIL'} ${relative}`);
    if (!passed) failures++;
  }
} finally {
  rmSync(sandbox, { recursive: true, force: true });
}
console.log(`${specs.length - failures}/${specs.length} production logic specs passed.`);
process.exitCode = failures ? 1 : 0;
