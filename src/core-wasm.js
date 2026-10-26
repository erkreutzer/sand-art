// The Rust core (core/, built into sand_core.wasm by tools/build-core.sh)
// through its C ABI, with the same shape as core-js.js. The grid is read
// straight out of wasm memory, so drawing it needs no copy.

export async function loadWasmCore(w, h, tps, seedNo) {
  const res = await fetch(new URL('./sand_core.wasm', import.meta.url));
  const { instance } = await WebAssembly.instantiate(await res.arrayBuffer(), {});
  return new WasmCore(instance.exports, w, h, tps, seedNo);
}

class WasmCore {
  constructor(x, w, h, tps, seedNo) {
    this.x = x;
    this.e = x.sand_new(w, h, tps, seedNo >>> 0);
    this.w = w; this.h = h;
    this.W = x.sand_grid_width(this.e); this.H = x.sand_grid_height(this.e);
    this.view = null;
  }

  // A view into wasm memory, renewed if the memory has grown.
  get bytes() {
    const { x } = this;
    if (this.view?.buffer !== x.memory.buffer)
      this.view = new Uint8Array(x.memory.buffer, x.sand_grid_ptr(this.e), this.W * this.H * 4);
    return this.view;
  }

  reseed(upsideDown = false) { this.x.sand_reseed(this.e, upsideDown ? 1 : 0); }

  // Settings in the debug panel's shape; the core skips "render".
  tune(t) {
    const { x } = this, json = new TextEncoder().encode(JSON.stringify(t));
    const p = x.sand_alloc(json.length);
    new Uint8Array(x.memory.buffer, p, json.length).set(json);
    const n = x.sand_tune(this.e, p, json.length);
    x.sand_dealloc(p, json.length);
    if (n < 0) throw new Error('sand_tune: not valid JSON');
  }

  // maxTicks is a u32 in the core: pass 0xffffffff, not Infinity, for no limit.
  frame(dt, gx, gy, maxTicks) {
    const ticks = this.x.sand_frame(this.e, dt, gx, gy, maxTicks);
    return { ticks, moves: this.x.sand_moves(this.e) };
  }

  takeDirty() {
    const r = this.x.sand_take_dirty(this.e) >>> 0;
    return r === 0xffffffff ? null : [r >>> 16, r & 0xffff];
  }

  // SandFlow in core/src/lib.rs: u, v, solid pointers, then nx, ny, fs.
  flow() {
    const m = this.x.memory.buffer;
    const [u, v, solid, nx, ny, fs] = new Uint32Array(m, this.x.sand_flow(this.e), 6), n = nx * ny;
    return { u: new Float32Array(m, u, n), v: new Float32Array(m, v, n), solid: new Uint8Array(m, solid, n), nx, ny, fs };
  }
}
