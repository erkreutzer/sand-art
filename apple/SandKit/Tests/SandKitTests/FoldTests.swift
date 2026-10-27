import simd
import Testing
@testable import SandKit

// The tent posture's gravity and the fixed-shape refit (Fold.swift).

private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { simd_length(a - b) < 1e-9 }
private func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool { simd_length(a - b) < 1e-9 }

/// Flat open: both halves read the same.
@Test func flatOpenHalvesAgree() {
    let g = simd_normalize(SIMD3(0.3, -0.8, -0.5))
    for half in [TentGravity.SensorHalf.left, .right] {
        #expect(near(TentGravity.halves(sensor: g, hingeAngle: 180, sensorHalf: half).other, g))
    }
}

/// Sensor half flat on the table, screen up; the other half stands at 90°
/// with its far edge up, so its gravity points back along its own x towards
/// the hinge, in its screen plane.
@Test func tentSensorHalfFlat() {
    let flat = SIMD3<Double>(0, 0, -1)
    #expect(near(TentGravity.upright(sensor: flat, hingeAngle: 90, sensorHalf: .left), [-1, 0, 0]))
    #expect(near(TentGravity.upright(sensor: flat, hingeAngle: 90, sensorHalf: .right), [1, 0, 0]))
    // Leaning back (open to 120°): sin 60° in the screen plane, the rest
    // presses the sand against the back pane.
    #expect(near(TentGravity.upright(sensor: flat, hingeAngle: 120, sensorHalf: .left), [-sin(.pi / 3), 0, -0.5]))
}

/// Sensor half upright: its own reading is used unchanged.
@Test func tentSensorHalfUpright() {
    let up = SIMD3<Double>(1, 0, 0) // stood on its right edge
    #expect(near(TentGravity.upright(sensor: up, hingeAngle: 90, sensorHalf: .left), up))
    #expect(near(TentGravity.upright(sensor: up, hingeAngle: 90, sensorHalf: .right), up))
}

/// The halves' readings stay unit length and the turn undoes itself.
@Test func turnIsARotation() {
    let g = simd_normalize(SIMD3(0.2, 0.4, -0.9))
    for a in stride(from: 0.0, through: 180, by: 15) {
        let o = TentGravity.halves(sensor: g, hingeAngle: a, sensorHalf: .left).other
        #expect(abs(simd_length(o) - 1) < 1e-12)
        #expect(near(TentGravity.halves(sensor: o, hingeAngle: a, sensorHalf: .right).other, g), "angle \(a)")
    }
}

/// Device gravity onto the interface's screen frame for each orientation.
@Test func toScreen() {
    // Portrait upright: down the screen.
    #expect(near(TentGravity.toScreen([0, -1, 0], screenAngle: 0), [0, 1]))
    // Device turned anticlockwise (interface .landscapeRight, angle 90): down
    // is the device's left edge.
    #expect(near(TentGravity.toScreen([-1, 0, 0], screenAngle: 90), [0, 1]))
    // Clockwise (.landscapeLeft, -90): down is the device's right edge.
    #expect(near(TentGravity.toScreen([1, 0, 0], screenAngle: -90), [0, 1]))
}

/// A frame keeps its shape: the fitted glass has the given aspect in any view,
/// and the grid built for it does too.
@Test func fixedAspectFit() {
    for (w, h) in [(466.0, 678.0), (678.0, 466.0), (669.0, 475.0), (951.0, 669.0)] {
        let L = FrameLayout.fit(viewWidth: w, viewHeight: h, aspect: 1.38)
        #expect(abs(L.iw / L.ih - 1.38) < 1e-12)
        #expect(L.tw <= w * 0.9 + 1e-9)
        #expect(L.th <= h * 0.8 + 1e-9)
    }
    // Same as the view-shaped sizing when the aspect agrees.
    #expect(GridSize(viewWidth: 402, viewHeight: 874, aspect: 0.74, pixelsPerPoint: 3)
        == GridSize(viewWidth: 402, viewHeight: 874, pixelsPerPoint: 3))
}

@Test func smootherEases() {
    var s = HingeSmoother()
    #expect(s.step(towards: 180, dt: 1 / 60) == 180)
    var a = 180.0
    for _ in 0..<6 { a = s.step(towards: 90, dt: 1 / 60) }
    #expect(a > 90 && a < 180)
    for _ in 0..<120 { a = s.step(towards: 90, dt: 1 / 60) }
    #expect(abs(a - 90) < 0.01)
}
