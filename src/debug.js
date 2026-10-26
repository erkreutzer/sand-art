// Tuning panel (press D): live sliders for every physics setting, a flow-field
// overlay, and stats. Tweaks persist in localStorage until reset, and "Copy"
// puts them on the clipboard as JSON.
import { params } from './sim.js';
import { fluidParams } from './fluid.js';
import { seedParams } from './seed.js';
import { renderParams } from './render.js';
import { engineParams } from './core-js.js';

// [key, label, min, max, step | 'log']
const GROUPS = [
  { title: 'Look', key: 'render', obj: renderParams, open: true, items: [
    ['liquidTint', 'Liquid opacity (× palette)', 0, 4, 0.05],
  ] },
  { title: 'Liquid', key: 'fluid', obj: fluidParams, open: true, items: [
    ['vorticity', 'Swirl (vorticity)', 0, 3, 0.01],
    ['sandWeight', 'Sand drags liquid', 0, 6, 0.05],
    ['airLift', 'Bubbles lift liquid', 0, 3, 0.05],
    ['damping', 'Viscosity', 0.001, 0.1, 'log'],
    ['maxSpeed', 'Max flow speed', 0.5, 6, 0.1],
    ['iterations', 'Pressure iterations', 4, 40, 1],
  ] },
  { title: 'Grains', key: 'sim', obj: params, items: [
    ['fallSeconds', 'Sink time, full height (s)', 1, 12, 0.1],
    ['jitter', 'Random wander', 0, 0.5, 0.01],
    ['slide', 'Rolling while moving', 0, 1, 0.01],
    ['slideRest', 'Steep faces collapse', 0.001, 0.3, 'log'],
  ] },
  { title: 'Hanging sand', key: 'sim', obj: params, items: [
    ['flat', 'Lets go: flat underside', 1e-4, 0.3, 'log'],
    ['tip', 'Lets go: points', 1e-4, 0.5, 'log'],
    ['narrow', 'Lets go: narrow gaps', 1e-4, 0.5, 'log'],
    ['hole', 'Lets go: one-wide holes', 1e-4, 0.5, 'log'],
    ['slideWall', 'Cavity walls collapse', 1e-5, 0.1, 'log'],
  ] },
  { title: 'Air barrier', key: 'sim', obj: params, items: [
    ['thinAir', 'Leak through thin air', 1e-4, 0.3, 'log'],
    ['leakFalloff', 'Leak kept per extra cell', 0.05, 0.95, 0.01],
    ['thickAir', 'Leak through deep air', 1e-6, 1e-2, 'log'],
    ['bubbleDepth', 'Bubble min depth (cells)', 1, 16, 1],
    ['riseSeconds', 'Bubble rise time (s)', 0.2, 5, 0.05],
    ['airSpread', 'Air spreads sideways', 0, 1, 0.01],
    ['seep', 'Air seeps up through sand', 1e-6, 1e-2, 'log'],
  ] },
  { title: 'New sand (applies on R)', key: 'seed', obj: seedParams, items: [
    ['air', 'Air amount', 5e-4, 0.03, 'log'],
    ['sand', 'Sand level', 0.15, 0.6, 0.01],
  ] },
  { title: 'Simulation', key: 'engine', obj: engineParams, open: true, items: [
    ['timeScale', 'Speed', 0.1, 4, 'log'],
  ] },
];

const STORE = 'sand.tuning';
const load = () => { try { return JSON.parse(localStorage.getItem(STORE)) || {}; } catch { return {}; } };
const save = (o) => { try { localStorage.setItem(STORE, JSON.stringify(o)); } catch {} };
const fmt = (v) => (Math.abs(v) >= 100 || Number.isInteger(v) ? String(Math.round(v * 100) / 100)
  : Math.abs(v) >= 0.01 ? v.toFixed(3).replace(/0+$/, '').replace(/\.$/, '') : v.toPrecision(2));

