import SwiftUI

@main
struct MountManagerApp: App {
    @StateObject private var manager = VolumeManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
        } label: {
            Image(systemName: manager.hostVolumes.values.flatMap({ $0 }).contains(where: { $0.isMounted })
                  ? "externaldrive.fill.badge.checkmark"
                  : "externaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}
