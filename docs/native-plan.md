# Native apps plan: web + iPhone + Vision Pro

One simulation core shared by every surface; thin platform shells for input and drawing. Non-AR iPhone first, visionOS after, AR as a second generation.

## Ground rules

- **Port before you change.** Each port must match the current sim on the standard scenarios (fresh start, a few flips) side by side before anything builds on it. No physics changes ride along with a port.
- **Stay physical.** Any look or behaviour added for a platform must name the physical effect it models (see the physics notes in `CLAUDE.md`).
- **One copy of the physics.** The JS sim stays as the reference only until the Rust core passes parity, then the JS physics is deleted.

## Architecture

```
core/            Rust crate: sim, fluid, seed, engine timing; params.json, palettes.json
  → wasm         web: worker.js calls it; grid memory goes straight to texSubImage2D
  → C ABI        Apple: xcframework, wrapped by SandKit
web/             today's index.html, style.css, src/ (app, render, worker, debug)
apple/
  SandKit/       Swift package: core bridge, Metal grid→colour kernel, gravity, palettes
  SandArt        one multiplatform Xcode project: iOS + visionOS targets
tools/compare/   headless scenario runner: JS reference vs Rust core
```

**Why Rust:** clean targets for both wasm (wasm-bindgen) and a static library for Swift; the sim is packed-integer arrays and tight loops, so it ports almost line for line. Rejected: keeping JS on Apple (an app's embedded JavaScriptCore has no JIT, so it's far too slow), a web view on visionOS (no RealityKit glass), Swift→wasm (less mature toolchain).

**Core API** (hand-written C ABI, about 8 functions, no UniFFI, so the grid is shared without copying):
`new(w, h, tps, seed)`, `reseed(upsideDown)`, `tune(json)`, `frame(dt, gx, gy, maxTicks) → stats`, `grid_ptr()` (RGBA8, W×H×4, layout as in `src/sim.js`), `take_dirty() → row range`, `flow()`, `snapshot()` / `restore()`.
The core has no clock: the host measures time per tick and passes `maxTicks` (today's `BUDGET_MS` logic in `src/engine.js` moves to the hosts).

**Shared:** all physics and its parameters (`params.json` is the single source for the core, the web tuning panel and a Swift tuning view, in the same JSON shape "Copy settings" produces), palettes, seeding, tick timing, snapshot format.
**Per platform:** input → gravity, and rendering. The grid→colour shader is about 60 lines and gets hand-ported to Metal; on Apple, glint and air-rim highlights come from real lighting rather than the `uGlint`/`uRim` uniforms.

**Gravity:** every platform projects its own "down" onto the glass plane and calls `frame(dt, gx, gy)` (grid space, x right, y down, |g| = 1 upright). Web: DeviceOrientation (as now). iOS: CoreMotion `gravity`. visionOS: world down turned into the frame entity's local space. A frame lying flat gives |g| → 0, which the sim already handles (it does nothing below 0.03); the component pressing sand against the back pane is ignored.

**Build step:** the web loses "no build step". The built `.wasm` is committed so `python3 -m http.server` still works.

## Platform notes

### iPhone, non-AR (first)

- `RealityView` with a virtual camera (non-AR, iOS 18+): same scene, materials and Metal kernel as visionOS; only the camera differs.
- Behind the glass: an app-provided backdrop (softly lit wall, a blurred library photo, or plain light/dark). Sand layer and backdrop sit at different depths, so the clear liquid reads as see-through.
- Panes reflect a bundled image-based light; CoreMotion attitude turns the reflections as the phone tilts, like a real frame in hand. Same sensor data as gravity.
- Tap / swipe flips the frame on its stand, as on the web.

### iPhone Duo (iOS 27.1)

APIs (secondhand sources; check Apple's docs for exact signatures): `onHingeChange { old, new in }` → `DeviceHingeContext.hinge?` with `angle: Angle` (180° flat) and `status` (`.closed`, `.partiallyOpen`, `.fullyOpen`); `nil` on devices without a hinge. Apple: use it for effects, not layout; the update rate is system policy, so smooth it. UIKit: `UIHingeInteraction`. Layout: `ArrangementView` (`.split` / `.overlay`), `GeometryProxy.reservedRegions(kind: .division)` for the fold.

- **Tent posture:** upright half is the picture (landscape, like the web layout), flat half is the wooden base with palette and flip controls. Gravity for the upright half = the motion-sensor reading turned by the hinge angle. Which half holds the motion sensor must be checked on a real device.
- **Fold / unfold:** one fixed grid per frame that refits to each display; never resize or reseed. A real frame keeps its shape.
- **Unfolded:** tuning panel beside the picture via `ArrangementView`.

### Vision Pro

- Volumetric window with a `RealityView`: wooden stand, two glass panes, the sand layer between them.
- **No refraction in RealityKit** (Apple engineer: "our rendering pipeline doesn't currently support refraction", developer forums thread 831762), and apps can't read the passthrough camera. Flat parallel panes barely refract in real life anyway. Realism comes from transparency (real room visible through the clear liquid), reflections lit by the real room (stronger at shallow angles), and a green-tinted edge mesh.
- Sand layer: sim on a background thread → dirty rows → Metal compute kernel → colour + mipmaps in a `LowLevelTexture` → ShaderGraph material. Liquid keeps low alpha.
- Physical touches: normals from the air/liquid boundary so bubble edges reflect the room; glitter sparkles by the real view direction, separately per eye.
- Interaction: pinch-drag spins the frame about its stand pivot; two hands pick up the whole frame. Gravity follows the real 3D orientation.
- Rejected for now: CompositorServices (full Metal) only works in an immersive space, still can't read passthrough, and loses RealityKit's room lighting.

### Second generation

AR on iPhone (place on a table; fake refraction by sampling the camera feed, which iOS allows), visionOS mixed immersive "place on table", handoff of a picture mid-pour between devices via `snapshot`/`restore`.

## Phases

0. **Parity harness, then Rust port.**
   - a. Seeded PRNG in `src/seed.js` instead of `Math.random`, so both versions start from the same picture (this alone must not change behaviour).
   - b. `tools/compare/`: headless runner for the standard scenarios that prints a few numbers per scenario (moves per tick, sand still hanging, pour count, how evenly the colour bands drain) and writes one side-by-side image per run. `sim.js`, `fluid.js` and `seed.js` already run in Node with no browser (about 3.5 ms per frame at 1000×725, 2 ticks plus fluid).
   - c. Port `sim.js` + `fluid.js` + `seed.js` to `core/`. Expect statistical agreement, not bit-exact: JS does float maths in 64-bit, the port in 32-bit.
1. **Web on wasm** behind `?core=wasm`; compare against JS; make it the default; delete the JS physics.
2. **iOS non-AR:** SandKit, shared RealityKit scene with a virtual camera, CoreMotion gravity and tilt-driven reflections.
3. **iPhone Duo:** hinge, tent posture, `ArrangementView`.
4. **visionOS volume:** room lighting, transparency over passthrough, direct manipulation.
5. **Second generation** (above).

After Phase 0, phases 1 and 2 depend only on the core's C ABI and can run in parallel worktrees.

## Working in Claude Code

- Fresh session per phase or sub-step, briefed from this file. Don't extend one long thread.
- Scripts print summaries: wrap `xcodebuild` / `cargo` in `tools/*.sh` that show only errors; the parity runner prints numbers plus one composite image.
- Cheapest check first: headless scenario runs → simulator → device (only for hinge angle and motion-sensor placement).
- Prefer page text and console output to screenshots; screenshot only when the visual result is what's being checked.
