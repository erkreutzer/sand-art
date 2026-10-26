# Sand Art

Moving sand picture simulation: coloured sand, liquid and a little air between two panes of glass. `README.md` covers controls and how the sim works; read it before reading `src/`.

- Run: `python3 -m http.server 5178` (also in `.claude/launch.json`), open http://localhost:5178. `?debug` opens the tuning panel, `?main` runs without the worker, `?core=wasm` runs the Rust core instead of the JS physics.
- After changing `core/`, run `tools/build-core.sh` (prints only errors) and commit the rebuilt `src/sand_core.wasm`, so the static server keeps working without a build step.
- `src/sim.js`, `src/fluid.js` and `src/seed.js` have no browser dependencies and run headless in Node.
- Compare: `node tools/compare/run.mjs <A> <B> --seeds 1,2` runs the standard scenarios on two versions (`.` = working tree, any git ref, or `rust` = `core/` built for wasm), prints a few numbers per phase and writes one side-by-side PNG to `tools/compare/out/`. The same seed number gives the same starting picture in both.

## Native apps

Work on the shared core, iPhone, iPhone Duo and Vision Pro follows `docs/native-plan.md` (architecture, phases, platform constraints). Read it before starting a phase; update it when a decision changes.

## Physics rules

- Keep the sim grounded in real physics (sand and air bubbles in slightly viscous water between glass: buoyancy, drag, surface tension). Name the physical effect before a change and keep values realistic. Never add ad-hoc rules to reproduce a target picture.
- Check every change against the standard scenarios (fresh start, a few flips), side by side with the current code. Drop anything that degrades normal behaviour.
- One small change at a time; let the user look before building on it.
- Ports (JS → Rust, GLSL → Metal) change no behaviour; they must pass the side-by-side comparison first.
