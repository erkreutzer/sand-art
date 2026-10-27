// Draws apple/SandArt/Resources/studio.png: the image-based light the iPhone
// app's glass and wood reflect. An equirectangular room (longitude across,
// latitude down; the middle of the image is straight ahead, -z, its edges
// behind the viewer): a warm wall in the web page's background colours, a darker floor, a light ceiling, a tall
// window behind the viewer at eye level (a pane facing you mirrors only a
// patch about 10 degrees across, straight behind you; its corner is there), a softer lamp behind to the right and a dark doorway ahead.
// 8 bits can't hold a real window's brightness, so the room is dim against
// it, as a real room's walls are (the app lights the frame with a sun-like
// light from the window too): a pane mirroring 8% of it shows the window
// and only faintly the walls.
//   swift tools/make-studio-ibl.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let W = 1024, H = 512
var px = [UInt8](repeating: 255, count: W * H * 4)
func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}
// A soft-edged rectangle on the sphere, in degrees of longitude / latitude.
func patch(_ lon: Double, _ lat: Double, _ lon0: Double, _ lon1: Double, _ lat0: Double, _ lat1: Double, _ soft: Double) -> Double {
    var l = lon
    let mid = (lon0 + lon1) / 2
    while l - mid > 180 { l -= 360 }
    while l - mid < -180 { l += 360 }
    return smooth(lon0 - soft, lon0 + soft, l) * (1 - smooth(lon1 - soft, lon1 + soft, l))
        * smooth(lat0 - soft, lat0 + soft, lat) * (1 - smooth(lat1 - soft, lat1 + soft, lat))
}
for y in 0..<H {
    for x in 0..<W {
        let lon = (Double(x) + 0.5) / Double(W) * 360 - 180 // 0 ahead, +-180 behind
        let lat = 90 - (Double(y) + 0.5) / Double(H) * 180
        // Wall #f1eee9 -> #d9d4cc towards the floor; ceiling lighter, floor darker.
        let wallLo: [Double] = [0.85, 0.83, 0.80].map { $0 * 0.3 }, wallHi: [Double] = [0.95, 0.93, 0.90].map { $0 * 0.36 }
        let wall = zip(wallLo, wallHi).map { $0 + ($1 - $0) * smooth(-6, 6, lat) }
        let up = smooth(25, 70, lat), down = smooth(-10, -40, lat)
        var c = wall.map { $0 * (1 - 0.35 * down) }
        c = zip(c, [0.42, 0.41, 0.40]).map { $0 + ($1 - $0) * up }
        // Window behind the viewer, cool daylight, with mullions.
        var win = patch(lon, lat, 178, 232, -3, 50, 1)
        let mull = 1 - 0.7 * patch(lon, lat, 203, 205, -3, 50, 0.4) - 0.7 * patch(lon, lat, 178, 232, 3, 4.5, 0.3)
        win *= mull
        // Warm lamp behind-right.
        let lamp = patch(lon, lat, -130, -115, 10, 30, 6)
        let sky: [Double] = [0.93, 0.97, 1.0], warm: [Double] = [1.0, 0.85, 0.6]
        c = (0..<3).map { c[$0] + (sky[$0] - c[$0]) * win + (warm[$0] - c[$0]) * lamp }
        // A dark doorway ahead-left, so reflections have some contrast.
        let door = patch(lon, lat, -70, -50, -40, 25, 2)
        c = c.map { $0 * (1 - 0.5 * door) }
        let i = (y * W + x) * 4
        for k in 0..<3 { px[i + k] = UInt8(max(0, min(255, (c[k] * 255).rounded()))) }
    }
}
let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "apple/SandArt/Resources/studio.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
