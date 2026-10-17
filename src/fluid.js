// Coarse incompressible liquid (Stam-style stable fluids) underneath the sand grid.
//
// One fluid cell covers 2^fs x 2^fs sim cells. Velocities are in sim cells per
// tick, so the sand pass can add them straight onto a grain's motion.
// Coupling: sinking sand makes the liquid locally heavier and drags it down;
// bubbles lift it. Because the liquid can't compress, every downward curtain
// forces an upwelling beside it - which is where the swirls come from.

export const fluidParams = {
  sandWeight: 1.6,    // push from suspended sand, per unit concentration per frame
  airLift: 0.8,       // ...and from bubbles, the other way
  damping: 0.012,     // viscosity, crudely
  vorticity: 0.35,    // re-energises small eddies the coarse grid would smear out
  iterations: 18,     // pressure solve sweeps
  maxSpeed: 3,        // cells per tick
};

export class Fluid {
  constructor(simW, simH, fs) {
    this.fs = fs;
    // One cell of permanent wall all round, so neighbours never need bounds checks.
    const nx = (this.nx = (simW >> fs) + 3), ny = (this.ny = (simH >> fs) + 3);
    const N = nx * ny;
    this.u = new Float32Array(N); this.v = new Float32Array(N);
    this.u0 = new Float32Array(N); this.v0 = new Float32Array(N);
    this.p = new Float32Array(N); this.div = new Float32Array(N);
    this.curl = new Float32Array(N);
    this.sand = new Float32Array(N); this.air = new Float32Array(N);
    this.solid = new Uint8Array(N);
    this.edge = new Uint8Array(N);
    for (let x = 0; x < nx; x++) { this.edge[x] = 1; this.edge[(ny - 1) * nx + x] = 1; }
    for (let y = 0; y < ny; y++) { this.edge[y * nx] = 1; this.edge[y * nx + nx - 1] = 1; }
    this.solid.set(this.edge);
  }

  reset() {
    this.u.fill(0); this.v.fill(0); this.p.fill(0);
    this.sand.fill(0); this.air.fill(0);
  }

  // Advance one frame that covered `ticks` sim ticks under gravity (gx, gy).
  step(gx, gy, ticks) {
    if (ticks <= 0) return;
    const P = fluidParams;
    const { nx, ny, u, v, u0, v0, p, div, curl, solid, sand, air } = this;
    const N = nx * ny;

    // Body forces from suspended sand and bubbles.
    const norm = 1 / (ticks * (1 << (2 * this.fs)));
    const ks = P.sandWeight * norm, ka = P.airLift * norm;
    for (let k = 0; k < N; k++) {
      if (solid[k]) { u[k] = 0; v[k] = 0; }
      else {
        const f = sand[k] * ks - air[k] * ka;
        u[k] += gx * f; v[k] += gy * f;
      }
      sand[k] = 0; air[k] = 0;
    }

    // Vorticity confinement.
    if (P.vorticity > 0) {
      for (let y = 1; y < ny - 1; y++)
        for (let x = 1, k = y * nx + 1; x < nx - 1; x++, k++)
          curl[k] = 0.5 * (v[k + 1] - v[k - 1] - (u[k + nx] - u[k - nx]));
      const eps = P.vorticity * ticks * 0.05;
      for (let y = 2; y < ny - 2; y++)
        for (let x = 2, k = y * nx + 2; x < nx - 2; x++, k++) {
          if (solid[k]) continue;
          const nxg = Math.abs(curl[k + 1]) - Math.abs(curl[k - 1]);
          const nyg = Math.abs(curl[k + nx]) - Math.abs(curl[k - nx]);
          const len = Math.hypot(nxg, nyg) + 1e-5;
          u[k] += eps * (nyg / len) * curl[k];
          v[k] -= eps * (nxg / len) * curl[k];
        }
    }

    // Semi-Lagrangian advection of the velocity field by itself.
    u0.set(u); v0.set(v);
    const s = ticks / (1 << this.fs), keep = Math.pow(1 - P.damping, ticks / 3);
    const xmax = nx - 1.001, ymax = ny - 1.001;
    for (let y = 1; y < ny - 1; y++)
      for (let x = 1, k = y * nx + 1; x < nx - 1; x++, k++) {
        if (solid[k]) { u[k] = 0; v[k] = 0; continue; }
        let px = x - u0[k] * s, py = y - v0[k] * s;
        if (px < 0) px = 0; else if (px > xmax) px = xmax;
        if (py < 0) py = 0; else if (py > ymax) py = ymax;
        const x0 = px | 0, y0 = py | 0, fx = px - x0, fy = py - y0;
        const a = y0 * nx + x0, b = a + nx;
        u[k] = keep * ((u0[a] * (1 - fx) + u0[a + 1] * fx) * (1 - fy) + (u0[b] * (1 - fx) + u0[b + 1] * fx) * fy);
        v[k] = keep * ((v0[a] * (1 - fx) + v0[a + 1] * fx) * (1 - fy) + (v0[b] * (1 - fx) + v0[b + 1] * fx) * fy);
      }

    // Pressure projection: make the flow divergence-free (walls are no-flux).
    for (let y = 1; y < ny - 1; y++)
      for (let x = 1, k = y * nx + 1; x < nx - 1; x++, k++) {
        if (solid[k]) { div[k] = 0; continue; }
        const ur = solid[k + 1] ? 0 : u[k + 1], ul = solid[k - 1] ? 0 : u[k - 1];
        const vd = solid[k + nx] ? 0 : v[k + nx], vu = solid[k - nx] ? 0 : v[k - nx];
        div[k] = 0.5 * (ur - ul + vd - vu);
      }
    for (let it = 0; it < P.iterations; it++)
      for (let y = 1; y < ny - 1; y++)
        for (let x = 1, k = y * nx + 1; x < nx - 1; x++, k++) {
          if (solid[k]) continue;
          let sum = 0, n = 0;
          if (!solid[k - 1]) { sum += p[k - 1]; n++; }
          if (!solid[k + 1]) { sum += p[k + 1]; n++; }
          if (!solid[k - nx]) { sum += p[k - nx]; n++; }
          if (!solid[k + nx]) { sum += p[k + nx]; n++; }
          if (n) p[k] = (sum - div[k]) / n;
        }
    const vmax = P.maxSpeed;
    for (let y = 1; y < ny - 1; y++)
      for (let x = 1, k = y * nx + 1; x < nx - 1; x++, k++) {
        if (solid[k]) continue;
        const pc = p[k];
        const pl = solid[k - 1] ? pc : p[k - 1], pr = solid[k + 1] ? pc : p[k + 1];
        const pu = solid[k - nx] ? pc : p[k - nx], pd = solid[k + nx] ? pc : p[k + nx];
        let uu = u[k] - 0.5 * (pr - pl), vv = v[k] - 0.5 * (pd - pu);
        if (uu > vmax) uu = vmax; else if (uu < -vmax) uu = -vmax;
        if (vv > vmax) vv = vmax; else if (vv < -vmax) vv = -vmax;
        u[k] = uu; v[k] = vv;
      }
  }
}
