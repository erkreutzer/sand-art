//! Cellular sand/liquid/air simulation; ported from src/sim.js, which it replaced.
//!
//! Every cell is one u32 so a move is a single swap and the whole grid can be
//! uploaded to the GPU as an RGBA8 texture with zero conversion:
//!   byte 0 (R) type    0 liquid, 1 air, 2 wall, 3.. sand colour index
//!   byte 1 (G) shade   per-grain random brightness, travels with the grain
//!   byte 2 (B) energy  >0 while a grain is in motion (momentum)
//!   byte 3 (A) clock   tick stamp, so nothing moves twice in one tick
//!
//! Two kinds of motion:
//!  - Contact: grains hanging, landing, rolling down slopes. Gravity can point
//!    anywhere; each tick it is split between the two nearest of the 8
//!    neighbour directions, so the average drift follows the true angle.
//!  - Suspension: a grain sinking through open liquid (or a bubble rising) moves
//!    with the local liquid velocity from the coarse fluid solver plus its own
//!    settling speed, so curtains of sand drag the liquid and get swirled by it.
//!
//! How the patterns form (as in the real toy): after a flip the air rises and
//! spreads into a barrier under the sand. Sand over air is held; it pours
//! through the weak spots - gaps and thin places in the barrier. Air drifting
//! into a drained cavity can close a gap, so streams start, stop and wander.
//! Streams pile into cones whose colours change as different layers drain.
//!
//! Arithmetic is f64 and reads outside the grid count as liquid, as in the JS.

use crate::fluid::Fluid;
use crate::jsmath::{hypot, round};
use crate::rng::Mulberry32;
use crate::snapshot::{Reader, Writer};

pub const LIQUID: u32 = 0;
pub const AIR: u32 = 1;
pub const WALL: u32 = 2;
pub const SAND: u32 = 3;
pub const GLITTER: u32 = SAND + 6;

const CS: isize = 5; // chunk = 32x32 cells
const EMAX: u32 = 5; // ticks a blocked grain keeps trying to slide
const ENERGY: u32 = EMAX << 16;
const REACH: isize = 5; // furthest a cell can move in one tick (+1)

/// Speeds are per second of real time; contact rates are per tick at the
/// reference resolution and get rescaled for the actual grid and tick rate.
#[derive(Clone, Debug)]
pub struct SimParams {
    pub fall_seconds: f64,  // a lone grain sinks the height of the glass in this long
    pub rise_seconds: f64,  // ...and a bubble rises it
    pub jitter: f64,        // random wander of a sinking grain, as a fraction of its speed
    pub fall_air: f64,      // grain dropping through an air pocket
    pub hole: f64,          // hanging grain over open liquid, above a one-wide hole
    pub narrow: f64,        // ...open on one more side
    pub flat: f64,          // ...on a flat underside (it erodes layer by layer)
    pub tip: f64,           // ...on a downward point
    pub thin_air: f64,      // hanging grain over a film of air one (reference) cell thick: it leaks
    pub leak_falloff: f64,  // ...each extra cell of film thickness multiplies that by this
    pub thick_air: f64,     // floor: even a deep pocket lets the odd grain through
    pub slide: f64,         // moving grain rolls down a slope
    pub slide_rest: f64,    // resting grain on a too-steep pile face gives way
    pub slide_wall: f64,    // ...or on the side wall of a hole in the hanging sand
    pub air_spread: f64,
    pub bubble_depth: f64,  // thinnest an air pocket spreads (reference cells, ~2mm)
    pub seep: f64,          // air working its way up through packed sand
}

impl Default for SimParams {
    /// As core/params.json gives them.
    fn default() -> Self {
        let d = crate::tune::defaults("sim");
        Self {
            fall_seconds: d("fallSeconds"), rise_seconds: d("riseSeconds"), jitter: d("jitter"), fall_air: d("fallAir"),
            hole: d("hole"), narrow: d("narrow"), flat: d("flat"), tip: d("tip"),
            thin_air: d("thinAir"), leak_falloff: d("leakFalloff"), thick_air: d("thickAir"),
            slide: d("slide"), slide_rest: d("slideRest"), slide_wall: d("slideWall"),
            air_spread: d("airSpread"), bubble_depth: d("bubbleDepth"), seep: d("seep"),
        }
    }
}

// Contact rates were tuned on a 581-row grid at 209 ticks/s.
const REF_ROWS: f64 = 581.0;
const REF_TPS: f64 = 209.0;

