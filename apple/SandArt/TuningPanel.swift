import SandKit
import SwiftUI
import UIKit

/// The tuning panel of src/debug.js: a slider for every physics setting,
/// defaults from core/params.json, applied through the core's `tune`. Tweaks
/// are remembered (UserDefaults "sand.tuning", the "Copy settings" shape)
/// until reset. The flow overlay is not ported.
@MainActor
@Observable
final class Tuning {
    struct Item: Identifiable {
        let key: String, label: String, min: Double, max: Double
        /// nil: logarithmic.
        let step: Double?
        var id: String { key }
    }

    struct Group: Identifiable {
        let title: String, key: String
        var open = false
        let items: [Item]
        var id: String { title }
    }

    // [key, label, min, max, step | log], as GROUPS in src/debug.js.
    static let groups: [Group] = [
        Group(title: "Look", key: "render", open: true, items: [
            Item(key: "liquidTint", label: "Liquid opacity (× palette)", min: 0, max: 4, step: 0.05),
        ]),
        Group(title: "Liquid", key: "fluid", open: true, items: [
            Item(key: "vorticity", label: "Swirl (vorticity)", min: 0, max: 3, step: 0.01),
            Item(key: "sandWeight", label: "Sand drags liquid", min: 0, max: 6, step: 0.05),
            Item(key: "airLift", label: "Bubbles lift liquid", min: 0, max: 3, step: 0.05),
            Item(key: "damping", label: "Viscosity", min: 0.001, max: 0.1, step: nil),
            Item(key: "maxSpeed", label: "Max flow speed", min: 0.5, max: 6, step: 0.1),
            Item(key: "iterations", label: "Pressure iterations", min: 4, max: 40, step: 1),
        ]),
        Group(title: "Grains", key: "sim", items: [
            Item(key: "fallSeconds", label: "Sink time, full height (s)", min: 1, max: 12, step: 0.1),
            Item(key: "jitter", label: "Random wander", min: 0, max: 0.5, step: 0.01),
            Item(key: "slide", label: "Rolling while moving", min: 0, max: 1, step: 0.01),
            Item(key: "slideRest", label: "Steep faces collapse", min: 0.001, max: 0.3, step: nil),
        ]),
        Group(title: "Hanging sand", key: "sim", items: [
            Item(key: "flat", label: "Lets go: flat underside", min: 1e-4, max: 0.3, step: nil),
            Item(key: "tip", label: "Lets go: points", min: 1e-4, max: 0.5, step: nil),
            Item(key: "narrow", label: "Lets go: narrow gaps", min: 1e-4, max: 0.5, step: nil),
            Item(key: "hole", label: "Lets go: one-wide holes", min: 1e-4, max: 0.5, step: nil),
            Item(key: "slideWall", label: "Cavity walls collapse", min: 1e-5, max: 0.1, step: nil),
        ]),
        Group(title: "Air barrier", key: "sim", items: [
            Item(key: "thinAir", label: "Leak through thin air", min: 1e-4, max: 0.3, step: nil),
            Item(key: "leakFalloff", label: "Leak kept per extra cell", min: 0.05, max: 0.95, step: 0.01),
            Item(key: "thickAir", label: "Leak through deep air", min: 1e-6, max: 1e-2, step: nil),
            Item(key: "bubbleDepth", label: "Bubble min depth (cells)", min: 1, max: 16, step: 1),
            Item(key: "riseSeconds", label: "Bubble rise time (s)", min: 0.2, max: 5, step: 0.05),
            Item(key: "airSpread", label: "Air spreads sideways", min: 0, max: 1, step: 0.01),
            Item(key: "seep", label: "Air seeps up through sand", min: 1e-6, max: 1e-2, step: nil),
        ]),
        Group(title: "New sand (applies on New sand)", key: "seed", items: [
            Item(key: "air", label: "Air amount", min: 5e-4, max: 0.03, step: nil),
            Item(key: "sand", label: "Sand level", min: 0.15, max: 0.6, step: 0.01),
        ]),
        Group(title: "Simulation", key: "engine", open: true, items: [
            Item(key: "timeScale", label: "Speed", min: 0.1, max: 4, step: nil),
        ]),
    ]

    private static let store = "sand.tuning"
    /// What the core and the renderer start with.
    let defaults: [String: [String: Double]]
    private(set) var values: [String: [String: Double]]
    /// Only the settings that differ from the defaults, as the web keeps them.
    private(set) var overrides: [String: [String: Double]]
    var paused = false { didSet { controller.paused = paused } }

    private let controller: SceneController

