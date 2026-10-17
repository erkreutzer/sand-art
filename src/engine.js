// Simulation + liquid + rendering for one frame. Runs inside the worker, or on
// the main thread as a fallback where OffscreenCanvas/WebGL2 isn't available.
import { Sim, params } from './sim.js';
import { Fluid, fluidParams } from './fluid.js';
import { Renderer, renderParams } from './render.js';
import { seed, seedParams } from './seed.js';

const MAX_TICKS = 8;           // per frame, at normal speed
const BUDGET_MS = 11;          // run fewer ticks (slow motion) rather than drop frames

export class Engine {
  constructor(canvas, w, h, scale, tps) {
    // Liquid cells span 8x8 sim cells (16x16 on huge grids): fine enough for
    // a curtain of sand to roll up into eddies.
    this.fluid = new Fluid(w + 2, h + 2, Math.max(w, h) > 1600 ? 4 : 3);
    this.sim = new Sim(w, h, this.fluid);
    this.sim.setTickRate(tps);
    this.tps = tps;
    this.renderer = new Renderer(canvas, this.sim, scale);
    this.acc = 0; this.perTick = 0; this.frameNo = 0; this.timeScale = 1;
    this.lastGA = NaN; this.lastGM = NaN;
    this.reseed();
  }

  reseed(upsideDown = false) {
    seed(this.sim, upsideDown);
    this.fluid.reset();
    this.sim.updateSolids(0, this.fluid.ny);
    this.redraw = true;
  }

  setPalette(p) { this.renderer.setPalette(p); this.redraw = true; }

  // Live tuning, grouped as in the debug panel.
  tune(t) {
    Object.assign(params, t.sim || {});
    Object.assign(fluidParams, t.fluid || {});
    Object.assign(seedParams, t.seed || {});
    if (t.render) { Object.assign(renderParams, t.render); this.renderer.applyLiquid(); this.redraw = true; }
    if (t.engine?.timeScale) this.timeScale = t.engine.timeScale;
    this.sim.wakeAll();
  }

  frame(dt, gx, gy, glint, poseChanged, paused, wantFlow) {
    const { sim, fluid } = this;
    const ga = Math.atan2(gy, gx), gm = Math.hypot(gx, gy);
    if (!(Math.abs(ga - this.lastGA) < 0.01) || Math.abs(gm - this.lastGM) > 0.03) {
      sim.wakeAll(); this.lastGA = ga; this.lastGM = gm;
    }

    this.acc += dt * this.tps * this.timeScale;
    const cap = Math.ceil(MAX_TICKS * this.timeScale);
    const budget = this.perTick > 0 ? Math.max(1, Math.floor(BUDGET_MS / this.perTick)) : cap;
    let n = paused ? 0 : Math.min(cap, budget, Math.floor(this.acc));
    this.acc -= Math.floor(this.acc);
    if (this.acc > 1) this.acc = 1;

    const t0 = performance.now();
    let moves = 0;
    for (let i = 0; i < n; i++) { sim.step(gx, gy); moves += sim.moves; }
    const t1 = performance.now();
    if (n) this.perTick = this.perTick ? this.perTick * 0.9 + ((t1 - t0) / n) * 0.1 : (t1 - t0) / n;

    // Liquid: once per frame, with a rolling refresh of which cells are packed sand.
    if (n) {
      const band = Math.ceil(fluid.ny / 6), f = this.frameNo++ % 6;
      sim.updateSolids(f * band, (f + 1) * band);
      fluid.step(gx, gy, n);
    }
    const t2 = performance.now();

    const rows = sim.takeDirty();
    if (rows || poseChanged || this.redraw) {
      this.renderer.upload(rows);
      this.renderer.draw(glint);
      this.redraw = false;
    }
    const stats = { ticks: n, simMs: t1 - t0, fluidMs: t2 - t1, moves, w: sim.w, h: sim.h };
    if (wantFlow) {
      const { u, v, solid, nx, ny, fs } = fluid;
      stats.flow = { u: u.slice(), v: v.slice(), solid: solid.slice(), nx, ny, fs, W: sim.W, H: sim.H };
    }
    return stats;
  }
}
