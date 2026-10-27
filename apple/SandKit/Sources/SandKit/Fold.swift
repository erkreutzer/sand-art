import Foundation
import simd

// Foldable phones (iPhone Duo): the hinge, the tent posture's gravity, and a
// frame of fixed shape refitted to whichever display shows it.

/// The hinge angle as the app uses it: degrees, 180 flat open, 0 shut.
/// Hinge updates come at a rate and granularity that are system policy, so
/// the angle eases towards each new reading (frame-rate independent).
public struct HingeSmoother: Sendable {
    /// Seconds to cover about 63% of a jump.
    public var timeConstant = 0.12
    public private(set) var angle: Double?

    public init() {}

    public mutating func step(towards target: Double, dt: Double) -> Double {
        guard let a = angle, dt > 0 else {
            angle = target
            return target
        }
        let k = 1 - exp(-dt / timeConstant)
        let next = a + (target - a) * k
        angle = next
        return next
    }
}

/// The tent posture: the phone stands on the fold like a tent or laptop, one
/// half flat on the table, the other upright. The motion sensor sits in one of
/// the halves, so its gravity reading belongs to that half; the other half's
/// gravity is the same vector turned about the hinge by the fold.
public enum TentGravity {
    /// Which half of the inner display holds the motion sensor, as seen with
    /// the phone open in its portrait (book) orientation: the hinge vertical,
    /// halves left and right of it. **Unconfirmed**: check on a device (stand
    /// it as a tent both ways round; sand must fall towards the hinge both
    /// times). With the wrong value, gravity on the upright half comes out
    /// upside down whenever the sensor's half is the one lying flat.
    public static let sensorHalf = SensorHalf.left

    public enum SensorHalf: Sendable { case left, right }

    /// Device-frame gravity (CoreMotion: x right, y up the screen, z out of
    /// it; the hinge along y) of each half, given the sensor half's reading
    /// and the hinge angle in degrees (180 flat). The screens fold towards
    /// each other, so each half turns about y towards the other's +z.
    public static func halves(sensor g: SIMD3<Double>, hingeAngle: Double, sensorHalf: SensorHalf = sensorHalf)
        -> (sensor: SIMD3<Double>, other: SIMD3<Double>)
    {
        let beta = (180 - hingeAngle) * .pi / 180
        let c = cos(beta), s = sin(beta)
        // The other half's x axis, written in the sensor half's frame: it
        // points away from the hinge on its own side and rises out of the
        // sensor half's screen as the phone closes.
        let side: Double = sensorHalf == .left ? 1 : -1
        let x = SIMD3(c, 0, side * s), z = SIMD3(-side * s, 0, c)
        return (g, SIMD3(dot(g, x), g.y, dot(g, z)))
    }

    /// Gravity for the upright half: of the two halves, the one more nearly
    /// vertical (larger component in its own screen plane). Device frame.
    public static func upright(sensor g: SIMD3<Double>, hingeAngle: Double, sensorHalf: SensorHalf = sensorHalf) -> SIMD3<Double> {
        let h = halves(sensor: g, hingeAngle: hingeAngle, sensorHalf: sensorHalf)
        let inPlane = { (v: SIMD3<Double>) in v.x * v.x + v.y * v.y }
        return inPlane(h.sensor) >= inPlane(h.other) ? h.sensor : h.other
    }

    /// Device-frame gravity (y up) projected on the screen and turned into the
    /// interface's frame (x right, y down): screenAngle as MotionSource's.
    public static func toScreen(_ g: SIMD3<Double>, screenAngle: Double) -> SIMD2<Double> {
        let gx = g.x, gy = -g.y
        let a = -screenAngle * .pi / 180
        return SIMD2(gx * cos(a) - gy * sin(a), gx * sin(a) + gy * cos(a))
    }
}

extension FrameLayout {
    /// The toy fitted into a view as the web fits it (90% of the width, 80% of
    /// the height), keeping a glass aspect fixed elsewhere (a frame keeps its
    /// shape on any display).
    public static func fit(viewWidth: Double, viewHeight: Double, aspect a: Double) -> FrameLayout {
        let unit = FrameLayout(iw: a, ih: 1)
        let s = min(viewWidth * 0.9 / unit.tw, viewHeight * 0.8 / unit.th)
        return FrameLayout(iw: a * s, ih: s)
    }
}

extension GridSize {
    /// As init(viewWidth:viewHeight:pixelsPerPoint:), with the glass aspect
    /// given rather than taken from the view's shape.
    public init(viewWidth: Double, viewHeight: Double, aspect: Double, pixelsPerPoint: Double, maxCells: Int = mobileBudget) {
        let L = FrameLayout.fit(viewWidth: viewWidth, viewHeight: viewHeight, aspect: aspect)
        let dpr = min(pixelsPerPoint, 3)
        let devW = L.iw * dpr, devH = L.ih * dpr
        scale = max(1, Int((devW * devH / Double(maxCells)).squareRoot().rounded(.up)))
        w = Int((devW / Double(scale)).rounded(.down))
        h = Int((devH / Double(scale)).rounded(.down))
    }
}
