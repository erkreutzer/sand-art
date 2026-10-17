// Cellular sand/liquid/air simulation.
//
// Every cell is one 32-bit int so a move is a single swap and the whole grid can be
// uploaded to the GPU as an RGBA8 texture with zero conversion:
//   byte 0 (R) type    0 liquid, 1 air, 2 wall, 3.. sand colour index
//   byte 1 (G) shade   per-grain random brightness, travels with the grain
//   byte 2 (B) energy  >0 while a grain is in motion (momentum)
//   byte 3 (A) clock   tick stamp, so nothing moves twice in one tick
//
// Two kinds of motion:
//  - Contact: grains hanging, landing, rolling down slopes. Gravity can point
//    anywhere; each tick it is split between the two nearest of the 8
//    neighbour directions, so the average drift follows the true angle.
//  - Suspension: a grain sinking through open liquid (or a bubble rising) moves
//    with the local liquid velocity from the coarse fluid solver plus its own
//    settling speed, so curtains of sand drag the liquid and get swirled by it.
//
// How the patterns form (as in the real toy): after a flip the air rises and
// spreads into a barrier under the sand. Sand over air is held; it pours
// through the weak spots - gaps and thin places in the barrier. Air drifting
// into a drained cavity can close a gap, so streams start, stop and wander.
// Streams pile into cones whose colours change as different layers drain.

export const LIQUID = 0, AIR = 1, WALL = 2, SAND = 3;
export const GLITTER = SAND + 6;

const CS = 5;                       // chunk = 32x32 cells
const EMAX = 5;                     // ticks a blocked grain keeps trying to slide
const ENERGY = EMAX << 16;
const REACH = 5;                    // furthest a cell can move in one tick (+1)

// Speeds are per second of real time; contact rates are per tick at the
// reference resolution and get rescaled for the actual grid and tick rate.
export const params = {
  fallSeconds: 4.2,   // a lone grain sinks the height of the glass in this long
  riseSeconds: 1.3,   // ...and a bubble rises it
  jitter: 0.06,       // random wander of a sinking grain, as a fraction of its speed
  fallAir: 1.0,       // grain dropping through an air pocket
  hole: 0.04,         // hanging grain over open liquid, above a one-wide hole
  narrow: 0.035,      // ...open on one more side
  flat: 0.025,        // ...on a flat underside (it erodes layer by layer)
  tip: 0.05,          // ...on a downward point
  thinAir: 0.02,      // hanging grain over a film of air one (reference) cell thick: it leaks
  leakFalloff: 0.5,   // ...each extra cell of film thickness multiplies that by this
  thickAir: 0.00008,  // floor: even a deep pocket lets the odd grain through
  slide: 0.8,         // moving grain rolls down a slope
  slideRest: 0.03,    // resting grain on a too-steep pile face gives way
  slideWall: 0.003,   // ...or on the side wall of a hole in the hanging sand
  airSpread: 0.6,
  bubbleDepth: 4,     // thinnest an air pocket spreads (reference cells, ~2mm)
  seep: 0.00005,      // air working its way up through packed sand
};

// Contact rates were tuned on a 581-row grid at 209 ticks/s.
const REF_ROWS = 581, REF_TPS = 209;

// Is there air for `depth` cells from i along `down` (i itself included)?
function deepAir(cells, i, down, depth) {
  for (let k = 1; k < depth; k++) if ((cells[i + k * down] & 255) !== AIR) return false;
  return true;
}

export class Sim {
  constructor(w, h, fluid) {
    this.w = w; this.h = h;
    this.fluid = fluid;
    const W = this.W = w + 2, H = this.H = h + 2;
    this.buffer = new ArrayBuffer(W * H * 4);
    this.cells = new Int32Array(this.buffer);   // Int32 keeps values in V8's fast small-int path
    this.bytes = new Uint8Array(this.buffer);
    this.cw = (W >> CS) + 1; this.ch = (H >> CS) + 1;
    this.active = new Uint8Array(this.cw * this.ch);
    this.next = new Uint8Array(this.cw * this.ch);
    this.airIn = new Uint8Array(this.cw * this.ch);   // chunks the sand pass saw air in
    this.colCount = new Int32Array(fluid.nx);
    this.tick = 0;
    this.seed = (Math.random() * 0xffffffff) >>> 0 || 1;
    this.moves = 0;
    this.dirtyMin = 0; this.dirtyMax = H - 1;
    this.off = Int32Array.from([1, W + 1, W, W - 1, -1, -W - 1, -W, -W + 1]);
    this.setTickRate(REF_TPS);
    this.reset();
  }

