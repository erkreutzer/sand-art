//! Snapshot / restore: everything a picture needs to carry on exactly where it
//! was (grains, liquid, which chunks are awake, random number states, frame
//! timing), for handing a picture mid-pour between devices or apps. Tuning and
//! the tick rate are the host's settings and stay out of it.
//!
//! Format (little-endian): "SAND", version, w, h, fs, then the engine's fields
//! in the order `Engine::save` writes them. A snapshot only restores onto an
//! engine of the same grid size.

use crate::engine::Engine;

const MAGIC: &[u8; 4] = b"SAND";
const VERSION: u32 = 1;

#[derive(Default)]
pub struct Writer(pub Vec<u8>);

impl Writer {
    pub fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    pub fn f64(&mut self, v: f64) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    pub fn u8s(&mut self, a: &[u8]) {
        self.0.extend_from_slice(a);
    }
    pub fn u32s(&mut self, a: &[u32]) {
        a.iter().for_each(|&v| self.u32(v));
    }
    pub fn f32s(&mut self, a: &[f32]) {
        a.iter().for_each(|v| self.0.extend_from_slice(&v.to_le_bytes()));
    }
}

/// Reads back what `Writer` wrote; the caller has checked the length first.
pub struct Reader<'a>(pub &'a [u8]);

impl Reader<'_> {
    fn take<const N: usize>(&mut self) -> [u8; N] {
        let (a, rest) = self.0.split_at(N);
        self.0 = rest;
        a.try_into().unwrap()
    }
    pub fn u32(&mut self) -> u32 {
        u32::from_le_bytes(self.take())
    }
    pub fn f64(&mut self) -> f64 {
        f64::from_le_bytes(self.take())
    }
    pub fn u8s(&mut self, a: &mut [u8]) {
        let (s, rest) = self.0.split_at(a.len());
        a.copy_from_slice(s);
        self.0 = rest;
    }
    pub fn u32s(&mut self, a: &mut [u32]) {
        a.iter_mut().for_each(|v| *v = self.u32());
    }
    pub fn f32s(&mut self, a: &mut [f32]) {
        a.iter_mut().for_each(|v| *v = f32::from_le_bytes(self.take()));
    }
}

fn header(e: &Engine) -> Writer {
    let mut w = Writer::default();
    w.u8s(MAGIC);
    for v in [VERSION, e.sim.w as u32, e.sim.h as u32, e.fluid.fs] {
        w.u32(v);
    }
    w
}

pub fn snapshot(e: &Engine) -> Vec<u8> {
    let mut w = header(e);
    e.save(&mut w);
    w.0
}

/// false (and the engine untouched) if `b` isn't a snapshot of this grid size.
pub fn restore(e: &mut Engine, b: &[u8]) -> bool {
    let head = header(e).0;
    let mut probe = Writer::default();
    e.save(&mut probe);
    if b.len() != head.len() + probe.0.len() || !b.starts_with(&head) {
        return false;
    }
    e.load(&mut Reader(&b[head.len()..]));
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    // A flip with the frame held at an angle, so the liquid and the timing
    // state are all in play.
    fn run(e: &mut Engine, from: usize, frames: usize) {
        for f in from..from + frames {
            let th = (f as f64 * 0.01).min(2.6);
            e.frame(1.0 / 60.0, th.sin() * 0.4, th.cos(), u32::MAX);
        }
    }

    #[test]
    fn carries_on_exactly() {
        let mut a = Engine::new(240, 170, 209.0, 7);
        a.tune(r#"{"engine": {"timeScale": 0.7}}"#).unwrap();
        run(&mut a, 0, 400);
        let snap = snapshot(&a);

        let mut b = Engine::new(240, 170, 209.0, 99);
        b.tune(r#"{"engine": {"timeScale": 0.7}}"#).unwrap();
        assert!(restore(&mut b, &snap));
        assert_eq!(b.sim.take_dirty(), Some((0, 171)));
        run(&mut a, 400, 300);
        run(&mut b, 400, 300);
        assert!(a.sim.cells == b.sim.cells && a.fluid.u == b.fluid.u && a.fluid.v == b.fluid.v);
        assert_eq!(snapshot(&a), snapshot(&b));
        b.reseed(true);
        a.reseed(true);
        assert!(a.sim.cells == b.sim.cells);
    }

    #[test]
    fn refuses_other_sizes() {
        let a = Engine::new(240, 170, 209.0, 7);
        let mut b = Engine::new(241, 170, 209.0, 7);
        let before = snapshot(&b);
        assert!(!restore(&mut b, &snapshot(&a)));
        assert!(!restore(&mut b, &before[..before.len() - 1]));
        assert_eq!(snapshot(&b), before);
    }
}
