import RealityKit
import SandKit
import SwiftUI

struct ContentView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller: SceneController?
    @State private var palette = 0
    @State private var dragMode: DragMode?

    enum DragMode { case flip, other }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Sized from the whole screen, as the web's innerWidth/innerHeight.
            GeometryReader { geo in
                if let controller {
                    RealityView { content in
                        await controller.install(in: &content, viewSize: geo.size, dark: colorScheme == .dark)
                    }
                    .gesture(flipGesture(controller))
                } else {
                    Color.clear.onAppear {
                        // The grid is sized once from the first layout, as on the web.
                        controller = try? SceneController(viewSize: geo.size, pixelsPerPoint: displayScale)
                        palette = controller?.paletteIndex ?? 0
                    }
                }
            }
            .ignoresSafeArea()
            if let controller {
                PalettePicker(selection: $palette) { controller.setPalette(Palette.all[$0]) }
                    .padding(.bottom, 8)
            }
        }
        .background(colorScheme == .dark ? Color(white: 0.1) : Color(red: 0.91, green: 0.9, blue: 0.88))
        .statusBarHidden()
    }

    /// Tap to flip; drag up or down to flip by hand (src/app.js).
    private func flipGesture(_ c: SceneController) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let t = v.translation
                if dragMode == nil, hypot(t.width, t.height) > 8 {
                    dragMode = abs(t.height) > abs(t.width) * 1.2 ? .flip : .other
                }
                if dragMode == .flip { c.dragChanged(y: v.location.y) }
            }
            .onEnded { _ in
                switch dragMode {
                case nil: c.flip()
                case .flip: c.dragEnded()
                case .other: break
                }
                dragMode = nil
            }
    }
}

/// Swatches of each palette's six sand colours, as the web's nav.
struct PalettePicker: View {
    @Binding var selection: Int
    var onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(Palette.all.enumerated()), id: \.offset) { i, p in
                Button {
                    selection = i
                    onPick(i)
                } label: {
                    Circle()
                        .fill(AngularGradient(stops: p.sand.enumerated().flatMap { k, h in
                            let c = Palette.rgb(h)
                            let col = Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                            return [Gradient.Stop(color: col, location: Double(k) / 6), .init(color: col, location: Double(k + 1) / 6)]
                        }, center: .center))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: selection == i ? 2.5 : 0))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .scaleEffect(selection == i ? 1.12 : 1)
                }
                .accessibilityLabel(p.name)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
