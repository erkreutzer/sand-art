#if os(iOS) || os(visionOS)
import CoreGraphics
import Foundation
import RealityKit
import UIKit

/// The sand picture as a RealityKit model: a wooden frame holding two glass
/// panes with the sand layer between them, on steel posts with axle pins and
/// a wooden base, sized by FrameLayout. Origin at the axle (the frame's
/// centre), y up, z towards the viewer, metres.
@MainActor
public final class FrameModel {
    public let root = Entity()
    /// Turns about x on the axle; the posts and base stay put.
    public let frame = Entity()
    public let sand: ModelEntity
    /// The two glass panes, front then back.
    public private(set) var panes: [ModelEntity] = []
    public let layout: FrameLayout
    private var sandMaterial: UnlitMaterial

    /// glassHeight: a real sand picture's glass is about 20 cm tall.
    public init(gridAspect: Double, sandTexture: TextureResource, glassHeight: Double = 0.2) {
        let L = FrameLayout(iw: glassHeight * gridAspect, ih: glassHeight)
        layout = L
        let f = { (x: Double) in Float(x) }

        let wood = Self.woodMaterial()
        let steel = { () -> PhysicallyBasedMaterial in
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: UIColor(white: 0.78, alpha: 1))
            m.metallic = 1.0
            m.roughness = 0.28
            return m
        }()

        // Rails (the grain runs along each; mitres are left out).
        let railH = MeshResource.generateBox(width: f(L.fw), height: f(L.b), depth: f(L.depth))
        let railV = MeshResource.generateBox(width: f(L.ih), height: f(L.b), depth: f(L.depth))
        for s: Float in [1, -1] {
            let h = ModelEntity(mesh: railH, materials: [wood])
            h.position = [0, s * f(L.fh - L.b) / 2, 0]
            frame.addChild(h)
            let v = ModelEntity(mesh: railV, materials: [wood])
            v.position = [s * f(L.fw - L.b) / 2, 0, 0]
            v.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            frame.addChild(v)
        }

        // Sand layer mid-depth; the panes either side of a gap a few mm wide,
        // as in a real frame. Seen from behind it reads upside down, as it
        // should: the grid is never rewritten on a flip.
        sandMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        sandMaterial.color = .init(tint: .white, texture: .init(sandTexture))
        sandMaterial.blending = .transparent(opacity: 1.0)
        sandMaterial.faceCulling = .none
        sand = ModelEntity(mesh: .generatePlane(width: f(L.iw), height: f(L.ih)), materials: [sandMaterial])
        frame.addChild(sand)

        let glassT = 0.002, halfGap = 0.0015
        let pane = MeshResource.generateBox(width: f(L.iw), height: f(L.ih), depth: f(glassT))
        for s: Float in [1, -1] {
            let p = ModelEntity(mesh: pane, materials: [Self.glassMaterial()])
            p.position = [0, 0, s * f(halfGap + glassT / 2)]
            frame.addChild(p)
            panes.append(p)
        }
        root.addChild(frame)

        // Steel posts from the base up past the axle, each with a pin into
        // the frame's side and a knob where it turns.
        let postTop = 0.18 * L.fh, postBottom = -L.fh / 2 - L.gap - 0.3 * L.baseh
        let post = MeshResource.generateCylinder(height: f(postTop - postBottom), radius: f(L.postw / 2))
        let cap = MeshResource.generateSphere(radius: f(L.postw / 2))
        let knob = MeshResource.generateSphere(radius: f(0.6 * L.postw))
        let pinLen = L.side - L.postw / 2 + 0.12 * L.b
        let pin = MeshResource.generateCylinder(height: f(pinLen), radius: f(0.3 * L.postw))
        for s: Float in [1, -1] {
            let x = s * f(L.tw - L.postw) / 2
            let p = ModelEntity(mesh: post, materials: [steel])
            p.position = [x, f(postTop + postBottom) / 2, 0]
            root.addChild(p)
            let c = ModelEntity(mesh: cap, materials: [steel])
            c.position = [x, f(postTop), 0]
            root.addChild(c)
            let k = ModelEntity(mesh: knob, materials: [steel])
            k.position = [x, 0, 0]
            root.addChild(k)
            let a = ModelEntity(mesh: pin, materials: [steel])
            a.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            a.position = [x - s * f(pinLen) / 2, 0, 0]
            root.addChild(a)
        }

        // Base plank the posts stand in.
        let baseW = L.tw + 0.8 * L.side
        let base = ModelEntity(mesh: .generateBox(width: f(baseW), height: f(L.baseh), depth: f(4 * L.depth),
                                                  cornerRadius: f(0.08 * L.b)), materials: [wood])
        base.position = [0, f(-L.fh / 2 - L.gap - L.baseh / 2), 0]
        root.addChild(base)
    }

    /// theta: the flip about the axle, degrees (0 upright, 180 resting
    /// flipped). The sand's face shades as it turns from the light, as the
    /// web's --shade does (the sand layer is unlit, like the web canvas).
    public func setPose(theta: Double) {
        let t = theta * .pi / 180
        frame.orientation = simd_quatf(angle: Float(t), axis: [1, 0, 0])
        let k = 1 - 0.35 * abs(sin(t))
        sandMaterial.color.tint = UIColor(white: k, alpha: 1)
        sand.model?.materials = [sandMaterial]
    }

    /// Clear glass: about 8% of the light is mirrored (4% at each of a
    /// pane's two faces, near normal incidence) and the rest passes. A smooth
    /// mirror at 8% opacity gives exactly that split; RealityKit's transparent
    /// PBR would otherwise scale a dielectric's 4% reflection down by the
    /// opacity again. The faint green is the iron in soda-lime glass.
    static func glassMaterial() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.93, green: 0.97, blue: 0.95, alpha: 1))
        m.metallic = 1.0
        m.roughness = 0.03
        m.blending = .transparent(opacity: 0.08)
        m.faceCulling = .back
        return m
    }

    /// Light wood (the web's --wood, #d8b48b) with a generated grain along u.
    static func woodMaterial() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        let tint = UIColor(red: 0xd8 / 255, green: 0xb4 / 255, blue: 0x8b / 255, alpha: 1)
        if let img = woodGrain(), let tex = try? TextureResource(image: img, options: .init(semantic: .color)) {
            m.baseColor = .init(tint: .white, texture: .init(tex))
        } else {
            m.baseColor = .init(tint: tint)
        }
        m.roughness = 0.62
        m.metallic = 0.0
        return m
    }

    /// Long, slightly wavy streaks of darker late wood over the wood colour.
    public static func woodGrain(width: Int = 1024, height: Int = 128) -> CGImage? {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        let base: SIMD3<Double> = [0xd8, 0xb4, 0x8b]
        var rng = SystemRandomNumberGenerator()
        let phases = (0..<6).map { _ in Double.random(in: 0..<(2 * .pi), using: &rng) }
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                let wave = 0.025 * sin(u * 9 + phases[0]) + 0.012 * sin(u * 23 + phases[1])
                let ring = sin((v + wave) * 2 * .pi * 3 + 0.8 * sin(u * 5 + phases[2]))
                let fine = sin((v + wave * 1.7) * 2 * .pi * 14 + phases[3])
                let k = 1 - 0.08 * pow(max(0, ring), 3) - 0.025 * fine
                let i = (y * width + x) * 4
                let c = base * k
                px[i] = UInt8(max(0, min(255, c.x)))
                px[i + 1] = UInt8(max(0, min(255, c.y)))
                px[i + 2] = UInt8(max(0, min(255, c.z)))
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
