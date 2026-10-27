import Foundation
import Metal
import Testing
@testable import SandKit

// The Metal colour kernel must draw what the web's WebGL shader draws. This
// renders one picture in every palette and writes the pixels (sRGB, 8 bits,
// top row first) to tools/compare/out/; tools/compare/kernel.html renders the
// same picture with src/render.js and compares them pixel by pixel:
//   swift test --filter kernel   (in apple/SandKit), then open
//   http://localhost:5178/tools/compare/kernel.html
// The liquid is drawn opaque (liquidTint 100) on both sides so it can be
// compared too; how see-through it is differs by design (ColourKernel).

struct KernelScene: Codable {
    var w = 160, h = 120, scale = 2, seed: UInt32 = 11, tps = 180.0
    /// Frames of 1/60 s at each gravity, in order.
    var steps: [[Double]] = [[300, 0, 1], [90, 0.45, 0.9], [60, 0, -1]]
    var glint: Float = 1.234
    var liquidTint: Float = 100
}

@Test func kernelDrawsEveryPalette() throws {
    let scene = KernelScene()
    let core = Core(w: scene.w, h: scene.h, tps: scene.tps, seed: scene.seed)
    for s in scene.steps {
        for _ in 0..<Int(s[0]) { core.frame(dt: 1.0 / 60, gx: s[1], gy: s[2]) }
    }
    let device = try #require(MTLCreateSystemDefaultDevice())
    let grid = try #require(device.makeBuffer(bytes: core.grid.baseAddress!, length: core.grid.count, options: .storageModeShared))
    let kernel = try ColourKernel(device: device, w: core.w, h: core.h, W: core.W, scale: scene.scale)
    kernel.liquidTint = scene.liquidTint
    let pw = core.w * scene.scale, ph = core.h * scene.scale
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ColourKernel.pixelFormat, width: pw, height: ph, mipmapped: false)
    desc.usage = [.shaderWrite, .shaderRead]
    desc.storageMode = .shared
    let tex = try #require(device.makeTexture(descriptor: desc))
    let queue = try #require(device.makeCommandQueue())

    let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../tools/compare/out").standardized
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try JSONEncoder().encode(scene).write(to: out.appendingPathComponent("kernel-metal.json"))

    let srgb = { (v: Float) -> UInt8 in
        let c = max(0, min(1, v))
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8((s * 255).rounded())
    }
    for (i, p) in Palette.all.enumerated() {
        kernel.setPalette(p)
        let cb = try #require(queue.makeCommandBuffer())
        kernel.encode(cb, grid: grid, glint: scene.glint, into: tex)
        cb.commit()
        cb.waitUntilCompleted()
        var half = [Float16](repeating: 0, count: pw * ph * 4)
        tex.getBytes(&half, bytesPerRow: pw * 8, from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        var rgba = [UInt8](repeating: 0, count: pw * ph * 4)
        for k in 0..<(pw * ph) {
            for c in 0..<3 { rgba[k * 4 + c] = srgb(Float(half[k * 4 + c])) }
            rgba[k * 4 + 3] = UInt8((Float(half[k * 4 + 3]) * 255).rounded())
        }
        try Data(rgba).write(to: out.appendingPathComponent("kernel-metal-\(i).bin"))
        // Something of each kind was drawn: sand, and opaque liquid.
        #expect(Set(rgba.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)).count > 8)
        #expect(rgba[3] == 255)
    }
}
