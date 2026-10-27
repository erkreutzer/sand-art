import Metal
import os
import RealityKit
import SandKit
import SwiftUI
import UIKit

/// The Vision Pro scene: the sand picture on its stand at a real sand
/// picture's size, standing on the floor of the volume and lit by the room
/// (the system's lighting, from the real surroundings; no bundled light).
/// The clear liquid lets the room show through; the panes mirror it as real
/// glass does. Gravity is the room's down in the frame's own axes, so the sand
/// falls true whichever way the frame is turned or held. Flip timing follows
/// src/app.js, as the iPhone app does.
@MainActor
final class VolumeController {
    /// The volume, metres: room for the toy (about 40 x 32 cm) and for the
    /// frame's sweep as it turns on its axle (14 cm each way).
    static let volumeSize = SIMD3<Double>(0.5, 0.4, 0.4)

    /// The glass, metres: 33.5 x 24.3 cm (the web's landscape aspect, 1.38),
    /// so the whole toy is about 40 cm wide, as a real sand picture.
    static let glassHeight = 0.243
    static let glassAspect = 1.38
    /// One grain: 0.4 mm. The headset shows about one pixel per 0.36 mm at
    /// 70 cm, so a grain is about a display pixel at arm's length; finer adds
    /// cost and no visible detail. The grid comes to 838 x 607 = 509k cells,
    /// the web's touch-screen budget (520k), well inside the M-series budget
    /// (the web runs 1.7M on a desktop).
    static let grain = 0.0004
    /// Texels per grain, so a grain keeps a crisp edge up close (at 35 cm it
    /// covers two display pixels).
    static let texelsPerGrain = 2

    let w: Int, h: Int
    let engine: SandEngine
    let renderer: SandRenderer
    let surface: SurfaceKernel
    let model: FrameModel
    /// What you pick up: the whole toy, its origin at the axle.
    let holder = Entity()
    /// Positions for the spin gesture are taken in this space (the axle's).
    var axleSpace: Entity { model.root }

    private var subscription: EventSubscription?
    private let log = Logger(subsystem: "art.sand.SandArt", category: "vision")

    // Flip about the stand's axle, degrees, as theta in src/app.js.
    private(set) var theta = 0.0
    private var anim: (from: Double, to: Double, t0: Double, dur: Double)?
    private var lastPose = Double.nan
    private var gravity = SIMD2<Double>(0, 1)

    // Test hooks (launch arguments), for the simulator, where nothing pinches.
    private let flipEvery = UserDefaults.standard.double(forKey: "flipEvery")
    private lazy var lastAutoFlip = CACurrentMediaTime()
    private let paletteEvery = UserDefaults.standard.double(forKey: "paletteEvery")
    private lazy var lastAutoPalette = CACurrentMediaTime()
    private let dragFlipEvery = UserDefaults.standard.double(forKey: "dragFlipEvery")
    private lazy var lastAutoDrag = CACurrentMediaTime()
    private var autoDrag: (t0: Double, a0: Double)? // a pretend pinch-drag: start time, angle
    private let holdTilt = UserDefaults.standard.double(forKey: "holdTilt")
    private let holdTurn = UserDefaults.standard.double(forKey: "holdTurn")

    // The renderer runs in another process; replacing the sand textures
    // waits while it still holds older copies. If a redraw had to wait, the
    // next ones are skipped for as long (changed rows stay pending).
    private var drawHold = 0.0, drawWaits = 0

    private var logT0 = CACurrentMediaTime(), logFrames = 0, logMaxDt = 0.0
    private var logEngine = SandEngine.Stats()

