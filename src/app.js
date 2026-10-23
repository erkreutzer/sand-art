import { palettes } from './palettes.js';
import { createDebug } from './debug.js';

// The grid is sized from the viewport, so wait until there is one.
while (!innerWidth || !innerHeight) await new Promise((r) => requestAnimationFrame(r));

const $ = (s) => document.querySelector(s);
const toy = $('#toy'), frame = $('#frame');
let canvas = $('#sand');
const hint = $('#hint');
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch {} },
};

const coarse = matchMedia('(pointer: coarse)').matches;
const dpr = Math.min(window.devicePixelRatio || 1, 3);
// One grain per device pixel where that fits the budget, else 2x2, and so on.
const MAX_CELLS = coarse ? 520_000 : 1_700_000;
const TICKS_PER_SEC = 180;
const query = new URLSearchParams(location.search);

// ---------- layout ----------
const portrait = innerHeight > innerWidth * 1.1;
const aspect = portrait ? 0.74 : 1.38;     // glass width / height

function measure(iw, ih) {
  const b = 0.085 * Math.min(iw, ih);
  const postw = 0.26 * b, side = postw + 0.3 * b;
  const fw = iw + 2 * b, fh = ih + 2 * b;
  const gap = 0.55 * b, baseh = 1.05 * b;
  return { iw, ih, b, postw, side, fw, fh, gap, baseh, depth: 0.8 * b, tw: fw + 2 * side, th: fh + gap + baseh };
}

function fit() {
  const unit = measure(aspect, 1);
  const s = Math.min((innerWidth * 0.9) / unit.tw, (innerHeight * 0.8) / unit.th);
  return measure(aspect * s, s);
}

// Grid resolution: whole device pixels per cell, capped total cell count.
const first = fit();
const devW = first.iw * dpr, devH = first.ih * dpr;
const scale = Math.max(1, Math.ceil(Math.sqrt((devW * devH) / MAX_CELLS)));
const gw = Math.floor(devW / scale), gh = Math.floor(devH / scale);
const gridAspect = gw / gh;

function layout() {
  const m = fit();
  // Keep the canvas at the grid's exact aspect.
  m.ih = m.iw / gridAspect;
  const L = measure(m.iw, m.ih);
  const st = toy.style;
  for (const k of ['iw', 'ih', 'b', 'postw', 'side', 'fw', 'fh', 'gap', 'baseh', 'depth', 'tw', 'th'])
    st.setProperty('--' + k, L[k] + 'px');
  document.documentElement.style.setProperty('--b', L.b + 'px');
  return L;
}
let L = layout();
addEventListener('resize', () => { L = layout(); });

