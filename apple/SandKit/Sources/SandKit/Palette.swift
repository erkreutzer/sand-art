import Foundation
import simd

/// Six sand colours + a glitter colour, plus the liquid and air the sand sits
/// in, from core/palettes.json (shared with the web). liquidAlpha: how much
/// the liquid tints what's behind the glass (0 = water-clear).
public struct Palette: Decodable, Identifiable, Hashable, Sendable {
    public let name: String
    public let sand: [String]
    public let glitter: String
    public let liquid: [String]
    public let liquidAlpha: Float
    public let air: String
    public let rim: String

    public var id: String { name }

    public static let all: [Palette] = {
        let url = Bundle.module.url(forResource: "palettes", withExtension: "json")!
        return try! JSONDecoder().decode([Palette].self, from: Data(contentsOf: url))
    }()

    /// "#rrggbb" as sRGB components in 0...1.
    public static func rgb(_ hex: String) -> SIMD3<Float> {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return SIMD3(Float(v >> 16 & 0xff), Float(v >> 8 & 0xff), Float(v & 0xff)) / 255
    }
}

/// The core's default settings (core/params.json, the "Copy settings" shape);
/// the core embeds the same file, so these are for display and tuning only.
public enum Params {
    public static let defaults: [String: [String: Double]] = {
        let url = Bundle.module.url(forResource: "params", withExtension: "json")!
        return try! JSONDecoder().decode([String: [String: Double]].self, from: Data(contentsOf: url))
    }()
}
