// Worker: runs the standard scenarios on one version with one seed number and
// sends back per-phase measurements, grid hashes and snapshot images.
import { parentPort, workerData } from 'node:worker_threads';
import { createHash } from 'node:crypto';
import { loadJs } from './js-engine.mjs';
import { loadRust } from './rust-engine.mjs';
import { countStreams } from './streams.mjs';

// Grid layout as in core/src/sim.rs: RGBA8 per cell (type, shade, energy, clock),
// one cell of wall all round.
const LIQUID = 0, AIR = 1, SAND = 3, COLOURS = 6;

// Lagoon palette (src/palettes.js), drawn opaque over white.
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const SAND_RGB = ['#0a2f7a', '#1a5fc4', '#22b4cf', '#7ddde3', '#eef7f6', '#071d4f', '#f2c443'].map(hex);
const LIQ_TOP = hex('#f4f7f8'), LIQ_BOT = hex('#e3eaee'), AIR_RGB = hex('#fbfdfe');

const { dir, wasm, tps, seedNo, w, h, fresh, hold, fps: FPS, snapAt, tune } = workerData;
const DT = 1 / FPS;
const FLIP_MS = 1150;                 // flip() in src/app.js
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

const ver = wasm ? await loadRust(wasm, tps) : await loadJs(dir);
const eng = ver.create(w, h, seedNo);
// Tuned as from the debug panel, then a new picture (R) so seed settings count too.
if (tune) { eng.tune(tune); eng.reseed(false); }
const { W } = eng;
const res = h / 581;                  // reference grid height in core/src/sim.rs

// Sand still hanging: in each column, every grain above the first real gap
// (open liquid or air at least ~3 mm deep) in the pile resting on the floor;
// gravity is straight up or down here. Piles hold small pockets of liquid, so
// a short gap doesn't count.
// Pour streams: see countStreams.
function measure(down) {
  const bytes = eng.bytes;
  const hang = new Float64Array(COLOURS + 1);
  const total = new Float64Array(COLOURS + 1);
  const falling = new Int32Array(w + 1);
  const dy = down ? W : -W;
  const minGap = Math.max(3, Math.round(6 * res));
  for (let x = 1; x <= w; x++) {
    let resting = true, open = 0;
    for (let k = 0; k < h; k++) {
      const y = down ? h - k : 1 + k, i = (y * W + x) * 4;
      const t = bytes[i];
      if (t < SAND) { if (++open >= minGap) resting = false; continue; }
      open = 0;
      const c = Math.min(t - SAND, COLOURS);
      total[c]++;
      if (!resting) {
        hang[c]++;
        if (bytes[i + 2] && bytes[i + 4 * dy] === LIQUID) falling[x]++;
      }
    }
  }
  return { hang, total, streams: countStreams(falling, w, res) };
}

function snapshot(upsideDown) {
  const bytes = eng.bytes;
  const s = 2, sw = Math.floor(w / s), sh = Math.floor(h / s);
  const rgb = new Uint8Array(sw * sh * 3);
  for (let Y = 0; Y < sh; Y++)
    for (let X = 0; X < sw; X++) {
      let r = 0, g = 0, b = 0;
      for (let yy = 0; yy < s; yy++)
        for (let xx = 0; xx < s; xx++) {
          // Shown as the viewer sees it: a frame resting flipped is turned over.
          const gx = upsideDown ? w - (X * s + xx) : X * s + xx + 1;
          const gy = upsideDown ? h - (Y * s + yy) : Y * s + yy + 1;
          const i = (gy * W + gx) * 4, t = bytes[i];
          let col;
          if (t >= SAND) {
            const p = SAND_RGB[Math.min(t - SAND, COLOURS)], k = 0.8 + 0.34 * (bytes[i + 1] / 255);
            col = [p[0] * k, p[1] * k, p[2] * k];
          } else if (t === AIR) col = AIR_RGB;
          else { const v = (Y * s + yy) / h; col = LIQ_TOP.map((a, n) => a + (LIQ_BOT[n] - a) * v); }
          r += col[0]; g += col[1]; b += col[2];
        }
      const o = (Y * sw + X) * 3, n = s * s;
      rgb[o] = Math.min(255, r / n); rgb[o + 1] = Math.min(255, g / n); rgb[o + 2] = Math.min(255, b / n);
    }
  return { sw, sh, rgb };
}

// Phases: a fresh start, then two flips, each followed by `hold` seconds at rest.
const phases = [
  { name: 'fresh', from: 0, to: 0, secs: fresh },
  { name: 'flip 1', from: 0, to: 180, secs: hold },
  { name: 'flip 2', from: 180, to: 360, secs: hold },
];
const out = [], snaps = [];
for (const ph of phases) {
  const animFrames = ph.from === ph.to ? 0 : Math.round((FLIP_MS / 1000) * FPS);
  for (let f = 1; f <= animFrames; f++) {
    const th = ((ph.from + (ph.to - ph.from) * ease(f / animFrames)) * Math.PI) / 180;
    eng.frame(DT, 0, Math.cos(th));
  }
  const gy = Math.cos((ph.to * Math.PI) / 180) > 0 ? 1 : -1, down = gy > 0;
  const every = Math.round(FPS / 2);           // measure twice a second
  let moves = 0, ticks = 0, hang0 = null, spread = 0, nSpread = 0;
  const m = { movesAt: [], hangAt: [], streams: [], t50: null };
  for (let f = 1; f <= ph.secs * FPS; f++) {
    const r = eng.frame(DT, 0, gy);
    moves += r.moves; ticks += r.ticks;
    const t = f / FPS;
    if (snapAt.includes(t) || f === ph.secs * FPS) snaps.push({ label: `${ph.name} ${Math.round(t)}s`, ...snapshot(!down) });
    if (f % every) continue;
    const { hang, total, streams } = measure(down);
    const all = total.reduce((a, b) => a + b), hung = hang.reduce((a, b) => a + b);
    hang0 ??= { hang: hang.slice(), hung };
    m.movesAt.push([t, ticks ? moves / ticks : 0]); moves = 0; ticks = 0;
    m.hangAt.push([t, hung / all]);
    m.streams.push(streams);
    if (m.t50 === null && hung <= hang0.hung / 2) m.t50 = t;
    // How evenly the colours drain: spread (SD) across colours of the fraction
    // of each one's hanging sand that has come down, averaged over the phase.
    // 0: all colours drain together; ~0.5: one band at a time.
    const fr = [];
    for (let c = 0; c < COLOURS; c++) if (hang0.hang[c] > 0.01 * all) fr.push(1 - hang[c] / hang0.hang[c]);
    if (fr.length > 1 && hung > 0.02 * all) {
      const mean = fr.reduce((a, b) => a + b) / fr.length;
      spread += Math.sqrt(fr.reduce((a, b) => a + (b - mean) ** 2, 0) / fr.length); nSpread++;
    }
  }
  m.spread = nSpread ? spread / nSpread : 0;
  m.hash = createHash('sha1').update(eng.bytes).digest('hex').slice(0, 12);
  const fl = eng.flow();
  m.flowHash = createHash('sha1').update(new Uint8Array(fl.u.buffer, fl.u.byteOffset, fl.u.byteLength))
    .update(new Uint8Array(fl.v.buffer, fl.v.byteOffset, fl.v.byteLength)).update(fl.solid).digest('hex').slice(0, 12);
  out.push(m);
}
parentPort.postMessage({ phases: out, snaps }, snaps.map((s) => s.rgb.buffer));