// ---------- wood grain (generated once, as SVG noise) ----------
function grain(fx, fy) {
  const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='640' height='220'>
    <filter id='g'><feTurbulence type='fractalNoise' baseFrequency='${fx} ${fy}' numOctaves='3' seed='7'/>
    <feColorMatrix values='0 0 0 0 .45  0 0 0 0 .28  0 0 0 0 .12  0 -1.6 0 0 1.05'/></filter>
    <rect width='100%' height='100%' filter='url(#g)' opacity='.55'/></svg>`;
  return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
}
const grainV = grain(0.12, 0.0035).replace("width='640' height='220'", "width='220' height='640'");
document.documentElement.style.setProperty('--grain-h', grain(0.0035, 0.12));
document.documentElement.style.setProperty('--grain-v', grainV);

// ---------- engine (in a worker when the browser allows) ----------
let palIndex = Math.min(palettes.length - 1, Math.max(0, +(store.get('sand.palette') ?? 0) || 0));

async function startEngine() {
  const init = { w: gw, h: gh, scale, tps: TICKS_PER_SEC, palette: palettes[palIndex] };
  if (canvas.transferControlToOffscreen && !query.has('main')) {
    let worker;
    try {
      const off = canvas.transferControlToOffscreen();
      worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
      const ok = await new Promise((res) => {
        worker.onmessage = (e) => { if (e.data.type !== 'ready') console.warn(e.data.message); res(e.data.type === 'ready'); };
        worker.onerror = (e) => { console.warn(e.message); res(false); };
        worker.postMessage({ type: 'init', canvas: off, ...init }, [off]);
      });
      if (ok) return workerHost(worker);
    } catch (e) { console.warn(e); }
    worker?.terminate();
    // The old canvas now belongs to the dead worker; start over with a fresh one.
    const fresh = canvas.cloneNode();
    canvas.replaceWith(fresh);
    canvas = fresh;
  }
  const { Engine } = await import('./engine.js');
  const engine = new Engine(canvas, gw, gh, scale, TICKS_PER_SEC);
  engine.setPalette(init.palette);
  return {
    kind: 'main thread', engine, stats: null,
    frame(dt, gx, gy, glint, pose, paused, wantFlow) { this.stats = engine.frame(dt, gx, gy, glint, pose, paused, wantFlow); },
    palette: (p) => engine.setPalette(p),
    seed: (up) => engine.reseed(up),
    tune: (t) => engine.tune(t),
  };
}

// The worker draws as fast as it can keep up: a frame is only posted once the
// previous one is done, with the time in between carried over.
function workerHost(worker) {
  let busy = false, dtAcc = 0, poseAcc = false;
  const host = {
    kind: 'worker', stats: null,
    frame(dt, gx, gy, glint, pose, paused, wantFlow) {
      dtAcc += dt; poseAcc ||= pose;
      if (busy) return;
      busy = true;
      worker.postMessage({ type: 'frame', dt: Math.min(dtAcc, 0.1), gx, gy, glint, poseChanged: poseAcc, paused, wantFlow });
      dtAcc = 0; poseAcc = false;
    },
    palette: (p) => worker.postMessage({ type: 'palette', palette: p }),
    seed: (upsideDown) => worker.postMessage({ type: 'seed', upsideDown }),
    tune: (tuning) => worker.postMessage({ type: 'tune', tuning }),
  };
  worker.onmessage = (e) => {
    if (e.data.type === 'done') { busy = false; host.stats = e.data.stats; }
    else if (e.data.type === 'error') console.error(e.data.message);
  };
  return host;
}

let host;
try {
  host = await startEngine();
} catch (e) {
  $('#hint').textContent = 'This needs a browser with WebGL2.';
  throw e;
}

// ---------- palettes ----------
const nav = $('#palettes');
palettes.forEach((p, i) => {
  const b = document.createElement('button');
  b.title = p.name;
  b.setAttribute('aria-label', p.name);
  const stops = p.sand.map((c, k) => `${c} ${(k / 6) * 360}deg ${((k + 1) / 6) * 360}deg`).join(',');
  b.style.setProperty('--sw', `conic-gradient(${stops})`);
  b.addEventListener('click', () => setPalette(i));
  b.addEventListener('pointerdown', (e) => e.stopPropagation());
  nav.append(b);
});
function setPalette(i) {
  palIndex = (i + palettes.length) % palettes.length;
  host.palette(palettes[palIndex]);
  [...nav.children].forEach((b, k) => b.setAttribute('aria-pressed', String(k === palIndex)));
  store.set('sand.palette', palIndex);
}

// ---------- motion state ----------
let theta = 0;          // flip about the stand's pivot, degrees
let phi = 0;            // turn in the picture plane, degrees
let anim = null;        // { from, to, t0, dur }
let drag = null;
let keyTurn = 0;
let devG = null;        // device gravity in screen space, if available

const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

function animateTo(to, dur) {
  anim = { from: theta, to, t0: performance.now(), dur };
}
function flip() {
  const base = anim ? anim.to : Math.round(theta / 180) * 180;
  animateTo(base - 180, 1150);
  dismissHint();
}
// The grid is never rewritten on a flip: the frame simply rests at 180°, and
// gravity in grid space points the other way.
function settle(to) {
  theta = ((Math.round(to) % 360) + 360) % 360;
  anim = null;
}

// ---------- input ----------
const scene = $('#scene');
function frameCenter() {
  const r = toy.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + (L.fh / 2) };
}
// A second finger cancels the flip or drag; a third toggles the tuning panel.
// Nothing else happens until every finger has lifted.
const fingers = new Set();
let multi = false;
scene.addEventListener('pointerdown', (e) => {
  scene.setPointerCapture(e.pointerId);
  fingers.add(e.pointerId);
  if (fingers.size > 1) {
    if (drag?.mode === 'flip') animateTo(Math.round(theta / 180) * 180, 300);
    drag = null;
    multi = true;
    if (fingers.size === 3) debug.toggle();
    return;
  }
  if (multi) return;
  const c = frameCenter();
  drag = {
    id: e.pointerId, x0: e.clientX, y0: e.clientY, mode: null,
    theta0: theta, phi0: phi, a0: Math.atan2(e.clientY - c.y, e.clientX - c.x), c,
    lastY: e.clientY, lastT: performance.now(), vel: 0,
  };
});
scene.addEventListener('pointermove', (e) => {
  if (!drag || e.pointerId !== drag.id) return;
  const dx = e.clientX - drag.x0, dy = e.clientY - drag.y0;
  if (!drag.mode && Math.hypot(dx, dy) > 8) {
    drag.mode = Math.abs(dy) > Math.abs(dx) * 1.2 ? 'flip' : 'turn';
    if (drag.mode === 'flip') { anim = null; drag.theta0 = theta; drag.y0 = e.clientY; }
    dismissHint();
  }
  if (drag.mode === 'flip') {
    theta = drag.theta0 - ((e.clientY - drag.y0) / L.fh) * 180;
    const now = performance.now(), dt = now - drag.lastT;
    if (dt > 0) drag.vel = drag.vel * 0.6 + (-(e.clientY - drag.lastY) / L.fh * 180 / dt) * 0.4 * 1000;
    drag.lastY = e.clientY; drag.lastT = now;
  } else if (drag.mode === 'turn') {
    let a = Math.atan2(e.clientY - drag.c.y, e.clientX - drag.c.x) - drag.a0;
    if (a > Math.PI) a -= 2 * Math.PI;
    if (a < -Math.PI) a += 2 * Math.PI;
    phi = drag.phi0 + (a * 180) / Math.PI;
  }
});
function endDrag(e) {
  fingers.delete(e.pointerId);
  if (!fingers.size) multi = false;
  if (!drag || e.pointerId !== drag.id) return;
  if (!drag.mode) flip();
  else if (drag.mode === 'flip') {
    const target = Math.round((theta + drag.vel * 0.18) / 180) * 180;
    animateTo(target, Math.min(900, 250 + Math.abs(target - theta) * 4));
  }
  drag = null;
}
scene.addEventListener('pointerup', endDrag);
scene.addEventListener('pointercancel', endDrag);

addEventListener('keydown', (e) => {
  if (e.target instanceof HTMLInputElement || e.metaKey || e.ctrlKey) return;
  if (e.repeat && (e.key === ' ' || e.key === 'Enter')) return;
  if (e.key === ' ' || e.key === 'Enter' || e.key === 'ArrowUp' || e.key === 'ArrowDown') { e.preventDefault(); flip(); }
  else if (e.key === 'ArrowLeft') keyTurn = -1;
  else if (e.key === 'ArrowRight') keyTurn = 1;
  else if (e.key >= '1' && e.key <= String(palettes.length)) setPalette(+e.key - 1);
  else if (e.key === 'p') setPalette(palIndex + 1);
  else if (e.key === 'r') reseed();
  else if (e.key === 'd') debug.toggle();
});
addEventListener('keyup', (e) => {
  if ((e.key === 'ArrowLeft' && keyTurn < 0) || (e.key === 'ArrowRight' && keyTurn > 0)) keyTurn = 0;
});

// Tilting a phone or tablet moves the sand.
function enableMotion() {
  const onMotion = (e) => {
    const a = e.accelerationIncludingGravity;
    if (!a || a.x == null || a.y == null) return;
    let gx = -a.x / 9.81, gy = a.y / 9.81;
    const ang = (-(screen.orientation?.angle ?? window.orientation ?? 0) * Math.PI) / 180;
    const sx = gx * Math.cos(ang) - gy * Math.sin(ang), sy = gx * Math.sin(ang) + gy * Math.cos(ang);
    devG = devG ? { x: devG.x * 0.7 + sx * 0.3, y: devG.y * 0.7 + sy * 0.3 } : { x: sx, y: sy };
  };
  const DM = window.DeviceMotionEvent;
  if (!DM) return;
  if (typeof DM.requestPermission === 'function') {
    DM.requestPermission().then((s) => s === 'granted' && addEventListener('devicemotion', onMotion)).catch(() => {});
  } else addEventListener('devicemotion', onMotion);
}
if (coarse) addEventListener('click', enableMotion, { once: true });

// ---------- hint ----------
hint.textContent = coarse ? 'Tap to flip · drag to turn · tilt to pour' : 'Click to flip · drag to turn';
// ?hint forgets that the hint was dismissed, as on a first visit.
if (query.has('hint')) {
  try { localStorage.removeItem('sand.hinted'); } catch {}
}
let hintShown = !store.get('sand.hinted');
if (!hintShown) hint.classList.add('gone');
function dismissHint() {
  if (!hintShown) return;
  hintShown = false;
  store.set('sand.hinted', '1');
  setTimeout(() => hint.classList.add('gone'), 1500);
}

// ---------- main loop ----------
let last = performance.now(), lastPose = '', frameMs = 16;

function loop(now) {
  const dt = Math.min(0.05, (now - last) / 1000);
  frameMs = frameMs * 0.95 + (now - last) * 0.05;
  last = now;

  if (anim) {
    const p = Math.min(1, (now - anim.t0) / anim.dur);
    theta = anim.from + (anim.to - anim.from) * ease(p);
    if (p >= 1) settle(anim.to);
  }
  if (keyTurn) phi = Math.max(-120, Math.min(120, phi + keyTurn * 70 * dt));
  else if (!drag || drag.mode !== 'turn') phi *= Math.exp(-dt * 3.5);
  if (Math.abs(phi) < 0.01) phi = 0;

  // Gravity in grid space.
  const g0x = devG ? devG.x : 0, g0y = devG ? devG.y : 1;
  const pr = (phi * Math.PI) / 180, tr = (theta * Math.PI) / 180;
  const gx = g0x * Math.cos(pr) + g0y * Math.sin(pr);
  const gy = (-g0x * Math.sin(pr) + g0y * Math.cos(pr)) * Math.cos(tr);

  const pose = theta.toFixed(2) + ',' + phi.toFixed(2);
  const poseChanged = pose !== lastPose;
  if (poseChanged) {
    lastPose = pose;
    toy.style.transform = phi ? `rotate(${phi}deg)` : '';
    frame.style.transform = theta ? `rotateX(${theta}deg)` : '';
    frame.style.setProperty('--shade', (Math.abs(Math.sin(tr)) * 0.35).toFixed(3));
  }

  host.frame(dt, gx, gy, theta * 0.05 + phi * 0.08 + now * 0.0004, poseChanged,
    debug.paused || !!window.sand?.paused, debug.wantFlow);
  debug.update(host.stats, { scale, kind: host.kind, frameMs });
  requestAnimationFrame(loop);
}

// New sand always starts at the top as you see it, whichever way up the frame is.
function reseed() { host.seed(Math.cos((theta * Math.PI) / 180) < 0); }
const debug = createDebug({ host, reseed });
if (query.has('debug')) debug.toggle();
$('#settings').addEventListener('click', () => debug.toggle(true));
setPalette(palIndex);
requestAnimationFrame(loop);

// Console access: sand.tune({ fluid: { vorticity: 0.5 } }) (the D panel does the same).
// Load with ?main to run the engine on this thread and reach it as sand.engine.
window.sand = { flip, seed: reseed, tune: (t) => host.tune(t), engine: host.engine, paused: false };
