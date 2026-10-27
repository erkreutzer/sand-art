import CryptoKit
import Foundation
import Testing
@testable import SandKit

// The native core must match the web's wasm core bit for bit. This replays the
// standard scenario of tools/compare/job.mjs (a fresh start, then two flips,
// at 60 fps) through the C ABI and checks the grid and liquid flow hashes at
// each phase end against what tools/compare/run.mjs prints, e.g.
//   node tools/compare/run.mjs . . --size 400x300 --fresh 40 --hold 40 --seeds 3
// After a physics change, rerun those commands and update the hashes here.

private struct Case: CustomStringConvertible, Sendable {
    let w: Int, h: Int, seed: UInt32, fresh: Int, hold: Int
    var tune: String? = nil
    let grid: [String], flow: [String]
    var description: String { "\(w)x\(h) seed \(seed)\(tune == nil ? "" : " tuned")" }
}

private let cases = [
    Case(w: 400, h: 300, seed: 3, fresh: 40, hold: 40,
         grid: ["3f76abc5b54a", "b61481fd8672", "0791cbc45657"],
         flow: ["498770833901", "4ff2959164cb", "729160709739"]),
    Case(w: 1000, h: 725, seed: 1, fresh: 20, hold: 30,
         grid: ["d3165fb91d0f", "dff6128c5079", "40ff074fe940"],
         flow: ["56a77b264867", "434cf005a199", "accfe38ee225"]),
    // --tune '{"sim":{"hole":0.08,"thinAir":0.03},"fluid":{"vorticity":0.5},"seed":{"sand":0.45},"engine":{"timeScale":1}}'
    Case(w: 400, h: 300, seed: 5, fresh: 40, hold: 40,
         tune: #"{"sim":{"hole":0.08,"thinAir":0.03},"fluid":{"vorticity":0.5},"seed":{"sand":0.45},"engine":{"timeScale":1}}"#,
         grid: ["942c1c5fb916", "689576467a94", "225178bd0f05"],
         flow: ["12bc1a16c750", "21731a5fc1ec", "5ec4ee77717a"]),
]

private func sha1(_ parts: UnsafeRawBufferPointer...) -> String {
    var h = Insecure.SHA1()
    for p in parts { h.update(bufferPointer: p) }
    return h.finalize().map { String(format: "%02x", $0) }.joined().prefix(12).description
}

@Test(arguments: cases)
private func matchesWebCore(_ c: Case) {
    let tps = 180.0 // TICKS_PER_SEC in src/app.js, as run.mjs reads it
    let fps = 60, dt = 1.0 / Double(fps)
    let core = Core(w: c.w, h: c.h, tps: tps, seed: c.seed)
    if let t = c.tune {
        core.tune(json: t)
        core.reseed(upsideDown: false)
    }
    // flip() in src/app.js: 1150 ms with a cubic ease.
    let ease = { (t: Double) in t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    let phases = [(0.0, 0.0, c.fresh), (0.0, 180.0, c.hold), (180.0, 360.0, c.hold)]
    var grid: [String] = [], flow: [String] = []
    for (from, to, secs) in phases {
        let n = from == to ? 0 : Int((1.15 * Double(fps)).rounded())
        if n > 0 {
            for f in 1...n {
                let th = ((from + (to - from) * ease(Double(f) / Double(n))) * Double.pi) / 180
                core.frame(dt: dt, gx: 0, gy: cos(th))
                _ = core.takeDirty()
            }
        }
        let gy = cos(to * Double.pi / 180) > 0 ? 1.0 : -1.0
        for _ in 0..<(secs * fps) {
            core.frame(dt: dt, gx: 0, gy: gy)
            _ = core.takeDirty()
        }
        grid.append(sha1(core.grid))
        let fl = core.flow
        flow.append(sha1(fl.u, fl.v, fl.solid))
    }
    #expect(grid == c.grid)
    #expect(flow == c.flow)
}

@Test func snapshotCarriesOn() {
    let a = Core(w: 200, h: 150, tps: 180, seed: 9)
    for _ in 0..<300 { a.frame(dt: 1.0 / 60, gx: 0, gy: -1) }
    let b = Core(w: 200, h: 150, tps: 180, seed: 1)
    #expect(b.restore(a.snapshot()))
    for _ in 0..<300 {
        a.frame(dt: 1.0 / 60, gx: 0.2, gy: -1)
        b.frame(dt: 1.0 / 60, gx: 0.2, gy: -1)
    }
    #expect(sha1(a.grid) == sha1(b.grid))
}
