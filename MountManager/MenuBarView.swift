import SwiftUI

// MARK: - Main View

struct MenuBarView: View {
    @ObservedObject var manager: VolumeManager
    @State private var newRemotePath = ""
    @State private var newMountPoint = ""
    @State private var showSettings = false
    @State private var showAddForm = false
    @State private var logVolume: LogViewerIdentifiable?
    @State private var searchText = ""

    private var hasAnyUnmounted: Bool {
        manager.hostVolumes.values.flatMap { $0 }.contains { !$0.isMounted }
    }

    private var hasAnyMounted: Bool {
        manager.hostVolumes.values.flatMap { $0 }.contains { $0.isMounted }
    }

    private var hasFavorites: Bool {
        manager.hostVolumes.values.flatMap { $0 }.contains { $0.isFavorite }
    }

    private var hasUnmountedFavorites: Bool {
        manager.hostVolumes.values.flatMap { $0 }.contains { $0.isFavorite && !$0.isMounted }
    }

    private var filteredHosts: [SSHHost] {
        let hosts = manager.orderedHostsWithVolumes
        guard !searchText.isEmpty else { return hosts }
        let q = searchText.lowercased()
        return hosts.filter { host in
            host.name.lowercased().contains(q)
                || host.hostname.lowercased().contains(q)
                || (manager.hostVolumes[host.name] ?? []).contains {
                    $0.remotePath.lowercased().contains(q) || $0.mountPoint.lowercased().contains(q)
                }
        }
    }

