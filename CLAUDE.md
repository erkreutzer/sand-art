# Sand Art

Moving sand picture simulation: coloured sand, liquid and a little air between two panes of glass. `README.md` covers controls and how the sim works; read it before reading `src/`.

- Run: `python3 -m http.server 5178` (also in `.claude/launch.json`), open http://localhost:5178. `?debug` opens the tuning panel, `?main` runs without the worker.
- The physics is the Rust crate in `core/` (`cargo test` there); its defaults are `core/params.json`. After changing `core/`, run `tools/build-core.sh` (prints only errors) and commit the rebuilt `src/sand_core.wasm`, so the static server keeps working without a build step.
- Compare: `node tools/compare/run.mjs <A> <B> --seeds 1,2` runs the standard scenarios on two versions (`.` = this working tree's `core/`, built for wasm; or any git ref: its JS physics before that was deleted, else its committed wasm), prints a few numbers per phase and writes one side-by-side PNG to `tools/compare/out/`. The same seed number gives the same starting picture in both.

## Native apps

Work on the shared core, iPhone, iPhone Duo and Vision Pro follows `docs/native-plan.md` (architecture, phases, platform constraints). Read it before starting a phase; update it when a decision changes.

- `tools/build-apple.sh`: core → `apple/SandKit/SandCore.xcframework` (not committed; skips if `core/` is unchanged). Run it once after a clone, before opening Xcode.
- `tools/build-ios.sh [Debug|Release]`: core, `xcodegen` (`apple/project.yml`; the `.xcodeproj` isn't committed), simulator build; prints errors, then the `.app` path.
- `swift test` in `apple/SandKit`: native core vs the web's hashes (update them from `run.mjs` after a physics change), plus the Metal kernel's output for `tools/compare/kernel.html` (open it from the static server; should be within 1/255).
- Simulator: `xcrun simctl install booted <app>`, `xcrun simctl launch booted art.sand.SandArt -flipEvery 5 -paletteEvery 7` (test hooks; `-sand.palette N` picks one); frame times every 2 s in `xcrun simctl spawn booted log show --info --predicate 'subsystem == "art.sand.SandArt"'`.
- iPhone Duo hooks (the simulator can't move the hinge): `-postureEvery 15 -fakeTentSensor 1` cycles open / tent / shut, `-fakeHinge <deg>` holds one angle, `-rotateEvery <s>` turns the interface, `-openTuning 1` opens the tuning panel. The Duo simulator shows its cover display (`--display=1` for `simctl io screenshot`).

## Physics rules

- Keep the sim grounded in real physics (sand and air bubbles in slightly viscous water between glass: buoyancy, drag, surface tension). Name the physical effect before a change and keep values realistic. Never add ad-hoc rules to reproduce a target picture.
- Check every change against the standard scenarios (fresh start, a few flips), side by side with the current code. Drop anything that degrades normal behaviour.
- One small change at a time; let the user look before building on it.
- Ports (JS → Rust, GLSL → Metal) change no behaviour; they must pass the side-by-side comparison first.
