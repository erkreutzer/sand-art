//! Coarse incompressible liquid (Stam-style stable fluids) underneath the sand
//! grid; a port of src/fluid.js.
//!
//! One fluid cell covers 2^fs x 2^fs sim cells. Velocities are in sim cells per
//! tick, so the sand pass can add them straight onto a grain's motion.
//! Coupling: sinking sand makes the liquid locally heavier and drags it down;
//! bubbles lift it. Because the liquid can't compress, every downward curtain
//! forces an upwelling beside it - which is where the swirls come from.
//!
//! Fields are stored as f32 and the arithmetic is done in f64, as in the JS.

use crate::jsmath::hypot;

#[derive(Clone, Debug)]
pub struct FluidParams {
    pub sand_weight: f64, // push from suspended sand, per unit concentration per frame
    pub air_lift: f64,    // ...and from bubbles, the other way
    pub damping: f64,     // viscosity, crudely
    pub vorticity: f64,   // re-energises small eddies the coarse grid would smear out
    pub iterations: u32,  // pressure solve sweeps
    pub max_speed: f64,   // cells per tick
}

impl Default for FluidParams {
    fn default() -> Self {
        Self { sand_weight: 1.6, air_lift: 0.8, damping: 0.012, vorticity: 0.35, iterations: 18, max_speed: 3.0 }
    }
}

pub struct Fluid {
    pub fs: u32,
    pub nx: usize,
    pub ny: usize,
    pub u: Vec<f32>,
    pub v: Vec<f32>,
    u0: Vec<f32>,
    v0: Vec<f32>,
    p: Vec<f32>,
    div: Vec<f32>,
    curl: Vec<f32>,
    pub sand: Vec<f32>,
    pub air: Vec<f32>,
    pub solid: Vec<u8>,
    pub edge: Vec<u8>,
    pub params: FluidParams,
}

impl Fluid {
    pub fn new(sim_w: usize, sim_h: usize, fs: u32) -> Self {
        // One cell of permanent wall all round, so neighbours never need bounds checks.
        let nx = (sim_w >> fs) + 3;
        let ny = (sim_h >> fs) + 3;
        let n = nx * ny;
        let mut edge = vec![0u8; n];
        for x in 0..nx {
            edge[x] = 1;
            edge[(ny - 1) * nx + x] = 1;
        }
        for y in 0..ny {
            edge[y * nx] = 1;
            edge[y * nx + nx - 1] = 1;
        }
        let z = vec![0f32; n];
        Self {
            fs, nx, ny,
            u: z.clone(), v: z.clone(), u0: z.clone(), v0: z.clone(), p: z.clone(), div: z.clone(),
            curl: z.clone(), sand: z.clone(), air: z,
            solid: edge.clone(), edge,
            params: FluidParams::default(),
        }
    }

    pub fn reset(&mut self) {
        for a in [&mut self.u, &mut self.v, &mut self.p, &mut self.sand, &mut self.air] {
            a.fill(0.0);
        }
    }

