// Host for the simulation core: picks the JS or the wasm core, keeps the
// per-tick time budget, and draws. Runs inside the worker, or on the main
// thread as a fallback where OffscreenCanvas/WebGL2 isn't available.
import { Renderer, renderParams } from './render.js';
import { randomSeed } from './rng.js';

const BUDGET_MS = 11;          // run fewer ticks (slow motion) rather than drop frames
const NO_LIMIT = 0xffffffff;

export class Engine {
  // core: 'js' or 'wasm'. seedNo: the same number always gives the same
  // pictures; by default a new one each time.
  static async create(canvas, w, h, scale, tps, core = 'js', seedNo = randomSeed()) {
    const c = core === 'wasm'
      ? await (await import('./core-wasm.js')).loadWasmCore(w, h, tps, seedNo)
      : new (await import('./core-js.js')).JsCore(w, h, tps, seedNo);
    return new Engine(canvas, c, core, scale);
  }

  constructor(canvas, core, kind, scale) {
    this.core = core;
    this.kind = kind;
    this.renderer = new Renderer(canvas, core, scale);
    this.perTick = 0;
    this.redraw = true;
  }

  reseed(upsideDown = false) {
    this.core.reseed(upsideDown);
    this.redraw = true;
  }

  setPalette(p) { this.renderer.setPalette(p); this.redraw = true; }

  // Live tuning, grouped as in the debug panel.
  tune(t) {
    if (t.render) { Object.assign(renderParams, t.render); this.renderer.applyLiquid(); this.redraw = true; }
    this.core.tune(t);
  }

  frame(dt, gx, gy, glint, poseChanged, paused, wantFlow) {
    const { core } = this;
    // The core has no clock: allow as many ticks as recent ones say fit the budget.
    const maxTicks = paused ? 0 : this.perTick > 0 ? Math.max(1, Math.floor(BUDGET_MS / this.perTick)) : NO_LIMIT;
    const t0 = performance.now();
    const s = core.frame(dt, gx, gy, maxTicks);
    const ms = performance.now() - t0;
    if (s.ticks) this.perTick = this.perTick ? this.perTick * 0.9 + (ms / s.ticks) * 0.1 : ms / s.ticks;

    const rows = core.takeDirty();
    if (rows || poseChanged || this.redraw) {
      this.renderer.upload(rows);
      this.renderer.draw(glint);
      this.redraw = false;
    }
    const stats = { core: this.kind, ticks: s.ticks, coreMs: ms, simMs: s.simMs, fluidMs: s.fluidMs, moves: s.moves, w: core.w, h: core.h };
    if (wantFlow) {
      const { u, v, solid, nx, ny, fs } = core.flow();
      stats.flow = { u: u.slice(), v: v.slice(), solid: solid.slice(), nx, ny, fs, W: core.W, H: core.H };
    }
    return stats;
  }
}
