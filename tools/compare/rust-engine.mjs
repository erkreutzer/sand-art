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
        frame(dt, gx, gy) {
          const ticks = x.sand_frame(e, dt, gx, gy, 0xffffffff);
          x.sand_take_dirty(e);
          return { ticks, moves: x.sand_moves(e) };
        },
      };
    },
  };
}
