// Off-main-thread host for the engine: owns the OffscreenCanvas and does all
// simulation and drawing, so input and the frame's CSS animation stay smooth.
import { Engine } from './engine.js';

let engine = null;

onmessage = (e) => {
  const m = e.data;
  try {
    if (m.type === 'init') {
      engine = new Engine(m.canvas, m.w, m.h, m.scale, m.tps);
      engine.setPalette(m.palette);
      postMessage({ type: 'ready' });
    } else if (!engine) {
      return;
    } else if (m.type === 'frame') {
      const stats = engine.frame(m.dt, m.gx, m.gy, m.glint, m.poseChanged, m.paused, m.wantFlow);
      const f = stats.flow;
      postMessage({ type: 'done', stats }, f ? [f.u.buffer, f.v.buffer, f.solid.buffer] : []);
    } else if (m.type === 'palette') engine.setPalette(m.palette);
    else if (m.type === 'seed') engine.reseed(m.upsideDown);
    else if (m.type === 'tune') engine.tune(m.tuning);
  } catch (err) {
    postMessage({ type: 'error', message: String(err && err.stack || err), init: m.type === 'init' });
  }
};
