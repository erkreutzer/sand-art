// The JS physics as a core with the same shape as the Rust one (core-wasm.js,
// core/src/lib.rs): sand, liquid, seeding and frame timing. Drawing and the
// time budget are the host's (engine.js). The reference until the Rust core
// replaces it.
import { Sim, params } from './sim.js';
import { Fluid, fluidParams } from './fluid.js';
import { seed, seedParams } from './seed.js';
import { mulberry32 } from './rng.js';

const MAX_TICKS = 8;           // per frame, at normal speed

// Everything (sinking, pouring, bubbles, liquid) plays at this fraction of the
// speeds tuned in sim.js and fluid.js. At 1 it looks sped up; 0.3 is about the
// pace of a real sand picture.
export const engineParams = { timeScale: 0.3 };

export class JsCore {
  // seedNo: the same number always gives the same pictures.
  constructor(w, h, tps, seedNo) {
    this.rng = mulberry32(seedNo);
    // Liquid cells span 8x8 sim cells (16x16 on huge grids): fine enough for
    // a curtain of sand to roll up into eddies.
    this.fluid = new Fluid(w + 2, h + 2, Math.max(w, h) > 1600 ? 4 : 3);
    this.sim = new Sim(w, h, this.fluid, this.rng);
    this.sim.setTickRate(tps);
    this.tps = tps;
    this.w = w; this.h = h; this.W = this.sim.W; this.H = this.sim.H;
    this.acc = 0; this.frameNo = 0;
    this.lastGA = NaN; this.lastGM = NaN;
    this.reseed();
  }

  get bytes() { return this.sim.bytes; }

  reseed(upsideDown = false) {
    seed(this.sim, this.rng, upsideDown);
    this.fluid.reset();
    this.sim.updateSolids(0, this.fluid.ny);
  }

  // Live tuning, grouped as in the debug panel ("render" is the host's).
  tune(t) {
    Object.assign(params, t.sim || {});
    Object.assign(fluidParams, t.fluid || {});
    Object.assign(seedParams, t.seed || {});
    Object.assign(engineParams, t.engine || {});
    this.sim.wakeAll();
  }

  // At most maxTicks ticks (fewer means slow motion, not dropped frames).
  frame(dt, gx, gy, maxTicks) {
    const { sim, fluid } = this;
    const ga = Math.atan2(gy, gx), gm = Math.hypot(gx, gy);
    if (!(Math.abs(ga - this.lastGA) < 0.01) || Math.abs(gm - this.lastGM) > 0.03) {
      sim.wakeAll(); this.lastGA = ga; this.lastGM = gm;
    }

    const { timeScale } = engineParams;
    this.acc += dt * this.tps * timeScale;
    const n = Math.min(Math.ceil(MAX_TICKS * timeScale), maxTicks, Math.floor(this.acc));
    this.acc -= Math.floor(this.acc);
    if (this.acc > 1) this.acc = 1;

    const t0 = performance.now();
    let moves = 0;
    for (let i = 0; i < n; i++) { sim.step(gx, gy); moves += sim.moves; }
    const t1 = performance.now();

    // Liquid: once per frame, with a rolling refresh of which cells are packed sand.
    if (n) {
      const band = Math.ceil(fluid.ny / 6), f = this.frameNo++ % 6;
      sim.updateSolids(f * band, (f + 1) * band);
      fluid.step(gx, gy, n);
    }
    return { ticks: n, moves, simMs: t1 - t0, fluidMs: performance.now() - t1 };
  }

  takeDirty() { return this.sim.takeDirty(); }

  flow() {
    const { u, v, solid, nx, ny, fs } = this.fluid;
    return { u, v, solid, nx, ny, fs };
  }
}