#[inline]
fn typ(cells: &[u32], i: isize) -> u32 {
    cells.get(i as usize).map_or(LIQUID, |c| c & 255)
}

#[inline]
fn xorshift(r: &mut u32) {
    *r ^= *r << 13;
    *r ^= *r >> 17;
    *r ^= *r << 5;
}

#[inline]
fn mark(nxt: &mut [u8], k: isize) {
    if let Some(v) = nxt.get_mut(k as usize) {
        *v = 1;
    }
}

/// Is there air for `depth` cells from i along `down` (i itself included)?
fn deep_air(cells: &[u32], i: isize, down: isize, depth: isize) -> bool {
    (1..depth).all(|k| typ(cells, i + k * down) == AIR)
}

pub struct Sim {
    pub w: usize,
    pub h: usize,
    /// Padded size (one cell of wall all round): w + 2, h + 2.
    pub pw: usize,
    pub ph: usize,
    pub cells: Vec<u32>,
    cw: usize,
    active: Vec<u8>,
    next: Vec<u8>,
    air_in: Vec<u8>, // chunks the sand pass saw air in
    col_count: Vec<i32>,
    tick: u32,
    seed: u32,
    pub moves: u32,
    dirty_min: isize,
    dirty_max: isize,
    dmin: isize,
    dmax: isize,
    off: [isize; 8],
    rate: f64,
    tps: f64,
    pub params: SimParams,
}

impl Sim {
    /// rng: seed-time random numbers; the tick loop's xorshift starts from one.
    pub fn new(w: usize, h: usize, fluid: &Fluid, rng: &mut Mulberry32) -> Self {
        let (pw, ph) = (w + 2, h + 2);
        let cw = (pw >> CS) + 1;
        let ch = (ph >> CS) + 1;
        let seed = (rng.next() * 4294967295.0) as u32;
        let wi = pw as isize;
        let mut sim = Self {
            w, h, pw, ph,
            cells: vec![0; pw * ph],
            cw,
            active: vec![0; cw * ch],
            next: vec![0; cw * ch],
            air_in: vec![0; cw * ch],
            col_count: vec![0; fluid.nx],
            tick: 0,
            seed: if seed == 0 { 1 } else { seed },
            moves: 0,
            dirty_min: 0,
            dirty_max: ph as isize - 1,
            dmin: 0,
            dmax: 0,
            off: [1, wi + 1, wi, wi - 1, -1, -wi - 1, -wi, -wi + 1],
            rate: 0.0,
            tps: 0.0,
            params: SimParams::default(),
        };
        sim.set_tick_rate(REF_TPS);
        sim.reset();
        sim
    }

    pub fn set_tick_rate(&mut self, tps: f64) {
        self.rate = (self.h as f64 / REF_ROWS) * (REF_TPS / tps);
        self.tps = tps;
    }

    pub fn reset(&mut self) {
        let (pw, ph) = (self.pw, self.ph);
        self.cells.fill(LIQUID);
        for x in 0..pw {
            self.cells[x] = WALL;
            self.cells[(ph - 1) * pw + x] = WALL;
        }
        for y in 0..ph {
            self.cells[y * pw] = WALL;
            self.cells[y * pw + pw - 1] = WALL;
        }
        self.wake_all();
    }

    pub fn set(&mut self, x: usize, y: usize, typ: u32, shade: u32) {
        self.cells[(y + 1) * self.pw + x + 1] = typ | (shade << 8);
    }

    /// Snapshot state; `next` and `air_in` are scratch, cleared every tick.
    pub(crate) fn save(&self, w: &mut Writer) {
        w.u32(self.tick);
        w.u32(self.seed);
        w.u32s(&self.cells);
        w.u8s(&self.active);
    }

    /// Restores what `save` wrote, without waking anything (that would change
    /// what happens next); the whole grid counts as changed.
    pub(crate) fn load(&mut self, r: &mut Reader) {
        self.tick = r.u32();
        self.seed = r.u32();
        r.u32s(&mut self.cells);
        r.u8s(&mut self.active);
        self.dirty_min = 0;
        self.dirty_max = self.ph as isize - 1;
    }

    pub fn wake_all(&mut self) {
        self.active.fill(1);
        self.next.fill(1);
        self.dirty_min = 0;
        self.dirty_max = self.ph as isize - 1;
    }

