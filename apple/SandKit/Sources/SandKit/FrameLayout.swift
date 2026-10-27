import Foundation

/// The frame on its stand, sized from the glass as in src/app.js measure():
/// b is the wooden rail, then the steel posts, the gap and the wooden base.
/// Any unit; the 3D scene uses metres.
public struct FrameLayout: Sendable {
    public let iw: Double, ih: Double // glass
    public let b: Double, postw: Double, side: Double
    public let fw: Double, fh: Double // frame outside
    public let gap: Double, baseh: Double, depth: Double
    public let tw: Double, th: Double // the whole toy

    public init(iw: Double, ih: Double) {
        self.iw = iw
        self.ih = ih
        b = 0.085 * min(iw, ih)
        postw = 0.26 * b
        side = postw + 0.3 * b
        fw = iw + 2 * b
        fh = ih + 2 * b
        gap = 0.55 * b
        baseh = 1.05 * b
        depth = 0.8 * b
        tw = fw + 2 * side
        th = fh + gap + baseh
    }

    /// Glass width / height: portrait-ish screens get an upright frame.
    public static func aspect(viewWidth: Double, viewHeight: Double) -> Double {
        viewHeight > viewWidth * 1.1 ? 0.74 : 1.38
    }

    /// The toy fitted into a view as the web fits it (90% of the width, 80% of
    /// the height), in the view's units.
    public static func fit(viewWidth: Double, viewHeight: Double) -> FrameLayout {
        let a = aspect(viewWidth: viewWidth, viewHeight: viewHeight)
        let unit = FrameLayout(iw: a, ih: 1)
        let s = min(viewWidth * 0.9 / unit.tw, viewHeight * 0.8 / unit.th)
        return FrameLayout(iw: a * s, ih: s)
    }
}

/// Grid resolution as on the web: one grain per device pixel of the glass
/// where that fits the cell budget, else 2x2 pixels, and so on.
public struct GridSize: Sendable, Equatable {
    /// src/app.js MAX_CELLS for touch screens.
    public static let mobileBudget = 520_000

    public let w: Int, h: Int, scale: Int

    /// pixelsPerPoint is capped at 3, as the web caps devicePixelRatio.
    public init(viewWidth: Double, viewHeight: Double, pixelsPerPoint: Double, maxCells: Int = mobileBudget) {
        let L = FrameLayout.fit(viewWidth: viewWidth, viewHeight: viewHeight)
        let dpr = min(pixelsPerPoint, 3)
        let devW = L.iw * dpr, devH = L.ih * dpr
        scale = max(1, Int((devW * devH / Double(maxCells)).squareRoot().rounded(.up)))
        w = Int((devW / Double(scale)).rounded(.down))
        h = Int((devH / Double(scale)).rounded(.down))
    }
}
