import Foundation

@MainActor final class AccountManager: ObservableObject {
    @Published private(set) var githubAccounts: [GitHubAccount] = []
    @Published private(set) var vercelSessions: [VercelSession] = []
    @Published private(set) var profiles: [DeveloperProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var busy = false
    @Published var message = "Loading developer accounts…"
    @Published private(set) var shellIntegrationInstalled = false

    private let storeURL: URL
    private let supportURL: URL
    private let queue = DispatchQueue(label: "Nori.accounts", qos: .utility)
    private let githubExecutable = AccountDiscovery.executable(named: "gh")
    private let vercelExecutable = AccountDiscovery.executable(named: "vercel")

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        supportURL = home.appendingPathComponent("Library/Application Support/Nori", isDirectory: true)
        storeURL = supportURL.appendingPathComponent("accounts.json")
        let saved = AccountStore.load(from: storeURL)
        profiles = saved.profiles
        vercelSessions = saved.vercelSessions
        activeProfileID = saved.activeProfileID
        importDefaultVercelSession(home: home)
        shellIntegrationInstalled = Self.shellBlockExists(home: home)
        refresh()
    }

    var activeProfile: DeveloperProfile? { profiles.first { $0.id == activeProfileID } }
    var activeProfileName: String { activeProfile?.name ?? "No profile" }
    var activeVercelFile: URL { supportURL.appendingPathComponent("active-vercel-path") }

    func refresh(verifying profile: DeveloperProfile? = nil) {
        guard !busy else { return }
        busy = true
        let githubExecutable = githubExecutable
        let vercelExecutable = vercelExecutable
        let sessions = vercelSessions
        queue.async { [weak self] in
            let github = AccountDiscovery.githubAccounts(executable: githubExecutable)
            let refreshed = sessions.map { session -> VercelSession in
                var copy = session
                copy.username = AccountDiscovery.vercelUsername(executable: vercelExecutable, directory: session.directory) ?? session.username
                return copy
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.githubAccounts = github
                self.vercelSessions = refreshed
                self.busy = false
                if let profile {
                    if github.first(where: \.active)?.login == profile.githubLogin {
                        self.message = "Active profile: \(profile.name) · GitHub verified"
                    } else {
                        self.message = "\(profile.name) was selected, but GitHub could not be verified."
                    }
                } else if github.isEmpty {
                    self.message = self.githubExecutable == nil ? "Install GitHub CLI to switch GitHub accounts." : "No GitHub CLI accounts were found."
                } else {
                    self.message = "\(github.count) GitHub account\(github.count == 1 ? "" : "s") · \(refreshed.count) Vercel session\(refreshed.count == 1 ? "" : "s")"
                }
                self.persist()
            }
        }
    }

    func saveProfile(_ profile: DeveloperProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
        message = "Saved \(profile.name)."
    }

    func removeProfile(_ profile: DeveloperProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
        persist()
        message = "Removed \(profile.name). Vercel credentials were left untouched."
    }

    func switchTo(_ profile: DeveloperProfile) {
        guard !busy else { return }
        busy = true
        message = "Switching to \(profile.name)…"
        let sessions = vercelSessions
        let githubExecutable = githubExecutable
        let vercelExecutable = vercelExecutable
        let activeFile = activeVercelFile
        let previousGitHubLogin = githubAccounts.first(where: \.active)?.login
        queue.async { [weak self] in
            let outcome = ProfileSwitcher.apply(
                profile,
                sessions: sessions,
                previousGitHubLogin: previousGitHubLogin,
                githubExecutable: githubExecutable,
                vercelExecutable: vercelExecutable,
                activeVercelFile: activeFile
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                self.message = outcome.message
                if outcome.success {
                    self.activeProfileID = profile.id
                    self.persist()
                    self.refresh(verifying: profile)
                }
            }
        }
    }

