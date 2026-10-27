# Native apps plan: web + iPhone + Vision Pro

One simulation core shared by every surface; thin platform shells for input and drawing. Non-AR iPhone first, visionOS after, AR as a second generation.

## Ground rules

- **Port before you change.** Each port must match the current sim on the standard scenarios (fresh start, a few flips) side by side before anything builds on it. No physics changes ride along with a port.
- **Stay physical.** Any look or behaviour added for a platform must name the physical effect it models (see the physics notes in `CLAUDE.md`).
- **One copy of the physics.** The JS sim stays as the reference only until the Rust core passes parity, then the JS physics is deleted.

## Architecture

```
core/            Rust crate: sim, fluid, seed, engine timing; params.json, palettes.json, include/sand.h
  → wasm         web: worker.js calls it; grid memory goes straight to texSubImage2D
  → C ABI        Apple: xcframework, wrapped by SandKit
web/             today's index.html, style.css, src/ (app, render, worker, debug)
apple/
  SandKit/       Swift package: core bridge, engine thread, Metal grid→colour kernel, frame model, gravity, palettes
  SandArt/       the iPhone app's sources; project.yml (XcodeGen) → SandArt.xcodeproj, iOS now, visionOS target in Phase 4
tools/compare/   headless scenario runner: any two versions (git refs: JS physics before 1c, wasm after);
                 kernel.html: the Metal colour kernel against the WebGL shader
```

**Why Rust:** clean targets for both wasm (wasm-bindgen) and a static library for Swift; the sim is packed-integer arrays and tight loops, so it ports almost line for line. Rejected: keeping JS on Apple (an app's embedded JavaScriptCore has no JIT, so it's far too slow), a web view on visionOS (no RealityKit glass), Swift→wasm (less mature toolchain).

