import Metal

/// Turns the grid into colour: a Metal compute port of the fragment shader in
/// src/render.js (tools/compare/kernel.html checks it against the original).
/// Colours are worked out in sRGB as on the web and stored linear (half
/// float), with the liquid's alpha straight (not premultiplied). The web
/// composites the liquid over the page in sRGB; RealityKit blends linear
/// light, so the alpha is converted to give the web's result over the
/// backdrop (`backdrop`, its typical sRGB brightness).
public final class ColourKernel {
    public static let pixelFormat = MTLPixelFormat.rgba16Float

    private let pipeline: MTLComputePipelineState
    private var palette = [SIMD4<Float>](repeating: .zero, count: 8)
    private var uniforms = Uniforms()

    public var liquidTint: Float = 1 { didSet { applyLiquid() } }
    public var backdrop: Float = 0.9 { didSet { applyLiquid() } }
    /// How much of the web's painted glitter twinkle and air rims to draw
    /// (1, as the web). Vision Pro sets 0: there the room's real light makes
    /// them (SurfaceKernel in the app).
    public var highlights: Float {
        get { uniforms.highlights }
        set { uniforms.highlights = newValue }
    }
    private var liquidAlpha: Float = 1, liquidColour: Float = 1

    struct Uniforms {
        var liquidTop = SIMD4<Float>(), liquidBot = SIMD4<Float>(), air = SIMD4<Float>(), rim = SIMD4<Float>()
        var size = SIMD2<UInt32>() // grains (w, h)
        var W: UInt32 = 0 // padded grid width
        var scale: UInt32 = 1
        var glint: Float = 0
        var liquidAlpha: Float = 1
        var highlights: Float = 1
    }

    /// w x h grains, W the padded grid width, scale texels per grain.
    public init(device: MTLDevice, w: Int, h: Int, W: Int, scale: Int) throws {
        let lib = try device.makeLibrary(source: Self.source, options: nil)
        pipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "sandColour")!)
        uniforms.size = SIMD2(UInt32(w), UInt32(h))
        uniforms.W = UInt32(W)
        uniforms.scale = UInt32(scale)
    }

    public func setPalette(_ p: Palette) {
        for (i, h) in p.sand.enumerated() { palette[i] = SIMD4(Palette.rgb(h), 1) }
        palette[6] = SIMD4(Palette.rgb(p.glitter), 0) // alpha 0 marks glitter
        uniforms.liquidTop = SIMD4(Palette.rgb(p.liquid[0]), 0)
        uniforms.liquidBot = SIMD4(Palette.rgb(p.liquid[1]), 0)
        uniforms.air = SIMD4(Palette.rgb(p.air), 0)
        uniforms.rim = SIMD4(Palette.rgb(p.rim), 0)
        liquidAlpha = p.liquidAlpha
        let l = (Palette.rgb(p.liquid[0]) + Palette.rgb(p.liquid[1])) / 2
        liquidColour = (l.x + l.y + l.z) / 3
        applyLiquid()
    }

    private func applyLiquid() {
        let a = min(1, max(0, liquidAlpha * liquidTint))
        // Solve linear((1-a) bg + a c) = (1-a') linear(bg) + a' linear(c).
        let lin = { (v: Float) in v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let bg = lin(backdrop), c = lin(liquidColour), web = lin((1 - a) * backdrop + a * liquidColour)
        uniforms.liquidAlpha = abs(c - bg) < 1e-3 ? a : min(1, max(0, (web - bg) / (c - bg)))
    }

    /// Writes the whole of `out` (w * scale x h * scale) from the grid buffer
    /// (W x H cells of RGBA8, as the core lays them out).
    public func encode(_ cb: MTLCommandBuffer, grid: MTLBuffer, glint: Float, into out: MTLTexture) {
        uniforms.glint = glint
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(grid, offset: 0, index: 0)
        enc.setBytes(palette, length: 8 * MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        enc.setTexture(out, index: 0)
        let tw = pipeline.threadExecutionWidth, th = pipeline.maxTotalThreadsPerThreadgroup / tw
        enc.dispatchThreadgroups(MTLSize(width: (out.width + tw - 1) / tw, height: (out.height + th - 1) / th, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 liquidTop, liquidBot, air, rim;
        uint2 size;      // grains (w, h)
        uint W;          // padded grid width
        uint scale;      // texels per grain
        float glint;
        float liquidAlpha;   // the liquid is see-through; sand and air are not
        float highlights;    // painted twinkle and rims: 1 as the web, 0 where real light does them
    };

    static float hash(float2 p) {
        float3 q = fract(float3(p.xyx) * 0.1031);
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    static float3 toLinear(float3 c) {
        return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    }

    kernel void sandColour(device const uint *grid [[buffer(0)]],
                           constant float4 *pal [[buffer(1)]],
                           constant Uniforms &u [[buffer(2)]],
                           texture2d<float, access::write> out [[texture(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint pw = out.get_width(), ph = out.get_height();
        if (gid.x >= pw || gid.y >= ph) return;
        // As gl_FragCoord in the WebGL shader (y up), for the same noise.
        float2 fc = float2(gid.x, ph - 1 - gid.y);
        int2 cell = int2(gid / u.scale);
        int2 g = cell + 1;
        uint W = u.W;
        uint c = grid[g.y * W + g.x];
        uint t = c & 0xff;
        float2 uv = (float2(cell) + 0.5) / float2(u.size);
        float n = hash(fc);
        float3 col;

        if (t >= 3) {
            float4 p = pal[min(t - 3, 7u)];
            float s = float((c >> 8) & 0xff) / 255.0;
            col = p.rgb * (0.80 + 0.34 * s);
            col *= 0.94 + 0.10 * n;
            if (p.a < 0.5) {
                // Glitter flake: twinkles as the frame turns.
                float tw = pow(max(0.0, sin(s * 97.0 + u.glint * (1.0 + s * 3.0))), 24.0);
                col = mix(col, float3(1.0, 0.98, 0.9), tw * 0.85 * u.highlights);
            }
        } else if (t == 1) {
            // Air: silvery, with a soft meniscus only where a pocket has some
            // depth, so a one-cell film reads as a fine bright seam.
            uint up = grid[(g.y - 1) * W + g.x] & 0xff, dn = grid[(g.y + 1) * W + g.x] & 0xff;
            uint lf = grid[g.y * W + g.x - 1] & 0xff, rt = grid[g.y * W + g.x + 1] & 0xff;
            int nAir = int(up == 1) + int(dn == 1) + int(lf == 1) + int(rt == 1);
            bool edge = up == 0 || dn == 0 || lf == 0 || rt == 0;
            col = u.air.rgb * (0.97 + 0.05 * n);
            if (edge && nAir >= 2 && (up == 1 || dn == 1)) col = mix(col, u.rim.rgb, 0.55 * u.highlights);
        } else {
            // Clear liquid: a faint tint over whatever is behind the frame.
            col = mix(u.liquidTop.rgb, u.liquidBot.rgb, uv.y) * (0.985 + 0.02 * n);
            out.write(float4(toLinear(col), u.liquidAlpha), gid);
            return;
        }
        out.write(float4(toLinear(col), 1.0), gid);
    }
    """
}