export function createDebug({ host, reseed }) {
  // Defaults are whatever the modules start with; then apply saved tweaks.
  const defaults = {};
  for (const g of GROUPS) {
    defaults[g.key] ||= {};
    for (const [k] of g.items) defaults[g.key][k] = g.obj[k];
  }
  let overrides = load();
  for (const g of GROUPS) Object.assign(g.obj, pick(overrides[g.key], g.items));
  if (Object.keys(overrides).length) host.tune(overrides);

  function pick(o, items) {
    const r = {};
    if (o) for (const [k] of items) if (k in o) r[k] = o[k];
    return r;
  }

  const panel = document.getElementById('debug');
  panel.innerHTML = `
    <header><strong>Tuning</strong><span class="hint">D or three-finger tap to toggle · double-click a label to reset it</span>
      <button class="close" data-a="close" title="Close" aria-label="Close">✕</button></header>
    <pre class="stats"></pre>
    <div class="toggles">
      <label><input type="checkbox" data-t="flow"> Show flow</label>
      <label><input type="checkbox" data-t="pause"> Pause</label>
    </div>
    <div class="groups"></div>
    <footer>
      <button data-a="seed">New sand</button>
      <button data-a="copy">Copy settings</button>
      <button data-a="reset">Reset all</button>
    </footer>`;
  const statsEl = panel.querySelector('.stats');
  const groupsEl = panel.querySelector('.groups');
  const rows = [];

  for (const g of GROUPS) {
    const det = document.createElement('details');
    det.open = !!g.open;
    det.innerHTML = `<summary>${g.title}</summary>`;
    for (const [key, label, min, max, step] of g.items) {
      const log = step === 'log';
      const toSlider = (v) => (log ? Math.log10(Math.max(v, min)) : v);
      const fromSlider = (s) => (log ? Math.pow(10, s) : s);
      const row = document.createElement('div');
      row.className = 'row';
      row.innerHTML = `<label>${label}</label><output></output>
        <input type="range" min="${toSlider(min)}" max="${toSlider(max)}" step="${log ? 0.01 : step}">`;
      const input = row.querySelector('input'), out = row.querySelector('output');
      const sync = () => {
        const v = g.obj[key];
        input.value = toSlider(v);
        out.textContent = fmt(v);
        row.classList.toggle('changed', v !== defaults[g.key][key]);
      };
      const set = (v) => {
        if (step === 1) v = Math.round(v);
        g.obj[key] = v;
        (overrides[g.key] ||= {})[key] = v;
        if (v === defaults[g.key][key]) delete overrides[g.key][key];
        save(overrides);
        host.tune({ [g.key]: { [key]: v } });
        sync();
      };
      input.addEventListener('input', () => set(fromSlider(+input.value)));
      row.querySelector('label').addEventListener('dblclick', () => set(defaults[g.key][key]));
      sync();
      rows.push(sync);
      det.append(row);
    }
    groupsEl.append(det);
  }

  const state = { flow: false, paused: false };
  panel.querySelector('[data-t=flow]').addEventListener('change', (e) => {
    state.flow = e.target.checked;
    flowCanvas.hidden = !state.flow;
  });
  panel.querySelector('[data-t=pause]').addEventListener('change', (e) => { state.paused = e.target.checked; });
  panel.querySelector('[data-a=close]').addEventListener('click', () => toggle(false));
  panel.querySelector('[data-a=seed]').addEventListener('click', reseed);
  panel.querySelector('[data-a=reset]').addEventListener('click', () => {
    overrides = {};
    save(overrides);
    for (const g of GROUPS) Object.assign(g.obj, defaults[g.key]);
    host.tune(defaults);
    rows.forEach((s) => s());
  });
  const copyBtn = panel.querySelector('[data-a=copy]');
  copyBtn.addEventListener('click', async () => {
    const text = JSON.stringify(overrides, null, 2);
    try { await navigator.clipboard.writeText(text); copyBtn.textContent = 'Copied'; }
    catch { window.prompt('Settings', text); }
    setTimeout(() => { copyBtn.textContent = 'Copy settings'; }, 1200);
  });

  // ---------- flow overlay ----------
  const flowCanvas = document.getElementById('flow');
  function drawFlow(f) {
    const cw = flowCanvas.offsetWidth, ch = flowCanvas.offsetHeight;
    const dpr = Math.min(2, devicePixelRatio || 1);
    if (flowCanvas.width !== Math.round(cw * dpr)) { flowCanvas.width = Math.round(cw * dpr); flowCanvas.height = Math.round(ch * dpr); }
    const g = flowCanvas.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, cw, ch);
    const cell = 1 << f.fs, sx = cw / (f.W - 2), sy = ch / (f.H - 2);
    const stride = Math.max(1, Math.round(14 / (cell * sx)));   // an arrow every ~14px
    const len = cell * sx * stride * 0.9;
    g.lineWidth = 1.2;
    g.strokeStyle = 'rgba(255, 40, 120, .85)';
    g.fillStyle = 'rgba(255, 40, 120, .85)';
    g.beginPath();
    for (let y = 1; y < f.ny - 1; y += stride)
      for (let x = 1; x < f.nx - 1; x += stride) {
        const k = y * f.nx + x;
        if (f.solid[k]) continue;
        const px = ((x - 1) * cell + cell / 2 - 1) * sx, py = ((y - 1) * cell + cell / 2 - 1) * sy;
        const s = Math.hypot(f.u[k], f.v[k]);
        if (s < 0.02) { g.rect(px - 0.5, py - 0.5, 1, 1); continue; }
        const m = Math.min(1, s / 1.5) * len / s;
        g.moveTo(px, py);
        g.lineTo(px + f.u[k] * m, py + f.v[k] * m);
      }
    g.stroke();
  }

  function toggle(open = panel.hidden) {
    panel.hidden = !open;
    flowCanvas.hidden = panel.hidden || !state.flow;
  }

  return {
    get open() { return !panel.hidden; },
    get wantFlow() { return !panel.hidden && state.flow; },
    get paused() { return state.paused; },
    toggle,
    update(s, extra) {
      if (panel.hidden || !s) return;
      statsEl.textContent =
        `${s.w}×${s.h} grains @${extra.scale}px · ${(s.w * s.h / 1e6).toFixed(2)}M · ${extra.kind} · ${s.core} core\n` +
        `physics ${s.coreMs.toFixed(1)}ms (${s.ticks} ticks${s.simMs != null ? `: sand ${s.simMs.toFixed(1)} liquid ${s.fluidMs.toFixed(1)}` : ''})  frame ${extra.frameMs.toFixed(1)}ms`;
      if (s.flow && state.flow) drawFlow(s.flow);
    },
  };
}
