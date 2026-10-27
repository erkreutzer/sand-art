import Metal
import os
import RealityKit
import SandKit
import SwiftUI
import UIKit

/// The iPhone scene: the frame on its stand seen by a virtual camera, an
/// app-provided backdrop behind the glass, a bundled image-based light the
/// glass reflects (turned as the phone tilts), and the engine fed with the
/// phone's gravity. Flip logic and timing follow src/app.js.
///
/// One grid for the life of the app, like one real frame: a rotation, a fold
/// or a panel opening beside it only refits the same frame to the view it is
/// shown in (`resize`), never resizes or reseeds it. A view that is rebuilt
/// (a posture change moves the picture to another place in the layout) gets
/// the same scene installed again.
@MainActor
final class SceneController {
    let grid: GridSize
    /// Glass width / height, fixed with the grid.
    let gridAspect: Double
    let engine: SandEngine
    let renderer: SandRenderer
    let model: FrameModel
    let motion = MotionSource()
    /// The glass's layout in points in the current view, for turning drags
    /// into flip angles.
    private(set) var screenLayout: FrameLayout
    private(set) var viewSize: CGSize

    /// Holds everything the RealityView shows. Each install gets a fresh one
    /// and the scene moves into it: the view being replaced removes its own
    /// holder when it goes, which must not take the scene with it.
    private var world = Entity()
    private var built = false
    private let root = Entity()
    private let light = Entity()
    private let camera = Entity()
    private let backdrop = ModelEntity()
    private var subscription: EventSubscription?
    private let log = Logger(subsystem: "art.sand.SandArt", category: "frame")

    // Flip about the stand's axle, degrees, as theta in src/app.js.
    private(set) var theta = 0.0
    // The whole toy turned in the picture plane by a hand, degrees clockwise
    // as seen, as phi in src/app.js; let go, it rocks back upright.
    private(set) var phi = 0.0
    private var turn: (phi0: Double, a0: Double)?
    private var lastPhi = Double.nan
    /// `-holdTurn <deg>`: a pretend hand holds the toy turned (a test hook,
    /// through the drag's own handlers; the simulator can't touch).
    private let holdTurn = UserDefaults.standard.double(forKey: "holdTurn")
    private var anim: (from: Double, to: Double, t0: Double, dur: Double)?
    private var lastPose = Double.nan
    private var start = CACurrentMediaTime()
    private var attitude0: simd_quatd?
    private var envTurn = simd_quatf(angle: 0, axis: [0, 1, 0])
    private let flipEvery = UserDefaults.standard.double(forKey: "flipEvery")
    private lazy var lastAutoFlip = CACurrentMediaTime()
    private let paletteEvery = UserDefaults.standard.double(forKey: "paletteEvery")
    private lazy var lastAutoPalette = CACurrentMediaTime()

    // ---------- gravity on a foldable ----------

    /// Set by the view: the interface's rotation from the device's portrait,
    /// degrees (MotionSource.screenAngle).
    var screenAngle = 0.0 {
        didSet { motion.screenAngle = screenAngle }
    }
    /// The hinge angle while the phone stands as a tent (degrees, 180 flat),
    /// nil otherwise. The upright half's gravity is the sensor's reading turned
    /// by it (TentGravity); the angle is smoothed, as hinge updates come at a
    /// rate that is system policy.
    var tentHinge: Double?
    private var hinge = HingeSmoother()
    /// Test hook (`-fakeTentSensor 1`, with a faked hinge): no sensor in the
    /// simulator, so read what a sensor in the flat half of a tent would, and
    /// turn the interface as that tent would be turned.
    private let fakeTentSensor = UserDefaults.standard.bool(forKey: "fakeTentSensor")
    /// Gravity last sent to the core (grid space), for the log.
    private var lastG = SIMD2<Double>(0, 1)
    /// Tuning panel's pause.
    var paused = false

    // Frame-time log: render frames and core time over the last couple of seconds.
    private var logT0 = CACurrentMediaTime(), logFrames = 0, logMaxDt = 0.0
    private var logEngine = SandEngine.Stats()

