import SwiftUI

struct MenuBarView: View {
    @ObservedObject var manager: VolumeManager
    @State private var newRemotePath: String = ""
    @State private var newMountPoint: String = ""
    @State private var showQuitAlert = false
    @State private var showSettings = false

    /// Hosts that have at least one volume configured
    private var hostsWithVolumes: [SSHHost] {
        manager.hosts.filter { manager.hostVolumes[$0.name]?.isEmpty == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MountManager")
                .font(.headline)
                .padding(.bottom, 4)

            // Show all hosts that have volumes, grouped by host
            ForEach(hostsWithVolumes) { host in
                let vols = manager.hostVolumes[host.name] ?? []
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.displayName)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    ForEach(vols) { volume in
                        VolumeRow(volume: volume, hostName: host.name, manager: manager)
                    }
                }
                Divider()
            }

            // Host picker for adding new volumes
            HStack {
                Text("Add to:")
                    .foregroundColor(.secondary)
                Picker("", selection: $manager.selectedHost) {
                    Text("Select a host...").tag(nil as SSHHost?)
                    ForEach(manager.hosts) { host in
                        Text(host.displayName).tag(host as SSHHost?)
                    }
                }
                .labelsHidden()
            }

            if manager.selectedHost != nil {
                SecureField("Password (optional)", text: $manager.password)
                    .textFieldStyle(.roundedBorder)

                VStack(spacing: 4) {
                    TextField("Remote path, e.g. /storage5", text: $newRemotePath)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: newRemotePath) { _, newValue in
                            newMountPoint = manager.defaultMountPoint(remotePath: newValue)
                        }
                    HStack {
                        TextField("Mount point", text: $newMountPoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button(action: addVolume) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newRemotePath.isEmpty)
                        .buttonStyle(.borderless)
                    }
                }

            }

            if !hostsWithVolumes.isEmpty {
                Divider()
                HStack {
                    Button("Mount All") { Task { await manager.mountEverything() } }
                    Spacer()
                    Button("Unmount All") { Task { await manager.unmountEverything() } }
                }
            }

            if let error = manager.lastError {
                Divider()
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .lineLimit(3)
            }

            Divider()
            DisclosureGroup("Settings", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mount point template:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("/Volumes/{host}/{path}", text: $manager.mountTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Text("Placeholders: {host} {user} {hostname} {path}")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }

            Divider()
            Button("Quit") {
                let hasMounted = manager.hostVolumes.values.flatMap({ $0 }).contains { $0.isMounted }
                if hasMounted {
                    showQuitAlert = true
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
            .alert("Unmount all volumes before quitting?", isPresented: $showQuitAlert) {
                Button("Unmount & Quit") {
                    Task {
                        await manager.unmountEverything()
                        NSApplication.shared.terminate(nil)
                    }
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func addVolume() {
        guard !newRemotePath.isEmpty else { return }
        let path = newRemotePath
        let mount = newMountPoint
        newRemotePath = ""
        newMountPoint = ""
        Task {
            await manager.addVolume(remotePath: path, mountPoint: mount)
        }
    }
}

struct VolumeRow: View {
    let volume: MountedVolume
    let hostName: String
    @ObservedObject var manager: VolumeManager

    var body: some View {
        HStack {
            Circle()
                .fill(volume.isMounted ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(volume.remotePath)
                    .font(.system(.body, design: .monospaced))
                Text(volume.mountPoint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if volume.isMounted {
                Button("Unmount") { Task { await manager.unmountVolume(volume, hostName: hostName) } }
                    .controlSize(.small)
            } else {
                Button("Mount") { Task { await manager.mountVolume(volume, hostName: hostName) } }
                    .controlSize(.small)
            }

            Button(action: { Task { await manager.removeVolume(volume, hostName: hostName) } }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}