    func addVercelSession(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !busy else { return }
        guard let vercelExecutable else { message = "Vercel CLI was not found."; return }
        busy = true
        message = "Complete the Vercel sign-in in your browser…"
        let session = VercelSession(
            id: UUID(),
            name: name,
            directory: supportURL.appendingPathComponent("Vercel/" + UUID().uuidString, isDirectory: true).path,
            username: nil,
            isDefault: false
        )
        queue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(atPath: session.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                Task { @MainActor [weak self] in self?.busy = false; self?.message = "Could not create the Vercel profile directory." }
                return
            }
            let result = Shell.run(vercelExecutable, ["login", "--global-config", session.directory], timeout: 300)
            let username = AccountDiscovery.vercelUsername(executable: vercelExecutable, directory: session.directory)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                guard case .output = result else {
                    self.message = result.timedOut ? "Vercel sign-in timed out. Try again when ready." : "Vercel sign-in did not complete."
                    return
                }
                var completed = session
                completed.username = username
                self.vercelSessions.append(completed)
                self.persist()
                self.message = "Added Vercel session \(completed.displayName)."
            }
        }
    }

    func removeVercelSession(_ session: VercelSession) {
        guard !profiles.contains(where: { $0.vercelSessionID == session.id }) else {
            message = "Remove this Vercel session from its profiles first."
            return
        }
        vercelSessions.removeAll { $0.id == session.id }
        persist()
        message = "Removed \(session.name) from Nori. Its credential directory was not deleted."
    }

    func installShellIntegration() {
        guard let vercelExecutable else { message = "Vercel CLI was not found."; return }
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let bin = home.appendingPathComponent(".nori/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let wrapper = bin.appendingPathComponent("vercel")
            let noriWrapper = bin.appendingPathComponent("nori")
            let activeFile = shellQuote(activeVercelFile.path)
            let realCLI = shellQuote(vercelExecutable)
            let script = """
            #!/bin/zsh
            set -e
            active_file=\(activeFile)
            if [[ -r "$active_file" ]]; then
              profile_dir="$(cat "$active_file")"
              if [[ -n "$profile_dir" ]]; then
                exec \(realCLI) --global-config "$profile_dir" "$@"
              fi
            fi
            exec \(realCLI) "$@"
            """
            try Data(script.utf8).write(to: wrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            guard let noriExecutable = Bundle.main.executableURL?.path else { throw CocoaError(.fileNoSuchFile) }
            let noriScript = """
            #!/bin/zsh
            installed="/Applications/Nori.app/Contents/MacOS/Nori"
            if [[ -x "$installed" ]]; then
              exec "$installed" "$@"
            fi
            exec \(shellQuote(noriExecutable)) "$@"
            """
            try Data(noriScript.utf8).write(to: noriWrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: noriWrapper.path)
            let zshrc = home.appendingPathComponent(".zshrc")
            let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
            if !existing.contains(Self.shellMarkerStart) {
                let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                let block = "\(separator)\(Self.shellMarkerStart)\nexport PATH=\"$HOME/.nori/bin:$PATH\"\n\(Self.shellMarkerEnd)\n"
                try Data((existing + block).utf8).write(to: zshrc, options: .atomic)
            }
            shellIntegrationInstalled = true
            message = "Shell integration installed. Open a new terminal once; use nori use <profile> or switch in the app."
        } catch {
            message = "Shell integration could not be installed: \(error.localizedDescription)"
        }
    }

    func mismatch(for profile: DeveloperProfile) -> ProfileMismatch { ProfileInspector.inspect(profile) }

    private func importDefaultVercelSession(home: URL) {
        let directory = home.appendingPathComponent("Library/Application Support/com.vercel.cli", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path),
              !vercelSessions.contains(where: { $0.directory == directory.path }) else { return }
        vercelSessions.insert(VercelSession(id: UUID(), name: "Default Vercel", directory: directory.path, username: nil, isDefault: true), at: 0)
        persist()
    }

    private func persist() {
        try? AccountStore.save(AccountStoreData(profiles: profiles, vercelSessions: vercelSessions, activeProfileID: activeProfileID), to: storeURL)
    }

    private static let shellMarkerStart = "# >>> Nori developer profiles >>>"
    private static let shellMarkerEnd = "# <<< Nori developer profiles <<<"
    private static func shellBlockExists(home: URL) -> Bool {
        let text = try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        return text?.contains(shellMarkerStart) == true
            && FileManager.default.isExecutableFile(atPath: home.appendingPathComponent(".nori/bin/vercel").path)
            && FileManager.default.isExecutableFile(atPath: home.appendingPathComponent(".nori/bin/nori").path)
    }
}

private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private extension ShellResult {
    var timedOut: Bool { if case .timedOut = self { true } else { false } }
}
