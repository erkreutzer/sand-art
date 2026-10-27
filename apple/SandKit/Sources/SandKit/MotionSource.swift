#if os(iOS)
import CoreMotion
import simd

/// The phone's own "down", from CoreMotion: gravity projected onto the screen
/// plane (x right, y down, |g| = 1 upright; the part pressing the sand against
/// the back pane is left out, and a phone lying flat gives |g| -> 0), and the
/// attitude, which turns the reflections in the glass. Smoothed as the web's
/// devicemotion handler is. Nil where there is no motion sensor (the
/// simulator): callers fall back to upright.
@MainActor
public final class MotionSource {
    public private(set) var gravity: SIMD2<Double>?
    /// Device attitude in a frame with z up (the yaw is arbitrary).
    public private(set) var attitude: simd_quatd?
    /// The screen's rotation from the device's portrait, degrees (as
    /// screen.orientation.angle on the web).
    public var screenAngle = 0.0

    private let manager = CMMotionManager()

    public init() {}

    public func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / 60
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            // Device axes: x right, y up the screen, z out of it.
            let gx = m.gravity.x, gy = -m.gravity.y
            let a = -screenAngle * .pi / 180
            let s = SIMD2(gx * cos(a) - gy * sin(a), gx * sin(a) + gy * cos(a))
            gravity = gravity.map { $0 * 0.7 + s * 0.3 } ?? s
            let q = m.attitude.quaternion
            attitude = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
        }
    }

    public func stop() { manager.stopDeviceMotionUpdates() }
}
#endif