  setTickRate(tps) {
    this.rate = (this.h / REF_ROWS) * (REF_TPS / tps);
    this.tps = tps;
  }

  reset() {
    const { W, H, cells } = this;
    cells.fill(LIQUID);
    for (let x = 0; x < W; x++) { cells[x] = WALL; cells[(H - 1) * W + x] = WALL; }
    for (let y = 0; y < H; y++) { cells[y * W] = WALL; cells[y * W + W - 1] = WALL; }
    this.wakeAll();
  }

  set(x, y, type, shade = 0) {
    this.cells[(y + 1) * this.W + x + 1] = type | (shade << 8);
  }

  wakeAll() {
    this.active.fill(1); this.next.fill(1);
    this.dirtyMin = 0; this.dirtyMax = this.H - 1;
  }

  // Mark fluid cells that are mostly packed sand as solid, for fluid rows [fy0, fy1).
  updateSolids(fy0, fy1) {
    const { W, H, cells, fluid, colCount } = this;
    const fs = fluid.fs, nx = fluid.nx, lim = (1 << (2 * fs)) * 0.55;
    for (let fy = Math.max(1, fy0); fy < Math.min(fluid.ny - 1, fy1); fy++) {
      colCount.fill(0);
      const y0 = (fy - 1) << fs, y1 = Math.min(H, y0 + (1 << fs));
      for (let y = y0; y < y1; y++)
        for (let x = 0, i = y * W; x < W; x++, i++)
          if ((cells[i] & 255) >= SAND) colCount[(x >> fs) + 1]++;
      for (let fx = 1, k = fy * nx + 1; fx < nx - 1; fx++, k++)
        fluid.solid[k] = fluid.edge[k] || colCount[fx] > lim ? 1 : 0;
    }
  }

  // Advance one tick with gravity (gx, gy) in grid space; |g| = 1 is upright.
  step(gx, gy) {
    const mag = Math.min(1, Math.hypot(gx, gy));
    this.moves = 0;
    if (mag < 0.03) return;

    let ang = Math.atan2(gy, gx);
    if (ang < 0) ang += Math.PI * 2;
    const sec = ang / (Math.PI / 4);
    const k0 = Math.floor(sec) & 7;
    const tDir = ((sec - Math.floor(sec)) * 65536) | 0;

    this.tick = (this.tick + 1) & 255;
    const act = this.active, nxt = this.next;
    nxt.fill(0);
    this.airIn.fill(0);
    this.dmin = this.H; this.dmax = 0;

    const side = Math.abs(gx) > 0.15 ? gx > 0 : (this.tick & 1) === 1;
    this.sandPass(k0, tDir, mag, gx, gy, gy >= 0, side, act, nxt);
    this.airPass(k0, tDir, mag, gx, gy, gy < 0, !side, this.airIn, nxt);

    this.active = nxt; this.next = act;
    if (this.dmin < this.dirtyMin) this.dirtyMin = this.dmin;
    if (this.dmax > this.dirtyMax) this.dirtyMax = this.dmax;
  }

