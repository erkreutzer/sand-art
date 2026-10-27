import Foundation
import os
import RealityKit
import SandKit
import UIKit

/// Materials for the frame in a real room. The iPhone's FrameModel stands in
/// for a room it can't see (a bundled light, an unlit sand layer shaded by
/// the flip angle); here the system lights everything from the real
/// surroundings, so the sand is a lit surface and the panes are real glass.
@MainActor
enum VolumeLook {
    private static let log = Logger(subsystem: "art.sand.SandArt", category: "vision")

    static func apply(to model: FrameModel, sandTexture: TextureResource) async {
        // Sand: a matte layer lit by the room, darker as it turns from the
        // light (the web's --shade, done by real light). The texture's alpha
        // keeps the clear liquid see-through. Seen from behind it shows its
        // back, mirrored, with its own normal, so it is lit as a real layer.
        var sand = PhysicallyBasedMaterial()
        sand.baseColor = .init(tint: .white, texture: .init(sandTexture))
        sand.roughness = 0.9
        sand.metallic = 0.0
        sand.blending = .transparent(opacity: 1.0)
        sand.faceCulling = .back
        let L = model.layout
        if let mesh = try? twoSidedPlane(width: Float(L.iw), height: Float(L.ih)) {
            model.sand.model = ModelComponent(mesh: mesh, materials: [sand])
        } else {
            model.sand.model?.materials = [sand]
        }

        if let glass = await glassMaterial() {
            for p in model.panes { p.model?.materials = [glass] }
            log.notice("[sand] glass: shader graph, Fresnel reflection added over the room")
        } else {
            log.error("[sand] glass shader graph failed to load; keeping the iPhone's glass")
        }

        // Wood and steel cast a soft shadow on whatever the toy stands on.
        for e in [model.root] + descendants(of: model.root) where e is ModelEntity {
            if e === model.sand || model.panes.contains(where: { $0 === e }) { continue }
            e.components.set(GroundingShadowComponent(castsShadow: true))
        }
    }

    /// The sand layer as two faces back to back, sharing the texture: the
    /// back face's normal points out of the back and its texture reads
    /// mirrored, as the back of a real sand layer does.
    static func twoSidedPlane(width: Float, height: Float) throws -> MeshResource {
        let x = width / 2, y = height / 2
        let corners: [SIMD3<Float>] = [[-x, -y, 0], [x, -y, 0], [x, y, 0], [-x, y, 0]]
        let uv: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1]]
        var d = MeshDescriptor(name: "sand")
        d.positions = MeshBuffers.Positions(corners + corners)
        d.normals = MeshBuffers.Normals(Array(repeating: [0, 0, 1], count: 4) + Array(repeating: [0, 0, -1], count: 4))
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uv + uv)
        d.primitives = .triangles([0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6])
        return try MeshResource.generate(from: [d])
    }

    /// Clear soda-lime glass. A pane mirrors about 8% of the light near
    /// normal incidence (4% at each of its two faces, n = 1.52), rising
    /// towards all of it at grazing angles (Fresnel); the rest passes,
    /// less about 1% absorbed. The back face's share has crossed the glass
    /// twice, so the reflection is very slightly green (the iron in it).
    ///
    /// RealityKit's PBR scales reflections by the opacity, which would
    /// make a clear pane nearly unreflective. With premultiplied alpha the
    /// reflection is added in full and the opacity only dims what is seen
    /// through: out = reflection + (1 - 0.09) * behind. The two faces are one
    /// Fresnel reflector with F0 = 0.08 (Schlick's form, as RealityKit uses
    /// for a metal's specular colour).
    static func glassMaterial() async -> ShaderGraphMaterial? {
        do {
            var m = try await ShaderGraphMaterial(named: "/Root/Glass", from: Data(glassUSDA.utf8))
            m.faceCulling = .back
            return m
        } catch {
            log.error("[sand] glass: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static let glassUSDA = """
    #usda 1.0
    (
        defaultPrim = "Root"
        metersPerUnit = 1
        upAxis = "Y"
    )

    def Xform "Root"
    {
        def Material "Glass"
        {
            token outputs:mtlx:surface.connect = </Root/Glass/Surface.outputs:out>
            token outputs:realitykit:vertex

            def Shader "Surface"
            {
                uniform token info:id = "ND_realitykit_pbr_surfaceshader"
                color3f inputs:baseColor = (0.077, 0.081, 0.079)
                float inputs:metallic = 1
                float inputs:roughness = 0.03
                float inputs:opacity = 0.09
                bool inputs:hasPremultipliedAlpha = 1
                token outputs:out
            }
        }
    }
    """

    private static func descendants(of e: Entity) -> [Entity] {
        e.children.flatMap { [$0] + descendants(of: $0) }
    }
}
