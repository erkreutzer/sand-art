# Sand Art

A simulation of a moving sand picture: coloured sand, liquid and a little air between two panes of glass. Flip the frame and the sand pours through gaps in the air barrier, building layered mountains.

No build step and no dependencies. Serve the folder with any static server:

```bash
python3 -m http.server 5178
```

Then open http://localhost:5178.

## Controls

| | |
|---|---|
| Click / tap, Space, ↑ ↓ | Flip the frame on its stand |
| Drag up/down | Flip by hand (snaps to the nearest side) |
| Drag around | Turn the frame (eases back when released); ← → also turn |
| Tilt a phone or tablet | Moves the sand (motion permission is requested on the first tap) |
| Swatches, 1–7, P | Sand colours |
| R | New sand |
| D, three-finger tap, ⚙ button | Tuning panel: live sliders for every physics setting, a flow-field overlay, stats |
| `?debug` | Opens the tuning panel on load |
| `?hint` | Forgets that the hint was dismissed, so it shows again as on a first visit |

## How it works

- **Grains** (`src/sim.js`): a cellular automaton over one `Int32Array`, one grain per device pixel where the screen allows. Each cell packs type, shade, momentum and a tick stamp, so a move is one swap. Only 32×32 chunks where something can still move are simulated, so a settled picture costs almost nothing.
- **Air barrier**: after a flip the air rises and gathers under the sand. Surface tension keeps it in pockets about 2 mm deep, not a thin film. Sand seeps through thin parts of the barrier and pours through gaps, so streams open, close and wander, and each drains one colour band at a time.
- **Liquid** (`src/fluid.js`): a coarse incompressible fluid solver, one cell per 8×8 grains. Sinking sand drags the liquid down and bubbles lift it. Because the liquid can't compress, every falling curtain sets up a return flow, and that's where the eddies come from. Every sinking grain and rising bubble moves with the local flow plus its own sinking or rising speed.
- **Threads**: `src/worker.js` runs the sim, the liquid and the WebGL drawing on an OffscreenCanvas, so the page itself only handles input and the frame's CSS animation. Without OffscreenCanvas support it falls back to running on the main thread. A flip never rewrites the grid: the frame just rests at 180° and gravity in grid space reverses.
- **Drawing** (`src/render.js`): the grid is uploaded as an RGBA8 texture as-is, with only the rows that changed re-sent. One shader draws grains, glitter, air menisci and liquid.

## Tuning

Press **D** for the tuning panel. Sliders change grain, air and liquid physics live; double-click a label to reset that one setting. Tweaks are saved in this browser until you press **Reset all**, and **Copy settings** puts them on the clipboard as JSON. To make them permanent, put the values in `params` (`src/sim.js`), `fluidParams` (`src/fluid.js`), `seedParams` (`src/seed.js`) or `engineParams` (`src/engine.js`, which holds the overall speed).

From the console the same settings are available as `sand.tune({ fluid: { vorticity: 0.5 } })`. Load with `?main` to run everything on the main thread, where `sand.engine` gives direct access.
