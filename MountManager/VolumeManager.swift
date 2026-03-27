import AppKit
import Combine
import Security
import UserNotifications

struct MountedVolume: Identifiable, Hashable {
    let id = UUID()
    let remotePath: String
    let mountPoint: String
    var isMounted: Bool = false
    var isFavorite: Bool = false
}

@MainActor
class VolumeManager: ObservableObject {
    @Published var hosts: [SSHHost] = []
    private var isLoadingPassword = false

    @Published var selectedHost: SSHHost? {
        didSet {
            if let host = selectedHost {
                isLoadingPassword = true
                password = Self.loadPassword(for: host.name) ?? ""
                isLoadingPassword = false
            } else {
                password = ""
            }
        }
    }
    /// Per-host volume lists, keyed by host name
    @Published var hostVolumes: [String: [MountedVolume]] = [:]

    @Published var password: String = "" {
        didSet {
            if !isLoadingPassword, let host = selectedHost {
                Self.savePassword(password, for: host.name)
            }
        }
    }
    /// IDs of volumes currently being mounted/unmounted.
    @Published var loadingVolumes: Set<UUID> = []
    @Published var lastError: String?
    /// Latency per host in ms; nil = not yet checked, -1 = unreachable
    @Published var hostLatencies: [String: Double] = [:]
    /// Custom display order of host names
    @Published var hostOrder: [String] = []

    var isLoading: Bool { !loadingVolumes.isEmpty }

    private let oxfsPath: String
    private var timer: Timer?
    private var latencyTimer: Timer?
    /// Previous mount states for disconnect detection
    private var previousMountStates: [UUID: Bool] = [:]
    private static let volumesKey = "com.mountmanager.savedVolumes"
    private static let templateKey = "com.mountmanager.mountTemplate"
    private static let oxfsPathKey = "com.mountmanager.oxfsPath"
    private static let appearanceKey = "com.mountmanager.appearance"
    private static let hostOrderKey = "com.mountmanager.hostOrder"
    private static let defaultTemplate = "/Volumes/{host}/{path}"

    /// 0 = system, 1 = light, 2 = dark
    @Published var appearanceMode: Int {
        didSet {
            UserDefaults.standard.set(appearanceMode, forKey: Self.appearanceKey)
        }
    }

    @Published var mountTemplate: String {
        didSet {
            UserDefaults.standard.set(mountTemplate, forKey: Self.templateKey)
        }
    }

