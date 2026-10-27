import Foundation
import SandCore

/// The Rust core (core/src/lib.rs) through its C ABI. Not thread-safe: one
/// thread owns it (SandEngine's). The grid is read in place, without a copy.
public final class Core {
    let e: OpaquePointer
    /// Grid size in grains, and padded with its one cell of wall all round.
    public let w: Int, h: Int, W: Int, H: Int

    /// tps: ticks a second at normal speed; the same seed always gives the
    /// same pictures.
    public init(w: Int, h: Int, tps: Double, seed: UInt32) {
        e = sand_new(UInt32(w), UInt32(h), tps, seed)
        self.w = w
        self.h = h
        W = Int(sand_grid_width(e))
        H = Int(sand_grid_height(e))
    }

    deinit { sand_free(e) }

    /// New sand at the top as you see it.
    public func reseed(upsideDown: Bool) { sand_reseed(e, upsideDown ? 1 : 0) }

    /// Settings in the "Copy settings" JSON shape; returns how many applied.
    @discardableResult
    public func tune(json: String) -> Int {
        var bytes = Array(json.utf8)
        let n = sand_tune(e, &bytes, bytes.count)
        precondition(n >= 0, "sand_tune: not valid JSON")
        return Int(n)
    }

    /// One frame; gravity in grid space (x right, y down, |g| = 1 upright).
    /// Returns the ticks run.
    @discardableResult
    public func frame(dt: Double, gx: Double, gy: Double, maxTicks: UInt32 = .max) -> Int {
        Int(sand_frame(e, dt, gx, gy, maxTicks))
    }

    public var moves: Int { Int(sand_moves(e)) }

    /// W x H cells of RGBA8 (type, shade, energy, clock).
    public var grid: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: sand_grid_ptr(e), count: W * H * 4)
    }

    /// Rows changed since the last call, inclusive.
    public func takeDirty() -> ClosedRange<Int>? {
        let r = sand_take_dirty(e)
        return r == .max ? nil : Int(r >> 16)...Int(r & 0xffff)
    }

    /// The liquid's velocity field (u, v as f32 bytes, solid as u8).
    public var flow: (u: UnsafeRawBufferPointer, v: UnsafeRawBufferPointer, solid: UnsafeRawBufferPointer, nx: Int, ny: Int) {
        let f = sand_flow(e)!.pointee
        let n = Int(f.nx * f.ny)
        return (UnsafeRawBufferPointer(start: f.u, count: n * 4), UnsafeRawBufferPointer(start: f.v, count: n * 4),
                UnsafeRawBufferPointer(start: f.solid, count: n), Int(f.nx), Int(f.ny))
    }

    /// The whole picture in motion; restores onto a core of the same size.
    public func snapshot() -> Data {
        let n = sand_snapshot(e)
        return Data(bytes: sand_snapshot_ptr(e), count: n)
    }

    @discardableResult
    public func restore(_ data: Data) -> Bool {
        data.withUnsafeBytes { sand_restore(e, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) == 1 }
    }
}
