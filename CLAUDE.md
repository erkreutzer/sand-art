# Sand Art

Moving sand picture simulation: coloured sand, liquid and a little air between two panes of glass. `README.md` covers controls and how the sim works; read it before reading `src/`.

- Run: `python3 -m http.server 5178` (also in `.claude/launch.json`), open http://localhost:5178. `?debug` opens the tuning panel, `?main` runs without the worker.
- `src/sim.js`, `src/fluid.js` and `src/seed.js` have no browser dependencies and run headless in Node.

## Native apps

Work on the shared core, iPhone, iPhone Duo and Vision Pro follows `docs/native-plan.md` (architecture, phases, platform constraints). Read it before starting a phase; update it when a decision changes.

## Physics rules

- Keep the sim grounded in real physics (sand and air bubbles in slightly viscous water between glass: buoyancy, drag, surface tension). Name the physical effect before a change and keep values realistic. Never add ad-hoc rules to reproduce a target picture.
- Check every change against the standard scenarios (fresh start, a few flips), side by side with the current code. Drop anything that degrades normal behaviour.
- One small change at a time; let the user look before building on it.
- Ports (JS → Rust, GLSL → Metal) change no behaviour; they must pass the side-by-side comparison first.
