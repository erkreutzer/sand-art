// Starting picture: the sand hanging at the top in wavy colour bands (the
// underside shaped like the last picture's mountains, upside down), with the
// air still at the bottom, as if the frame had just been flipped.
import { SAND, AIR, GLITTER } from './sim.js';

export const seedParams = {
  sand: 0.38,         // how far down the glass the hanging sand reaches (fraction)
  air: 0.005,         // air, as a fraction of the glass height
};

// rng: seeded random numbers (src/rng.js). upsideDown: the frame is resting
// flipped, so "top as you see it" is the grid's last row.
export function seed(sim, rng, upsideDown = false) {
  const { w, h } = sim;
  const put = upsideDown ? (x, y, t, s) => sim.set(x, h - 1 - y, t, s) : (x, y, t, s) => sim.set(x, y, t, s);
  const k = h / 581;                // features are tuned in cells at this size
  sim.reset();
  const R = rng;
  const nCols = 6;

  // Underside of the hanging sand: the last picture's mountains, upside down.
  const waves = Array.from({ length: 3 }, (_, i) => ({ f: (1 + R() * 3) * (i + 1), p: R() * 6.28, a: 1 / (i + 1.5) }));
  const peaks = Array.from({ length: 2 + Math.floor(R() * 3) }, () => ({ c: R(), wd: 0.06 + R() * 0.16, a: 0.4 + R() * 0.6 }));
  const bottom = new Float32Array(w);
  let mean = 0;
  for (let x = 0; x < w; x++) {
    const u = x / w;
    let v = 0;
    for (const q of waves) v += q.a * Math.sin(u * q.f * 6.283 + q.p);
    let pk = 0;
    for (const q of peaks) pk = Math.max(pk, q.a * Math.max(0, 1 - Math.abs(u - q.c) / q.wd));
    bottom[x] = h * (seedParams.sand + 0.035 * v + 0.13 * pk);
    mean += bottom[x];
  }
  mean /= w;

  // Colour bands, measured upward from that underside.
  const band = new Uint8Array(h * 2);
  const glit = new Uint8Array(h * 2);
  let prev = -1;
  for (let v = 0; v < band.length;) {
    let c;
    do c = Math.floor(R() * nCols); while (c === prev);
    prev = c;
    const thick = Math.max(2, Math.round(h * (0.02 + R() * R() * 0.08)));
    const g = R() < 0.3;
    for (let k = 0; k < thick && v < band.length; k++, v++) {
      band[v] = c;
      glit[v] = g && k < Math.max(2, h * 0.006) ? 1 : 0;
    }
  }

  const wob = R() * 6.28;
  for (let x = 0; x < w; x++) {
    const B = bottom[x];
    const wobble = k * (1.5 * Math.sin(x * 0.045 / k + wob) + 1.0 * Math.sin(x * 0.13 / k + wob * 2));
    for (let y = 0; y < B; y++) {
      const d = B - y;
      const v = Math.max(0, Math.round(d - (B - mean) * Math.min(1, d / (h * 0.25)) + wobble));
      let t = SAND + band[Math.min(v, band.length - 1)];
      const r = R();
      if (glit[Math.min(v, band.length - 1)] && r < 0.45) t = GLITTER;
      else if (r < 0.006) t = GLITTER;
      else if (r < 0.012) t = SAND + Math.floor(R() * nCols);
      put(x, y, t, Math.floor((R() + R()) * 127.5));
    }
  }
  // A strip of air, now at the bottom.
  const airRows = Math.max(1, Math.round(h * seedParams.air));
  for (let y = h - airRows; y < h; y++) for (let x = 0; x < w; x++) put(x, y, AIR, 0);
  sim.wakeAll();
}
