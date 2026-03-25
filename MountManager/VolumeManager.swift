import Foundation
import Combine
import Security

struct MountedVolume: Identifiable, Hashable {
    let id = UUID()
    let remotePath: String
    let mountPoint: String
    var isMounted: Bool = false

    var name: String {
        remotePath == "/" ? "root" : String(remotePath.split(separator: "/").last ?? "unknown")
    }
}

@MainActor
class VolumeManager: ObservableObject {
    @Published var hosts: [SSHHost] = []
    @Published var selectedHost: SSHHost? {
        didSet {
            if let host = selectedHost {
                password = Self.loadPassword(for: host.name) ?? ""
            } else {
                password = ""
            }
        }
    }
    /// Per-host volume lists, keyed by host name
    @Published var hostVolumes: [String: [MountedVolume]] = [:]

    /// Convenience: volumes for the currently selected host
    var volumes: [MountedVolume] {
        get { hostVolumes[selectedHost?.name ?? ""] ?? [] }
        set {
            if let name = selectedHost?.name {
                hostVolumes[name] = newValue
                saveVolumes()
            }
        }
    }

    @Published var password: String = "" {
        didSet {
            if let host = selectedHost {
                Self.savePassword(password, for: host.name)
            }
        }
    }
    @Published var isLoading = false
    @Published var lastError: String?

    private let oxfsPath: String
    private var timer: Timer?
    private static let volumesKey = "com.mountmanager.savedVolumes"
    private static let templateKey = "com.mountmanager.mountTemplate"
    private static let oxfsPathKey = "com.mountmanager.oxfsPath"
    private static let defaultTemplate = "/Volumes/{host}/{path}"

    @Published var mountTemplate: String {
        didSet {
            UserDefaults.standard.set(mountTemplate, forKey: Self.templateKey)
        }
    }

    init() {
        mountTemplate = UserDefaults.standard.string(forKey: Self.templateKey) ?? Self.defaultTemplate
        oxfsPath = Self.findOxfs()
        hosts = SSHConfigParser.parse()
        loadSavedVolumes()
        startPolling()
    }

    private static func findOxfs() -> String {
        // Check UserDefaults first
        if let saved = UserDefaults.standard.string(forKey: oxfsPathKey), !saved.isEmpty {
            return saved
        }
        // Search common locations
        let candidates = [
            "/opt/homebrew/bin/oxfs",
            "/usr/local/bin/oxfs",
            "\(NSHomeDirectory())/.local/bin/oxfs",
            "/usr/bin/oxfs",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: try `which`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["oxfs"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? "/usr/local/bin/oxfs" : output
    }

    // MARK: - Volume persistence

    private func saveVolumes() {
        var dict: [String: [[String: String]]] = [:]
        for (hostName, vols) in hostVolumes {
            dict[hostName] = vols.map { ["remotePath": $0.remotePath, "mountPoint": $0.mountPoint] }
        }
        UserDefaults.standard.set(dict, forKey: Self.volumesKey)
    }

    private func loadSavedVolumes() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.volumesKey) as? [String: [[String: String]]] else { return }
        for (hostName, entries) in dict {
            hostVolumes[hostName] = entries.compactMap { entry in
                guard let remotePath = entry["remotePath"], let mountPoint = entry["mountPoint"] else { return nil }
                return MountedVolume(remotePath: remotePath, mountPoint: mountPoint)
            }
        }
    }

    func mountPointFor(host: SSHHost, remotePath: String) -> String {
        let safePath = remotePath == "/" ? "root" : remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return mountTemplate
            .replacingOccurrences(of: "{host}", with: host.name)
            .replacingOccurrences(of: "{user}", with: host.user)
            .replacingOccurrences(of: "{hostname}", with: host.hostname)
            .replacingOccurrences(of: "{path}", with: safePath)
    }

    func logPathFor(host: SSHHost, remotePath: String) -> String {
        let safeName = remotePath == "/" ? "root" : remotePath.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let logDir = NSHomeDirectory() + "/.mountmanager/logs"
        return "\(logDir)/\(host.name)-\(safeName).log"
    }

