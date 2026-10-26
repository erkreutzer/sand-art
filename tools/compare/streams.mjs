// Pour streams: runs of columns where grains fall through open liquid much more
// densely (averaged over ~2 mm) than within ~10 mm either side, and at more
// than a couple of grains per column. A fine rain from the whole underside,
// even over only part of the width, isn't a stream.
// falling[x], x = 1..w: falling grains in column x. res: grid rows / 581 (one
// reference cell is about 0.5 mm).
export function countStreams(falling, w, res) {
  const r = Math.max(1, Math.round(2 * res)), R = Math.max(4 * r, Math.round(20 * res));
  const sum = new Float64Array(w + 2);
  for (let x = 1; x <= w; x++) sum[x] = sum[x - 1] + falling[x];
  const avg = (x, k) => { const a = Math.max(1, x - k), b = Math.min(w, x + k); return (sum[b] - sum[a - 1]) / (b - a + 1); };
  let streams = 0, run = 0;
  for (let x = 1; x <= w + 1; x++) {
    const n = x <= w ? avg(x, r) : 0;
    if (n >= 2 * res && n >= 3 * avg(x, R)) run++;
    else { if (run > r) streams++; run = 0; }
  }
  return streams;
}