    static func make() -> VolumeController? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? VolumeController(device: device)
    }

    init(device: MTLDevice) throws {
        let t0 = CACurrentMediaTime()
        h = Int((Self.glassHeight / Self.grain).rounded(.down))
        w = Int((Self.glassHeight * Self.glassAspect / Self.grain).rounded(.down))
        // `-seed <n>`: the same starting picture every launch.
        let seed = UserDefaults.standard.integer(forKey: "seed")
        engine = SandEngine(device: device, w: w, h: h, seed: seed > 0 ? UInt32(seed) : .random(in: 0 ... .max))
        let t1 = CACurrentMediaTime()
        renderer = try SandRenderer(engine: engine, device: device, scale: Self.texelsPerGrain)
        // Typical brightness of a lit room seen through the glass, for the
        // liquid's tint (see ColourKernel.backdrop).
        renderer.backdrop = 0.5
        // Glitter and air rims come from the room's light (SurfaceKernel).
        renderer.kernel.highlights = 0
        surface = try SurfaceKernel(device: device, w: w, h: h, W: engine.W, scale: Self.texelsPerGrain)
        renderer.encodeExtra = { [surface] cb, grid, changed in surface.encode(cb, grid: grid, gridChanged: changed) }
        let t2 = CACurrentMediaTime()
        model = FrameModel(gridAspect: Double(w) / Double(h), sandTexture: renderer.resource,
                           glassHeight: Double(h) * Self.grain)
        let L = model.layout
        note(String(format: "[sand] grid %dx%d (%d cells), %d texels per grain; glass %.1f x %.1f cm, toy %.1f x %.1f cm; engine %.0f ms, renderer %.0f ms",
                    w, h, w * h, Self.texelsPerGrain, L.iw * 100, L.ih * 100, L.tw * 100, L.th * 100,
                    (t1 - t0) * 1000, (t2 - t1) * 1000))
    }

    /// Builds the scene into the volume and starts the loop.
    func install(in content: inout RealityViewContent) async {
        let t0 = CACurrentMediaTime()
        let L = model.layout
        // The base stands on the volume's floor.
        holder.position = [0, Float(-Self.volumeSize.y / 2 + L.fh / 2 + L.gap + L.baseh), 0]
        holder.addChild(model.root)
        content.add(holder)

        await VolumeLook.apply(to: model, sandTexture: renderer.resource, surface: surface)
        setUpInput()
        if holdTilt != 0 || holdTurn != 0 {
            // As if held in the hand: turned about the vertical, then rolled
            // about the line of sight.
            holder.orientation = simd_quatf(angle: Float(holdTurn * .pi / 180), axis: [0, 1, 0])
                * simd_quatf(angle: Float(holdTilt * .pi / 180), axis: [0, 0, 1])
        }
        note(String(format: "[sand] scene built in %.0f ms", (CACurrentMediaTime() - t0) * 1000))

        setPalette(currentPalette)
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            self?.tick(dt: e.deltaTime)
        }
    }

    /// Pinch the frame to turn it (VolumeView's gesture); pinch the stand to
    /// pick up the whole toy, turn and tilt it in your hand (the sand follows
    /// the real down), and let go to set it back in its place. It keeps its
    /// real size.
    private func setUpInput() {
        model.frame.generateCollisionShapes(recursive: true)
        model.frame.components.set(InputTargetComponent())
        model.frame.components.set(HoverEffectComponent())

        let stand = model.root.children.filter { $0 !== model.frame }
        let shapes = stand.map { e -> ShapeResource in
            let b = e.visualBounds(relativeTo: holder)
            return ShapeResource.generateBox(size: b.extents).offsetBy(translation: b.center)
        }
        ManipulationComponent.configureEntity(holder, hoverEffect: .spotlight(.default), collisionShapes: shapes)
        var m = holder.components[ManipulationComponent.self] ?? ManipulationComponent()
        m.releaseBehavior = .reset
        m.dynamics.scalingBehavior = .none
        holder.components.set(m)
    }

    func isOnFrame(_ e: Entity) -> Bool {
        var p: Entity? = e
        while let q = p {
            if q === model.frame { return true }
            p = q.parent
        }
        return false
    }

    // ---------- palette ----------

    var paletteIndex: Int = min(Palette.all.count - 1, max(0, UserDefaults.standard.integer(forKey: "sand.palette")))
    var currentPalette: Palette { Palette.all[paletteIndex] }

    func setPalette(_ p: Palette) {
        paletteIndex = Palette.all.firstIndex(of: p) ?? 0
        UserDefaults.standard.set(paletteIndex, forKey: "sand.palette")
        renderer.setPalette(p)
    }

    // ---------- flipping (src/app.js) ----------

    private static func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    func animate(to: Double, dur: Double) {
        anim = (theta, to, CACurrentMediaTime(), dur / 1000)
    }

    func flip() {
        let base = anim?.to ?? (theta / 180).rounded() * 180
        animate(to: base - 180, dur: 1150)
        note("[sand] flip to \(Int(base - 180))")
    }

    /// The pinch's angle about the axle (in the frame's turning plane, y-z)
    /// is followed directly, so the frame turns with the hand. Close to the
    /// axle the angle means little and is held.
    private var spin: (theta0: Double, angle: Double, lastT: Double, vel: Double, p0: SIMD3<Float>, travel: Float)?

    func spinChanged(at p: SIMD3<Float>) {
        let now = CACurrentMediaTime()
        let a = atan2(Double(p.z), Double(p.y)) * 180 / .pi
        guard var s = spin else {
            anim = nil
            spin = (theta, a, now, 0, p, 0)
            return
        }
        s.travel = max(s.travel, simd_distance(p, s.p0))
        if hypot(Double(p.y), Double(p.z)) > 0.02 {
            var da = a - s.angle
            da -= (da / 360).rounded() * 360
            theta += da
            let dt = now - s.lastT
            if dt > 0 { s.vel = s.vel * 0.6 + da / dt * 0.4 }
            s.angle = a
            s.lastT = now
        }
        spin = s
    }

    func spinEnded() {
        guard let s = spin else { return }
        spin = nil
        if s.travel < 0.01, abs(theta - s.theta0) < 3 {
            theta = s.theta0
            flip()
            return
        }
        let target = ((theta + s.vel * 0.18) / 180).rounded() * 180
        animate(to: target, dur: min(900, 250 + abs(target - theta) * 4))
        note(String(format: "[sand] released at %.0f°, %.0f°/s, settling to %.0f", theta, s.vel, target))
    }

    /// New sand at the top as you see it, whichever way up the frame is.
    func reseed() { engine.reseed(upsideDown: cos(theta * .pi / 180) < 0) }

    // ---------- per frame ----------

    private func tick(dt rawDt: Double) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, rawDt)
        runTestHooks(now: now)
        if let a = anim {
            let p = min(1, (now - a.t0) / a.dur)
            theta = a.from + (a.to - a.from) * Self.ease(p)
            if p >= 1 {
                theta = Double(((Int(a.to.rounded()) % 360) + 360) % 360)
                anim = nil
            }
        }
        let poseChanged = theta != lastPose
        if poseChanged {
            lastPose = theta
            model.frame.orientation = simd_quatf(angle: Float(theta * .pi / 180), axis: [1, 0, 0])
        }

        // Gravity: the room's down in the frame's axes (x right, y up, z out
        // of the front pane), onto the glass: grid x right, y down, |g| = 1
        // upright. The part pressing the sand against a pane is left out, and
        // a frame lying flat gives |g| -> 0, as on a phone.
        let down = model.frame.convert(direction: [0, -1, 0], from: nil)
        gravity = [Double(down.x), Double(-down.y)]
        engine.requestFrame(dt: dt, gx: gravity.x, gy: gravity.y)

        // The sand's look no longer depends on the pose: the room lights it.
        if now >= drawHold {
            let t = CACurrentMediaTime()
            renderer.draw(glint: 0, poseChanged: false)
            let waited = CACurrentMediaTime() - t
            if waited > 0.008 {
                drawHold = CACurrentMediaTime() + waited
                drawWaits += 1
            }
        }
        logFrame(dt: rawDt)
    }

    /// `-flipEvery <s>` flips and `-paletteEvery <s>` steps the palette, as
    /// the ornament's buttons do; `-dragFlipEvery <s>` swings the frame by a
    /// pretend pinch on its top rail (through the gesture's own handlers);
    /// `-holdTilt <deg>` holds the toy rolled and `-holdTurn <deg>` turned
    /// about the vertical, as in the hand.
    private func runTestHooks(now: Double) {
        if flipEvery > 0, now - lastAutoFlip >= flipEvery {
            lastAutoFlip = now
            flip()
        }
        if paletteEvery > 0, now - lastAutoPalette >= paletteEvery {
            lastAutoPalette = now
            setPalette(Palette.all[(paletteIndex + 1) % Palette.all.count])
            note("[sand] palette \(currentPalette.name)")
        }
        if dragFlipEvery > 0, autoDrag == nil, now - lastAutoDrag >= dragFlipEvery {
            // The top rail's angle about the axle, in the axle's space.
            autoDrag = (now, atan2(0.01, model.layout.fh / 2) + theta * .pi / 180)
            note("[sand] pretend pinch on the top rail")
        }
        if let (t0, a0) = autoDrag {
            // Push the top rail away through 110° in 0.35 s, then let go.
            let r = Float(model.layout.fh / 2), t = now - t0
            let a = a0 - min(1, t / 0.35) * 110 * .pi / 180
            spinChanged(at: [0, r * Float(cos(a)), r * Float(sin(a))])
            if t >= 0.35 {
                spinEnded()
                autoDrag = nil
                lastAutoDrag = now
            }
        }
    }

    private func logFrame(dt: Double) {
        logFrames += 1
        logMaxDt = max(logMaxDt, dt)
        let now = CACurrentMediaTime()
        guard now - logT0 >= 2 else { return }
        let s = engine.stats, secs = now - logT0
        let frames = s.frames - logEngine.frames, ticks = s.totalTicks - logEngine.totalTicks
        let line = String(format: "[sand] %.1f fps (worst %.1f ms); core %.1f frames/s, %.1f ticks/s, %.2f ms per core frame, %.3f ms/tick, %d moves; theta %.0f, g (%.2f, %.2f); %d texture waits",
                          Double(logFrames) / secs, logMaxDt * 1000, Double(frames) / secs, Double(ticks) / secs,
                          frames > 0 ? (s.totalCoreMs - logEngine.totalCoreMs) / Double(frames) : 0, s.perTickMs, s.moves,
                          theta, gravity.x, gravity.y, drawWaits)
        note(line)
        logT0 = now
        logFrames = 0
        logMaxDt = 0
        logEngine = s
        drawWaits = 0
    }

    /// To stdout and the unified log (`log show --info`), for checking timing.
    private func note(_ line: String) {
        print(line)
        log.notice("\(line, privacy: .public)")
    }
}
