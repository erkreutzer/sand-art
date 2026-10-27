import simd
import XCTest
@testable import SandKit

/// The tent posture's gravity and the fixed-shape refit (Fold.swift).
final class FoldTests: XCTestCase {
    private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-9, "\(a) vs \(b) \(msg)", file: file, line: line)
    }

    /// Flat open: both halves read the same.
    func testFlatOpenHalvesAgree() {
        let g = simd_normalize(SIMD3(0.3, -0.8, -0.5))
        for half in [TentGravity.SensorHalf.left, .right] {
            near(TentGravity.halves(sensor: g, hingeAngle: 180, sensorHalf: half).other, g)
        }
    }

    /// Sensor half flat on the table, screen up; the other half stands at 90°
    /// with its far edge up, so its gravity points back along its own x
    /// towards the hinge, in its screen plane.
    func testTentSensorHalfFlat() {
        let flat = SIMD3<Double>(0, 0, -1)
        near(TentGravity.upright(sensor: flat, hingeAngle: 90, sensorHalf: .left), [-1, 0, 0])
        near(TentGravity.upright(sensor: flat, hingeAngle: 90, sensorHalf: .right), [1, 0, 0])
        // Leaning back (open to 120°): sin 60° in the screen plane, the rest
        // presses the sand against the back pane.
        let g = TentGravity.upright(sensor: flat, hingeAngle: 120, sensorHalf: .left)
        near(g, [-sin(.pi / 3), 0, -0.5])
    }

    /// Sensor half upright: its own reading is used unchanged.
    func testTentSensorHalfUpright() {
        let up = SIMD3<Double>(1, 0, 0) // stood on its right edge
        near(TentGravity.upright(sensor: up, hingeAngle: 90, sensorHalf: .left), up)
        near(TentGravity.upright(sensor: up, hingeAngle: 90, sensorHalf: .right), up)
    }

    /// The halves' readings stay unit length and the turn undoes itself.
    func testTurnIsARotation() {
        let g = simd_normalize(SIMD3(0.2, 0.4, -0.9))
        for a in stride(from: 0.0, through: 180, by: 15) {
            let o = TentGravity.halves(sensor: g, hingeAngle: a, sensorHalf: .left).other
            XCTAssertEqual(simd_length(o), 1, accuracy: 1e-12)
            near(TentGravity.halves(sensor: o, hingeAngle: a, sensorHalf: .right).other, g, "angle \(a)")
        }
    }

    /// Device gravity onto the interface's screen frame for each orientation.
    func testToScreen() {
        // Portrait upright: down the screen.
        XCTAssertEqual(TentGravity.toScreen([0, -1, 0], screenAngle: 0), SIMD2(0, 1))
        // Device turned anticlockwise (interface .landscapeRight, angle 90):
        // down is the device's left edge.
        let r = TentGravity.toScreen([-1, 0, 0], screenAngle: 90)
        XCTAssertEqual(r.x, 0, accuracy: 1e-12)
        XCTAssertEqual(r.y, 1, accuracy: 1e-12)
        // Clockwise (.landscapeLeft, -90): down is the device's right edge.
        let l = TentGravity.toScreen([1, 0, 0], screenAngle: -90)
        XCTAssertEqual(l.x, 0, accuracy: 1e-12)
        XCTAssertEqual(l.y, 1, accuracy: 1e-12)
    }

    /// A frame keeps its shape: the fitted glass has the given aspect in any
    /// view, and the grid built for it does too.
    func testFixedAspectFit() {
        for (w, h) in [(466.0, 678.0), (678.0, 466.0), (669.0, 475.0), (951.0, 669.0)] {
            let L = FrameLayout.fit(viewWidth: w, viewHeight: h, aspect: 1.38)
            XCTAssertEqual(L.iw / L.ih, 1.38, accuracy: 1e-12)
            XCTAssertLessThanOrEqual(L.tw, w * 0.9 + 1e-9)
            XCTAssertLessThanOrEqual(L.th, h * 0.8 + 1e-9)
        }
        // Same as the view-shaped sizing when the aspect agrees.
        XCTAssertEqual(GridSize(viewWidth: 402, viewHeight: 874, aspect: 0.74, pixelsPerPoint: 3),
                       GridSize(viewWidth: 402, viewHeight: 874, pixelsPerPoint: 3))
    }

    func testSmootherEases() {
        var s = HingeSmoother()
        XCTAssertEqual(s.step(towards: 180, dt: 1 / 60), 180)
        var a = 180.0
        for _ in 0..<6 { a = s.step(towards: 90, dt: 1 / 60) }
        XCTAssertGreaterThan(a, 90)
        XCTAssertLessThan(a, 180)
        for _ in 0..<120 { a = s.step(towards: 90, dt: 1 / 60) }
        XCTAssertEqual(a, 90, accuracy: 0.01)
    }
}