    func addVolume(remotePath: String, mountPoint: String) async {
        guard let host = selectedHost else { return }
        let cleaned = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        let mp = mountPoint.isEmpty ? mountPointFor(host: host, remotePath: cleaned) : mountPoint
        var vols = hostVolumes[host.name] ?? []
        if !vols.contains(where: { $0.mountPoint == mp }) {
            let vol = MountedVolume(remotePath: cleaned, mountPoint: mp, isMounted: await checkMounted(mountPoint: mp))
            vols.append(vol)
            hostVolumes[host.name] = vols
            saveVolumes()
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
        let pw = Self.loadPassword(for: hostName) ?? ""
        isLoading = true
        lastError = nil

        let mkdirResult = await shell("/bin/mkdir", args: ["-p", volume.mountPoint])
        if mkdirResult.status != 0 {
            lastError = "Failed to create mount point: \(mkdirResult.error)"
            isLoading = false
            return
        }

        let logDir = (logPathFor(host: host, remotePath: volume.remotePath) as NSString).deletingLastPathComponent
        _ = await shell("/bin/mkdir", args: ["-p", logDir])

        var oxfsArgs = [
            oxfsPath,
            "--host", host.oxfsHost,
            "--remote-path", volume.remotePath,
            "--mount-point", volume.mountPoint,
            "--cache-path", "\(NSHomeDirectory())/.oxfs",
            "--logging", logPathFor(host: host, remotePath: volume.remotePath),
            "--daemon",
            "--auto-cache"
        ]
        if let keyFile = host.identityFile {
            oxfsArgs += ["--ssh-key", keyFile]
        }
        if host.port != 22 {
            oxfsArgs += ["--ssh-port", "\(host.port)"]
        }

        let result: (output: String, error: String, status: Int32)
        if pw.isEmpty {
            result = await shell(oxfsPath, args: Array(oxfsArgs.dropFirst()))
        } else {
            let escapedPassword = pw.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "[", with: "\\[")
            let spawnCmd = oxfsArgs.map { "\"\($0)\"" }.joined(separator: " ")
            let expectScript = """
            spawn \(spawnCmd)
            expect {
                -re ".*assword.*" { send "\(escapedPassword)\\r"; exp_continue }
                -re ".*passphrase.*" { send "\(escapedPassword)\\r"; exp_continue }
                eof
            }
            """
            result = await shell("/usr/bin/expect", args: ["-c", expectScript])
        }
        if result.status != 0 {
            lastError = "Mount failed: \(result.error.isEmpty ? result.output : result.error)"
        }
        await refreshStatus()
        isLoading = false
    }

    func unmountVolume(_ volume: MountedVolume, hostName: String) async {
        isLoading = true
        lastError = nil

        let result = await shell("/sbin/umount", args: [volume.mountPoint])
        if result.status != 0 {
            lastError = "Unmount failed: \(result.error)"
        }
        await refreshStatus()
        isLoading = false
    }

    func mountAll() async {
        guard let host = selectedHost else { return }
        for volume in (hostVolumes[host.name] ?? []) where !volume.isMounted {
            await mountVolume(volume, hostName: host.name)
        }
    }

    func unmountAll() async {
        guard let host = selectedHost else { return }
        for volume in (hostVolumes[host.name] ?? []) where volume.isMounted {
            await unmountVolume(volume, hostName: host.name)
        }
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
        for hostName in hostVolumes.keys {
            guard var vols = hostVolumes[hostName] else { continue }
            for i in vols.indices {
                vols[i].isMounted = await checkMounted(mountPoint: vols[i].mountPoint)
            }
            hostVolumes[hostName] = vols
        }
    }

    private func checkMounted(mountPoint: String) async -> Bool {
        let result = await shell("/sbin/mount", args: [])
        return result.output.contains(mountPoint)
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshStatus()
            }
        }
    }

    private static let keychainService = "com.mountmanager.ssh"

    private static func savePassword(_ password: String, for hostName: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: hostName,
        ]
        SecItemDelete(query as CFDictionary)
        if !password.isEmpty {
            var addQuery = query
            addQuery[kSecValueData as String] = data
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

    private nonisolated func shell(_ command: String, args: [String]) async -> (output: String, error: String, status: Int32) {
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
                continuation.resume(returning: (
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? "",
                    process.terminationStatus
                ))
            }
        }
    }
}