    init() {
        appearanceMode = UserDefaults.standard.integer(forKey: Self.appearanceKey)
        mountTemplate =
            UserDefaults.standard.string(forKey: Self.templateKey) ?? Self.defaultTemplate
        oxfsPath = Self.findOxfs()
        hosts = SSHConfigParser.parse()
        loadSavedVolumes()
        hostOrder = UserDefaults.standard.stringArray(forKey: Self.hostOrderKey) ?? []
        syncHostOrder()
        requestNotificationPermission()
        startPolling()
        startLatencyPolling()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func findOxfs() -> String {
        // Check UserDefaults first
        if let saved = UserDefaults.standard.string(forKey: oxfsPathKey), !saved.isEmpty,
            FileManager.default.isExecutableFile(atPath: saved)
        {
            return saved
        }
        // Use login shell to resolve from user's full PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which oxfs"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty && process.terminationStatus == 0 {
            UserDefaults.standard.set(output, forKey: oxfsPathKey)
            return output
        }
        // Fallback: check common locations
        let candidates = [
            "/opt/homebrew/bin/oxfs",
            "/usr/local/bin/oxfs",
            "\(NSHomeDirectory())/.local/bin/oxfs",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                UserDefaults.standard.set(path, forKey: oxfsPathKey)
                return path
            }
        }
        return "/usr/local/bin/oxfs"
    }

    // MARK: - Volume persistence

    private func saveVolumes() {
        var dict: [String: [[String: String]]] = [:]
        for (hostName, vols) in hostVolumes {
            dict[hostName] = vols.map {
                var entry = ["remotePath": $0.remotePath, "mountPoint": $0.mountPoint]
                if $0.isFavorite { entry["favorite"] = "1" }
                return entry
            }
        }
        UserDefaults.standard.set(dict, forKey: Self.volumesKey)
    }

    private func loadSavedVolumes() {
        guard
            let dict = UserDefaults.standard.dictionary(forKey: Self.volumesKey)
                as? [String: [[String: String]]]
        else { return }
        for (hostName, entries) in dict {
            hostVolumes[hostName] = entries.compactMap { entry in
                guard let remotePath = entry["remotePath"], let mountPoint = entry["mountPoint"]
                else { return nil }
                return MountedVolume(
                    remotePath: remotePath, mountPoint: mountPoint,
                    isFavorite: entry["favorite"] == "1")
            }
        }
    }

    func mountPointFor(host: SSHHost, remotePath: String) -> String {
        let safePath =
            remotePath == "/"
            ? "root" : remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return
            mountTemplate
            .replacingOccurrences(of: "{host}", with: host.name)
            .replacingOccurrences(of: "{user}", with: host.user)
            .replacingOccurrences(of: "{hostname}", with: host.hostname)
            .replacingOccurrences(of: "{path}", with: safePath)
    }

    func logPathFor(host: SSHHost, remotePath: String) -> String {
        let safeName =
            remotePath == "/"
            ? "root"
            : remotePath.replacingOccurrences(of: "/", with: "-").trimmingCharacters(
                in: CharacterSet(charactersIn: "-"))
        let logDir = NSHomeDirectory() + "/.mountmanager/logs"
        return "\(logDir)/\(host.name)-\(safeName).log"
    }

    func addVolume(remotePath: String, mountPoint: String) async {
        guard let host = selectedHost else { return }
        let cleaned = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        let mp = mountPoint.isEmpty ? mountPointFor(host: host, remotePath: cleaned) : mountPoint
        var vols = hostVolumes[host.name] ?? []
        if !vols.contains(where: { $0.mountPoint == mp }) {
            let mountOutput = (await shell("/sbin/mount", args: [])).output
            let vol = MountedVolume(
                remotePath: cleaned, mountPoint: mp, isMounted: mountOutput.contains(mp))
            vols.append(vol)
            hostVolumes[host.name] = vols
            saveVolumes()
            syncHostOrder()
        }
    }

    func defaultMountPoint(remotePath: String) -> String {
        guard let host = selectedHost else { return "" }
        let cleaned = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        return mountPointFor(host: host, remotePath: cleaned)
    }

    func removeVolume(_ volume: MountedVolume, hostName: String) async {
        if volume.isMounted {
            await unmountVolume(volume, hostName: hostName)
        }
        hostVolumes[hostName]?.removeAll { $0.id == volume.id }
        saveVolumes()
    }

    private func hostFor(name: String) -> SSHHost? {
        hosts.first { $0.name == name }
    }

    func mountVolume(_ volume: MountedVolume, hostName: String) async {
        guard let host = hostFor(name: hostName) else { return }
        let pw =
            (selectedHost?.name == hostName ? password : nil) ?? Self.loadPassword(for: hostName)
            ?? ""
        loadingVolumes.insert(volume.id)
        lastError = nil

        let mkdirResult = await shell("/bin/mkdir", args: ["-p", volume.mountPoint])
        if mkdirResult.status != 0 {
            lastError = "Failed to create mount point: \(mkdirResult.error)"
            loadingVolumes.remove(volume.id)
            return
        }

        let logDir = (logPathFor(host: host, remotePath: volume.remotePath) as NSString)
            .deletingLastPathComponent
        _ = await shell("/bin/mkdir", args: ["-p", logDir])

        var oxfsArgs = [
            oxfsPath,
            "--host", host.oxfsHost,
            "--remote-path", volume.remotePath,
            "--mount-point", volume.mountPoint,
            "--cache-path", "\(NSHomeDirectory())/.oxfs",
            "--logging", logPathFor(host: host, remotePath: volume.remotePath),
            "--daemon",
            "--auto-cache",
        ]
        if let keyFile = host.identityFile {
            oxfsArgs += ["--ssh-key", keyFile]
        }
        if host.port != 22 {
            oxfsArgs += ["--ssh-port", "\(host.port)"]
        }

        let result: (output: String, error: String, status: Int32)
        if pw.isEmpty {
            result = await daemonShell(oxfsPath, args: Array(oxfsArgs.dropFirst()))
        } else {
            result = await daemonShell(
                oxfsPath, args: Array(oxfsArgs.dropFirst()), input: pw + "\n")
        }
        if result.status != 0 {
            let msg = "Mount failed: \(result.error.isEmpty ? result.output : result.error)"
            lastError = msg
            sendNotification(
                title: "Mount Failed",
                body:
                    "\(volume.remotePath) on \(hostName): \(result.error.isEmpty ? result.output : result.error)"
            )
            await refreshStatus()
            loadingVolumes.remove(volume.id)
            return
        }
        // The daemon child needs a moment to establish the FUSE mount.
        // Poll until mounted or timeout (up to 10s).
        for _ in 0..<20 {
            await refreshStatus()
            if hostVolumes[hostName]?.first(where: { $0.id == volume.id })?.isMounted == true {
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        loadingVolumes.remove(volume.id)
    }

    func unmountVolume(_ volume: MountedVolume, hostName: String) async {
        loadingVolumes.insert(volume.id)
        lastError = nil

        let result = await shell("/sbin/umount", args: [volume.mountPoint])
        if result.status != 0 {
            lastError = "Unmount failed: \(result.error)"
        }
        await refreshStatus()
        loadingVolumes.remove(volume.id)
    }

    func mountEverything() async {
        for (hostName, vols) in hostVolumes {
            for volume in vols where !volume.isMounted {
                await mountVolume(volume, hostName: hostName)
            }
        }
    }

    func unmountEverything() async {
        for (hostName, vols) in hostVolumes {
            for volume in vols where volume.isMounted {
                await unmountVolume(volume, hostName: hostName)
            }
        }
    }

    func refreshStatus() async {
        let result = await shell("/sbin/mount", args: [])
        let mountOutput = result.output
        for hostName in hostVolumes.keys {
            guard var vols = hostVolumes[hostName] else { continue }
            for i in vols.indices {
                let wasMounted = previousMountStates[vols[i].id] ?? vols[i].isMounted
                vols[i].isMounted = mountOutput.contains(vols[i].mountPoint)
                // Detect unexpected disconnect (was mounted, now not, and not loading)
                if wasMounted && !vols[i].isMounted && !loadingVolumes.contains(vols[i].id) {
                    sendNotification(
                        title: "Volume Disconnected",
                        body: "\(vols[i].remotePath) on \(hostName) was unexpectedly unmounted.")
                }
                previousMountStates[vols[i].id] = vols[i].isMounted
            }
            hostVolumes[hostName] = vols
        }
    }

    // MARK: - Open in Finder

    func openInFinder(_ volume: MountedVolume) {
        guard volume.isMounted else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: volume.mountPoint)
    }

    // MARK: - Connection status / latency

    func checkLatency(hostName: String) async {
        guard let host = hostFor(name: hostName) else { return }
        let start = CFAbsoluteTimeGetCurrent()
        // Use ssh with a 5s timeout to run `true` — measures real SSH latency
        let result = await shell(
            "/usr/bin/ssh",
            args: [
                "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=no",
                "-o", "BatchMode=yes",
                "-p", "\(host.port)",
                host.oxfsHost, "true",
            ])
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if result.status == 0 {
            hostLatencies[hostName] = elapsed
        } else {
            hostLatencies[hostName] = -1
        }
    }

    // MARK: - Copy path

    func copyMountPath(_ volume: MountedVolume) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(volume.mountPoint, forType: .string)
    }

    // MARK: - Favorites

    func toggleFavorite(_ volume: MountedVolume, hostName: String) {
        guard var vols = hostVolumes[hostName],
            let idx = vols.firstIndex(where: { $0.id == volume.id })
        else { return }
        vols[idx].isFavorite.toggle()
        hostVolumes[hostName] = vols
        saveVolumes()
    }

    func mountFavorites() async {
        for (hostName, vols) in hostVolumes {
            for volume in vols where volume.isFavorite && !volume.isMounted {
                await mountVolume(volume, hostName: hostName)
            }
        }
    }

    // MARK: - Periodic latency

    func startLatencyPolling() {
        latencyTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for host in self.hosts where self.hostVolumes[host.name]?.isEmpty == false {
                    await self.checkLatency(hostName: host.name)
                }
            }
        }
        // Initial check
        Task {
            for host in hosts where hostVolumes[host.name]?.isEmpty == false {
                await checkLatency(hostName: host.name)
            }
        }
    }

    // MARK: - Computed helpers

    var mountedCount: Int {
        hostVolumes.values.flatMap { $0 }.filter { $0.isMounted }.count
    }

    var totalCount: Int {
        hostVolumes.values.flatMap { $0 }.count
    }

    // MARK: - Reorder

    /// Hosts that have volumes, in user-defined order
    var orderedHostsWithVolumes: [SSHHost] {
        let active = hosts.filter { hostVolumes[$0.name]?.isEmpty == false }
        // Sort by hostOrder position; unknown hosts go to the end
        return active.sorted { a, b in
            let ia = hostOrder.firstIndex(of: a.name) ?? Int.max
            let ib = hostOrder.firstIndex(of: b.name) ?? Int.max
            return ia < ib
        }
    }

    /// Ensure hostOrder includes all active host names
    private func syncHostOrder() {
        let activeNames = Set(
            hosts.filter { hostVolumes[$0.name]?.isEmpty == false }.map { $0.name })
        // Add any new hosts not yet in the order
        for name in activeNames where !hostOrder.contains(name) {
            hostOrder.append(name)
        }
        // Remove stale entries
        hostOrder.removeAll { !activeNames.contains($0) }
    }

    func moveHost(from source: IndexSet, to destination: Int) {
        syncHostOrder()
        hostOrder.move(fromOffsets: source, toOffset: destination)
        UserDefaults.standard.set(hostOrder, forKey: Self.hostOrderKey)
    }

    func moveVolume(hostName: String, from source: IndexSet, to destination: Int) {
        hostVolumes[hostName]?.move(fromOffsets: source, toOffset: destination)
        saveVolumes()
    }

    // MARK: - Log viewer

    func logContent(for volume: MountedVolume, hostName: String) -> String {
        guard let host = hostFor(name: hostName) else { return "Host not found." }
        let path = logPathFor(host: host, remotePath: volume.remotePath)
        guard let data = FileManager.default.contents(atPath: path),
            let content = String(data: data, encoding: .utf8)
        else { return "No log file found at \(path)." }
        // Return last 200 lines
        let lines = content.components(separatedBy: .newlines)
        let tail = lines.suffix(200)
        return tail.joined(separator: "\n")
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshStatus()
            }
        }
    }

    private static let keychainService = "com.mountmanager.ssh"

    private static func savePassword(_ password: String, for hostName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: hostName,
        ]
        if password.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attrs: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = Data(password.utf8)
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func loadPassword(for hostName: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: hostName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated func shell(_ command: String, args: [String]) async -> (
        output: String, error: String, status: Int32
    ) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = args

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                    return
                }

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: (
                        String(data: outData, encoding: .utf8) ?? "",
                        String(data: errData, encoding: .utf8) ?? "",
                        process.terminationStatus
                    ))
            }
        }
    }

    /// Launch a daemon process (oxfs --daemon). Does not wait for exit —
    /// the daemon forks a child whose inherited pipe handles would block
    /// waitUntilExit/readDataToEndOfFile forever. Instead we wait briefly
    /// for the parent to finish spawning, then return.
    private nonisolated func daemonShell(_ command: String, args: [String], input: String? = nil)
        async -> (output: String, error: String, status: Int32)
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = args

                if input != nil {
                    var env = ProcessInfo.processInfo.environment
                    env["BACKGROUND"] = "BACKGROUND"
                    process.environment = env
                }

                let inPipe = input != nil ? Pipe() : nil
                if let inPipe = inPipe {
                    process.standardInput = inPipe
                }
                // Send stdout/stderr to /dev/null — the daemon child would
                // keep pipe FDs open forever, and we don't need the output.
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    if let input = input, let data = input.data(using: .utf8) {
                        inPipe!.fileHandleForWriting.write(data)
                        inPipe!.fileHandleForWriting.closeFile()
                    }
                    // Wait up to 30s for the parent process to exit.
                    // The parent spawns the daemon child then calls sys.exit().
                    let deadline = Date().addingTimeInterval(30)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.2)
                    }
                } catch {
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                    return
                }

                let status: Int32 = process.isRunning ? -1 : process.terminationStatus
                let errMsg = process.isRunning ? "Timed out waiting for mount" : ""
                continuation.resume(returning: ("", errMsg, status))
            }
        }
    }
}
