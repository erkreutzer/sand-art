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

    static func apply(to model: FrameModel, sandTexture: TextureResource, surface: SurfaceKernel) async {
        // Sand: a layer lit by the room, darker as it turns from the light
        // (the web's --shade, done by real light); glitter and air pockets
        // reflect the room (SurfaceKernel). The texture's alpha keeps the
        // clear liquid see-through. Seen from behind it shows its back,
        // mirrored, with its own normal, so it is lit as a real layer.
        model.useLitSand(surface.sandMaterial(colour: sandTexture))

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
