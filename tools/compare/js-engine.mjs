// One version of the JS sim, run headless: src/engine.js's frame timing without
// the drawing or the wall-clock budget (a fast enough machine never hits it),
// so a run depends only on the seed number.
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

// Same generator as src/rng.js. Versions from before rng.js drew their picture
// from Math.random, so for them it stands in for Math.random during seeding,
// in the same order of draws, which gives them the same starting picture.
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function withRandom(R, fn) {
  const orig = Math.random;
  Math.random = R;
  try { return fn(); } finally { Math.random = orig; }
}

// dir: a copy of some version's src/.
export async function loadJs(dir) {
  const imp = (f) => import(pathToFileURL(join(dir, f)).href);
  const [{ Sim }, { Fluid }, { seed }, { engineParams }] =
    await Promise.all([imp('sim.js'), imp('fluid.js'), imp('seed.js'), imp('engine.js')]);
  const seeded = existsSync(join(dir, 'rng.js'));
  const num = (file, name) => +readFileSync(join(dir, file), 'utf8').match(new RegExp(`const ${name} = ([\\d.]+)`))[1];
  const MAX_TICKS = num('engine.js', 'MAX_TICKS'), tps = num('app.js', 'TICKS_PER_SEC');
  const { timeScale } = engineParams;

  return {
    tps, timeScale,
    create(w, h, seedNo) {
      const fluid = new Fluid(w + 2, h + 2, Math.max(w, h) > 1600 ? 4 : 3);
      const rng = mulberry32(seedNo);
      const sim = seeded ? new Sim(w, h, fluid, rng) : withRandom(rng, () => new Sim(w, h, fluid));
      sim.setTickRate(tps);
      const reseed = (upsideDown) => {
        if (seeded) seed(sim, rng, upsideDown); else withRandom(rng, () => seed(sim, upsideDown));
        fluid.reset();
        sim.updateSolids(0, fluid.ny);
      };
      reseed(false);

      let acc = 0, frameNo = 0, lastGA = NaN, lastGM = NaN;
      return {
        W: sim.W, H: sim.H, bytes: sim.bytes,
        reseed,
        // As Engine.frame: returns ticks run and grain moves.
        frame(dt, gx, gy) {
          const ga = Math.atan2(gy, gx), gm = Math.hypot(gx, gy);
          if (!(Math.abs(ga - lastGA) < 0.01) || Math.abs(gm - lastGM) > 0.03) {
            sim.wakeAll(); lastGA = ga; lastGM = gm;
          }
          acc += dt * tps * timeScale;
          const n = Math.min(Math.ceil(MAX_TICKS * timeScale), Math.floor(acc));
          acc -= Math.floor(acc);
          if (acc > 1) acc = 1;
          let moves = 0;
          for (let i = 0; i < n; i++) { sim.step(gx, gy); moves += sim.moves; }
          if (n) {
            const band = Math.ceil(fluid.ny / 6), f = frameNo++ % 6;
            sim.updateSolids(f * band, (f + 1) * band);
            fluid.step(gx, gy, n);
          }
          sim.takeDirty();
          return { ticks: n, moves };
        },
      };
    },
  };
}
