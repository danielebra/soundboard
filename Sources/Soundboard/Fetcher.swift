import AppKit

/// Downloads and previews through the bundled SoundboardFetch helper.
///
/// The main app is sandboxed without network access, so it can't download anything
/// itself. The helper is a separate tiny app that only runs when you look up, preview or
/// download something, and talks to this app only through files in the downloads folder.
enum Fetcher {
    enum Mode: String {
        /// Video details only (title, channel, length, thumbnail).
        case info
        /// YouTube and other video sites (yt-dlp).
        case video
        /// A web page, e.g. a soundboard site: list the sounds on it.
        case page
        /// A link straight to an audio/video file.
        case direct
    }

    struct Choice: Equatable, Hashable, Identifiable {
        let url: String
        let name: String
        var id: String { url }
    }

    struct VideoInfo: Equatable {
        let title: String
        let uploader: String
        let duration: Double
        /// Local copy of the thumbnail, if one was available.
        let thumbnail: URL?
    }

    enum Status {
        case progress(Double, String)
        case done(URL, title: String)
        /// The sounds found on a page: preview them, then fetch one with `.direct`.
        case choices([Choice], pageTitle: String)
        case info(VideoInfo)
    }

    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/SoundboardFetch.app")
    }

    static var downloads: URL { Paths.root.appending(path: "downloads", directoryHint: .isDirectory) }

    /// Downloads are only needed while editing; clear leftovers from earlier sessions.
    static func clearDownloads() {
        let files = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Hands a request to a new helper instance. Returns the job id.
    /// (Launch arguments don't reach apps opened from the sandbox, so it's a request file.)
    static func launch(_ fields: [String: String]) throws -> String {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw AudioError.message("Download helper missing. Rebuild with ./build.sh")
        }
        let job = String(UUID().uuidString.prefix(8)).lowercased()
        let request = try JSONSerialization.data(withJSONObject: fields)
        try request.write(to: downloads.appending(path: "\(job).request.json"), options: .atomic)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            if let error { NSLog("Soundboard: helper launch failed: %@", error.localizedDescription) }
        }
        return job
    }

    static func statusURL(_ job: String) -> URL { downloads.appending(path: "\(job).json") }
    static func cancel(_ job: String) {
        FileManager.default.createFile(atPath: downloads.appending(path: "\(job).cancel").path, contents: nil)
    }

    static func readStatus(_ job: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: statusURL(job)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func fetch(_ link: URL, mode: Mode, title: String? = nil, section: ClosedRange<Double>? = nil)
        -> AsyncThrowingStream<Status, Error> {
        AsyncThrowingStream { continuation in
            var fields = ["link": link.absoluteString, "mode": mode.rawValue]
            if let title { fields["title"] = title }
            if let section { fields["section"] = String(format: "%.2f-%.2f", section.lowerBound, section.upperBound) }
            let job: String
            do { job = try launch(fields) } catch {
                continuation.finish(throwing: error)
                return
            }

            let poll = Task {
                let started = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let status = readStatus(job) else {
                        if Date().timeIntervalSince(started) > 20 {
                            continuation.finish(throwing: AudioError.message("The download helper didn't start."))
                            return
                        }
                        continue
                    }
                    let message = status["message"] as? String ?? ""
                    let state = status["state"] as? String
                    if state != "downloading" { try? FileManager.default.removeItem(at: statusURL(job)) }
                    switch state {
                    case "done":
                        if let file = status["file"] as? String {
                            continuation.yield(.done(URL(fileURLWithPath: file), title: status["title"] as? String ?? ""))
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: AudioError.message("Download finished but no file was produced."))
                        }
                        return
                    case "choices":
                        let choices = (status["choices"] as? [[String: String]] ?? []).compactMap { item -> Choice? in
                            guard let url = item["url"] else { return nil }
                            return Choice(url: url, name: item["name"] ?? url)
                        }
                        continuation.yield(.choices(choices, pageTitle: status["title"] as? String ?? ""))
                        continuation.finish()
                        return
                    case "info":
                        continuation.yield(.info(VideoInfo(
                            title: status["title"] as? String ?? "",
                            uploader: status["uploader"] as? String ?? "",
                            duration: status["duration"] as? Double ?? 0,
                            thumbnail: (status["thumbnail"] as? String).map { URL(fileURLWithPath: $0) })))
                        continuation.finish()
                        return
                    case "error":
                        continuation.finish(throwing: AudioError.message(message))
                        return
                    default:
                        continuation.yield(.progress(status["progress"] as? Double ?? 0, message))
                    }
                }
            }

            continuation.onTermination = { reason in
                poll.cancel()
                if case .cancelled = reason { cancel(job) }
            }
        }
    }
}

/// Streams a sound or a video's audio through the helper, straight to the speakers.
/// Nothing is saved to disk; only one preview plays at a time.
final class PreviewPlayer: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case failed(String)
    }

    /// What's being previewed (a choice URL, or a video link).
    @Published private(set) var current: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0

    private var job: String?
    private var poll: Task<Void, Never>?

    func isPlaying(_ id: String) -> Bool { current == id && (state == .playing || state == .loading) }

    /// `video`: the link is a YouTube/video-site page rather than an audio file.
    func play(_ link: String, video: Bool) {
        stop()
        do {
            job = try Fetcher.launch(["link": link, "mode": "preview", "kind": video ? "video" : "audio"])
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        current = link
        state = .loading
        position = 0
        duration = 0
        let job = self.job!
        poll = Task { @MainActor [weak self] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.job == job else { return }
                guard let status = Fetcher.readStatus(job) else {
                    if Date().timeIntervalSince(started) > 25 { self.state = .failed("The preview didn't start.") }
                    continue
                }
                self.position = status["position"] as? Double ?? self.position
                self.duration = status["duration"] as? Double ?? self.duration
                switch status["state"] as? String {
                case "playing": self.state = .playing
                case "ended":
                    self.finish()
                    return
                case "error":
                    self.state = .failed(status["message"] as? String ?? "Preview failed.")
                    self.finish(keepState: true)
                    return
                default: self.state = .loading
                }
            }
        }
    }

    func seek(to seconds: Double) {
        guard let job else { return }
        position = seconds
        try? String(seconds).write(to: Fetcher.downloads.appending(path: "\(job).seek"), atomically: true, encoding: .utf8)
    }

    func stop() {
        if let job { Fetcher.cancel(job) }
        finish()
    }

    private func finish(keepState: Bool = false) {
        poll?.cancel()
        poll = nil
        if let job { try? FileManager.default.removeItem(at: Fetcher.statusURL(job)) }
        job = nil
        if !keepState {
            current = nil
            state = .idle
        }
    }
}