    /// aspect: the glass's width / height; nil takes it from the view's shape
    /// as the web does.
    init(viewSize: CGSize, pixelsPerPoint: Double, aspect: Double? = nil) throws {
        let t0 = CACurrentMediaTime()
        let vw = Double(viewSize.width), vh = Double(viewSize.height)
        let a = aspect ?? FrameLayout.aspect(viewWidth: vw, viewHeight: vh)
        grid = GridSize(viewWidth: vw, viewHeight: vh, aspect: a, pixelsPerPoint: pixelsPerPoint)
        let device = MTLCreateSystemDefaultDevice()!
        engine = SandEngine(device: device, w: grid.w, h: grid.h)
        let t1 = CACurrentMediaTime()
        renderer = try SandRenderer(engine: engine, device: device, scale: grid.scale)
        let t2 = CACurrentMediaTime()
        gridAspect = Double(grid.w) / Double(grid.h)
        model = FrameModel(gridAspect: gridAspect, sandTexture: renderer.resource)
        let t3 = CACurrentMediaTime()
        self.viewSize = viewSize
        screenLayout = Self.fit(viewSize, gridAspect)
        note(String(format: "[sand] grid %dx%d scale %d (%d cells), view %.0fx%.0f pt @%.0fx; engine %.0f ms, renderer %.0f ms, model %.0f ms",
                    grid.w, grid.h, grid.scale, grid.w * grid.h, vw, vh, pixelsPerPoint, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000))
    }

    /// As layout() in src/app.js: fitted, then kept at the grid's exact aspect.
    private static func fit(_ size: CGSize, _ aspect: Double) -> FrameLayout {
        let fitted = FrameLayout.fit(viewWidth: Double(size.width), viewHeight: Double(size.height), aspect: aspect)
        return FrameLayout(iw: fitted.iw, ih: fitted.iw / aspect)
    }

