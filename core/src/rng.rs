//! Seeded random numbers for everything drawn at seed time (mulberry32), as in
//! src/rng.js, so a seed number always gives the same starting picture. The
//! tick loop keeps its own xorshift state in `Sim`, itself drawn from here.

pub struct Mulberry32(u32);

impl Mulberry32 {
    pub fn new(seed: u32) -> Self {
        Self(seed)
    }

    pub fn state(&self) -> u32 {
        self.0
    }

    /// Uniform in [0, 1).
    pub fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x6d2b79f5);
        let a = self.0;
        let mut t = (a ^ (a >> 15)).wrapping_mul(1 | a);
        t = t.wrapping_add((t ^ (t >> 7)).wrapping_mul(61 | t)) ^ t;
        (t ^ (t >> 14)) as f64 / 4294967296.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_js() {
        // mulberry32(42) in src/rng.js
        let mut r = Mulberry32::new(42);
        let got: Vec<f64> = (0..3).map(|_| r.next()).collect();
        assert_eq!(got, JS_42);
    }

    const JS_42: [f64; 3] = [0.6011037519201636, 0.44829055899754167, 0.8524657934904099];
}
