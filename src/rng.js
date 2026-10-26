// Seeded random numbers for everything drawn at seed time (mulberry32), so a
// seed number always gives the same starting picture. The tick loop keeps its
// own xorshift state in Sim, which is itself drawn from here.

export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// A fresh seed number, so each page load still starts from a new picture.
export const randomSeed = () => (Math.random() * 4294967296) >>> 0;