    /// Advance one frame that covered `ticks` sim ticks under gravity (gx, gy).
    pub fn step(&mut self, gx: f64, gy: f64, ticks: u32) {
        if ticks == 0 {
            return;
        }
        let pp = self.params.clone();
        let (nx, ny) = (self.nx, self.ny);
        let n = nx * ny;
        let tk = ticks as f64;
        let Fluid { u, v, u0, v0, p, div, curl, solid, sand, air, .. } = self;

        // Body forces from suspended sand and bubbles.
        let norm = 1.0 / (tk * (1u32 << (2 * self.fs)) as f64);
        let (ks, ka) = (pp.sand_weight * norm, pp.air_lift * norm);
        for k in 0..n {
            if solid[k] != 0 {
                u[k] = 0.0;
                v[k] = 0.0;
            } else {
                let f = sand[k] as f64 * ks - air[k] as f64 * ka;
                u[k] = (u[k] as f64 + gx * f) as f32;
                v[k] = (v[k] as f64 + gy * f) as f32;
            }
            sand[k] = 0.0;
            air[k] = 0.0;
        }

        // Vorticity confinement.
        if pp.vorticity > 0.0 {
            for y in 1..ny - 1 {
                for k in y * nx + 1..y * nx + nx - 1 {
                    curl[k] = (0.5 * (v[k + 1] as f64 - v[k - 1] as f64 - (u[k + nx] as f64 - u[k - nx] as f64))) as f32;
                }
            }
            let eps = pp.vorticity * tk * 0.05;
            for y in 2..ny.saturating_sub(2) {
                for k in y * nx + 2..y * nx + nx - 2 {
                    if solid[k] != 0 {
                        continue;
                    }
                    let nxg = (curl[k + 1] as f64).abs() - (curl[k - 1] as f64).abs();
                    let nyg = (curl[k + nx] as f64).abs() - (curl[k - nx] as f64).abs();
                    let len = hypot(nxg, nyg) + 1e-5;
                    u[k] = (u[k] as f64 + eps * (nyg / len) * curl[k] as f64) as f32;
                    v[k] = (v[k] as f64 - eps * (nxg / len) * curl[k] as f64) as f32;
                }
            }
        }

        // Semi-Lagrangian advection of the velocity field by itself.
        u0.copy_from_slice(u);
        v0.copy_from_slice(v);
        let s = tk / (1u32 << self.fs) as f64;
        let keep = (1.0 - pp.damping).powf(tk / 3.0);
        let (xmax, ymax) = (nx as f64 - 1.001, ny as f64 - 1.001);
        for y in 1..ny - 1 {
            for x in 1..nx - 1 {
                let k = y * nx + x;
                if solid[k] != 0 {
                    u[k] = 0.0;
                    v[k] = 0.0;
                    continue;
                }
                let mut px = x as f64 - u0[k] as f64 * s;
                let mut py = y as f64 - v0[k] as f64 * s;
                if px < 0.0 { px = 0.0 } else if px > xmax { px = xmax }
                if py < 0.0 { py = 0.0 } else if py > ymax { py = ymax }
                let (x0, y0) = (px as usize, py as usize);
                let (fx, fy) = (px - x0 as f64, py - y0 as f64);
                let a = y0 * nx + x0;
                let b = a + nx;
                let lerp = |f: &[f32]| {
                    keep * ((f[a] as f64 * (1.0 - fx) + f[a + 1] as f64 * fx) * (1.0 - fy)
                        + (f[b] as f64 * (1.0 - fx) + f[b + 1] as f64 * fx) * fy)
                };
                u[k] = lerp(u0) as f32;
                v[k] = lerp(v0) as f32;
            }
        }

        // Pressure projection: make the flow divergence-free (walls are no-flux).
        for y in 1..ny - 1 {
            for k in y * nx + 1..y * nx + nx - 1 {
                if solid[k] != 0 {
                    div[k] = 0.0;
                    continue;
                }
                let ur = if solid[k + 1] != 0 { 0.0 } else { u[k + 1] as f64 };
                let ul = if solid[k - 1] != 0 { 0.0 } else { u[k - 1] as f64 };
                let vd = if solid[k + nx] != 0 { 0.0 } else { v[k + nx] as f64 };
                let vu = if solid[k - nx] != 0 { 0.0 } else { v[k - nx] as f64 };
                div[k] = (0.5 * (ur - ul + vd - vu)) as f32;
            }
        }
        for _ in 0..pp.iterations {
            for y in 1..ny - 1 {
                for k in y * nx + 1..y * nx + nx - 1 {
                    if solid[k] != 0 {
                        continue;
                    }
                    let (mut sum, mut cnt) = (0.0f64, 0u32);
                    for q in [k - 1, k + 1, k - nx, k + nx] {
                        if solid[q] == 0 {
                            sum += p[q] as f64;
                            cnt += 1;
                        }
                    }
                    if cnt != 0 {
                        p[k] = ((sum - div[k] as f64) / cnt as f64) as f32;
                    }
                }
            }
        }
        let vmax = pp.max_speed;
        for y in 1..ny - 1 {
            for k in y * nx + 1..y * nx + nx - 1 {
                if solid[k] != 0 {
                    continue;
                }
                let pc = p[k] as f64;
                let at = |q: usize| if solid[q] != 0 { pc } else { p[q] as f64 };
                let (pl, pr, pu, pd) = (at(k - 1), at(k + 1), at(k - nx), at(k + nx));
                let mut uu = u[k] as f64 - 0.5 * (pr - pl);
                let mut vv = v[k] as f64 - 0.5 * (pd - pu);
                if uu > vmax { uu = vmax } else if uu < -vmax { uu = -vmax }
                if vv > vmax { vv = vmax } else if vv < -vmax { vv = -vmax }
                u[k] = uu as f32;
                v[k] = vv as f32;
            }
        }
    }
}