  sandPass(k0, tDir, mag, gx, gy, down, right, act, nxt) {
    const airIn = this.airIn;
    const P = params, M = 65536 * mag, R = this.rate;
    const rate = (p) => Math.min(1, p * R) * M;
    const tFallAir = P.fallAir * M;
    // Leak rate through an air film, by its thickness in cells. Thickness is
    // physical, so the falloff is per reference-grid cell.
    const res = this.h / REF_ROWS;
    const maxFilm = Math.max(2, Math.ceil(8 * res));
    const tLeak = new Float64Array(maxFilm + 1);
    for (let k = 1; k <= maxFilm; k++)
      tLeak[k] = Math.max(rate(P.thickAir), rate(P.thinAir * Math.pow(P.leakFalloff, Math.max(0, k / res - 1))));
    const tThick = rate(P.thickAir);
    // Release rate for a hanging grain, by how many of its four lower/side
    // neighbours are open: 0 = ceiling of a one-wide hole ... 4 = dangling tip.
    const tHang = [rate(P.hole), rate(P.narrow), rate(P.flat), rate(P.tip), rate(P.tip * 3)];
    const tSlide = P.slide * M, tSlideRest = P.slideRest * M, tSlideWall = P.slideWall * M;

    // Suspension: settling velocity (cells/tick) plus the liquid's.
    const vs = this.h / (P.fallSeconds * this.tps);
    const svx = gx * vs, svy = gy * vs, jit = P.jitter * vs * mag * 2;
    const { u: fu, v: fv, sand: fsand, nx: fnx, fs } = this.fluid;

    const { W, w, h, cells, off, cw } = this;
    const k1 = (k0 + 1) & 7;
    const d0 = off[k0], d1 = off[k1];
    const a0 = off[(k0 + 7) & 7], b0 = off[(k0 + 1) & 7];
    const a1 = off[(k1 + 7) & 7], b1 = off[(k1 + 1) & 7];
    const tick = this.tick, clk = tick << 24;
    let r = this.seed, moves = 0, dmin = this.dmin, dmax = this.dmax;

    for (let yi = 0; yi < h; yi++) {
      const y = down ? h - yi : 1 + yi;
      const crow = (y >> CS) * cw;
      const yw = y * W;
      const frow = ((y >> fs) + 1) * fnx + 1;
      for (let ci = 0; ci < cw; ci++) {
        const cx = right ? cw - 1 - ci : ci;
        if (act[crow + cx] === 0) continue;
        let xs = cx << CS, xe = xs + (1 << CS) - 1;
        if (xs < 1) xs = 1;
        if (xe > w) xe = w;
        if (xs > xe) continue;
        const x0 = right ? xe : xs, x1 = right ? xs - 1 : xe + 1, sx = right ? -1 : 1;

        for (let x = x0; x !== x1; x += sx) {
          const i = yw + x;
          const c = cells[i];
          const t = c & 255;
          if (t < SAND) { if (t === AIR) airIn[crow + cx] = 1; continue; }
          if ((c >>> 24) === tick) continue;

          r ^= r << 13; r ^= r >>> 17; r ^= r << 5;
          const pick = (r & 0xffff) < tDir;
          const roll = r >>> 16;
          const d = pick ? d1 : d0, sa = pick ? a1 : a0, sb = pick ? b1 : b0;
          const energy = c & 0xff0000;
          const td = cells[i + d] & 255;
          let j, th;

          if (td <= AIR) {
            // Fluid underneath.
            const free = energy !== 0 || (cells[i - d] & 255) < WALL;
            if (free && td === LIQUID) {
              // Suspended: drift with the liquid while settling.
              const fi = frow + (x >> fs);
              fsand[fi]++;
              nxt[crow + cx] = 1;
              r ^= r << 13; r ^= r >>> 17; r ^= r << 5;
              const jx = ((r & 0xff) - 127.5) * (jit / 255), jy = (((r >>> 8) & 0xff) - 127.5) * (jit / 255);
              let dx = Math.floor(fu[fi] + svx + jx + ((r >>> 16) & 0xff) / 256);
              let dy = Math.floor(fv[fi] + svy + jy + (r >>> 24) / 256);
              if (dx > 3) dx = 3; else if (dx < -3) dx = -3;
              if (dy > 3) dy = 3; else if (dy < -3) dy = -3;
              if (x + dx < 1) dx = 1 - x; else if (x + dx > w) dx = w - x;
              if (y + dy < 1) dy = 1 - y; else if (y + dy > h) dy = h - y;
              if (dx === 0 && dy === 0) continue;
              j = i + dx + dy * W;
              if ((cells[j] & 255) !== LIQUID ||
                  ((dx > 1 || dx < -1 || dy > 1 || dy < -1) && (cells[i + (dx >> 1) + (dy >> 1) * W] & 255) !== LIQUID))
                j = i + d;                       // path blocked: just sink
              th = 65536;
            } else if (free) {
              th = tFallAir; j = i + d;
            } else {
              // Hanging from the sand above: how exposed is it?
              const open = ((cells[i + sa] & 255) < WALL ? 1 : 0) + ((cells[i + sb] & 255) < WALL ? 1 : 0) +
                ((cells[i + sa - d] & 255) < WALL ? 1 : 0) + ((cells[i + sb - d] & 255) < WALL ? 1 : 0);
              const t2 = cells[i + d + d] & 255;
              if (td === LIQUID) {
                if (t2 >= SAND) continue;      // a pocket of liquid sealed in sand can't swallow more
                th = tHang[open];
              } else {
                // Over air: how thick is the film before liquid?
                let depth = 1, q = i + d + d, tq = t2;
                while (tq === AIR && depth < maxFilm) { depth++; q += d; tq = cells[q] & 255; }
                th = tq === LIQUID ? tLeak[depth] : tThick;
              }
              j = i + d;
            }
          } else {
            // Supported: try to roll down a slope.
            const first = (roll & 1) ? sa : sb, second = (roll & 1) ? sb : sa;
            const tf = cells[i + first] & 255, ts = cells[i + second] & 255;
            if (energy !== 0) {
              if (tf <= AIR) { j = i + first; th = tSlide; }
              else if (ts <= AIR) { j = i + second; th = tSlide; }
              else {
                cells[i] = c - 0x10000;           // blocked: bleed off momentum
                nxt[crow + cx] = 1;
                continue;
              }
            } else if (tf <= AIR && (cells[i + first + d] & 255) <= AIR) j = i + first;
            else if (ts <= AIR && (cells[i + second + d] & 255) <= AIR) j = i + second;
            else continue;
            if (energy === 0) {
              if ((cells[i - d] & 255) < WALL) th = tSlideRest;
              else if ((cells[j - d] & 255) < WALL) th = tSlideWall;   // facing an open cavity
              else continue;
            }
          }

          nxt[crow + cx] = 1;
          r ^= r << 13; r ^= r >>> 17; r ^= r << 5;
          if ((r & 0xffff) >= th) continue;

          // Only motion through liquid builds momentum; a grain nudged by air doesn't.
          const o = cells[j];
          cells[i] = (o & 0xffffff) | clk;
          cells[j] = (c & 0xffff) | ((o & 255) === LIQUID ? ENERGY : 0) | clk;

          moves++;
          const ccx0 = (x - REACH) >> CS, ccx1 = (x + REACH) >> CS;
          const ccy0 = (y - REACH) >> CS, ccy1 = (y + REACH) >> CS;
          nxt[ccy0 * cw + ccx0] = 1; nxt[ccy0 * cw + ccx1] = 1;
          nxt[ccy1 * cw + ccx0] = 1; nxt[ccy1 * cw + ccx1] = 1;
          if (y - REACH < dmin) dmin = y - REACH;
          if (y + REACH > dmax) dmax = y + REACH;
        }
      }
    }
    this.seed = r; this.moves += moves; this.dmin = dmin; this.dmax = dmax;
  }

