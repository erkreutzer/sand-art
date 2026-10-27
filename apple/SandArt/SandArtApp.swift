import os
import SandKit
import SwiftUI
import UIKit

@main
struct SandArtApp: App {
    /// Held by the app, not the window: a fold can move the app to the other
    /// display, and the picture must come along unchanged.
    @State private var app = SandModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
    }
}

/// The hinge as the app sees it: degrees (180 flat open) and status.
struct HingeReading: Equatable {
    enum Status: String { case closed, partiallyOpen, fullyOpen }
    var angle: Double
    var status: Status

    /// Test hook: a status from a faked angle.
    init(fakeAngle a: Double) {
        angle = a
        status = a < 5 ? .closed : a > 175 ? .fullyOpen : .partiallyOpen
    }

    @available(iOS 27.1, *)
    init(_ h: DeviceHinge) {
        angle = h.angle.degrees
        status = h.status == .closed ? .closed : h.status == .fullyOpen ? .fullyOpen : .partiallyOpen
    }
}

/// How the phone is held, which decides the layout.
enum Posture: String {
    /// One display, no fold in it: the picture with the palette picker; the
    /// tuning panel opens as a sheet.
    case flat
    /// Open with the fold through the display: the picture beside the tuning
    /// panel (ArrangementView), the fold between them.
    case unfolded
    /// Partly open, the fold horizontal: the upright half shows the picture,
    /// the flat half is the wooden base with the palette and flip controls.
    case tent
}

/// App state that outlives any one view: the scene controller (one grid for
/// the app's life), the tuning, the hinge.
@MainActor
@Observable
final class SandModel {
    private(set) var controller: SceneController?
    private(set) var tuning: Tuning?
    private(set) var hinge: HingeReading?
    /// True once the hinge's first state is in (or it is clearly absent).
    private(set) var hingeKnown = false
    var posture = Posture.flat
    private var postureLogged = false
    /// The palette shown, mirrored from the controller for the pickers.
    private(set) var palette = 0

    /// Test hooks for the simulator, which has no hinge: `-fakeHinge <deg>`
    /// holds the hinge at an angle (with a fold across the middle of the
    /// display), `-postureEvery <s>` steps it through open, tent and shut.
    private let fakeHinge = UserDefaults.standard.object(forKey: "fakeHinge") as? Double
        ?? (UserDefaults.standard.double(forKey: "postureEvery") > 0 ? 180 : nil)
    var isFaking: Bool { fakeHinge != nil }

    init() {
        if let a = fakeHinge {
            hinge = HingeReading(fakeAngle: a)
            hingeKnown = true
        }
        startHooks()
    }

    func hingeChanged(_ h: HingeReading?) {
        guard fakeHinge == nil else { return }
        let first = !hingeKnown
        hingeKnown = true
        guard h != hinge || first else { return }
        hinge = h
        note(h.map { String(format: "[sand] hinge %@ %.1f°", $0.status.rawValue, $0.angle) } ?? "[sand] hinge: none")
    }

    private let log = Logger(subsystem: "art.sand.SandArt", category: "app")

    /// To stdout and the unified log, as SceneController's.
    func note(_ line: String) {
        print(line)
        log.notice("\(line, privacy: .public)")
    }

    /// The scene, built once from the first view it is shown in. A phone with
    /// a hinge gets a landscape frame (the shape its tent posture and opened
    /// display show), others the web's choice from the view's shape.
    func makeController(viewSize: CGSize, pixelsPerPoint: Double) {
        guard controller == nil, viewSize.width > 0 else { return }
        let aspect: Double? = hinge != nil ? 1.38 : nil
        guard let c = try? SceneController(viewSize: viewSize, pixelsPerPoint: pixelsPerPoint, aspect: aspect) else { return }
        controller = c
        tuning = Tuning(controller: c)
        palette = c.paletteIndex
        c.onPalette = { [weak self] in self?.palette = $0 }
        updateScreenAngle()
    }

    func setPalette(_ i: Int) { controller?.setPalette(Palette.all[i]) }

    /// The fold in a view's space: the system's division region, or a faked
    /// one across the middle of the longer side.
    func fold(in geo: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *),
           let r = geo.reservedRegions(kind: .division).first(where: \.isActive) {
            return r.frame
        }
        guard fakeHinge != nil, hinge?.status != .closed else { return nil }
        let s = geo.size
        return s.height >= s.width ? CGRect(x: 0, y: s.height / 2, width: s.width, height: 0)
            : CGRect(x: s.width / 2, y: 0, width: 0, height: s.height)
    }

    func posture(fold: CGRect?) -> Posture {
        guard let h = hinge, let fold, h.status != .closed else { return .flat }
        return h.status == .partiallyOpen && fold.width > fold.height ? .tent : .unfolded
    }

    /// Called whenever the layout settles: posture and gravity follow.
    func update(posture p: Posture) {
        if p != posture || !postureLogged {
            posture = p
            postureLogged = true
            note("[sand] posture \(p.rawValue)")
        }
        controller?.tentHinge = p == .tent ? hinge?.angle : nil
        updateScreenAngle()
    }

    /// MotionSource wants the interface's turn from the device's portrait,
    /// degrees, as screen.orientation.angle on the web.
    func updateScreenAngle() {
        guard let o = windowScene?.effectiveGeometry.interfaceOrientation else { return }
        let a: Double = switch o {
        case .landscapeRight: 90
        case .landscapeLeft: -90
        case .portraitUpsideDown: 180
        default: 0
        }
        if controller?.screenAngle != a { controller?.screenAngle = a }
    }

    private var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    // ---------- test hooks ----------

    private func startHooks() {
        let postureEvery = UserDefaults.standard.double(forKey: "postureEvery")
        if postureEvery > 0 {
            // Open flat, tent at 100°, shut, and round again.
            let angles = [180.0, 100, 0]
            var i = 0
            Timer.scheduledTimer(withTimeInterval: postureEvery, repeats: true) { _ in
                MainActor.assumeIsolated {
                    i = (i + 1) % angles.count
                    self.hinge = HingeReading(fakeAngle: angles[i])
                    self.note(String(format: "[sand] fake hinge %.0f°", angles[i]))
                }
            }
        }
        // `-rotateEvery <s>`: turn the interface, as turning the phone would.
        let rotateEvery = UserDefaults.standard.double(forKey: "rotateEvery")
        if rotateEvery > 0 {
            let masks: [UIInterfaceOrientationMask] = [.landscapeRight, .portrait, .landscapeLeft, .portrait]
            var i = 0
            Timer.scheduledTimer(withTimeInterval: rotateEvery, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let m = masks[i % masks.count]
                    i += 1
                    self.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: m)) { err in
                        print("[sand] rotate: \(err)")
                    }
                    self.note("[sand] rotate to \(m == .portrait ? "portrait" : m == .landscapeLeft ? "landscapeLeft" : "landscapeRight")")
                }
            }
        }
    }
}
