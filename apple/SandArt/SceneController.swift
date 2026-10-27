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
@MainActor
final class SceneController {
    let grid: GridSize
    let engine: SandEngine
    let renderer: SandRenderer
    let model: FrameModel
    let motion = MotionSource()
    /// The glass's layout in points, for turning drags into flip angles.
    let screenLayout: FrameLayout

    private let root = Entity()
    private let light = Entity()
    private let camera = Entity()
    private let backdrop = ModelEntity()
    private var subscription: EventSubscription?
    private let log = Logger(subsystem: "art.sand.SandArt", category: "frame")

    // Flip about the stand's axle, degrees, as theta in src/app.js.
    private(set) var theta = 0.0
    private var anim: (from: Double, to: Double, t0: Double, dur: Double)?
    private var lastPose = Double.nan
    private var start = CACurrentMediaTime()
    private var attitude0: simd_quatd?
    private var envTurn = simd_quatf(angle: 0, axis: [0, 1, 0])
    private let flipEvery = UserDefaults.standard.double(forKey: "flipEvery")
    private lazy var lastAutoFlip = CACurrentMediaTime()
    private let paletteEvery = UserDefaults.standard.double(forKey: "paletteEvery")
    private lazy var lastAutoPalette = CACurrentMediaTime()

    // Frame-time log: render frames and core time over the last couple of seconds.
    private var logT0 = CACurrentMediaTime(), logFrames = 0, logMaxDt = 0.0
    private var logEngine = SandEngine.Stats()

    init(viewSize: CGSize, pixelsPerPoint: Double) throws {
        let t0 = CACurrentMediaTime()
        let vw = Double(viewSize.width), vh = Double(viewSize.height)
        grid = GridSize(viewWidth: vw, viewHeight: vh, pixelsPerPoint: pixelsPerPoint)
        let device = MTLCreateSystemDefaultDevice()!
        engine = SandEngine(device: device, w: grid.w, h: grid.h)
        let t1 = CACurrentMediaTime()
        renderer = try SandRenderer(engine: engine, device: device, scale: grid.scale)
        let t2 = CACurrentMediaTime()
        let gridAspect = Double(grid.w) / Double(grid.h)
        model = FrameModel(gridAspect: gridAspect, sandTexture: renderer.resource)
        let t3 = CACurrentMediaTime()
        // As layout() in src/app.js: fitted, then kept at the grid's exact aspect.
        let fitted = FrameLayout.fit(viewWidth: vw, viewHeight: vh)
        screenLayout = FrameLayout(iw: fitted.iw, ih: fitted.iw / gridAspect)
        note(String(format: "[sand] grid %dx%d scale %d (%d cells), view %.0fx%.0f pt @%.0fx; engine %.0f ms, renderer %.0f ms, model %.0f ms",
                    grid.w, grid.h, grid.scale, grid.w * grid.h, vw, vh, pixelsPerPoint, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000))
    }

    /// Builds the scene into the RealityView's content and starts the loop.
    func install(in content: inout RealityViewCameraContent, viewSize: CGSize, dark: Bool) async {
        let t0 = CACurrentMediaTime()
        content.camera = .virtual
        content.renderingEffects.motionBlur = .disabled
        content.renderingEffects.depthOfField = .disabled
        content.renderingEffects.cameraGrain = .disabled

        root.addChild(model.root)
        content.add(root)
        placeCamera(viewSize: viewSize)
        content.add(camera)
        buildBackdrop(viewSize: viewSize, dark: dark)
        renderer.backdrop = dark ? 0.13 : 0.9
        content.add(backdrop)

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
        content.add(light)

        note(String(format: "[sand] scene built in %.0f ms", (CACurrentMediaTime() - t0) * 1000))
        setPalette(currentPalette)
        model.setPose(theta: 0)
        motion.start()
        start = CACurrentMediaTime()
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            self?.tick(dt: e.deltaTime)
        }
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

        // Gravity in grid space: the phone's down on the screen (upright where
        // there's no sensor), turned by the flip.
        let g0 = motion.gravity ?? [0, 1]
        let tr = theta * .pi / 180
        engine.requestFrame(dt: dt, gx: g0.x, gy: g0.y * cos(tr))

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

        let poseChanged = theta != lastPose
        if poseChanged {
            lastPose = theta
            model.setPose(theta: theta)
        }
        renderer.draw(glint: Float(theta * 0.05 + (now - start) * 0.4), poseChanged: poseChanged)
        turnReflections()
        logFrame(dt: rawDt)
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
        let line = String(format: "[sand] %.1f fps (worst %.1f ms); core %.1f frames/s, %.1f ticks/s, %.2f ms per core frame, %.3f ms/tick, %d moves",
                          Double(logFrames) / secs, logMaxDt * 1000, Double(frames) / secs, Double(ticks) / secs,
                          frames > 0 ? (s.totalCoreMs - logEngine.totalCoreMs) / Double(frames) : 0, s.perTickMs, s.moves)
        note(line)
        logT0 = now
        logFrames = 0
        logMaxDt = 0
        logEngine = s
    }

    /// To stdout and the unified log (`log show --info`), for checking timing.
    private func note(_ line: String) {
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
        let L = model.layout
        let z = -1.2 * L.fh
        let dist = 4 * L.fh - z
        let k = L.ih / screenLayout.ih
        let h = Double(viewSize.height) * k * dist / (4 * L.fh) * 1.15
        let w = h * Double(viewSize.width / viewSize.height)
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        if let img = Self.wallImage(dark: dark), let tex = try? TextureResource(image: img, options: .init(semantic: .color)) {
            m.color = .init(tint: .white, texture: .init(tex))
        }
        backdrop.model = ModelComponent(mesh: .generatePlane(width: Float(w), height: Float(h)), materials: [m])
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
