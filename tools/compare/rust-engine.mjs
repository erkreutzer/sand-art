// The Rust core (core/), built for wasm and driven through its C ABI, with the
// same interface as js-engine.mjs. The host side of the frame budget isn't
// needed here, so every frame may run as many ticks as the timing allows.
import { readFileSync } from 'node:fs';

export async function loadRust(wasmFile, tps) {
  const { instance } = await WebAssembly.instantiate(readFileSync(wasmFile), {});
  const x = instance.exports;
  return {
    create(w, h, seedNo) {
      const e = x.sand_new(w, h, tps, seedNo >>> 0);
      const W = x.sand_grid_width(e), H = x.sand_grid_height(e);
      let view = null;
      return {
        W, H,
        // A view into wasm memory, renewed if the memory has grown.
        get bytes() {
          if (!view || view.buffer !== x.memory.buffer) view = new Uint8Array(x.memory.buffer, x.sand_grid_ptr(e), W * H * 4);
          return view;
        },
        reseed: (upsideDown) => x.sand_reseed(e, upsideDown ? 1 : 0),
        tune(t) {
          const json = new TextEncoder().encode(JSON.stringify(t));
          const p = x.sand_alloc(json.length);
          new Uint8Array(x.memory.buffer, p, json.length).set(json);
          const n = x.sand_tune(e, p, json.length);
          x.sand_dealloc(p, json.length);
          if (n < 0) throw new Error('sand_tune: not valid JSON');
        },
        // SandFlow in core/src/lib.rs: u, v, solid pointers, then nx, ny, fs.
        flow() {
          const [u, v, solid, nx, ny] = new Uint32Array(x.memory.buffer, x.sand_flow(e), 6), n = nx * ny;
          const m = x.memory.buffer;
          return { u: new Float32Array(m, u, n), v: new Float32Array(m, v, n), solid: new Uint8Array(m, solid, n) };
        },
        frame(dt, gx, gy) {
          const ticks = x.sand_frame(e, dt, gx, gy, 0xffffffff);
          x.sand_take_dirty(e);
          return { ticks, moves: x.sand_moves(e) };
        },
      };
    },
  };
}