**Core API** (hand-written C ABI, no UniFFI, so the grid is shared without copying; `core/src/lib.rs`, prefixed `sand_`, each documented there; the C header for Apple is `core/include/sand.h`, kept in step by hand):
`new(w, h, tps, seed)`, `free`, `reseed(upsideDown)`, `tune(json, len) → values applied | -1` (the "Copy settings" shape; `render` is the host's and skipped), `frame(dt, gx, gy, maxTicks) → ticks` + `moves()`, `grid_ptr()` / `grid_width()` / `grid_height()` (RGBA8, W×H×4, layout as in `core/src/sim.rs`), `take_dirty() → first << 16 | last`, `flow() → *SandFlow` (u, v, solid pointers + nx, ny, fs), `snapshot() → len` + `snapshot_ptr()`, `restore(bytes, len) → 1 | 0`, and `alloc` / `dealloc` for hosts that have to copy bytes in (wasm).
The core has no clock: the host measures time per tick and passes `maxTicks` (on the web, `BUDGET_MS` in `src/engine.js`). In wasm, any call that allocates (`new`, `snapshot`, `restore`, `alloc`) can grow memory, so hosts renew their views of it afterwards.
Snapshots (`core/src/snapshot.rs`) hold the picture in motion: grains, liquid, awake chunks, random states and frame timing, so a restored engine carries on bit for bit. Tuning and the tick rate are host settings and stay out; a snapshot only restores onto the same grid size.

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
   - c. Port `sim.js` + `fluid.js` + `seed.js` (and `engine.js`'s frame timing) to `core/`. The port keeps the JS number model: f64 arithmetic, f32 storage for the liquid fields, Math.hypot and Math.round reproduced exactly (`core/src/jsmath.rs`). So it matches the JS bit for bit rather than statistically, and any difference in the runner is a bug, not noise. Done: `node tools/compare/run.mjs . rust` builds the core for wasm and gives identical grids; so do tilted, rotating and near-flat gravity.
1. **Web on wasm** behind `?core=wasm`; compare against JS; make it the default; delete the JS physics.
   - a. Finish the C ABI: `tune`, `flow`, `snapshot`/`restore`. Done: `run.mjs . rust --tune <json|file>` tunes both versions (then draws a new picture, so seed settings count) and gives identical grids and liquid flow fields; `cargo test` checks that a restored engine carries on bit for bit.
   - b. `?core=wasm`: `src/engine.js` is the host (renderer + time budget) over a core with the C ABI's shape: `core-js.js` (the JS physics) or `core-wasm.js` (`src/sand_core.wasm`, committed, rebuilt by `tools/build-core.sh`). The grid is uploaded with `texSubImage2D` straight from a view on wasm memory. The budget now times the whole core frame (ticks + the once-per-frame liquid step) per tick, where it used to time the sand ticks alone; at the default speed (under one tick per frame) it never binds. In the browser at 1298×940, the same seed: identical grids with no tick limit; physics ~2.9 ms per frame in wasm against ~3.4–3.8 ms in JS.
   - c. Done: wasm is the only core; `src/sim.js`, `fluid.js`, `seed.js`, `rng.js` and `core-js.js` are deleted. Defaults live in `core/params.json`: the core embeds it (`include_str!`, `cargo test` checks every setting is there and known) and the tuning panel fetches it. `tools/compare` runs a git ref's JS physics when it has `src/sim.js`, else its committed wasm; `run.mjs e8cfcb7 .` (the last JS) gives identical grids and liquid flow, tuned and untuned.
2. **iOS non-AR:** SandKit, shared RealityKit scene with a virtual camera, CoreMotion gravity and tilt-driven reflections. Done (below).
3. **iPhone Duo:** hinge, tent posture, `ArrangementView`.
4. **visionOS volume:** room lighting, transparency over passthrough, direct manipulation.
5. **Second generation** (above).

After Phase 0, phases 1 and 2 depend only on the core's C ABI and can run in parallel worktrees.

## Phase 2 as built

**Core for Apple.** `tools/build-apple.sh` builds `core/` as a static library (`cargo rustc --crate-type staticlib`, Cargo.toml untouched) for iOS, iOS simulator, visionOS, visionOS simulator and macOS (arm64 only; the app's simulator builds exclude x86_64) and packs `apple/SandKit/SandCore.xcframework` with `sand.h` and a module map (`import SandCore`). It skips the work when `core/` hasn't changed since the last pack. **Not committed:** each slice carries Rust's std, about 28 MB in all, and it would churn with every core change. So it is built, not checked in: by `tools/build-ios.sh`, and by the Xcode scheme's pre-build action. SwiftPM resolves the binary target when the project opens, so after a fresh clone run `tools/build-apple.sh` once before opening Xcode.

**Parity.** `swift test` in `apple/SandKit` (macOS host) replays the standard scenario through the C ABI (fresh start then two flips at 60 fps, as `tools/compare/job.mjs`) and checks grid and liquid-flow hashes against what `run.mjs` prints: 400×300 seed 3, 1000×725 seed 1, and a tuned run (all four groups). All match bit for bit; so does a snapshot/restore round trip. `run.mjs` now prints flow hashes too. Residual risk: `sin`, `atan2` and `powf` in the core come from the platform's libm (Rust's bundled libm in wasm, Apple's natively). They agree on these runs; if a run ever diverges, route those calls through the `libm` crate on every target (a build change, not a physics one).

**SandKit** (iOS 18 / visionOS 2 / macOS 15; Swift 5 language mode):
- `Core`: the C ABI, one owner thread. `SandEngine`: runs it on a serial queue, as the web worker does: the display asks for a frame, asks again only when it's done, carrying the time over (capped at 0.1 s); the host times ticks and allows `floor(11 ms / per-tick)` (the web's `BUDGET_MS`). Dirty rows are copied into a shared `MTLBuffer`; a semaphore keeps that copy and the GPU's read apart (the renderer never waits: it skips a frame instead).
- `ColourKernel`: the `src/render.js` fragment shader as a Metal compute kernel (compiled from source at start, ~0.4 s), one thread per device pixel, same hash noise from WebGL-style frag coords. Writes `rgba16Float` linear colour. `KernelTests` + `tools/compare/kernel.html` render one picture in every palette both ways: every pixel within 1/255 (half-float rounding). The liquid's alpha is converted: browsers composite it over the page in sRGB, RealityKit blends linear light, so `liquidAlpha` is solved to give the web's result over the backdrop (without this Ember's near-black liquid came out mid-grey).
- `SandRenderer`: kernel → `LowLevelTexture` (one texel per device pixel of the glass, as the web canvas) + mipmaps → `TextureResource`; redraws only when rows changed, the pose changed or the look did.
- `FrameLayout` / `GridSize`: `measure()` and the grid sizing from `src/app.js` (mobile budget 520k cells, dpr capped at 3, 180 ticks/s; `timeScale` comes with the core's embedded params.json).
- `FrameModel`: wooden rails (generated grain), two 2 mm panes 3 mm apart with the sand layer between, steel posts, pins and knobs, a wooden base; the frame turns about its axle. Sand layer: unlit, untone-mapped, double-sided (seen from behind it reads upside down, as the grid isn't rewritten), shaded by `1 - 0.35|sin θ|` as the web's `--shade`. Glass: a smooth mirror at 8% opacity, which is real glass's split (≈4% reflected at each face near normal incidence, the rest passes); a transparent dielectric would have its 4% scaled down by the opacity again. Faint green for the iron in soda-lime glass.
- `MotionSource` (iOS): CoreMotion gravity projected on the screen plane (smoothed as the web's handler), and attitude. `Palette` / `Params`: `core/palettes.json` (moved out of `src/palettes.js`, which now fetches it) and `core/params.json`, symlinked into the package's resources.

**App** (`apple/SandArt`, `apple/project.yml`): portrait only for now. A `RealityView` with `.virtual` camera at the web's CSS perspective distance (4 frame heights) and the field of view that fits the toy as the web lays it out (90% width / 80% height, nudged up 0.3 b). Backdrop: an unlit plane 1.2 frame heights behind the glass, the page's radial gradient (light or dark). Light: `studio.png` (from `tools/make-studio-ibl.swift`): a dim room with a bright window behind the viewer at eye level, since a pane facing you mirrors only a patch about 10° across straight behind you; plus a directional "window" light for the wood and steel. Both turn by the inverse of the phone's turn since launch (smoothed), so the room stays put as the phone tilts. Gravity: CoreMotion, upright where there's none (simulator), then `gy *= cos θ` as the web. Tap flips; vertical drag flips by hand and settles with the swipe's speed (src/app.js). Palette picker at the bottom (remembered). Test hooks: `-flipEvery <s>`, `-paletteEvery <s>`, and `-sand.palette <n>` (any UserDefaults key works as a launch argument). Logs a frame-time line every 2 s (`log show --info --predicate 'subsystem == "art.sand.SandArt"'`).

**Verified** in the iOS 27 simulators (Apple-silicon Mac): iPhone 18 Pro, grid 428×579 at scale 2 (248k cells); sand hangs and rains down, a flip turns the frame in 3D and the hanging sand lands while the fallen sand pours; palettes change at runtime; light and dark backdrops; 60 fps, 54.0 ticks/s (= 180 × 0.3), about 1–1.7 ms per core frame. iPhone Duo (unfolded, 466×678 pt): launches, grid 490×663, 60 fps. First launch on a fresh simulator spends ~20 s compiling shaders; warm launches show the first frame in about a second. The SandKit package also builds for visionOS and the app for an iOS device (unsigned).

**Not verified / deferred:**
- Touch: the simulator panel's access grant was pending, so tap, drag-flip and the picker's tap were not driven by touch; the hooks run the same `flip()` / `setPalette` paths.
- Motion: no sensor in the simulator, so gravity from tilt and the turning reflections are untested; check on a device (axis signs follow CoreMotion's documented frame).
- A device run (needs a development team in Xcode), device frame times.
- Not ported yet: turning the frame by dragging around (web), new sand (R), the hint, the tuning panel and flow overlay, landscape.
- RealityKit logs "EnvironmentResource with no skybox texture is no longer supported. Please use ImageBasedLightResource instead" even with `skyboxMode: .preserve`; `ImageBasedLightResource` isn't public in the iOS 27.1 SDK. The light works.
- Glitter twinkle and air rims still come from the shader's `uGlint`/`uRim` (as the web), not real lighting.

## Phase 4 as built

**Target.** `SandArtVision` in `apple/project.yml` (visionOS 26: `ManipulationComponent` needs it), sources in `apple/SandArtVision/`, scheme with the same core pre-build; `tools/build-vision.sh` builds it for the simulator. It reuses SandKit whole: `SandEngine`, `ColourKernel`, `SandRenderer` (`LowLevelTexture`), `FrameModel`, `Palette`. Shared changes are additive: `FrameModel.panes`, `SandRenderer.encodeExtra` (more GPU work on the held grid), `ColourKernel.highlights` (below).

**Volume.** One volumetric window, gravity-aligned (`.volumeWorldAlignment(.gravityAligned)`: it only turns to face you, so its down is the room's), fixed at 50 × 40 × 40 cm (`.windowResizability(.contentSize)`, sized with `PhysicalMetric`), baseplate shown. The toy stands on the volume's floor: glass 33.5 × 24.3 cm (the web's landscape aspect, 1.38), toy 40.0 × 31.7 cm, as a real sand picture; the depth leaves room for the frame's 14 cm sweep about its axle. Moving it around the room is the system's window bar.

**Grid: 838 × 607 = 509k cells, grains 0.4 mm.** Vision Pro resolves about 34 pixels per degree, about 0.36 mm at 70 cm, so a grain is about one display pixel at arm's length; finer grains would cost more and show nothing. 509k is the web's touch-screen budget (520k); the web runs 1.7M on a desktop, so the M-series chip has room to spare (the simulator measured 1.3–2 ms per core frame, ~3 ms per tick, at 54 ticks/s). The colour texture has 2 texels per grain (1676 × 1214), so a grain keeps a crisp edge up close (two display pixels at 35 cm). GPU memory: colour (rgba16Float + mips) ~22 MB, the three surface maps (rgba8 + mips) ~33 MB.

**Light.** No bundled light and no IBL: the system lights the volume from the real room. Wood and steel are FrameModel's PBR materials. The sand layer becomes a lit PBR surface (roughness 0.9) in place of the iPhone's unlit one, so it darkens as it turns from the light (the web's `--shade`, done by real light) and dims in a dim room. It's a two-faced mesh (back face with its own normal, texture mirrored, as the back of a real layer reads), so it is lit correctly seen from either side. The base texture's alpha keeps the liquid see-through: the room shows through the clear liquid, tinted by the palette. The liquid-alpha conversion (Phase 2) assumes a backdrop of 0.5 sRGB, a typical lit room. Wood and steel cast grounding shadows; glass and sand don't.

**Glass** (`VolumeLook.glassMaterial`). A pane mirrors ~8% near normal incidence (4% at each face, n = 1.52), rising towards 100% at grazing angles (Fresnel); ~1% is absorbed; the rest passes. RealityKit's PBR scales reflection by opacity, so a clear pane came out almost unreflective (the iPhone works around it with a constant 8% mirror, with no Fresnel). Here the pane is a ShaderGraph material, a hand-written USDA (the RealityKit PBR surface node) loaded from memory with `ShaderGraphMaterial(named:from: Data)`: metallic with F0 = 0.08 (Schlick, so it rises with angle), `hasPremultipliedAlpha` so the reflection is added in full and the opacity (0.09) only dims what's behind: out = reflection + 0.91 × room. The F0 is very slightly green (0.077, 0.081, 0.079): the back face's share has crossed the glass twice (iron in soda-lime glass). Checked: face-on the panes are barely visible; with the toy turned 55° the room's bright wall shows as a clear sheen over what's behind. Not done: per-channel tint of the light passing through (premultiplied blending has one opacity), and a green edge mesh: as in a real frame, the pane edges sit inside the rails, so none is visible. No refraction (as planned).

**Gravity.** Each frame: `frame.convert(direction: [0, -1, 0], from: nil)` (the volume's down in the turning frame's axes) → grid (x, −y); the part into the glass is dropped. This covers the flip, the toy picked up and tilted, and any volume orientation. Checked with the log line: θ 121° → g = (0, −0.51) = cos 121°; frame near flat (θ 88°) → (0, 0.04); toy rolled 25° → (−0.42, 0.91), and the sand runs to the lower side.

**Interaction.** Pinch-drag on the frame (`DragGesture().targetedToAnyEntity()`, frame collision shapes): the frame follows the pinch's angle about the axle (in the y-z plane, ignored within 2 cm of the axle), and on release settles on the nearer side carried by the swing's speed (src/app.js's rule: `round((θ + 0.18 v) / 180) × 180`, eased). A pinch without moving flips, as a tap. Pinch the stand (base, posts): `ManipulationComponent` on the whole toy, real size kept (`scalingBehavior .none`): pick it up, turn and tilt it in your hand while the sand follows the real down; let go and it goes back to its place (`releaseBehavior .reset`, as setting it down). Collision for that is boxes around the stand's parts only, so pinching the frame stays a spin. Ornament below the volume: palette swatches and a flip button.

**Glitter and air rims from real light** (`SurfaceKernel`, visionOS only). A second compute kernel writes normal, metallic and roughness maps beside the colour, redrawn only when the grid changes; the sand material uses them. `ColourKernel.highlights` (1 by default, as the web) is set to 0 on visionOS, so the painted `uGlint` twinkle and `uRim` mix are off. At 1 the kernel's output is byte-identical to before for every palette (compared against the previous commit's `KernelTests` output); `swift test` passes.
- Glitter: metal flakes (metallic 1, roughness 0.12, the palette's glitter colour as their reflectance), each tilted up to 40° in its own direction, chosen from its shade byte, which travels with the grain. They flash when a bright part of the room lines up with your eye; RealityKit renders each eye separately, so each eye sees its own flashes. Checked: same seed, toy at 20° and 30°: more of the boundary flakes flash at 30° (the simulator's screenshots are too coarse to follow single flakes).
- Air pockets: water wets the glass, so a pocket's edge is a curved meniscus. Its normal leans away from the pocket by the slope of the air fraction (3 × 3 counts, central differences, slope up to ~63°). Past the critical angle for water to air (48.8°) light is totally internally reflected: there the surface is a mirror (metallic, a smoothstep on the slope); elsewhere it's a smooth water surface (roughness 0.06). Thin air films read as bright seams; the runs had few large pockets, so pocket rims are barely tested.
- The maps are rgba8 with the value in every channel, as I couldn't confirm which channel RealityKit samples for metallic and roughness. Single-channel maps would save ~25 MB if a test confirms it.

**Texture pacing.** RealityKit renders in another process; `LowLevelTexture.replace` waits while that renderer still holds older copies. While other sessions' simulators and builds loaded the Mac (load average ~900), it logged "Hang detected while waiting for renderer to free resources" and frames took up to 0.8 s. The controller times each redraw; if one waited (> 8 ms), it skips redraws for as long. Changed rows stay pending, so no sand is lost. The log line counts the waits.

**Test hooks** (launch arguments): `-flipEvery`, `-paletteEvery`, `-sand.palette` as on the iPhone; `-dragFlipEvery <s>`: a pretend pinch on the top rail, swung 110° in 0.35 s and released, through the gesture's own `spinChanged`/`spinEnded`; `-holdTilt <deg>` / `-holdTurn <deg>`: the toy held rolled / turned; `-seed <n>`. The log line every 2 s adds θ, the gravity sent to the core and the texture waits.

**Verified** in the visionOS 27.0 simulator (Apple Vision Pro, Apple-silicon Mac): builds and launches into the volume on the simulated room's table; sand hangs, rains and builds a landscape below; the clear liquid shows the room (the TV and its stand) through it; flips (button path) turn the frame in 3D, the hanging sand lands and the rest pours, gravity follows cos θ; the pretend pinch-swing settles correctly (released at −110° at −190°/s → 180; from 180 to 70° → 0); tilting moves the sand sideways; palettes change at runtime; Fresnel sheen at a shallow angle; glitter lit by the room. Idle Mac: 120 fps (the simulator's rate), 54.0 ticks/s, 1.3–2 ms per core frame; first frame in ~4 s on a warm launch (the glass shader graph compiles at start), ~50 s under the heavy load. `swift test` passes (core parity bit for bit; kernel byte-identical at `highlights` 1); the iPhone app still builds.

**Not verified / a headset must confirm:**
- Real input: no simulator input access (the user was away), so pinch-drag on the frame, the pinch-to-flip, ManipulationComponent pick-up and the ornament's buttons were not driven by hand. The hooks run the same code paths, except the SwiftUI gesture's hit-testing and `convert` into the axle's space. On a device, check that the frame pinch and the stand manipulation don't both fire (hits on the frame shouldn't reach the stand's `ManipulationComponent`; if they do, give the frame `ManipulationComponent.HitTarget` or move the stand into its own entity).
- Real room lighting and passthrough: the simulator's room stands in. Check that the panes reflect real light at believable levels (barely visible face-on, a clear sheen at a shallow angle), that the liquid's tint over real backgrounds matches the web's look (`backdrop` 0.5), and the sand's brightness in dim and bright rooms.
- Glitter: per-eye flashes and how they twinkle as your head moves. Air-pocket rims on a picture with big pockets (after several flips).
- Frame times, thermals and memory on the device, and whether `replace` ever waits there (the log counts it). Volume clipping while the toy is held outside its volume.
- Whether the volume keeps its true size as you move away (volumes default to fixed scale; `.defaultWorldScaling` would set it explicitly).

## Working in Claude Code

- Fresh session per phase or sub-step, briefed from this file. Don't extend one long thread.
- Scripts print summaries: wrap `xcodebuild` / `cargo` in `tools/*.sh` that show only errors; the parity runner prints numbers plus one composite image.
- Cheapest check first: headless scenario runs → simulator → device (only for hinge angle and motion-sensor placement).
- Prefer page text and console output to screenshots; screenshot only when the visual result is what's being checked.