  airPass(k0, tDir, mag, gx, gy, down, right, act, nxt) {
    const P = params, M = 65536 * mag;
    const tSpread = P.airSpread * M, tSeep = P.seep * M;
    // Surface tension: air only spreads sideways where the pocket is at least
    // this deep, so it gathers into bubbles instead of one thin film.
    const minDepth = Math.max(2, Math.round(P.bubbleDepth * this.h / REF_ROWS));
    const vr = this.h / (P.riseSeconds * this.tps);
    const rvx = -gx * vr, rvy = -gy * vr;
    const { u: fu, v: fv, air: fair, nx: fnx, fs } = this.fluid;

    const { W, w, h, cells, off, cw } = this;
    const k1 = (k0 + 1) & 7;
    // Everything mirrored: air "falls" upward.
    const u0 = off[(k0 + 4) & 7], u1 = off[(k1 + 4) & 7];
    const ua0 = off[(k0 + 3) & 7], ub0 = off[(k0 + 5) & 7];
    const ua1 = off[(k1 + 3) & 7], ub1 = off[(k1 + 5) & 7];
    const la0 = off[(k0 + 2) & 7], lb0 = off[(k0 + 6) & 7];
    const la1 = off[(k1 + 2) & 7], lb1 = off[(k1 + 6) & 7];
    const tick = this.tick, clk = tick << 24;
    let r = this.seed, moves = 0, dmin = this.dmin, dmax = this.dmax;

    for (let yi = 0; yi < h; yi++) {
      const y = down ? h - yi : 1 + yi;
      const crow = (y >> CS) * cw;
      const yw = y * W;
      const frow = ((y >> fs) + 1) * fnx + 1;
      for (let ci = 0; ci < cw; ci++) {
        const cx = right ? cw - 1 - ci : ci;
        if (act[crow + cx] === 0) continue;
        let xs = cx << CS, xe = xs + (1 << CS) - 1;
        if (xs < 1) xs = 1;
        if (xe > w) xe = w;
        if (xs > xe) continue;
        const x0 = right ? xe : xs, x1 = right ? xs - 1 : xe + 1, sx = right ? -1 : 1;

        for (let x = x0; x !== x1; x += sx) {
          const i = yw + x;
          const c = cells[i];
          if ((c & 255) !== AIR) continue;
          if ((c >>> 24) === tick) continue;

          r ^= r << 13; r ^= r >>> 17; r ^= r << 5;
          const pick = (r & 0xffff) < tDir;
          const flipSide = (r >>> 16) & 1;
          const u = pick ? u1 : u0;
          const tu = cells[i + u] & 255;
          let j = -1, th = 0;
          if (tu === LIQUID) {
            // A bubble in open liquid: rise, carried by the flow.
            const fi = frow + (x >> fs);
            fair[fi]++;
            r ^= r << 13; r ^= r >>> 17; r ^= r << 5;
            let dx = Math.floor(fu[fi] + rvx + (r & 0xffff) / 65536);
            let dy = Math.floor(fv[fi] + rvy + (r >>> 16) / 65536);
            if (dx > 4) dx = 4; else if (dx < -4) dx = -4;
            if (dy > 4) dy = 4; else if (dy < -4) dy = -4;
            if (x + dx < 1) dx = 1 - x; else if (x + dx > w) dx = w - x;
            if (y + dy < 1) dy = 1 - y; else if (y + dy > h) dy = h - y;
            j = i + dx + dy * W;
            if ((dx === 0 && dy === 0) || (cells[j] & 255) !== LIQUID ||
                ((dx > 1 || dx < -1 || dy > 1 || dy < -1) && (cells[i + (dx >> 1) + (dy >> 1) * W] & 255) !== LIQUID))
              j = i + u;
            th = 65536;
          } else {
            const p1 = flipSide ? (pick ? ub1 : ub0) : (pick ? ua1 : ua0);
            const p2 = flipSide ? (pick ? ua1 : ua0) : (pick ? ub1 : ub0);
            const l1 = flipSide ? (pick ? lb1 : lb0) : (pick ? la1 : la0);
            const l2 = flipSide ? (pick ? la1 : la0) : (pick ? lb1 : lb0);
            if ((cells[i + p1] & 255) === LIQUID) { j = i + p1; th = M; }
            else if ((cells[i + p2] & 255) === LIQUID) { j = i + p2; th = M; }
            else if (((cells[i + l1] & 255) === LIQUID || (cells[i + l2] & 255) === LIQUID) && deepAir(cells, i, -u, minDepth))
              { j = (cells[i + l1] & 255) === LIQUID ? i + l1 : i + l2; th = tSpread; }
            else if (tu >= SAND) { j = i + u; th = tSeep; }
            else continue;
          }

          nxt[crow + cx] = 1;
          r ^= r << 13; r ^= r >>> 17; r ^= r << 5;
          if ((r & 0xffff) >= th) continue;
          const o = cells[j];
          cells[i] = (o & 255) >= SAND ? ((o & 0xffff) | clk) : ((o & 0xffffff) | clk);
          cells[j] = (c & 0xffffff) | clk;

          moves++;
          const ccx0 = (x - REACH) >> CS, ccx1 = (x + REACH) >> CS;
          const ccy0 = (y - REACH) >> CS, ccy1 = (y + REACH) >> CS;
          nxt[ccy0 * cw + ccx0] = 1; nxt[ccy0 * cw + ccx1] = 1;
          nxt[ccy1 * cw + ccx0] = 1; nxt[ccy1 * cw + ccx1] = 1;
          if (y - REACH < dmin) dmin = y - REACH;
          if (y + REACH > dmax) dmax = y + REACH;
        }
      }
    }
    this.seed = r; this.moves += moves; this.dmin = dmin; this.dmax = dmax;
  }

  // Row range touched since the last call (for partial texture uploads).
  takeDirty() {
    let a = Math.max(0, this.dirtyMin), b = Math.min(this.H - 1, this.dirtyMax);
    this.dirtyMin = this.H; this.dirtyMax = -1;
    return a <= b ? [a, b] : null;
  }
}
