import Foundation

/// Keeps the sounds and keys in a Git repository the user owns, so every Mac connected to it
/// has the same board. The app has no network access, so the helper does the syncing (its
/// `sync` mode); this side decides when, and shows how it went.
///
/// Syncs when connected and at launch, 15 s after the sounds or keys change, and every
/// 10 minutes. One sync runs at a time; a request during one runs once it's done.
final class SyncService {
    enum State: Equatable {
        case off
        case syncing(String)
        case synced(Date)
        case failed(String)
    }

    private(set) var state: State = .off {
        didSet { if state != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    private var remote: String?
    private var running = false
    private var again = false
    private var soon: DispatchWorkItem?
    private var timer: Timer?

    /// Called whenever the config is applied; only a different repository changes anything.
    func configure(remote: String?) {
        let remote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = remote?.isEmpty == false ? remote : nil
        guard normalized != self.remote else { return }
        self.remote = normalized
        soon?.cancel()
        timer?.invalidate()
        timer = nil
        guard normalized != nil else {
            state = .off
            return
        }
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.syncNow() }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        syncNow()
    }

    /// The sounds or keys changed: sync once the edits settle.
    func changed() {
        guard remote != nil else { return }
        soon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        soon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    func syncNow() {
        guard let remote else { return }
        soon?.cancel()
        guard !running else {
            again = true
            return
        }
        running = true
        state = .syncing("Starting…")
        Task { @MainActor [weak self] in
            let result = await Self.run(remote) { message in
                if self?.remote == remote { self?.state = .syncing(message) }
            }
            guard let self else { return }
            self.running = false
            // Disconnected or switched repositories meanwhile: that result no longer applies.
            if self.remote == remote {
                switch result {
                case .success: self.state = .synced(Date())
                case let .failure(error): self.state = .failed(error.localizedDescription)
                }
            }
            if self.again {
                self.again = false
                self.syncNow()
            }
        }
    }

    /// One sync through the helper, reporting its progress messages.
    @MainActor
    private static func run(_ remote: String, progress: @escaping (String) -> Void) async -> Result<Void, Error> {
        let job: String
        do {
            job = try Fetcher.launch(["mode": "sync", "link": remote])
        } catch {
            return .failure(error)
        }
        let started = Date()
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            // The helper gives each git command a time limit, so this is only a backstop.
            if Date().timeIntervalSince(started) > 1200 {
                Fetcher.cancel(job)
                return .failure(AudioError.message("The sync took too long."))
            }
            guard let status = Fetcher.readStatus(job) else {
                if Date().timeIntervalSince(started) > 20 { return .failure(AudioError.message("The sync helper didn't start.")) }
                continue
            }
            let message = status["message"] as? String ?? ""
            switch status["state"] as? String {
            case "synced":
                try? FileManager.default.removeItem(at: Fetcher.statusURL(job))
                return .success(())
            case "error":
                try? FileManager.default.removeItem(at: Fetcher.statusURL(job))
                return .failure(AudioError.message(message))
            default:
                progress(message)
            }
        }
    }
}
