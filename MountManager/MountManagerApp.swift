import SwiftUI

@main
struct MountManagerApp: App {
    @StateObject private var manager = VolumeManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: menuBarIconName)
                    .symbolEffect(.pulse, isActive: manager.isLoading)
                if manager.mountedCount > 0 {
                    Text("\(manager.mountedCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIconName: String {
        if manager.isLoading {
            return "externaldrive.badge.timemachine"
        } else if manager.mountedCount > 0 {
            return "externaldrive.fill.badge.checkmark"
        } else {
            return "externaldrive"
        }
    }
}
