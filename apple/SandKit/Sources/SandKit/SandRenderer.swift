import Metal
import RealityKit

/// Shows the grid in RealityKit: ColourKernel writes it into a
/// LowLevelTexture (one texel per device pixel of the glass, each grain
/// `scale` texels square, as the web canvas has), plus mipmaps for when the
/// frame turns away; `resource` goes into the sand layer's material.
@MainActor
public final class SandRenderer {
    public let texture: LowLevelTexture
    public let resource: TextureResource
    public let scale: Int
    public let kernel: ColourKernel

    private let engine: SandEngine
    private let queue: MTLCommandQueue
    private var pending = true

    public init(engine: SandEngine, device: MTLDevice, scale: Int) throws {
        self.engine = engine
        self.scale = scale
        queue = device.makeCommandQueue()!
        kernel = try ColourKernel(device: device, w: engine.w, h: engine.h, W: engine.W, scale: scale)
        let pw = engine.w * scale, ph = engine.h * scale
        texture = try LowLevelTexture(descriptor: .init(
            pixelFormat: ColourKernel.pixelFormat, width: pw, height: ph,
            mipmapLevelCount: Int(log2(Double(max(pw, ph)))) + 1,
            textureUsage: [.shaderRead, .shaderWrite]))
        resource = try TextureResource(from: texture)
    }

    public func setPalette(_ p: Palette) {
        kernel.setPalette(p)
        pending = true
    }

    /// liquidTint scales each palette's own liquid opacity (renderParams in
    /// src/render.js); backdrop: see ColourKernel.
    public var liquidTint: Float {
        get { kernel.liquidTint }
        set { kernel.liquidTint = newValue; pending = true }
    }

    public var backdrop: Float {
        get { kernel.backdrop }
        set { kernel.backdrop = newValue; pending = true }
    }

    /// Redraws if the grid changed, the pose changed (glitter twinkles as the
    /// frame turns) or the look did. Never waits: if the engine is copying
    /// rows in, it tries again next frame.
    public func draw(glint: Float, poseChanged: Bool) {
        pending = pending || poseChanged
        guard engine.gridLock.wait(timeout: .now()) == .success else { return }
        let changed = engine.takeChanged()
        guard pending || changed else {
            engine.gridLock.signal()
            return
        }
        pending = false

        let cb = queue.makeCommandBuffer()!
        let out = texture.replace(using: cb)
        kernel.encode(cb, grid: engine.grid, glint: glint, into: out)
        let blit = cb.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: out)
        blit.endEncoding()
        let lock = engine.gridLock
        cb.addCompletedHandler { _ in lock.signal() }
        cb.commit()
    }
}