    /// Mark fluid cells that are mostly packed sand as solid, for fluid rows [fy0, fy1).
    pub fn update_solids(&mut self, fluid: &mut Fluid, fy0: usize, fy1: usize) {
        let (pw, ph, fs, nx) = (self.pw, self.ph, fluid.fs, fluid.nx);
        let lim = (1u32 << (2 * fs)) as f64 * 0.55;
        let col = &mut self.col_count;
        for fy in fy0.max(1)..fy1.min(fluid.ny - 1) {
            col.fill(0);
            let y0 = (fy - 1) << fs;
            let y1 = ph.min(y0 + (1 << fs));
            for y in y0..y1 {
                for x in 0..pw {
                    if self.cells[y * pw + x] & 255 >= SAND {
                        col[(x >> fs) + 1] += 1;
                    }
                }
            }
            for fx in 1..nx - 1 {
                let k = fy * nx + fx;
                fluid.solid[k] = (fluid.edge[k] != 0 || col[fx] as f64 > lim) as u8;
            }
        }
    }

    /// Advance one tick with gravity (gx, gy) in grid space; |g| = 1 is upright.
    pub fn step(&mut self, fluid: &mut Fluid, gx: f64, gy: f64) {
        let mag = hypot(gx, gy).min(1.0);
        self.moves = 0;
        if mag < 0.03 {
            return;
        }

        let mut ang = gy.atan2(gx);
        if ang < 0.0 {
            ang += std::f64::consts::PI * 2.0;
        }
        let sec = ang / (std::f64::consts::PI / 4.0);
        let k0 = (sec.floor() as i64 & 7) as usize;
        let t_dir = ((sec - sec.floor()) * 65536.0) as u32;

        self.tick = (self.tick + 1) & 255;
        let act = std::mem::take(&mut self.active);
        let mut nxt = std::mem::take(&mut self.next);
        nxt.fill(0);
        self.air_in.fill(0);
        self.dmin = self.ph as isize;
        self.dmax = 0;

        let side = if gx.abs() > 0.15 { gx > 0.0 } else { self.tick & 1 == 1 };
        self.sand_pass(fluid, k0, t_dir, mag, gx, gy, gy >= 0.0, side, &act, &mut nxt);
        let air_in = std::mem::take(&mut self.air_in);
        self.air_pass(fluid, k0, t_dir, mag, gx, gy, gy < 0.0, !side, &air_in, &mut nxt);
        self.air_in = air_in;

        self.active = nxt;
        self.next = act;
        if self.dmin < self.dirty_min {
            self.dirty_min = self.dmin;
        }
        if self.dmax > self.dirty_max {
            self.dirty_max = self.dmax;
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn sand_pass(&mut self, fluid: &mut Fluid, k0: usize, t_dir: u32, mag: f64, gx: f64, gy: f64,
                 down: bool, right: bool, act: &[u8], nxt: &mut [u8]) {
        let p = &self.params;
        let m = 65536.0 * mag;
        let rr = self.rate;
        let rate = |x: f64| (x * rr).min(1.0) * m;
        let t_fall_air = p.fall_air * m;
        // Leak rate through an air film, by its thickness in cells. Thickness is
        // physical, so the falloff is per reference-grid cell.
        let res = self.h as f64 / REF_ROWS;
        let max_film = 2f64.max((8.0 * res).ceil()) as usize;
        let mut t_leak = vec![0f64; max_film + 1];
        for (k, t) in t_leak.iter_mut().enumerate().skip(1) {
            *t = rate(p.thick_air).max(rate(p.thin_air * p.leak_falloff.powf((k as f64 / res - 1.0).max(0.0))));
        }
        let t_thick = rate(p.thick_air);
        // Release rate for a hanging grain, by how many of its four lower/side
        // neighbours are open: 0 = ceiling of a one-wide hole ... 4 = dangling tip.
        let t_hang = [rate(p.hole), rate(p.narrow), rate(p.flat), rate(p.tip), rate(p.tip * 3.0)];
        let (t_slide, t_slide_rest, t_slide_wall) = (p.slide * m, p.slide_rest * m, p.slide_wall * m);

        // Suspension: settling velocity (cells/tick) plus the liquid's.
        let vs = self.h as f64 / (p.fall_seconds * self.tps);
        let (svx, svy, jit) = (gx * vs, gy * vs, p.jitter * vs * mag * 2.0);
        let (fnx, fs) = (fluid.nx as isize, fluid.fs as isize);

        let (pw, w, h, cw) = (self.pw as isize, self.w as isize, self.h as isize, self.cw as isize);
        let off = self.off;
        let k1 = (k0 + 1) & 7;
        let (d0, d1) = (off[k0], off[k1]);
        let (a0, b0) = (off[(k0 + 7) & 7], off[(k0 + 1) & 7]);
        let (a1, b1) = (off[(k1 + 7) & 7], off[(k1 + 1) & 7]);
        let tick = self.tick;
        let clk = tick << 24;
        let (mut r, mut moves, mut dmin, mut dmax) = (self.seed, 0u32, self.dmin, self.dmax);
        let cells = &mut self.cells;
        let air_in = &mut self.air_in;

        for yi in 0..h {
            let y = if down { h - yi } else { 1 + yi };
            let crow = (y >> CS) * cw;
            let yw = y * pw;
            let frow = ((y >> fs) + 1) * fnx + 1;
            for ci in 0..cw {
                let cx = if right { cw - 1 - ci } else { ci };
                if act[(crow + cx) as usize] == 0 {
                    continue;
                }
                let xs = (cx << CS).max(1);
                let xe = ((cx << CS) + (1 << CS) - 1).min(w);
                if xs > xe {
                    continue;
                }
                for s in 0..=xe - xs {
                    let x = if right { xe - s } else { xs + s };
                    let i = yw + x;
                    let c = cells[i as usize];
                    let t = c & 255;
                    if t < SAND {
                        if t == AIR {
                            air_in[(crow + cx) as usize] = 1;
                        }
                        continue;
                    }
                    if c >> 24 == tick {
                        continue;
                    }

                    xorshift(&mut r);
                    let pick = (r & 0xffff) < t_dir;
                    let roll = r >> 16;
                    let (d, sa, sb) = if pick { (d1, a1, b1) } else { (d0, a0, b0) };
                    let energy = c & 0xff0000;
                    let td = typ(cells, i + d);
                    let j: isize;
                    let th: f64;

                    if td <= AIR {
                        // Fluid underneath.
                        let free = energy != 0 || typ(cells, i - d) < WALL;
                        if free && td == LIQUID {
                            // Suspended: drift with the liquid while settling.
                            let fi = (frow + (x >> fs)) as usize;
                            fluid.sand[fi] += 1.0;
                            nxt[(crow + cx) as usize] = 1;
                            xorshift(&mut r);
                            let jx = ((r & 0xff) as f64 - 127.5) * (jit / 255.0);
                            let jy = (((r >> 8) & 0xff) as f64 - 127.5) * (jit / 255.0);
                            let mut dx = (fluid.u[fi] as f64 + svx + jx + ((r >> 16) & 0xff) as f64 / 256.0).floor() as isize;
                            let mut dy = (fluid.v[fi] as f64 + svy + jy + (r >> 24) as f64 / 256.0).floor() as isize;
                            dx = dx.clamp(-3, 3);
                            dy = dy.clamp(-3, 3);
                            if x + dx < 1 { dx = 1 - x } else if x + dx > w { dx = w - x }
                            if y + dy < 1 { dy = 1 - y } else if y + dy > h { dy = h - y }
                            if dx == 0 && dy == 0 {
                                continue;
                            }
                            let jj = i + dx + dy * pw;
                            j = if typ(cells, jj) != LIQUID
                                || ((dx > 1 || dx < -1 || dy > 1 || dy < -1) && typ(cells, i + (dx >> 1) + (dy >> 1) * pw) != LIQUID)
                            {
                                i + d // path blocked: just sink
                            } else {
                                jj
                            };
                            th = 65536.0;
                        } else if free {
                            th = t_fall_air;
                            j = i + d;
                        } else {
                            // Hanging from the sand above: how exposed is it?
                            let open = (typ(cells, i + sa) < WALL) as usize + (typ(cells, i + sb) < WALL) as usize
                                + (typ(cells, i + sa - d) < WALL) as usize + (typ(cells, i + sb - d) < WALL) as usize;
                            let t2 = typ(cells, i + d + d);
                            if td == LIQUID {
                                if t2 >= SAND {
                                    continue; // a pocket of liquid sealed in sand can't swallow more
                                }
                                th = t_hang[open];
                            } else {
                                // Over air: how thick is the film before liquid?
                                let (mut depth, mut q, mut tq) = (1usize, i + d + d, t2);
                                while tq == AIR && depth < max_film {
                                    depth += 1;
                                    q += d;
                                    tq = typ(cells, q);
                                }
                                th = if tq == LIQUID { t_leak[depth] } else { t_thick };
                            }
                            j = i + d;
                        }
                    } else {
                        // Supported: try to roll down a slope.
                        let (first, second) = if roll & 1 != 0 { (sa, sb) } else { (sb, sa) };
                        let (tf, ts) = (typ(cells, i + first), typ(cells, i + second));
                        if energy != 0 {
                            if tf <= AIR {
                                j = i + first;
                            } else if ts <= AIR {
                                j = i + second;
                            } else {
                                cells[i as usize] = c - 0x10000; // blocked: bleed off momentum
                                nxt[(crow + cx) as usize] = 1;
                                continue;
                            }
                            th = t_slide;
                        } else {
                            if tf <= AIR && typ(cells, i + first + d) <= AIR {
                                j = i + first;
                            } else if ts <= AIR && typ(cells, i + second + d) <= AIR {
                                j = i + second;
                            } else {
                                continue;
                            }
                            if typ(cells, i - d) < WALL {
                                th = t_slide_rest;
                            } else if typ(cells, j - d) < WALL {
                                th = t_slide_wall; // facing an open cavity
                            } else {
                                continue;
                            }
                        }
                    }

                    nxt[(crow + cx) as usize] = 1;
                    xorshift(&mut r);
                    if (r & 0xffff) as f64 >= th {
                        continue;
                    }

                    // Only motion through liquid builds momentum; a grain nudged by air doesn't.
                    let o = cells[j as usize];
                    cells[i as usize] = (o & 0xffffff) | clk;
                    cells[j as usize] = (c & 0xffff) | (if o & 255 == LIQUID { ENERGY } else { 0 }) | clk;

                    moves += 1;
                    let (ccx0, ccx1) = ((x - REACH) >> CS, (x + REACH) >> CS);
                    let (ccy0, ccy1) = ((y - REACH) >> CS, (y + REACH) >> CS);
                    mark(nxt, ccy0 * cw + ccx0);
                    mark(nxt, ccy0 * cw + ccx1);
                    mark(nxt, ccy1 * cw + ccx0);
                    mark(nxt, ccy1 * cw + ccx1);
                    dmin = dmin.min(y - REACH);
                    dmax = dmax.max(y + REACH);
                }
            }
        }
        self.seed = r;
        self.moves += moves;
        self.dmin = dmin;
        self.dmax = dmax;
    }

    #[allow(clippy::too_many_arguments)]
    fn air_pass(&mut self, fluid: &mut Fluid, k0: usize, t_dir: u32, mag: f64, gx: f64, gy: f64,
                down: bool, right: bool, act: &[u8], nxt: &mut [u8]) {
        let p = &self.params;
        let m = 65536.0 * mag;
        let (t_spread, t_seep) = (p.air_spread * m, p.seep * m);
        // Surface tension: air only spreads sideways where the pocket is at least
        // this deep, so it gathers into bubbles instead of one thin film.
        let min_depth = 2f64.max(round(p.bubble_depth * self.h as f64 / REF_ROWS)) as isize;
        let vr = self.h as f64 / (p.rise_seconds * self.tps);
        let (rvx, rvy) = (-gx * vr, -gy * vr);
        let (fnx, fs) = (fluid.nx as isize, fluid.fs as isize);

        let (pw, w, h, cw) = (self.pw as isize, self.w as isize, self.h as isize, self.cw as isize);
        let off = self.off;
        let k1 = (k0 + 1) & 7;
        // Everything mirrored: air "falls" upward.
        let (u0, u1) = (off[(k0 + 4) & 7], off[(k1 + 4) & 7]);
        let (ua0, ub0) = (off[(k0 + 3) & 7], off[(k0 + 5) & 7]);
        let (ua1, ub1) = (off[(k1 + 3) & 7], off[(k1 + 5) & 7]);
        let (la0, lb0) = (off[(k0 + 2) & 7], off[(k0 + 6) & 7]);
        let (la1, lb1) = (off[(k1 + 2) & 7], off[(k1 + 6) & 7]);
        let tick = self.tick;
        let clk = tick << 24;
        let (mut r, mut moves, mut dmin, mut dmax) = (self.seed, 0u32, self.dmin, self.dmax);
        let cells = &mut self.cells;

        for yi in 0..h {
            let y = if down { h - yi } else { 1 + yi };
            let crow = (y >> CS) * cw;
            let yw = y * pw;
            let frow = ((y >> fs) + 1) * fnx + 1;
            for ci in 0..cw {
                let cx = if right { cw - 1 - ci } else { ci };
                if act[(crow + cx) as usize] == 0 {
                    continue;
                }
                let xs = (cx << CS).max(1);
                let xe = ((cx << CS) + (1 << CS) - 1).min(w);
                if xs > xe {
                    continue;
                }
                for s in 0..=xe - xs {
                    let x = if right { xe - s } else { xs + s };
                    let i = yw + x;
                    let c = cells[i as usize];
                    if c & 255 != AIR || c >> 24 == tick {
                        continue;
                    }

                    xorshift(&mut r);
                    let pick = (r & 0xffff) < t_dir;
                    let flip_side = (r >> 16) & 1 == 1;
                    let u = if pick { u1 } else { u0 };
                    let tu = typ(cells, i + u);
                    let j: isize;
                    let th: f64;
                    if tu == LIQUID {
                        // A bubble in open liquid: rise, carried by the flow.
                        let fi = (frow + (x >> fs)) as usize;
                        fluid.air[fi] += 1.0;
                        xorshift(&mut r);
                        let mut dx = (fluid.u[fi] as f64 + rvx + (r & 0xffff) as f64 / 65536.0).floor() as isize;
                        let mut dy = (fluid.v[fi] as f64 + rvy + (r >> 16) as f64 / 65536.0).floor() as isize;
                        dx = dx.clamp(-4, 4);
                        dy = dy.clamp(-4, 4);
                        if x + dx < 1 { dx = 1 - x } else if x + dx > w { dx = w - x }
                        if y + dy < 1 { dy = 1 - y } else if y + dy > h { dy = h - y }
                        let jj = i + dx + dy * pw;
                        j = if (dx == 0 && dy == 0) || typ(cells, jj) != LIQUID
                            || ((dx > 1 || dx < -1 || dy > 1 || dy < -1) && typ(cells, i + (dx >> 1) + (dy >> 1) * pw) != LIQUID)
                        {
                            i + u
                        } else {
                            jj
                        };
                        th = 65536.0;
                    } else {
                        let (p1, p2) = if flip_side {
                            (if pick { ub1 } else { ub0 }, if pick { ua1 } else { ua0 })
                        } else {
                            (if pick { ua1 } else { ua0 }, if pick { ub1 } else { ub0 })
                        };
                        let (l1, l2) = if flip_side {
                            (if pick { lb1 } else { lb0 }, if pick { la1 } else { la0 })
                        } else {
                            (if pick { la1 } else { la0 }, if pick { lb1 } else { lb0 })
                        };
                        if typ(cells, i + p1) == LIQUID {
                            j = i + p1;
                            th = m;
                        } else if typ(cells, i + p2) == LIQUID {
                            j = i + p2;
                            th = m;
                        } else if (typ(cells, i + l1) == LIQUID || typ(cells, i + l2) == LIQUID) && deep_air(cells, i, -u, min_depth) {
                            j = if typ(cells, i + l1) == LIQUID { i + l1 } else { i + l2 };
                            th = t_spread;
                        } else if tu >= SAND {
                            j = i + u;
                            th = t_seep;
                        } else {
                            continue;
                        }
                    }

                    nxt[(crow + cx) as usize] = 1;
                    xorshift(&mut r);
                    if (r & 0xffff) as f64 >= th {
                        continue;
                    }
                    let o = cells[j as usize];
                    cells[i as usize] = if o & 255 >= SAND { (o & 0xffff) | clk } else { (o & 0xffffff) | clk };
                    cells[j as usize] = (c & 0xffffff) | clk;

                    moves += 1;
                    let (ccx0, ccx1) = ((x - REACH) >> CS, (x + REACH) >> CS);
                    let (ccy0, ccy1) = ((y - REACH) >> CS, (y + REACH) >> CS);
                    mark(nxt, ccy0 * cw + ccx0);
                    mark(nxt, ccy0 * cw + ccx1);
                    mark(nxt, ccy1 * cw + ccx0);
                    mark(nxt, ccy1 * cw + ccx1);
                    dmin = dmin.min(y - REACH);
                    dmax = dmax.max(y + REACH);
                }
            }
        }
        self.seed = r;
        self.moves += moves;
        self.dmin = dmin;
        self.dmax = dmax;
    }

    /// Row range touched since the last call (for partial texture uploads).
    pub fn take_dirty(&mut self) -> Option<(usize, usize)> {
        let a = self.dirty_min.max(0);
        let b = self.dirty_max.min(self.ph as isize - 1);
        self.dirty_min = self.ph as isize;
        self.dirty_max = -1;
        if a <= b { Some((a as usize, b as usize)) } else { None }
    }
}
