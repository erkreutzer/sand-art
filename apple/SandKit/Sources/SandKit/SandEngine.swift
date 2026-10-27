import Foundation
import Metal

/// Runs the core on its own thread, as the web's worker does (src/engine.js,
/// src/worker.js): the display asks for a frame, and asks again only once the
/// previous one is done, with the time in between carried over. The core has
/// no clock, so this host times its ticks and allows only as many per frame as
/// fit the budget (slow motion rather than dropped frames).
///
/// After each frame the rows that changed are copied into `grid`, a Metal
/// buffer the colour kernel reads. `gridLock` keeps the copy and the GPU's
/// read apart: the engine holds it while copying, a reader from encoding
/// until its command buffer completes.
public final class SandEngine: @unchecked Sendable {
    /// src/app.js: TICKS_PER_SEC; src/engine.js: BUDGET_MS.
    public static let ticksPerSecond = 180.0
    static let budgetMs = 11.0

    public struct Stats: Sendable {
        public var ticks = 0, moves = 0
        /// Time the last core frame took, and the running average per tick.
        public var coreMs = 0.0, perTickMs = 0.0
        /// Running totals since the engine started: core frames, ticks and
        /// core time.
        public var frames = 0, totalTicks = 0, totalCoreMs = 0.0

        public init() {}
        init(ticks: Int, moves: Int, coreMs: Double, perTickMs: Double) {
            self.ticks = ticks
            self.moves = moves
            self.coreMs = coreMs
            self.perTickMs = perTickMs
        }
    }

    /// Grid size in grains, and padded (one cell of wall all round).
    public let w: Int, h: Int, W: Int, H: Int
    public let grid: MTLBuffer
    public let gridLock = DispatchSemaphore(value: 1)

    private let core: Core // only touched on `queue`
    private let queue = DispatchQueue(label: "sand.engine", qos: .userInteractive)
    private var perTick = 0.0 // queue only

    private let lock = NSLock() // guards the rest
    private var busy = false, dtAcc = 0.0, changed = true, _stats = Stats()

    public init(device: MTLDevice, w: Int, h: Int, seed: UInt32 = .random(in: 0 ... .max)) {
        core = Core(w: w, h: h, tps: Self.ticksPerSecond, seed: seed)
        self.w = w
        self.h = h
        W = core.W
        H = core.H
        grid = device.makeBuffer(length: W * H * 4, options: .storageModeShared)!
        copyRows(0...(H - 1))
        _ = core.takeDirty()
    }

    public var stats: Stats { lock.withLock { _stats } }

    /// True once since the grid buffer last changed.
    public func takeChanged() -> Bool {
        lock.withLock { defer { changed = false }; return changed }
    }

    /// Asks for a frame: dt seconds, gravity in grid space (x right, y down,
    /// |g| = 1 upright). If the last one is still running, the time is kept
    /// for the next.
    public func requestFrame(dt: Double, gx: Double, gy: Double, paused: Bool = false) {
        let d: Double? = lock.withLock {
            dtAcc += dt
            if busy { return nil }
            busy = true
            defer { dtAcc = 0 }
            return min(dtAcc, 0.1)
        }
        guard let d else { return }
        queue.async { self.run(dt: d, gx: gx, gy: gy, paused: paused) }
    }

    /// New sand at the top as you see it (`upsideDown`: the frame rests flipped).
    public func reseed(upsideDown: Bool) {
        queue.async {
            self.core.reseed(upsideDown: upsideDown)
            _ = self.core.takeDirty()
            self.publish(0...(self.H - 1), frame: nil)
        }
    }

    /// Settings in the "Copy settings" JSON shape (core/params.json).
    public func tune(json: String) {
        queue.async { self.core.tune(json: json) }
    }

    private func run(dt: Double, gx: Double, gy: Double, paused: Bool) {
        let maxTicks: UInt32 = paused ? 0 : perTick > 0 ? UInt32(max(1, (Self.budgetMs / perTick).rounded(.down))) : .max
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ticks = core.frame(dt: dt, gx: gx, gy: gy, maxTicks: maxTicks)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        if ticks > 0 {
            let t = ms / Double(ticks)
            perTick = perTick > 0 ? perTick * 0.9 + t * 0.1 : t
        }
        publish(core.takeDirty(), frame: Stats(ticks: ticks, moves: core.moves, coreMs: ms, perTickMs: perTick))
    }

    /// frame: the stats of the frame that just ended, if this ends one.
    private func publish(_ rows: ClosedRange<Int>?, frame: Stats?) {
        if let rows { copyRows(rows) }
        lock.withLock {
            if rows != nil { changed = true }
            if let frame {
                let t = _stats
                _stats = frame
                _stats.frames = t.frames + 1
                _stats.totalTicks = t.totalTicks + frame.ticks
                _stats.totalCoreMs = t.totalCoreMs + frame.coreMs
                busy = false
            }
        }
    }

    private func copyRows(_ rows: ClosedRange<Int>) {
        let row = W * 4
        gridLock.wait()
        let src = core.grid.baseAddress! + rows.lowerBound * row
        (grid.contents() + rows.lowerBound * row).copyMemory(from: src, byteCount: rows.count * row)
        gridLock.signal()
    }
}
