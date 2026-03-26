import Foundation

struct SSHHost: Identifiable, Hashable {
    let id: String
    let name: String
    let hostname: String
    let user: String
    let port: Int
    let identityFile: String?

    var displayName: String {
        "\(name) (\(user)@\(hostname))"
    }

    var oxfsHost: String {
        "\(user)@\(hostname)"
    }
}

struct SSHConfigParser {
    static func parse(configPath: String = "\(NSHomeDirectory())/.ssh/config") -> [SSHHost] {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }

        var hosts: [SSHHost] = []
        var currentName: String?
        var currentHostname: String?
        var currentUser: String?
        var currentPort: Int = 22
        var currentIdentityFile: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#")
                || trimmed.lowercased().hasPrefix("include")
            {
                continue
            }

            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "host" {
                if let name = currentName, let hostname = currentHostname, let user = currentUser {
                    hosts.append(
                        SSHHost(
                            id: name, name: name, hostname: hostname, user: user, port: currentPort,
                            identityFile: currentIdentityFile))
                }
                if value.contains("*") {
                    currentName = nil
                } else {
                    currentName = value
                }
                currentHostname = nil
                currentUser = nil
                currentPort = 22
                currentIdentityFile = nil
            } else if key == "hostname" {
                currentHostname = value
            } else if key == "user" {
                currentUser = value
            } else if key == "port" {
                currentPort = Int(value) ?? 22
            } else if key == "identityfile" {
                currentIdentityFile = value.replacingOccurrences(of: "~", with: NSHomeDirectory())
            }
        }

        if let name = currentName, let hostname = currentHostname, let user = currentUser {
            hosts.append(
                SSHHost(
                    id: name, name: name, hostname: hostname, user: user, port: currentPort,
                    identityFile: currentIdentityFile))
        }

        return hosts
    }
}