    init(controller: SceneController) {
        self.controller = controller
        var d = Params.defaults
        d["render"] = ["liquidTint": 1] // renderParams in src/render.js
        defaults = d
        var saved: [String: [String: Double]] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.store),
           let o = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            // Keep only settings the panel knows, as pick() in src/debug.js.
            for g in Self.groups {
                for it in g.items { if let v = o[g.key]?[it.key] { saved[g.key, default: [:]][it.key] = v } }
            }
        }
        overrides = saved
        var v = d
        for (g, kv) in saved { for (k, x) in kv { v[g, default: [:]][k] = x } }
        values = v
        if !saved.isEmpty { apply(saved) }
    }

    func value(_ group: String, _ key: String) -> Double { values[group]?[key] ?? 0 }
    func isChanged(_ group: String, _ key: String) -> Bool { value(group, key) != defaults[group]?[key] }

    func set(_ group: String, _ item: Item, _ raw: Double) {
        let v = item.step == 1 ? raw.rounded() : raw
        values[group, default: [:]][item.key] = v
        if v == defaults[group]?[item.key] {
            overrides[group]?[item.key] = nil
            if overrides[group]?.isEmpty == true { overrides[group] = nil }
        } else {
            overrides[group, default: [:]][item.key] = v
        }
        save()
        apply([group: [item.key: v]])
    }

    func reset(_ group: String, _ item: Item) {
        if let d = defaults[group]?[item.key] { set(group, item, d) }
    }

    func resetAll() {
        overrides = [:]
        values = defaults
        save()
        apply(defaults)
    }

    /// Pretty JSON of the overrides, as "Copy settings".
    var settingsJSON: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(overrides)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func newSand() { controller.reseed() }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: Self.store) }
    }

    /// The core takes everything but "render", which is the host's.
    private func apply(_ settings: [String: [String: Double]]) {
        if let t = settings["render"]?["liquidTint"] { controller.renderer.liquidTint = Float(t) }
        var physics = settings
        physics["render"] = nil
        guard !physics.isEmpty, let data = try? JSONEncoder().encode(physics),
              let json = String(data: data, encoding: .utf8) else { return }
        controller.engine.tune(json: json)
    }
}

/// The panel itself: stats, pause, the groups of sliders, and the footer's
/// New sand / Copy settings / Reset all. Double-tap a label to reset it.
struct TuningPanel: View {
    @Bindable var tuning: Tuning
    let controller: SceneController
    /// Beside the picture (unfolded), the palette swatches live here too.
    var showPalette = false
    var onClose: (() -> Void)?
    @State private var open: Set<String> = Set(Tuning.groups.filter(\.open).map(\.title))
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tuning").font(.headline)
                Spacer()
                if let onClose {
                    Button("Close", systemImage: "xmark", action: onClose)
                        .labelStyle(.iconOnly)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            if showPalette { PalettePicker().padding(.bottom, 10) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(stats).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Toggle("Pause", isOn: $tuning.paused).font(.subheadline)
                    ForEach(Tuning.groups) { g in
                        DisclosureGroup(isExpanded: Binding(
                            get: { open.contains(g.title) },
                            set: { if $0 { open.insert(g.title) } else { open.remove(g.title) } })) {
                            VStack(spacing: 10) {
                                ForEach(g.items) { it in row(g, it) }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text(g.title).font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Button("New sand") { tuning.newSand() }
                Spacer()
                Button(copied ? "Copied" : "Copy settings") {
                    UIPasteboard.general.string = tuning.settingsJSON
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                }
                Spacer()
                Button("Reset all", role: .destructive) { tuning.resetAll() }
            }
            .font(.subheadline)
            .padding()
        }
    }

    private func row(_ g: Tuning.Group, _ it: Tuning.Item) -> some View {
        let log = it.step == nil
        let toSlider = { (v: Double) in log ? log10(max(v, it.min)) : v }
        let fromSlider = { (s: Double) in log ? pow(10, s) : s }
        let v = tuning.value(g.key, it.key)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(it.label)
                    .fontWeight(tuning.isChanged(g.key, it.key) ? .semibold : .regular)
                    .onTapGesture(count: 2) { tuning.reset(g.key, it) }
                Spacer()
                Text(Self.format(v)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: Binding(get: { toSlider(v) }, set: { tuning.set(g.key, it, fromSlider($0)) }),
                   in: toSlider(it.min)...toSlider(it.max))
                .accessibilityLabel(it.label)
        }
    }

    private var stats: String {
        let s = controller.engine.stats, g = controller.grid
        return String(format: "%d×%d grains @%dpx · %.2fM\nphysics %.1f ms (%d ticks)%@",
                      g.w, g.h, g.scale, Double(g.w * g.h) / 1e6, s.coreMs, s.ticks,
                      tuning.paused ? " · paused" : "")
    }

    /// fmt() in src/debug.js.
    static func format(_ v: Double) -> String {
        if abs(v) >= 100 || v == v.rounded() { return String(format: "%g", (v * 100).rounded() / 100) }
        if abs(v) >= 0.01 {
            var s = String(format: "%.3f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return String(format: "%.2g", v)
    }
}
