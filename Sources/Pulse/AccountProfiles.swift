import Foundation

struct GitHubAccount: Identifiable, Codable, Equatable, Sendable {
    var id: String { login }
    let login: String
    var active: Bool
    var state: String
}

struct VercelSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var directory: String
    var username: String?
    var isDefault: Bool

    var displayName: String { username.map { "\(name) · \($0)" } ?? name }
}

struct DeveloperProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var githubLogin: String
    var vercelSessionID: UUID?
    var vercelTeam: String
    var gitName: String
    var gitEmail: String
    var projectPath: String
}

struct AccountStoreData: Codable, Equatable, Sendable {
    var profiles: [DeveloperProfile] = []
    var vercelSessions: [VercelSession] = []
    var activeProfileID: UUID?
}

enum AccountStore {
    static func load(from url: URL) -> AccountStoreData {
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(AccountStoreData.self, from: data) else { return AccountStoreData() }
        return result
    }

    static func save(_ value: AccountStoreData, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder.pretty.encode(value)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum AccountDiscovery {
    private struct GitHubStatus: Decodable {
        struct Entry: Decodable {
            let state: String
            let active: Bool
            let login: String
        }
        let hosts: [String: [Entry]]
    }

    static func githubAccounts(executable: String?) -> [GitHubAccount] {
        guard let executable else { return [] }
        switch Shell.run(executable, ["auth", "status", "--json", "hosts"], timeout: 12) {
        case .output(let data), .failed(let data, _):
            guard let status = try? JSONDecoder().decode(GitHubStatus.self, from: data) else { return [] }
            return (status.hosts["github.com"] ?? [])
                .map { GitHubAccount(login: $0.login, active: $0.active, state: $0.state) }
                .sorted { first, second in first.active != second.active ? first.active : first.login.localizedCaseInsensitiveCompare(second.login) == .orderedAscending }
        case .timedOut, .launchFailed: return []
        }
    }

    static func vercelUsername(executable: String?, directory: String) -> String? {
        guard let executable else { return nil }
        let arguments = ["whoami", "--json", "--no-color", "--global-config", directory]
        guard case .output(let data) = Shell.run(executable, arguments, timeout: 15) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["username", "user", "name", "email"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
                if let nested = object[key] as? [String: Any] {
                    for nestedKey in ["username", "name", "email"] {
                        if let value = nested[nestedKey] as? String, !value.isEmpty { return value }
                    }
                }
            }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.hasPrefix("{") ? nil : text
    }

    static func executable(named name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/" + name,
            "/opt/homebrew/bin/" + name,
            "/usr/local/bin/" + name,
            "/usr/bin/" + name
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct ProfileMismatch: Equatable, Sendable {
    var messages: [String] = []
    var clean: Bool { messages.isEmpty }
}

enum ProfileInspector {
    static func inspect(_ profile: DeveloperProfile) -> ProfileMismatch {
        let path = profile.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path + "/.git") else {
            return ProfileMismatch(messages: path.isEmpty ? [] : ["The bound project is not a Git repository."])
        }
        var messages: [String] = []
        if let remote = git(path, ["remote", "get-url", "origin"]),
           let owner = githubOwner(from: remote),
           owner.caseInsensitiveCompare(profile.githubLogin) != .orderedSame {
            messages.append("Origin belongs to \(owner), but this profile uses \(profile.githubLogin).")
        }
        if !profile.gitName.isEmpty, let current = git(path, ["config", "--local", "--get", "user.name"]), current != profile.gitName {
            messages.append("Repository Git name is \(current); profile expects \(profile.gitName).")
        }
        if !profile.gitEmail.isEmpty, let current = git(path, ["config", "--local", "--get", "user.email"]), current != profile.gitEmail {
            messages.append("Repository Git email is \(current); profile expects \(profile.gitEmail).")
        }
        return ProfileMismatch(messages: messages)
    }

    static func githubOwner(from remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "github.com/") {
            return trimmed[range.upperBound...].split(separator: "/").first.map(String.init)
        }
        if let range = trimmed.range(of: "github.com:") {
            return trimmed[range.upperBound...].split(separator: "/").first.map(String.init)
        }
        return nil
    }

    private static func git(_ path: String, _ arguments: [String]) -> String? {
        switch Shell.run("/usr/bin/git", ["-C", path] + arguments, timeout: 5) {
        case .output(let data):
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        default: return nil
        }
    }
}

struct SwitchOutcome: Equatable, Sendable {
    var success: Bool
    var message: String
}

enum ProfileSwitcher {
    static func apply(
        _ profile: DeveloperProfile,
        sessions: [VercelSession],
        previousGitHubLogin: String?,
        githubExecutable: String?,
        vercelExecutable: String?,
        activeVercelFile: URL
    ) -> SwitchOutcome {
        guard let githubExecutable else { return SwitchOutcome(success: false, message: "GitHub CLI was not found.") }
        guard !profile.githubLogin.isEmpty else { return SwitchOutcome(success: false, message: "Choose a GitHub account for this profile.") }

        let session: VercelSession?
        if let sessionID = profile.vercelSessionID {
            guard let selected = sessions.first(where: { $0.id == sessionID }) else {
                return SwitchOutcome(success: false, message: "The selected Vercel session no longer exists.")
            }
            if !profile.vercelTeam.isEmpty, vercelExecutable == nil {
                return SwitchOutcome(success: false, message: "Vercel CLI was not found.")
            }
            session = selected
        } else { session = nil }

        let project = profile.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty, !FileManager.default.fileExists(atPath: project + "/.git") {
            return SwitchOutcome(success: false, message: "The bound project is not a Git repository.")
        }
        let previousVercelData = try? Data(contentsOf: activeVercelFile)
        let previousGitName = project.isEmpty ? nil : gitValue(project, "user.name")
        let previousGitEmail = project.isEmpty ? nil : gitValue(project, "user.email")
        var githubChanged = false

        func rollback() {
            if githubChanged, let previousGitHubLogin, previousGitHubLogin != profile.githubLogin {
                _ = Shell.run(githubExecutable, ["auth", "switch", "--hostname", "github.com", "--user", previousGitHubLogin], timeout: 12)
            }
            if let previousVercelData {
                try? previousVercelData.write(to: activeVercelFile, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: activeVercelFile)
            }
            if !project.isEmpty {
                restoreGitValue(project, key: "user.name", value: previousGitName)
                restoreGitValue(project, key: "user.email", value: previousGitEmail)
            }
        }

        switch Shell.run(githubExecutable, ["auth", "switch", "--hostname", "github.com", "--user", profile.githubLogin], timeout: 12) {
        case .output: githubChanged = true
        case .timedOut: return SwitchOutcome(success: false, message: "GitHub account switching timed out.")
        case .launchFailed(let reason): return SwitchOutcome(success: false, message: "GitHub CLI could not start: \(reason)")
        case .failed: return SwitchOutcome(success: false, message: "GitHub could not switch to \(profile.githubLogin).")
        }

        if let session {
            if !profile.vercelTeam.isEmpty {
                let args = ["teams", "switch", profile.vercelTeam, "--global-config", session.directory, "--non-interactive"]
                guard case .output = Shell.run(vercelExecutable!, args, timeout: 20) else {
                    rollback()
                    return SwitchOutcome(success: false, message: "Vercel could not switch to team \(profile.vercelTeam). Previous settings were restored.")
                }
            }
            do {
                try FileManager.default.createDirectory(at: activeVercelFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data(session.directory.utf8).write(to: activeVercelFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeVercelFile.path)
            } catch {
                rollback()
                return SwitchOutcome(success: false, message: "Nori could not select the Vercel session. Previous settings were restored: \(error.localizedDescription)")
            }
        }

        if !project.isEmpty {
            if !profile.gitName.isEmpty,
               case .output = Shell.run("/usr/bin/git", ["-C", project, "config", "--local", "user.name", profile.gitName], timeout: 5) {} else if !profile.gitName.isEmpty {
                rollback()
                return SwitchOutcome(success: false, message: "Git could not apply the repository author name. Previous settings were restored.")
            }
            if !profile.gitEmail.isEmpty,
               case .output = Shell.run("/usr/bin/git", ["-C", project, "config", "--local", "user.email", profile.gitEmail], timeout: 5) {} else if !profile.gitEmail.isEmpty {
                rollback()
                return SwitchOutcome(success: false, message: "Git could not apply the repository author email. Previous settings were restored.")
            }
        }
        return SwitchOutcome(success: true, message: "Active profile: \(profile.name)")
    }

    private static func gitValue(_ project: String, _ key: String) -> String? {
        guard case .output(let data) = Shell.run("/usr/bin/git", ["-C", project, "config", "--local", "--get", key], timeout: 5) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func restoreGitValue(_ project: String, key: String, value: String?) {
        if let value {
            _ = Shell.run("/usr/bin/git", ["-C", project, "config", "--local", key, value], timeout: 5)
        } else {
            _ = Shell.run("/usr/bin/git", ["-C", project, "config", "--local", "--unset-all", key], timeout: 5)
        }
    }
}

enum AccountCommand {
    static func use(_ requestedName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SwitchOutcome {
        let support = home.appendingPathComponent("Library/Application Support/Nori", isDirectory: true)
        let storeURL = support.appendingPathComponent("accounts.json")
        var store = AccountStore.load(from: storeURL)
        guard let profile = store.profiles.first(where: { $0.name.caseInsensitiveCompare(requestedName) == .orderedSame }) else {
            let names = store.profiles.map(\.name).joined(separator: ", ")
            return SwitchOutcome(success: false, message: names.isEmpty ? "No Nori profiles exist yet." : "Unknown profile \(requestedName). Available: \(names)")
        }
        let github = AccountDiscovery.executable(named: "gh")
        let vercel = AccountDiscovery.executable(named: "vercel")
        let previous = AccountDiscovery.githubAccounts(executable: github).first(where: \.active)?.login
        let outcome = ProfileSwitcher.apply(
            profile,
            sessions: store.vercelSessions,
            previousGitHubLogin: previous,
            githubExecutable: github,
            vercelExecutable: vercel,
            activeVercelFile: support.appendingPathComponent("active-vercel-path")
        )
        if outcome.success {
            store.activeProfileID = profile.id
            try? AccountStore.save(store, to: storeURL)
        }
        return outcome
    }
}