    /// Builds the scene into the RealityView's content and starts the loop;
    /// a second call (a rebuilt view) moves the same scene into the new
    /// content.
    func install(in content: inout RealityViewCameraContent, viewSize: CGSize, dark: Bool) async {
        content.camera = .virtual
        content.renderingEffects.motionBlur = .disabled
        content.renderingEffects.depthOfField = .disabled
        content.renderingEffects.cameraGrain = .disabled
        if built {
            let holder = Entity()
            for e in Array(world.children) { holder.addChild(e) }
            world = holder
            content.add(world)
            resize(viewSize: viewSize)
            subscription?.cancel()
            subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] e in
                self?.tick(dt: e.deltaTime)
            }
            note(String(format: "[sand] scene installed again, view %.0fx%.0f pt", viewSize.width, viewSize.height))
            return
        }
        built = true
        let t0 = CACurrentMediaTime()
        content.add(world)

        root.addChild(model.root)
        world.addChild(root)
        self.viewSize = viewSize
        screenLayout = Self.fit(viewSize, gridAspect)
        placeCamera(viewSize: viewSize)
        world.addChild(camera)
        buildBackdrop(viewSize: viewSize, dark: dark)
        renderer.backdrop = dark ? 0.13 : 0.9
        world.addChild(backdrop)

        if let env = await Self.studioLight() {
            var ibl = ImageBasedLightComponent(source: .single(env), intensityExponent: 1.0)
            ibl.inheritsRotation = true
            light.components.set(ibl)
            receiveLight(model.root)
        }
        // Daylight from the window behind the viewer, high and to one side:
        // what mostly lights the wood and steel in a real room. It turns with
        // the room.
        let sun = DirectionalLight()
        sun.light.intensity = 2500
        sun.light.color = UIColor(red: 1, green: 0.98, blue: 0.95, alpha: 1)
        sun.look(at: [0, 0, 0], from: [-0.5, 0.6, 1.2], relativeTo: nil)
        light.addChild(sun)
        world.addChild(light)

        note(String(format: "[sand] scene built in %.0f ms", (CACurrentMediaTime() - t0) * 1000))
        setPalette(currentPalette)
        model.setPose(theta: 0)
        motion.start()
        start = CACurrentMediaTime()
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            self?.tick(dt: e.deltaTime)
        }
    }

    /// The same frame refitted to a new view size (a rotation, a fold, a
    /// panel opening beside it): camera, backdrop and drag scale follow; the
    /// grid stays as it is.
    func resize(viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let changed = viewSize != self.viewSize
        self.viewSize = viewSize
        screenLayout = Self.fit(viewSize, gridAspect)
        guard built else { return }
        placeCamera(viewSize: viewSize)
        resizeBackdrop(viewSize: viewSize)
        if changed {
            note(String(format: "[sand] refit to %.0fx%.0f pt (glass %.0fx%.0f pt), grid still %dx%d",
                        viewSize.width, viewSize.height, screenLayout.iw, screenLayout.ih, grid.w, grid.h))
        }
    }

    // ---------- palette ----------

    var paletteIndex: Int = min(Palette.all.count - 1, max(0, UserDefaults.standard.integer(forKey: "sand.palette")))
    var currentPalette: Palette { Palette.all[paletteIndex] }

    /// Tells the pickers.
    var onPalette: ((Int) -> Void)?

    func setPalette(_ p: Palette) {
        paletteIndex = Palette.all.firstIndex(of: p) ?? 0
        UserDefaults.standard.set(paletteIndex, forKey: "sand.palette")
        renderer.setPalette(p)
        onPalette?(paletteIndex)
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

    /// Drag-to-flip: the frame follows the finger; on release it settles on
    /// the nearer side, carried by the swipe's speed.
    private var drag: (theta0: Double, y0: Double, lastY: Double, lastT: Double, vel: Double)?

    func dragChanged(y: Double) {
        let now = CACurrentMediaTime()
        guard var d = drag else {
            anim = nil
            drag = (theta, y, y, now, 0)
            return
        }
        theta = d.theta0 - (y - d.y0) / screenLayout.fh * 180
        let dt = now - d.lastT
        if dt > 0 { d.vel = d.vel * 0.6 + (-(y - d.lastY) / screenLayout.fh * 180 / dt) * 0.4 }
        d.lastY = y
        d.lastT = now
        drag = d
    }

    func dragEnded() {
        guard let d = drag else { return }
        drag = nil
        let target = ((theta + d.vel * 0.18) / 180).rounded() * 180
        animate(to: target, dur: min(900, 250 + abs(target - theta) * 4))
    }

    /// Drag-to-turn: the toy follows the finger's angle about the axle
    /// (points in the picture view).
    func turnChanged(start: CGPoint, at p: CGPoint) {
        let c = axleOnScreen
        if turn == nil {
            turn = (phi, atan2(Double(start.y - c.y), Double(start.x - c.x)))
        }
        guard let t = turn else { return }
        var a = atan2(Double(p.y - c.y), Double(p.x - c.x)) - t.a0
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        phi = t.phi0 + a * 180 / .pi
    }

    func turnEnded() { turn = nil }

    /// The axle in the picture view: the camera sits `cy` above it, looking
    /// straight on, at the frame's scale.
    private var axleOnScreen: CGPoint {
        let k = model.layout.ih / screenLayout.ih // metres per point
        let cy = Double(camera.position.y)
        return CGPoint(x: viewSize.width / 2, y: viewSize.height / 2 + CGFloat(cy / k))
    }

    /// New sand at the top as you see it, whichever way up the frame is.
    func reseed() { engine.reseed(upsideDown: cos(theta * .pi / 180) < 0) }

    // ---------- per frame ----------

    private func tick(dt rawDt: Double) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, rawDt)
        if let a = anim {
            let p = min(1, (now - a.t0) / a.dur)
            theta = a.from + (a.to - a.from) * Self.ease(p)
            if p >= 1 {
                theta = Double(((Int(a.to.rounded()) % 360) + 360) % 360)
                anim = nil
            }
        }

        if holdTurn != 0 {
            let c = axleOnScreen, r = 0.3 * screenLayout.fw, a = holdTurn * .pi / 180
            turnChanged(start: CGPoint(x: c.x + r, y: c.y), at: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        } else if turn == nil {
            phi *= exp(-dt * 3.5)
            if abs(phi) < 0.01 { phi = 0 }
        }

        // Gravity in grid space: the phone's down on the screen (upright where
        // there's no sensor), turned with the toy, then by the flip.
        let g0 = screenGravity(dt: dt)
        let pr = phi * .pi / 180, tr = theta * .pi / 180
        lastG = SIMD2(g0.x * cos(pr) + g0.y * sin(pr), (-g0.x * sin(pr) + g0.y * cos(pr)) * cos(tr))
        engine.requestFrame(dt: dt, gx: lastG.x, gy: lastG.y, paused: paused)

        // Test hooks for the simulator, where nothing can touch the screen:
        // `-flipEvery <s>` flips and `-paletteEvery <s>` steps the palette on
        // a timer, as a tap and the picker would.
        if flipEvery > 0, now - lastAutoFlip >= flipEvery {
            lastAutoFlip = now
            flip()
        }
        if paletteEvery > 0, now - lastAutoPalette >= paletteEvery {
            lastAutoPalette = now
            setPalette(Palette.all[(paletteIndex + 1) % Palette.all.count])
            note("[sand] palette \(currentPalette.name)")
        }

        let poseChanged = theta != lastPose || phi != lastPhi
        if poseChanged {
            if theta != lastPose { model.setPose(theta: theta) }
            lastPose = theta
            lastPhi = phi
            model.root.orientation = simd_quatf(angle: Float(-phi * .pi / 180), axis: [0, 0, 1])
        }
        renderer.draw(glint: Float(theta * 0.05 + phi * 0.08 + (now - start) * 0.4), poseChanged: poseChanged)
        turnReflections()
        logFrame(dt: rawDt)
    }

    /// The phone's down on the screen. Standing as a tent, the picture is on
    /// the upright half, which may not be the half with the sensor: its
    /// gravity is the reading turned about the hinge.
    private func screenGravity(dt: Double) -> SIMD2<Double> {
        guard let target = tentHinge else {
            _ = hinge.step(towards: 180, dt: dt)
            return motion.gravity ?? [0, 1]
        }
        let angle = hinge.step(towards: target, dt: dt)
        if fakeTentSensor, motion.deviceGravity == nil {
            let up = TentGravity.upright(sensor: [0, 0, -1], hingeAngle: angle)
            return TentGravity.toScreen(up, screenAngle: TentGravity.sensorHalf == .left ? 90 : -90)
        }
        guard let g = motion.deviceGravity else { return [0, 1] }
        return TentGravity.toScreen(TentGravity.upright(sensor: g, hingeAngle: angle), screenAngle: screenAngle)
    }

    /// The room the glass reflects stays put while the phone turns in it.
    /// Scene axes are the screen's (x right, y up, z out), so the room turns
    /// by the inverse of the phone's turn since the app started.
    private func turnReflections() {
        guard let q = motion.attitude else { return }
        let q0 = attitude0 ?? q
        attitude0 = q0
        let rel = q.inverse * q0
        let target = simd_quatf(ix: Float(rel.imag.x), iy: Float(rel.imag.y), iz: Float(rel.imag.z), r: Float(rel.real))
        envTurn = simd_slerp(envTurn, target, 0.3)
        light.orientation = envTurn
    }

    private func logFrame(dt: Double) {
        logFrames += 1
        logMaxDt = max(logMaxDt, dt)
        let now = CACurrentMediaTime()
        guard now - logT0 >= 2 else { return }
        let s = engine.stats, secs = now - logT0
        let frames = s.frames - logEngine.frames, ticks = s.totalTicks - logEngine.totalTicks
        var line = String(format: "[sand] %.1f fps (worst %.1f ms); core %.1f frames/s, %.1f ticks/s, %.2f ms per core frame, %.3f ms/tick, %d moves; g %.2f,%.2f",
                          Double(logFrames) / secs, logMaxDt * 1000, Double(frames) / secs, Double(ticks) / secs,
                          frames > 0 ? (s.totalCoreMs - logEngine.totalCoreMs) / Double(frames) : 0, s.perTickMs, s.moves,
                          lastG.x, lastG.y)
        if phi != 0 { line += String(format: "; turned %.1f°", phi) }
        if tentHinge != nil, let a = hinge.angle { line += String(format: "; tent, hinge %.1f°", a) }
        note(line)
        logT0 = now
        logFrames = 0
        logMaxDt = 0
        logEngine = s
    }

    /// To stdout and the unified log (`log show --info`), for checking timing.
    func note(_ line: String) {
        print(line)
        log.notice("\(line, privacy: .public)")
    }

    // ---------- camera, backdrop, light ----------

    /// A camera where the web's CSS perspective puts the eye (4 frame heights
    /// out), with the field of view that fits the toy as the web lays it out.
    private func placeCamera(viewSize: CGSize) {
        let L = model.layout
        let k = L.ih / screenLayout.ih // metres per point
        let visibleH = Double(viewSize.height) * k
        let d = 4 * L.fh
        let fov = 2 * atan(visibleH / 2 / d) * 180 / .pi
        camera.components.set(PerspectiveCameraComponent(near: 0.02, far: 20, fieldOfViewInDegrees: Float(fov)))
        // The web centres the toy box, nudged up by 0.3 b.
        let cy = L.fh / 2 - L.th / 2 - 0.3 * L.b
        camera.position = [0, Float(cy), Float(d)]
    }

    /// A softly lit wall well behind the frame (the web page's background),
    /// so the clear liquid reads as see-through.
    private func buildBackdrop(viewSize: CGSize, dark: Bool) {
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        if let img = Self.wallImage(dark: dark), let tex = try? TextureResource(image: img, options: .init(semantic: .color)) {
            m.color = .init(tint: .white, texture: .init(tex))
        }
        backdrop.model = ModelComponent(mesh: .generatePlane(width: 1, height: 1), materials: [m])
        resizeBackdrop(viewSize: viewSize)
    }

    /// The wall fills the view whatever its shape (a unit plane, scaled).
    private func resizeBackdrop(viewSize: CGSize) {
        let L = model.layout
        let z = -1.2 * L.fh
        let dist = 4 * L.fh - z
        let k = L.ih / screenLayout.ih
        let h = Double(viewSize.height) * k * dist / (4 * L.fh) * 1.15
        let w = h * Double(viewSize.width / viewSize.height)
        backdrop.scale = [Float(w), Float(h), 1]
        backdrop.position = [0, camera.position.y, Float(z)]
    }

    /// radial-gradient(120% 90% at 50% 35%, --bg-1, --bg-2) from style.css.
    static func wallImage(dark: Bool) -> CGImage? {
        let w = 256, h = 512
        let c1: SIMD3<Double> = dark ? [0x2b, 0x2a, 0x28] : [0xf1, 0xee, 0xe9]
        let c2: SIMD3<Double> = dark ? [0x12, 0x12, 0x11] : [0xd9, 0xd4, 0xcc]
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let dx = (Double(x) / Double(w) - 0.5) / 0.6, dy = (Double(y) / Double(h) - 0.35) / 0.45
                let t = min(1, (dx * dx + dy * dy).squareRoot())
                let c = c1 + (c2 - c1) * t
                let i = (y * w + x) * 4
                px[i] = UInt8(c.x)
                px[i + 1] = UInt8(c.y)
                px[i + 2] = UInt8(c.z)
            }
        }
        guard let p = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The bundled room (tools/make-studio-ibl.swift) as an environment.
    static func studioLight() async -> EnvironmentResource? {
        guard let url = Bundle.main.url(forResource: "studio", withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if #available(iOS 27.0, *) {
            return try? await EnvironmentResource(equirectangular: img, options: .init(skyboxMode: .preserve, samplingQuality: .normal, specularCubeDimension: 512))
        }
        return try? await EnvironmentResource(equirectangular: img, withName: "studio")
    }

    private func receiveLight(_ e: Entity) {
        if e is ModelEntity { e.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light)) }
        for c in e.children { receiveLight(c) }
    }
}
