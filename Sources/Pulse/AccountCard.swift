import SwiftUI
import AppKit

struct AccountCard: View {
    @ObservedObject var accounts: AccountManager
    @State private var editingProfile: DeveloperProfile?
    @State private var showingVercelLogin = false
    @State private var vercelSessionName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Developer profiles", systemImage: "person.2.badge.gearshape")
                    .font(.system(size: 15, weight: .semibold))
                if let active = accounts.activeProfile {
                    Text(active.name.uppercased())
                        .font(.system(size: 9, weight: .bold)).tracking(1)
                        .foregroundStyle(ocean).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(ocean.opacity(0.12), in: Capsule())
                }
                Spacer()
                if accounts.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { accounts.refresh() }.disabled(accounts.busy)
                Button {
                    editingProfile = DeveloperProfile(
                        id: UUID(),
                        name: "",
                        githubLogin: accounts.githubAccounts.first?.login ?? "",
                        vercelSessionID: accounts.vercelSessions.first?.id,
                        vercelTeam: "",
                        gitName: "",
                        gitEmail: "",
                        projectPath: ""
                    )
                } label: { Label("Add profile", systemImage: "plus") }
            }

            Text("Switch GitHub, Vercel, and repository-local Git identity together. Tokens remain in the CLIs’ protected credential stores.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            if accounts.profiles.isEmpty {
                ContentUnavailableView(
                    "No developer profiles yet",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Create Personal and Work profiles, then switch the full toolchain with one click.")
                ).frame(minHeight: 145)
            } else {
                ForEach(accounts.profiles) { profile in profileRow(profile) }
            }

            Divider()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GITHUB ACCOUNTS").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    if accounts.githubAccounts.isEmpty { Text("No accounts found").foregroundStyle(.secondary) }
                    ForEach(accounts.githubAccounts) { account in
                        Label(account.login, systemImage: account.active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(account.active ? ocean : Color.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("VERCEL SESSIONS").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add login") { showingVercelLogin = true }.controlSize(.small).disabled(accounts.busy)
                    }
                    if accounts.vercelSessions.isEmpty { Text("No sessions found").foregroundStyle(.secondary) }
                    ForEach(accounts.vercelSessions) { session in
                        HStack {
                            Image(systemName: "triangle.fill").font(.system(size: 8))
                            Text(session.displayName).lineLimit(1)
                            Spacer()
                            if !session.isDefault {
                                Button { accounts.removeVercelSession(session) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help("Remove this session from Nori without deleting credentials")
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 11))

            HStack {
                Image(systemName: accounts.shellIntegrationInstalled ? "terminal.fill" : "terminal")
                    .foregroundStyle(accounts.shellIntegrationInstalled ? ocean : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(accounts.shellIntegrationInstalled ? "Terminal follows Nori profiles" : "Enable seamless Vercel switching in Terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text(accounts.shellIntegrationInstalled
                         ? "Vercel follows profile switches. You can also run nori use <profile>."
                         : "Installs small nori/vercel wrappers and one PATH block in ~/.zshrc.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if !accounts.shellIntegrationInstalled {
                    Button("Install shell helper") { accounts.installShellIntegration() }.controlSize(.small)
                }
            }.padding(12).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))

            Text(accounts.message).font(.system(size: 10)).foregroundStyle(accounts.message.contains("could not") || accounts.message.contains("failed") ? Color.orange : Color.secondary)
        }
        .padding(20)
        .background(panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ocean.opacity(0.18)))
        .sheet(item: $editingProfile) { profile in
            ProfileEditor(accounts: accounts, profile: profile) { updated in accounts.saveProfile(updated) }
        }
        .sheet(isPresented: $showingVercelLogin) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Add Vercel login").font(.title2.bold())
                Text("Give this session a recognizable name. Vercel will open its normal browser sign-in; Nori never reads or stores the token.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Work Vercel", text: $vercelSessionName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showingVercelLogin = false }
                    Button("Continue") {
                        let name = vercelSessionName
                        showingVercelLogin = false
                        vercelSessionName = ""
                        accounts.addVercelSession(named: name)
                    }.buttonStyle(.borderedProminent).disabled(vercelSessionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(24).frame(width: 460).background(canvas).preferredColorScheme(.dark)
        }
    }

    private func profileRow(_ profile: DeveloperProfile) -> some View {
        let active = accounts.activeProfileID == profile.id
        let session = accounts.vercelSessions.first { $0.id == profile.vercelSessionID }
        let mismatch = accounts.mismatch(for: profile)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: active ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 25)).foregroundStyle(active ? ocean : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(profile.name).font(.system(size: 13, weight: .semibold))
                        if active { Text("ACTIVE").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(ocean) }
                    }
                    Text("GitHub: \(profile.githubLogin)  ·  Vercel: \(session?.displayName ?? "Not configured")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !profile.projectPath.isEmpty {
                        Text(profile.projectPath).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer()
                Button("Edit") { editingProfile = profile }.controlSize(.small)
                Button(active ? "Active" : "Switch") { accounts.switchTo(profile) }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(active || accounts.busy)
            }
            if !mismatch.clean {
                Label(mismatch.messages.joined(separator: " "), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
        }.padding(13).background((active ? ocean : Color.white).opacity(active ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 10))
            .contextMenu { Button("Remove profile", role: .destructive) { accounts.removeProfile(profile) } }
    }
}

private struct ProfileEditor: View {
    @ObservedObject var accounts: AccountManager
    @State var profile: DeveloperProfile
    let save: (DeveloperProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(profile.name.isEmpty ? "New developer profile" : "Edit \(profile.name)").font(.title2.bold()); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            Form {
                TextField("Profile name", text: $profile.name)
                Picker("GitHub account", selection: $profile.githubLogin) {
                    ForEach(accounts.githubAccounts) { Text($0.login).tag($0.login) }
                }
                Picker("Vercel session", selection: $profile.vercelSessionID) {
                    Text("Not configured").tag(nil as UUID?)
                    ForEach(accounts.vercelSessions) { Text($0.displayName).tag($0.id as UUID?) }
                }
                TextField("Vercel team slug (optional)", text: $profile.vercelTeam)
                Section("Repository-local Git identity") {
                    TextField("Author name", text: $profile.gitName)
                    TextField("Author email", text: $profile.gitEmail)
                }
                Section("Bound project (optional)") {
                    HStack {
                        TextField("Project folder", text: $profile.projectPath)
                        Button("Choose…") { chooseProject() }
                    }
                }
            }.formStyle(.grouped)
            Text("Git author settings are written only to the bound repository. Global Git identity is never changed.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Save profile") { save(profile); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty || profile.githubLogin.isEmpty)
            }
        }.padding(24).frame(width: 570).background(canvas).preferredColorScheme(.dark).tint(ocean)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Bind Project"
        if panel.runModal() == .OK { profile.projectPath = panel.url?.path ?? profile.projectPath }
    }
}
