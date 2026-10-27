import RealityKit
import SandKit
import SwiftUI

struct VolumeView: View {
    @State private var controller = VolumeController.make()
    @State private var palette = 0
    @PhysicalMetric(from: .meters) private var metre = 1.0

    var body: some View {
        if let controller {
            let size = VolumeController.volumeSize
            GeometryReader3D { proxy in
                RealityView { content in
                    await controller.install(in: &content)
                }
                .gesture(spinGesture(controller))
                .onChange(of: proxy.size, initial: true) { _, s in
                    controller.fit(to: SIMD3(Double(s.width), Double(s.height), Double(s.depth)) / metre)
                }
            }
            // Opens at the real size; drag the corner to make it from half to
            // twice that, and the toy scales with it.
            .frame(minWidth: size.x * metre / 2, idealWidth: size.x * metre, maxWidth: size.x * metre * 2,
                   minHeight: size.y * metre / 2, idealHeight: size.y * metre, maxHeight: size.y * metre * 2)
            .frame(minDepth: size.z * metre / 2, idealDepth: size.z * metre, maxDepth: size.z * metre * 2)
            // The system's volume toolbar, which it lays out clear of the
            // window bar (an ornament at the bottom front sat on top of it).
            .toolbar {
                ToolbarItemGroup(placement: .bottomOrnament) {
                    Controls(palette: $palette) { controller.setPalette(Palette.all[$0]) } flip: { controller.flip() }
                }
            }
            .volumeBaseplateVisibility(.visible)
            .onAppear { palette = controller.paletteIndex }
        } else {
            Text("This device has no Metal GPU.")
        }
    }

    /// Pinch the frame and move your hand: it turns on its axle with you, and
    /// on release settles on the nearer side, carried by the swing. A pinch
    /// without moving flips it, as a tap does on the web.
    private func spinGesture(_ c: VolumeController) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .targetedToAnyEntity()
            .onChanged { v in
                guard c.isOnFrame(v.entity) else { return }
                c.spinChanged(at: v.convert(v.location3D, from: .local, to: c.axleSpace))
            }
            .onEnded { _ in c.spinEnded() }
    }
}

/// Below the volume: each palette's six sand colours (as the web's nav) and
/// a flip button.
struct Controls: View {
    @Binding var palette: Int
    var onPick: (Int) -> Void
    var flip: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(Palette.all.enumerated()), id: \.offset) { i, p in
                Button {
                    palette = i
                    onPick(i)
                } label: {
                    Circle()
                        .fill(AngularGradient(stops: p.sand.enumerated().flatMap { k, h in
                            let c = Palette.rgb(h)
                            let col = Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                            return [Gradient.Stop(color: col, location: Double(k) / 6),
                                    .init(color: col, location: Double(k + 1) / 6)]
                        }, center: .center))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: palette == i ? 2.5 : 0))
                        .padding(7)
                        .contentShape(.hoverEffect, Circle())
                        .hoverEffect()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.name)
            }
            Divider().frame(height: 30)
            Button(action: flip) {
                Label("Flip", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            }
        }
    }
}
