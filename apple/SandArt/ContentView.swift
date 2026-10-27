import RealityKit
import SandKit
import SwiftUI

struct ContentView: View {
    @Environment(SandModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    /// `-openTuning 1` opens it at launch (a test hook: the simulator can't tap).
    @State private var showTuning = UserDefaults.standard.bool(forKey: "openTuning")
    /// Where the layout puts the picture, in the root's space.
    @State private var picture = CGRect.zero

    var body: some View {
        GeometryReader { geo in
            let fold = app.fold(in: geo)
            let posture = app.posture(fold: fold)
            // One picture view whatever the posture, so its RealityView is
            // never rebuilt: each layout leaves a slot, and the picture is
            // placed over it. The palette sits on top of the picture.
            layout(posture, fold: fold ?? .zero, size: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
                // Overlays, so the picture's own size never feeds back into
                // the layout that places it.
                .overlay(alignment: .topLeading) {
                    PictureView()
                        .frame(width: picture.width, height: picture.height)
                        .offset(x: picture.minX, y: picture.minY)
                }
                .overlay(alignment: .topLeading) {
                    if posture == .flat {
                        controls(tune: true)
                            .padding(.bottom, 8)
                            .frame(width: picture.width, height: picture.height, alignment: .bottom)
                            .offset(x: picture.minX, y: picture.minY)
                    }
                }
                .coordinateSpace(.named("root"))
                .onChange(of: posture, initial: true) { app.update(posture: posture) }
                .onChange(of: app.hinge) { app.update(posture: posture) }
                .onChange(of: geo.size) {
                    app.updateScreenAngle()
                    app.note(String(format: "[sand] window %.0fx%.0f pt", geo.size.width, geo.size.height))
                }
        }
        .ignoresSafeArea()
        .background(colorScheme == .dark ? Color(white: 0.1) : Color(red: 0.91, green: 0.9, blue: 0.88))
        .statusBarHidden()
        .modifier(HingeObserver { app.hingeChanged($0) })
        .sheet(isPresented: $showTuning) {
            if let t = app.tuning, let c = app.controller {
                TuningPanel(tuning: t, controller: c) { showTuning = false }
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }

    /// The space the picture takes in a layout; reports its frame.
    private var slot: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { picture = $0 }
    }

    @ViewBuilder
    private func layout(_ posture: Posture, fold: CGRect, size: CGSize) -> some View {
        switch posture {
        case .flat:
            slot
        case .unfolded:
            // Open flat: the picture and the tuning panel either side of the fold.
            let panel = Group {
                if let t = app.tuning, let c = app.controller {
                    TuningPanel(tuning: t, controller: c, showPalette: true).background(.thinMaterial)
                }
            }
            if #available(iOS 27.1, *) {
                ArrangementView {
                    slot.avoidingFold()
                } secondary: {
                    panel.avoidingFold()
                }
                .arrangementViewStyle(.split)
            } else {
                HStack(spacing: 0) { slot; panel.frame(maxWidth: 360) }
            }
        case .tent:
            // Standing as a tent, the fold across the display: the picture on
            // the upright half above it, the wooden base with the controls below.
            VStack(spacing: 0) {
                slot.frame(height: max(1, fold.minY))
                Color.clear.frame(height: fold.height)
                StandBase(showTuning: $showTuning).frame(height: max(1, size.height - fold.maxY))
            }
        }
    }

    /// Palette swatches, and the button that opens the tuning panel.
    private func controls(tune: Bool) -> some View {
        HStack(spacing: 10) {
            PalettePicker()
            if tune {
                Button { showTuning = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tuning")
            }
        }
    }
}

/// The RealityView with the frame, sized by whatever space the layout gives
/// it; the scene is built once and refitted on every size change.
struct PictureView: View {
    @Environment(SandModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragMode: DragMode?
    /// Shown until the first touch, once per install, as the web's hint
    /// (`-hint 1` shows it again).
    @AppStorage("sand.hinted") private var hinted = false

    enum DragMode { case flip, turn }

    var body: some View {
        GeometryReader { geo in
            if let controller = app.controller {
                RealityView { content in
                    await controller.install(in: &content, viewSize: geo.size, dark: colorScheme == .dark)
                }
                .gesture(flipGesture(controller))
                .onChange(of: geo.size) { controller.resize(viewSize: geo.size) }
                .overlay(alignment: .bottom) {
                    Text("Tap to flip · drag to turn · tilt to pour")
                        .font(.subheadline)
                        .tracking(0.3)
                        .foregroundStyle(colorScheme == .dark ? Color(white: 0.85) : Color(white: 0.2))
                        .opacity(hinted ? 0 : 0.8)
                        .animation(.easeInOut(duration: 1.2).delay(1.5), value: hinted)
                        .padding(.bottom, 132)
                        .allowsHitTesting(false)
                }
                .onAppear { if UserDefaults.standard.bool(forKey: "hint") { hinted = false } }
            } else {
                Color.clear.task(id: geo.size) {
                    // A hinged phone gets a landscape frame, so wait (briefly)
                    // for the hinge's first state before sizing the grid.
                    guard geo.size.width > 0 else { return }
                    for _ in 0..<15 where !app.hingeKnown {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    app.makeController(viewSize: geo.size, pixelsPerPoint: displayScale)
                }
            }
        }
    }

    /// Tap to flip; drag up or down to flip by hand, sideways to turn the
    /// toy about its middle (src/app.js).
    private func flipGesture(_ c: SceneController) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let t = v.translation
                if dragMode == nil, hypot(t.width, t.height) > 8 {
                    dragMode = abs(t.height) > abs(t.width) * 1.2 ? .flip : .turn
                    hinted = true
                }
                switch dragMode {
                case .flip: c.dragChanged(y: v.location.y)
                case .turn: c.turnChanged(start: v.startLocation, at: v.location)
                case nil: break
                }
            }
            .onEnded { _ in
                switch dragMode {
                case nil: c.flip()
                case .flip: c.dragEnded()
                case .turn: c.turnEnded()
                }
                dragMode = nil
                hinted = true
            }
    }
}

/// The tent's flat half: the wooden base the frame stands on, carrying the
/// palette swatches, a flip button and the tuning button.
struct StandBase: View {
    @Environment(SandModel.self) private var app
    @Binding var showTuning: Bool
    /// A board seen from above: the grain runs along it.
    private static let wood: CGImage? = FrameModel.woodGrain(width: 1024, height: 320)

    var body: some View {
        VStack(spacing: 16) {
            PalettePicker()
            HStack(spacing: 14) {
                Button {
                    app.controller?.flip()
                    UserDefaults.standard.set(true, forKey: "sand.hinted")
                } label: {
                    Label("Flip", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Button { showTuning = true } label: {
                    Label("Tuning", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                if let img = Self.wood {
                    Image(decorative: img, scale: 1).resizable().scaledToFill()
                } else {
                    Color(red: 0xd8 / 255, green: 0xb4 / 255, blue: 0x8b / 255)
                }
                // The edge nearest the fold catches less light.
                LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
            }
        }
        .clipped()
    }
}

/// onHingeChange where the system has it (iOS 27.1): the hinge's state, nil
/// on phones without one.
struct HingeObserver: ViewModifier {
    let onChange: (HingeReading?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in onChange(new.hinge.map(HingeReading.init)) }
        } else {
            content.onAppear { onChange(nil) }
        }
    }
}

extension View {
    /// Keeps content off the fold: insets the edge a division region
    /// (reservedRegions(kind: .division)) crosses or touches.
    func avoidingFold() -> some View {
        modifier(AvoidFold())
    }
}

struct AvoidFold: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            GeometryReader { geo in
                content.padding(Self.insets(geo.reservedRegions(kind: .division).filter(\.isActive).map(\.frame), geo.size))
            }
        } else {
            content
        }
    }

    static func insets(_ folds: [CGRect], _ size: CGSize) -> EdgeInsets {
        var e = EdgeInsets()
        let bounds = CGRect(origin: .zero, size: size)
        for f in folds where f.intersects(bounds.insetBy(dx: -1, dy: -1)) {
            if f.height >= f.width { // a vertical fold
                if f.midX < size.width / 2 { e.leading = max(e.leading, f.maxX) } else { e.trailing = max(e.trailing, size.width - f.minX) }
            } else {
                if f.midY < size.height / 2 { e.top = max(e.top, f.maxY) } else { e.bottom = max(e.bottom, size.height - f.minY) }
            }
        }
        return e
    }
}

/// Swatches of each palette's six sand colours, as the web's nav.
struct PalettePicker: View {
    @Environment(SandModel.self) private var app

    var body: some View {
        let selection = app.palette
        HStack(spacing: 10) {
            ForEach(Array(Palette.all.enumerated()), id: \.offset) { i, p in
                Button {
                    app.setPalette(i)
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
