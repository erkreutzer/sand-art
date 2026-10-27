#if os(iOS) || os(visionOS)
import Metal
import RealityKit

/// How each spot of the sand layer meets the light, for the room to light
/// it: a normal, metallic and roughness map beside the colour (same size,
/// one texel per ColourKernel texel). The web paints a glitter twinkle and
/// air rims (uGlint, uRim); here they come from real reflections of the room,
/// rendered for each eye.
///
/// - Glitter: flat metal flakes lying at random tilts among the grains. Each
///   mirrors the room in its own direction, so it flashes when a bright part
///   of the room lines up with your eye, differently for each eye and as you
///   move. Tilt up to 40° (each flake's own, from its shade, which travels
///   with it).
/// - Air pockets: water wets the glass, so a pocket's edge is a curved
///   meniscus, sloping more steeply towards the rim. Its normal leans
///   outwards by the slope of the air fraction around it. Seen from the water
///   side, beyond the critical angle (48.8° for water to air) all the light is
///   reflected: total internal reflection, the bright silver edge of a real
///   bubble. That part is a mirror; the rest a smooth water surface.
/// - Sand grains and the clear liquid: matte, facing out.
@MainActor
public final class SurfaceKernel {
    public let normal: LowLevelTexture, metallic: LowLevelTexture, roughness: LowLevelTexture
    public let normalResource: TextureResource, metallicResource: TextureResource, roughnessResource: TextureResource

    private let pipeline: MTLComputePipelineState
    private var uniforms: SIMD4<UInt32>
    private var drawn = false

    /// w x h grains, W the padded grid width, scale texels per grain.
    public init(device: MTLDevice, w: Int, h: Int, W: Int, scale: Int) throws {
        let lib = try device.makeLibrary(source: Self.source, options: nil)
        pipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "sandSurface")!)
        uniforms = SIMD4(UInt32(w), UInt32(h), UInt32(W), UInt32(scale))
        let pw = w * scale, ph = h * scale
        let make = { () throws -> LowLevelTexture in
            try LowLevelTexture(descriptor: .init(
                pixelFormat: .rgba8Unorm, width: pw, height: ph,
                mipmapLevelCount: Int(log2(Double(max(pw, ph)))) + 1,
                textureUsage: [.shaderRead, .shaderWrite]))
        }
        normal = try make()
        metallic = try make()
        roughness = try make()
        normalResource = try TextureResource(from: normal)
        metallicResource = try TextureResource(from: metallic)
        roughnessResource = try TextureResource(from: roughness)
    }

    /// The sand layer's material: the colour texture lit by the scene, with
    /// these maps. The colour's alpha keeps the clear liquid see-through.
    public func sandMaterial(colour: TextureResource) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .white, texture: .init(colour))
        m.normal = .init(texture: .init(normalResource))
        m.metallic = .init(scale: 1, texture: .init(metallicResource))
        m.roughness = .init(scale: 1, texture: .init(roughnessResource))
        m.blending = .transparent(opacity: 1.0)
        m.faceCulling = .back
        return m
    }

    /// For SandRenderer.encodeExtra: redraws the maps when the grid changed.
    public func encode(_ cb: MTLCommandBuffer, grid: MTLBuffer, gridChanged: Bool) {
        guard gridChanged || !drawn else { return }
        drawn = true
        let outs = [normal.replace(using: cb), metallic.replace(using: cb), roughness.replace(using: cb)]
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(grid, offset: 0, index: 0)
        enc.setBytes(&uniforms, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 1)
        for (i, t) in outs.enumerated() { enc.setTexture(t, index: i) }
        let tw = pipeline.threadExecutionWidth, th = pipeline.maxTotalThreadsPerThreadgroup / tw
        let o = outs[0]
        enc.dispatchThreadgroups(MTLSize(width: (o.width + tw - 1) / tw, height: (o.height + th - 1) / th, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
        let blit = cb.makeBlitCommandEncoder()!
        for t in outs { blit.generateMipmaps(for: t) }
        blit.endEncoding()
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { uint w, h, W, scale; };

    static float hash(float2 p) {
        float3 q = fract(float3(p.xyx) * 0.1031);
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    static float air(device const uint *grid, uint W, int2 g) {
        return (grid[g.y * W + g.x] & 0xff) == 1 ? 1.0 : 0.0;
    }

    // Air cells in the 3x3 block around g (walls and the padding count as not air).
    static float airAround(device const uint *grid, constant Uniforms &u, int2 g) {
        float n = 0;
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++) {
                int2 p = clamp(g + int2(dx, dy), int2(0), int2(u.w + 1, u.h + 1));
                n += air(grid, u.W, p);
            }
        return n;
    }

    kernel void sandSurface(device const uint *grid [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]],
                            texture2d<float, access::write> normalOut [[texture(0)]],
                            texture2d<float, access::write> metallicOut [[texture(1)]],
                            texture2d<float, access::write> roughnessOut [[texture(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= normalOut.get_width() || gid.y >= normalOut.get_height()) return;
        int2 g = int2(gid / u.scale) + 1;
        uint c = grid[g.y * u.W + g.x];
        uint t = c & 0xff;
        float3 n = float3(0, 0, 1);   // tangent space: x right, y up the glass, z out
        float metal = 0, rough = 0.9;

        if (t == 9) {
            // Glitter flake: its own tilt and direction, a polished metal face.
            float s = float((c >> 8) & 0xff);
            float a = hash(float2(s, 17.0)) * 6.2831853;
            float tilt = sqrt(hash(float2(s, 91.0))) * 0.6427876; // sin 40°
            n = float3(cos(a) * tilt, sin(a) * tilt, sqrt(1.0 - tilt * tilt));
            metal = 1;
            rough = 0.12;
        } else if (t == 1) {
            // Meniscus: leans away from the pocket, by how fast the air fraction
            // falls off (grid y runs down, tangent y up).
            float2 grad = float2(airAround(grid, u, g + int2(1, 0)) - airAround(grid, u, g - int2(1, 0)),
                                 airAround(grid, u, g + int2(0, 1)) - airAround(grid, u, g - int2(0, 1))) / 9.0;
            float2 lean = 3.0 * float2(-grad.x, grad.y);
            n = normalize(float3(lean, 1.0));
            // tan of the slope against tan 48.8° (critical angle, water to air) = 1.14.
            metal = smoothstep(1.0, 1.3, length(lean));
            rough = 0.06;
        } else if (t == 0) {
            rough = 1.0;
        }
        normalOut.write(float4(n * 0.5 + 0.5, 1.0), gid);
        metallicOut.write(float4(metal), gid);
        roughnessOut.write(float4(rough), gid);
    }
    """
}
#endif