    private func filteredVolumes(for host: SSHHost) -> [MountedVolume] {
        let vols = manager.hostVolumes[host.name] ?? []
        guard !searchText.isEmpty else { return vols }
        let q = searchText.lowercased()
        if host.name.lowercased().contains(q) || host.hostname.lowercased().contains(q) {
            return vols
        }
        return vols.filter {
            $0.remotePath.lowercased().contains(q) || $0.mountPoint.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    hostSections
                    addVolumeSection
                    errorBanner
                }
                .padding(12)
            }
            Divider().opacity(0.3)
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: 580)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: manager.hostVolumes)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: showAddForm)
        .onChange(of: manager.appearanceMode) { _, mode in
            DispatchQueue.main.async { applyAppearance(mode) }
        }
        .onAppear { applyAppearance(manager.appearanceMode) }
        .popover(item: $logVolume) { item in
            LogViewerPanel(
                title: "\(item.hostName): \(item.volume.remotePath)",
                content: manager.logContent(for: item.volume, hostName: item.hostName)
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MountManager")
                        .font(.system(size: 14, weight: .bold))
                    if manager.totalCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.clear)
                                .frame(width: 7, height: 7)
                                .glassEffect(
                                    manager.mountedCount > 0
                                        ? .clear.tint(.green) : .clear,
                                    in: .circle
                                )
                            Text("\(manager.mountedCount) of \(manager.totalCount) active")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if manager.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            if manager.totalCount > 3 {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("Filter...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .glassEffect(.clear, in: .rect(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Host Sections

    @ViewBuilder
    private var hostSections: some View {
        let allHosts = filteredHosts
        if allHosts.isEmpty && !showAddForm && searchText.isEmpty {
            emptyState
        } else if allHosts.isEmpty && !searchText.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No matches")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .glassEffect(.clear, in: .rect(cornerRadius: 12))
        } else {
            ForEach(Array(allHosts.enumerated()), id: \.element.id) { idx, host in
                hostCard(
                    host: host, volumes: filteredVolumes(for: host),
                    hostIndex: idx, hostTotal: allHosts.count)
            }
            if allHosts.count > 1 && searchText.isEmpty {
                globalActions
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 32, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("No volumes yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Add a remote path to get started")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .glassEffect(.clear, in: .rect(cornerRadius: 12))
    }

    // MARK: - Host Card

    private func hostCard(
        host: SSHHost, volumes: [MountedVolume],
        hostIndex: Int, hostTotal: Int
    ) -> some View {
        let mounted = volumes.filter(\.isMounted).count
        let hasUnmounted = volumes.contains { !$0.isMounted }
        let hostLoading = volumes.contains { manager.loadingVolumes.contains($0.id) }
        let allMounted = mounted == volumes.count && mounted > 0

        return VStack(spacing: 0) {
            HostCardHeader(
                host: host, manager: manager,
                latency: manager.hostLatencies[host.name],
                mounted: mounted, volumeCount: volumes.count,
                hasUnmounted: hasUnmounted, hostLoading: hostLoading,
                hostIndex: hostIndex, hostTotal: hostTotal,
                volumes: volumes
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                if index > 0 { Divider().padding(.leading, 36).opacity(0.5) }
                VolumeRow(
                    volume: volume, hostName: host.name, manager: manager,
                    index: index, total: volumes.count,
                    onShowLog: { logVolume = LogViewerIdentifiable(volume, host.name) }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .padding(.bottom, 2)
        }
        .glassEffect(
            allMounted ? .clear.tint(.green.opacity(0.15)) : .clear,
            in: .rect(cornerRadius: 12)
        )
    }

    // MARK: - Add Volume

    private var addVolumeSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.25)) { showAddForm.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.green)
                    Text("Add Volume")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showAddForm ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAddForm {
                Divider().padding(.horizontal, 8).opacity(0.5)
                addFormContent
                    .padding(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .glassEffect(.clear, in: .rect(cornerRadius: 12))
    }

    private var addFormContent: some View {
        GlassEffectContainer {
        VStack(spacing: 8) {
            Picker(selection: $manager.selectedHost) {
                Text("Select host...").tag(nil as SSHHost?)
                ForEach(manager.hosts) { Text($0.displayName).tag($0 as SSHHost?) }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .controlSize(.small)
            .glassEffect(.clear, in: .rect(cornerRadius: 6))

            if manager.selectedHost != nil {
                formField(icon: "lock.fill", iconColor: .orange) {
                    SecureField("Password (optional)", text: $manager.password)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                formField(icon: "folder.fill", iconColor: .blue) {
                    TextField("Remote path, e.g. /data", text: $newRemotePath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onChange(of: newRemotePath) { _, v in
                            newMountPoint = manager.defaultMountPoint(remotePath: v)
                        }
                }
                formField(icon: "arrow.triangle.branch", iconColor: .purple) {
                    TextField("Mount point", text: $newMountPoint)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button(action: addVolume) {
                    Label("Add", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .controlSize(.small)
                .disabled(newRemotePath.isEmpty)
            }
        }
        }
    }

    private func formField<C: View>(
        icon: String, iconColor: Color, @ViewBuilder content: () -> C
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.clear, in: .rect(cornerRadius: 6))
    }

    // MARK: - Global Actions

    private var globalActions: some View {
        GlassEffectContainer {
            VStack(spacing: 4) {
                if hasFavorites {
                    Button {
                        Task { await manager.mountFavorites() }
                    } label: {
                        Label("Mount Favorites", systemImage: "star.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(.yellow)
                    .controlSize(.small)
                    .disabled(!hasUnmountedFavorites || manager.isLoading)
                }
                HStack(spacing: 4) {
                    Button {
                        Task { await manager.mountEverything() }
                    } label: {
                        Label("Mount All", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    .controlSize(.small)
                    .disabled(!hasAnyUnmounted || manager.isLoading)

                    Button {
                        Task { await manager.unmountEverything() }
                    } label: {
                        Label("Unmount All", systemImage: "eject.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(.orange)
                    .controlSize(.small)
                    .disabled(!hasAnyMounted || manager.isLoading)
                }
            }
        }
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = manager.lastError {
            GlassEffectContainer {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation { manager.lastError = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }
                .padding(8)
                .glassEffect(.clear.tint(.red.opacity(0.3)), in: .rect(cornerRadius: 10))
            }
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Button {
                    withAnimation { showSettings.toggle() }
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .popover(isPresented: $showSettings, arrowEdge: .top) {
                    settingsPopover
                }
                Spacer()
                Button {
                    Task {
                        if hasAnyMounted { await manager.unmountEverything() }
                        NSApp.terminate(nil)
                    }
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Settings Popover

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.system(size: 12, weight: .semibold))
                GlassEffectContainer {
                    HStack(spacing: 4) {
                        ForEach(
                            Array(
                                zip(
                                    [0, 1, 2],
                                    [
                                        ("circle.lefthalf.filled", "Auto"),
                                        ("sun.max.fill", "Light"),
                                        ("moon.fill", "Dark"),
                                    ])), id: \.0
                        ) { mode, info in
                            Button {
                                manager.appearanceMode = mode
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: info.0)
                                        .font(.system(size: 16, weight: .medium))
                                        .symbolRenderingMode(.hierarchical)
                                        .frame(height: 20)
                                    Text(info.1)
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.glass)
                            .tint(manager.appearanceMode == mode ? Color.accentColor : nil)
                            .controlSize(.small)
                            .focusEffectDisabled()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Mount Template")
                    .font(.system(size: 12, weight: .semibold))
                TextField("/Volumes/{host}/{path}", text: $manager.mountTemplate)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .glassEffect(.clear, in: .rect(cornerRadius: 6))
                Text("{host}  {user}  {hostname}  {path}")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Helpers

    private func applyAppearance(_ mode: Int) {
        switch mode {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func addVolume() {
        guard !newRemotePath.isEmpty else { return }
        let path = newRemotePath
        let mount = newMountPoint
        newRemotePath = ""
        newMountPoint = ""
        Task { await manager.addVolume(remotePath: path, mountPoint: mount) }
    }
}

// MARK: - Reorder Controls

private struct ReorderButtons: View {
    let index: Int
    let total: Int
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        VStack(spacing: 1) {
            Button {
                guard index > 0 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    onMove(IndexSet(integer: index), index - 1)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 6, weight: .bold))
                    .frame(width: 14, height: 10)
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .disabled(index == 0)

            Button {
                guard index < total - 1 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    onMove(IndexSet(integer: index), index + 2)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .frame(width: 14, height: 10)
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .disabled(index >= total - 1)
        }
        .transition(.opacity)
    }
}

// MARK: - Mini Glass Button

private struct MiniGlassButton: View {
    let icon: String
    let color: Color
    var disabled: Bool = false
    let tip: String
    var fontSize: CGFloat = 8
    let action: () async -> Void
    @State private var hovered = false

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .tint(hovered && !disabled ? color : nil)
        .controlSize(.mini)
        .disabled(disabled)
        .help(tip)
        .onHover { hovered = $0 }
    }
}

// MARK: - Host Card Header

struct HostCardHeader: View {
    let host: SSHHost
    @ObservedObject var manager: VolumeManager
    let latency: Double?
    let mounted: Int
    let volumeCount: Int
    let hasUnmounted: Bool
    let hostLoading: Bool
    let hostIndex: Int
    let hostTotal: Int
    let volumes: [MountedVolume]
    @State private var isHovered = false

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 6) {
                if isHovered && hostTotal > 1 {
                    ReorderButtons(index: hostIndex, total: hostTotal) { src, dst in
                        manager.moveHost(from: src, to: dst)
                    }
                }

                Image(systemName: "server.rack")
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(mounted > 0 ? Color.green : (isHovered ? Color.blue : Color.gray))
                    .frame(width: 28, height: 28)
                    .glassEffect(.clear, in: .circle)
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.system(size: 12, weight: .semibold))
                    if host.hostname != host.name {
                        Text(host.hostname)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                if let ms = latency { latencyBadge(ms: ms) }

                Spacer()

                if mounted > 0 {
                    Text("\(mounted)/\(volumeCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .glassEffect(.clear.tint(.green), in: .capsule)
                }

                HStack(spacing: 2) {
                    MiniGlassButton(
                        icon: "antenna.radiowaves.left.and.right", color: .blue,
                        tip: "Check latency"
                    ) {
                        await manager.checkLatency(hostName: host.name)
                    }
                    if mounted > 0 {
                        MiniGlassButton(
                            icon: "eject.fill", color: .orange, disabled: hostLoading,
                            tip: "Unmount all"
                        ) {
                            for vol in volumes where vol.isMounted {
                                await manager.unmountVolume(vol, hostName: host.name)
                            }
                        }
                    }
                    if hasUnmounted {
                        MiniGlassButton(
                            icon: "bolt.fill", color: .green, disabled: hostLoading, tip: "Mount all"
                        ) {
                            for vol in volumes where !vol.isMounted {
                                await manager.mountVolume(vol, hostName: host.name)
                            }
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
    }

    private func latencyBadge(ms: Double) -> some View {
        Group {
            if ms < 0 {
                HStack(spacing: 3) {
                    Circle().fill(.clear).frame(width: 6, height: 6)
                        .glassEffect(.clear.tint(.red), in: .circle)
                    Text("offline")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.red)
                }
            } else {
                HStack(spacing: 3) {
                    Circle().fill(.clear).frame(width: 6, height: 6)
                        .glassEffect(
                            .clear.tint(ms < 200 ? .green : .yellow),
                            in: .circle
                        )
                    Text("\(Int(ms))ms")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .glassEffect(.clear, in: .capsule)
    }

}

// MARK: - Volume Row

struct VolumeRow: View {
    let volume: MountedVolume
    let hostName: String
    @ObservedObject var manager: VolumeManager
    var index: Int = 0
    var total: Int = 1
    var onShowLog: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                if isHovered && total > 1 {
                    ReorderButtons(index: index, total: total) { src, dst in
                        manager.moveVolume(hostName: hostName, from: src, to: dst)
                    }
                }

                Circle()
                    .fill(.clear)
                    .frame(width: 8, height: 8)
                    .glassEffect(
                        volume.isMounted ? .clear.tint(.green) : .clear,
                        in: .circle
                    )
                    .animation(.easeInOut(duration: 0.25), value: volume.isMounted)

                if volume.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.yellow)
                        .frame(width: 14, height: 14)
                        .glassEffect(.clear.tint(.yellow), in: .circle)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(volume.mountPoint)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(volume.remotePath)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture { if volume.isMounted { manager.openInFinder(volume) } }

                Spacer(minLength: 2)

                if manager.loadingVolumes.contains(volume.id) {
                    ProgressView()
                        .controlSize(.mini)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 2) {
                        if isHovered {
                            MiniGlassButton(
                                icon: "doc.text", color: .blue,
                                tip: "View log", fontSize: 9
                            ) { onShowLog() }
                        }
                        if volume.isMounted {
                            MiniGlassButton(
                                icon: "folder", color: .blue,
                                tip: "Open in Finder", fontSize: 9
                            ) { manager.openInFinder(volume) }
                            MiniGlassButton(
                                icon: "eject.fill", color: .orange, tip: "Unmount"
                            ) {
                                await manager.unmountVolume(volume, hostName: hostName)
                            }
                        } else {
                            MiniGlassButton(
                                icon: "bolt.fill", color: .green, tip: "Mount"
                            ) {
                                await manager.mountVolume(volume, hostName: hostName)
                            }
                            MiniGlassButton(
                                icon: "xmark", color: .red,
                                tip: "Remove", fontSize: 8
                            ) {
                                await manager.removeVolume(volume, hostName: hostName)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
        .contextMenu { volumeContextMenu }
    }

    @ViewBuilder
    private var volumeContextMenu: some View {
        if volume.isMounted {
            Button {
                manager.openInFinder(volume)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            Button {
                Task { await manager.unmountVolume(volume, hostName: hostName) }
            } label: {
                Label("Unmount", systemImage: "eject.fill")
            }
        } else {
            Button {
                Task { await manager.mountVolume(volume, hostName: hostName) }
            } label: {
                Label("Mount", systemImage: "bolt.fill")
            }
        }
        Divider()
        Button {
            manager.copyMountPath(volume)
        } label: {
            Label("Copy Mount Path", systemImage: "doc.on.doc")
        }
        Button {
            onShowLog()
        } label: {
            Label("View Log", systemImage: "doc.text")
        }
        Button {
            manager.toggleFavorite(volume, hostName: hostName)
        } label: {
            Label(
                volume.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: volume.isFavorite ? "star.slash" : "star.fill")
        }
        if !volume.isMounted {
            Divider()
            Button(role: .destructive) {
                Task { await manager.removeVolume(volume, hostName: hostName) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

}

// MARK: - Log Viewer

struct LogViewerIdentifiable: Identifiable {
    let id = UUID()
    let volume: MountedVolume
    let hostName: String
    init(_ volume: MountedVolume, _ hostName: String) {
        self.volume = volume
        self.hostName = hostName
    }
}

struct LogViewerPanel: View {
    let title: String
    let content: String

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.clear, in: .capsule)

                ScrollView(.vertical, showsIndicators: true) {
                    Text(content)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .glassEffect(.clear, in: .rect(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(width: 400, height: 300)
    }
}
