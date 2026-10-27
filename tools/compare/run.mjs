// Side-by-side comparison of two versions of the sim on the standard scenarios:
// a fresh start settling, then two flips. Prints a few numbers per phase and
// writes one composite PNG (a row per version, a column per snapshot).
//
//   node tools/compare/run.mjs [A] [B] [--seeds 1,2,3] [--size 1000x725] [--fresh 600] [--hold 600] [--fps 60]
//                              [--tune '<json>' | --tune file.json]
//
// --tune: settings in the debug panel's "Copy settings" shape, applied to both
// versions before a new starting picture is drawn.
//
// A version is "." (this working tree's core/, built for wasm; "rust" is the
// same) or any git ref: the JS physics for refs from before it was deleted
// (they have src/sim.js), else that ref's committed src/sand_core.wasm.
// Defaults HEAD and ".".
import { Worker } from 'node:worker_threads';
import { execSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { writePng } from './png.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf('--' + name); return i < 0 ? def : args.splice(i, 2)[1]; };
const seeds = opt('seeds', '1').split(',').map(Number);
const [w, h] = opt('size', '1000x725').split('x').map(Number);
const fresh = +opt('fresh', 600), hold = +opt('hold', 600), fps = +opt('fps', 60);
const specs = [args[0] ?? 'HEAD', args[1] ?? '.'];
const snapAt = [150];
const tuneArg = opt('tune', null);
const tune = tuneArg && JSON.parse(tuneArg.trim().startsWith('{') ? tuneArg : readFileSync(tuneArg, 'utf8'));

// Each git ref gets its own copy of src/, marked as ES modules.
const local = (s) => s === '.' || s === 'rust';
const tmp = mkdtempSync(join(tmpdir(), 'sand-compare-'));
const names = specs.map((s) => (local(s) ? 'working tree'
  : execSync(`git rev-parse --short ${s}`, { cwd: root }).toString().trim()));
const dirs = specs.map((s, k) => {
  if (local(s)) return null;
  const d = join(tmp, String(k));
  mkdirSync(d);
  execSync(`git archive ${s} src | tar -x -C ${d} --strip-components 1`, { cwd: root });
  writeFileSync(join(d, 'package.json'), '{"type":"module"}');
  return d;
});

// The core gets the web app's tick rate; its timing and physics are its own.
let built = null;
if (specs.some(local)) {
  const cargo = existsSync(join(homedir(), '.cargo/bin/cargo')) ? join(homedir(), '.cargo/bin/cargo') : 'cargo';
  execSync(`${cargo} build --release --quiet --target wasm32-unknown-unknown`, { cwd: join(root, 'core'), stdio: 'inherit' });
  built = join(root, 'core/target/wasm32-unknown-unknown/release/sand_core.wasm');
  if (!readFileSync(built).equals(readFileSync(join(root, 'src/sand_core.wasm'))))
    console.log('note: src/sand_core.wasm is not this core/ (run tools/build-core.sh)');
}
const wasms = specs.map((s, k) => (local(s) ? built : existsSync(join(dirs[k], 'sim.js')) ? null : join(dirs[k], 'sand_core.wasm')));
const tps = +readFileSync(join(root, 'src/app.js'), 'utf8').match(/const TICKS_PER_SEC = (\d+)/)[1];

const t0 = Date.now();
const run = (k, seedNo) => new Promise((resolve, reject) => {
  const job = { dir: dirs[k], wasm: wasms[k], tps, seedNo, w, h, fresh, hold, fps, snapAt, tune };
  const wk = new Worker(join(here, 'job.mjs'), { workerData: job });
  wk.once('message', resolve); wk.once('error', reject);
});
const results = await Promise.all(specs.map((_, k) => Promise.all(seeds.map((s) => run(k, s)))));
rmSync(tmp, { recursive: true, force: true });

// ---------- numbers ----------
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;
const at = (series, t) => series.find(([s]) => s >= t)?.[1] ?? series[series.length - 1][1];
const window = (series, a, b) => mean(series.filter(([s]) => s > a && s <= b).map(([, v]) => v));
const pad = (s, n) => String(s).padEnd(n);
const f1 = (v) => (Number.isFinite(v) ? v.toFixed(1) : '-');

console.log(`${w}x${h} at ${fps} fps, seeds ${seeds.join(',')}, fresh ${fresh}s, flips held ${hold}s  (A = ${names[0]}, B = ${names[1]})`);
if (tune) console.log(`tuned: ${JSON.stringify(tune)}`);
console.log(`${pad('', 11)}${pad('moves/tick k: 0-10s 10-60 60-300 300+', 40)}${pad('hanging %: 60s 300s end', 25)}${pad('t50 s', 7)}${pad('streams avg/max', 17)}colour spread`);
const phaseNames = ['fresh', 'flip 1', 'flip 2'];
phaseNames.forEach((ph, p) => {
  results.forEach((runs, v) => {
    const r = runs.map((x) => x.phases[p]);
    const mv = [[0, 10], [10, 60], [60, 300], [300, 1e9]].map(([a, b]) => mean(r.map((m) => window(m.movesAt, a, b) / 1000)));
    const hg = [60, 300, 1e9].map((t) => mean(r.map((m) => at(m.hangAt, t) * 100)));
    const t50 = r.every((m) => m.t50 !== null) ? mean(r.map((m) => m.t50)) : NaN;
    const st = mean(r.map((m) => mean(m.streams))), stMax = Math.max(...r.flatMap((m) => m.streams));
    console.log(`${pad(v ? '' : ph, 8)}${pad('AB'[v], 3)}${pad(mv.map(f1).join(' '), 40)}${pad(hg.map(f1).join(' '), 25)}${pad(f1(t50), 7)}${pad(`${f1(st)} / ${stMax}`, 17)}${mean(r.map((m) => m.spread)).toFixed(2)}`);
  });
});
for (const [what, key] of [['grids', 'hash'], ['liquid flow', 'flowHash']]) {
  const same = phaseNames.map((_, p) => seeds.every((_, s) => results[0][s].phases[p][key] === results[1][s].phases[p][key]));
  console.log(same.every(Boolean) ? `${what}: A and B identical bit for bit at every phase end`
    : `${what} differ from: ${phaseNames[same.indexOf(false)]}`);
}
for (const [what, key] of [['grid', 'hash'], ['flow', 'flowHash']])
  console.log(`${what} hashes (seed ${seeds[0]}): ${results.map((runs, v) => 'AB'[v] + ' ' + runs[0].phases.map((m) => m[key]).join(' ')).join(' | ')}`);

// ---------- composite image (first seed) ----------
const rows = results.map((runs) => runs[0].snaps);
const { sw, sh } = rows[0][0], G = 6;
const cols = rows[0].length, CW = cols * sw + (cols - 1) * G, CH = 2 * sh + G;
const img = new Uint8Array(CW * CH * 3).fill(40);
rows.forEach((snaps, r) => snaps.forEach((s, c) => {
  for (let y = 0; y < sh; y++)
    img.set(s.rgb.subarray(y * sw * 3, (y + 1) * sw * 3), ((r * (sh + G) + y) * CW + c * (sw + G)) * 3);
}));
const outDir = join(here, 'out');
mkdirSync(outDir, { recursive: true });
const file = join(outDir, `${names.map((n) => n.replace(/\W+/g, '-')).join('_vs_')}${tune ? '_tuned' : ''}_seed${seeds[0]}.png`);
writePng(file, CW, CH, img);
console.log(`image: ${relative(process.cwd(), file)}  (rows A, B; columns ${rows[0].map((s) => s.label).join(', ')})  [${Math.round((Date.now() - t0) / 1000)}s]`);
