//! Simulation + liquid for one frame, as in src/engine.js minus the drawing.
//! The core has no clock: the host measures how long a tick takes and passes
//! the most ticks it can afford this frame.

use crate::fluid::Fluid;
use crate::jsmath::hypot;
use crate::rng::Mulberry32;
use crate::seed::{seed, SeedParams};
use crate::sim::Sim;

const MAX_TICKS: f64 = 8.0; // per frame, at normal speed

#[derive(Clone, Debug)]
pub struct EngineParams {
    // Everything (sinking, pouring, bubbles, liquid) plays at this fraction of
    // the speeds in SimParams and FluidParams. At 1 it looks sped up; 0.3 is
    // about the pace of a real sand picture.
    pub time_scale: f64,
}

impl Default for EngineParams {
    fn default() -> Self {
        Self { time_scale: 0.3 }
    }
}

pub struct Engine {
    pub sim: Sim,
    pub fluid: Fluid,
    pub seed_params: SeedParams,
    pub params: EngineParams,
    rng: Mulberry32,
    tps: f64,
    acc: f64,
    frame_no: usize,
    last_ga: f64,
    last_gm: f64,
    pub last_moves: u32, // for the C ABI
}

pub struct FrameStats {
    pub ticks: u32,
    pub moves: u32,
}

impl Engine {
    /// seed_no: the same number always gives the same pictures.
    pub fn new(w: usize, h: usize, tps: f64, seed_no: u32) -> Self {
        // Liquid cells span 8x8 sim cells (16x16 on huge grids): fine enough for
        // a curtain of sand to roll up into eddies.
        let fluid = Fluid::new(w + 2, h + 2, if w.max(h) > 1600 { 4 } else { 3 });
        let mut rng = Mulberry32::new(seed_no);
        let mut sim = Sim::new(w, h, &fluid, &mut rng);
        sim.set_tick_rate(tps);
        let mut e = Self {
            sim, fluid, rng, tps,
            seed_params: SeedParams::default(),
            params: EngineParams::default(),
            acc: 0.0, frame_no: 0, last_ga: f64::NAN, last_gm: f64::NAN, last_moves: 0,
        };
        e.reseed(false);
        e
    }

    pub fn reseed(&mut self, upside_down: bool) {
        seed(&mut self.sim, &mut self.rng, upside_down, &self.seed_params);
        self.fluid.reset();
        let ny = self.fluid.ny;
        self.sim.update_solids(&mut self.fluid, 0, ny);
    }

    /// Advance by dt seconds with gravity (gx, gy) in grid space, running at
    /// most max_ticks sim ticks (fewer means slow motion, not dropped frames).
    pub fn frame(&mut self, dt: f64, gx: f64, gy: f64, max_ticks: u32) -> FrameStats {
        let ga = gy.atan2(gx);
        let gm = hypot(gx, gy);
        if !((ga - self.last_ga).abs() < 0.01) || (gm - self.last_gm).abs() > 0.03 {
            self.sim.wake_all();
            self.last_ga = ga;
            self.last_gm = gm;
        }

        let ts = self.params.time_scale;
        self.acc += dt * self.tps * ts;
        let cap = (MAX_TICKS * ts).ceil();
        let n = cap.min(max_ticks as f64).min(self.acc.floor()) as u32;
        self.acc -= self.acc.floor();
        if self.acc > 1.0 {
            self.acc = 1.0;
        }

        let mut moves = 0;
        for _ in 0..n {
            self.sim.step(&mut self.fluid, gx, gy);
            moves += self.sim.moves;
        }
        // Liquid: once per frame, with a rolling refresh of which cells are packed sand.
        if n > 0 {
            let band = self.fluid.ny.div_ceil(6);
            let f = self.frame_no % 6;
            self.frame_no += 1;
            self.sim.update_solids(&mut self.fluid, f * band, (f + 1) * band);
            self.fluid.step(gx, gy, n);
        }
        FrameStats { ticks: n, moves }
    }
}
