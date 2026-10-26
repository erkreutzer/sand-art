//! Starting picture, a port of src/seed.js: the sand hanging at the top in wavy
//! colour bands (the underside shaped like the last picture's mountains, upside
//! down), with the air still at the bottom, as if the frame had just been flipped.

use crate::jsmath::round;
use crate::rng::Mulberry32;
use crate::sim::{Sim, AIR, GLITTER, SAND};

#[derive(Clone, Debug)]
pub struct SeedParams {
    pub sand: f64, // how far down the glass the hanging sand reaches (fraction)
    pub air: f64,  // air, as a fraction of the glass height
}

impl Default for SeedParams {
    fn default() -> Self {
        Self { sand: 0.38, air: 0.005 }
    }
}

/// upside_down: the frame is resting flipped, so "top as you see it" is the
/// grid's last row.
pub fn seed(sim: &mut Sim, rng: &mut Mulberry32, upside_down: bool, sp: &SeedParams) {
    let (w, h) = (sim.w, sim.h);
    let put = |sim: &mut Sim, x: usize, y: usize, t: u32, s: u32| {
        sim.set(x, if upside_down { h - 1 - y } else { y }, t, s)
    };
    let hf = h as f64;
    let k = hf / 581.0; // features are tuned in cells at this size
    sim.reset();
    let mut r = || rng.next();
    const N_COLS: f64 = 6.0;

    // Underside of the hanging sand: the last picture's mountains, upside down.
    struct Wave { f: f64, p: f64, a: f64 }
    struct Peak { c: f64, wd: f64, a: f64 }
    let waves: Vec<Wave> = (0..3)
        .map(|i| {
            let f = (1.0 + r() * 3.0) * (i + 1) as f64;
            let p = r() * 6.28;
            Wave { f, p, a: 1.0 / (i as f64 + 1.5) }
        })
        .collect();
    let n_peaks = 2 + (r() * 3.0).floor() as usize;
    let peaks: Vec<Peak> = (0..n_peaks)
        .map(|_| {
            let c = r();
            let wd = 0.06 + r() * 0.16;
            let a = 0.4 + r() * 0.6;
            Peak { c, wd, a }
        })
        .collect();
    let mut bottom = vec![0f32; w];
    let mut mean = 0.0f64;
    for x in 0..w {
        let u = x as f64 / w as f64;
        let mut v = 0.0;
        for q in &waves {
            v += q.a * (u * q.f * 6.283 + q.p).sin();
        }
        let mut pk = 0.0f64;
        for q in &peaks {
            pk = pk.max(q.a * 0f64.max(1.0 - (u - q.c).abs() / q.wd));
        }
        bottom[x] = (hf * (sp.sand + 0.035 * v + 0.13 * pk)) as f32;
        mean += bottom[x] as f64;
    }
    mean /= w as f64;

    // Colour bands, measured upward from that underside.
    let len = h * 2;
    let mut band = vec![0u8; len];
    let mut glit = vec![0u8; len];
    let mut prev = -1i32;
    let mut v = 0;
    while v < len {
        let mut c;
        loop {
            c = (r() * N_COLS).floor() as i32;
            if c != prev {
                break;
            }
        }
        prev = c;
        let thick = 2f64.max(round(hf * (0.02 + r() * r() * 0.08))) as usize;
        let g = r() < 0.3;
        let mut kk = 0;
        while kk < thick && v < len {
            band[v] = c as u8;
            glit[v] = (g && (kk as f64) < 2f64.max(hf * 0.006)) as u8;
            kk += 1;
            v += 1;
        }
    }

    let wob = r() * 6.28;
    for x in 0..w {
        let b = bottom[x] as f64;
        let xf = x as f64;
        let wobble = k * (1.5 * (xf * 0.045 / k + wob).sin() + 1.0 * (xf * 0.13 / k + wob * 2.0).sin());
        let mut y = 0;
        while (y as f64) < b {
            let d = b - y as f64;
            let vv = 0f64.max(round(d - (b - mean) * 1f64.min(d / (hf * 0.25)) + wobble)) as usize;
            let bi = vv.min(len - 1);
            let mut t = SAND + band[bi] as u32;
            let rv = r();
            if glit[bi] != 0 && rv < 0.45 {
                t = GLITTER;
            } else if rv < 0.006 {
                t = GLITTER;
            } else if rv < 0.012 {
                t = SAND + (r() * N_COLS).floor() as u32;
            }
            let shade = ((r() + r()) * 127.5).floor() as u32;
            put(sim, x, y, t, shade);
            y += 1;
        }
    }
    // A strip of air, now at the bottom.
    let air_rows = 1f64.max(round(hf * sp.air)) as usize;
    for y in h - air_rows..h {
        for x in 0..w {
            put(sim, x, y, AIR, 0);
        }
    }
    sim.wake_all();
}
