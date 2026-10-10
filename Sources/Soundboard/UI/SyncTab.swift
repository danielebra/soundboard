import SwiftUI

/// Sync tab: connect a Git repository so other Macs get the same sounds and keys.
struct SyncTab: View {
    @ObservedObject var settings: SettingsModel
    let state: SyncService.State
    let syncNow: () -> Void
    @State private var remote = ""

    private var connected: String? { settings.config.syncRemote }

    var body: some View {
        Form {
            repository
            setup
            privacy
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
    }

    private var repository: some View {
        Section {
            if let connected {
                LabeledContent("Repository") { Text(connected).textSelection(.enabled) }
                LabeledContent("Status") { statusText }
                HStack {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath", action: syncNow)
                        .disabled(isSyncing)
                    Button("Disconnect") {
                        remote = connected
                        settings.update { $0.syncRemote = nil }
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
            } else {
                TextField("Repository", text: $remote, prompt: Text("git@github.com:you/soundboard-config.git"))
                    .onSubmit(connect)
                HStack {
                    Button("Connect", action: connect)
                        .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Sync with a Git repository")
        } footer: {
            Text("Your sounds, key pictures and pages are kept in a private Git repository that you own, so every Mac you connect has the same board. Settings on the Audio and Settings tabs stay on each Mac, because each Mac has its own devices.")
                .foregroundStyle(.secondary)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = state { return true }
        return false
    }

    @ViewBuilder private var statusText: some View {
        switch state {
        case .off: Text("Not syncing").foregroundStyle(.secondary)
        case let .syncing(message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message)
            }
        case let .synced(date):
            Label("Synced at \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private func connect() {
        let remote = remote.trimmingCharacters(in: .whitespaces)
        guard !remote.isEmpty else { return }
        settings.update { $0.syncRemote = remote }
    }

    private var setup: some View {
        Section {
            step(1, "Create an empty **private** repository called `soundboard-config`, on GitHub, GitLab or your own server.")
            step(2, "Check that this Mac can reach it: in Terminal, `git ls-remote <repository>` should finish without asking for anything. Use an SSH address (`git@…`) with your SSH key, or an HTTPS one with the login saved in the Keychain.")
            step(3, "Paste the address above and press Connect. Do the same on your other Macs.")
        } header: {
            Text("Setting up")
        } footer: {
            Text("A Mac that connects to a repository already in use keeps its own sounds and takes the repository's keys. Your edits are sent shortly after you make them. Other Macs' changes arrive when you launch Soundboard, edit, or press Sync Now; nothing syncs in the background. If two Macs change the same sound or key before syncing, the repository's version wins. Nothing is deleted for good: every version stays in the repository's history.")
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.secondary).frame(width: 14)
            Text(text)
        }
    }

    private var privacy: some View {
        Section("Privacy") {
            Text("Soundboard itself still has no network access. Syncing runs in its download helper, which uses this Mac's own `git`, so you sign in with your SSH key or Keychain and Soundboard never sees a password. The repository is the only place your sounds go.")
        }
    }
}
