import SwiftUI

/// The Vision Pro app: one volume in the shared space holding the sand
/// picture on its stand at its real size. The volume stays upright (it only
/// turns to face you), so its own "down" is the room's.
@main
struct SandArtVisionApp: App {
    var body: some Scene {
        WindowGroup {
            VolumeView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: VolumeController.volumeSize.x, height: VolumeController.volumeSize.y,
                     depth: VolumeController.volumeSize.z, in: .meters)
        .windowResizability(.contentSize)
        .volumeWorldAlignment(.gravityAligned)
    }
}
