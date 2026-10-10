import AppKit

/// Downloads a video through the bundled SoundboardFetch helper.
///
/// The main app is sandboxed without network access, so it can't download anything
/// itself. The helper is a separate tiny app that only runs `yt-dlp` when you click
/// Fetch, and talks to this app only through files in the Soundboard downloads folder.
enum Fetcher {
    enum Mode: String {
        /// YouTube and other video sites (yt-dlp).
        case video
        /// A web page, e.g. a soundboard site: find the sounds on it.
        case page
        /// A link straight to an audio/video file.
        case direct
    }

    struct Choice: Equatable, Hashable, Identifiable {
        let url: String
        let name: String
        var id: String { url }
    }

    enum Status {
        case progress(Double, String)
        case done(URL, title: String)
        /// A page with several sounds on it — fetch one of these with `.direct`.
        case choices([Choice], pageTitle: String)
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

    static func fetch(_ link: URL, mode: Mode, title: String? = nil) -> AsyncThrowingStream<Status, Error> {
        AsyncThrowingStream { continuation in
            let job = String(UUID().uuidString.prefix(8)).lowercased()
            let statusURL = downloads.appending(path: "\(job).json")
            let cancelURL = downloads.appending(path: "\(job).cancel")

            do {
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            guard FileManager.default.fileExists(atPath: helperURL.path) else {
                continuation.finish(throwing: AudioError.message("Download helper missing — rebuild with ./build.sh"))
                return
            }

            // Launch arguments don't reach apps opened from the sandbox, so hand over a request file.
            do {
                var fields = ["link": link.absoluteString, "mode": mode.rawValue]
                if let title { fields["title"] = title }
                let request = try JSONSerialization.data(withJSONObject: fields)
                try request.write(to: downloads.appending(path: "\(job).request.json"), options: .atomic)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
                if let error { continuation.finish(throwing: error) }
            }

            let poll = Task {
                let started = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let data = try? Data(contentsOf: statusURL),
                          let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else {
                        if Date().timeIntervalSince(started) > 20 {
                            continuation.finish(throwing: AudioError.message("The download helper didn't start."))
                            return
                        }
                        continue
                    }
                    let message = status["message"] as? String ?? ""
                    switch status["state"] as? String {
                    case "done":
                        try? FileManager.default.removeItem(at: statusURL)
                        if let file = status["file"] as? String {
                            continuation.yield(.done(URL(fileURLWithPath: file), title: status["title"] as? String ?? ""))
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: AudioError.message("Download finished but no file was produced."))
                        }
                        return
                    case "choices":
                        try? FileManager.default.removeItem(at: statusURL)
                        let choices = (status["choices"] as? [[String: String]] ?? []).compactMap { item -> Choice? in
                            guard let url = item["url"] else { return nil }
                            return Choice(url: url, name: item["name"] ?? url)
                        }
                        continuation.yield(.choices(choices, pageTitle: status["title"] as? String ?? ""))
                        continuation.finish()
                        return
                    case "error":
                        try? FileManager.default.removeItem(at: statusURL)
                        continuation.finish(throwing: AudioError.message(message))
                        return
                    default:
                        continuation.yield(.progress(status["progress"] as? Double ?? 0, message))
                    }
                }
            }

            continuation.onTermination = { reason in
                poll.cancel()
                if case .cancelled = reason {
                    FileManager.default.createFile(atPath: cancelURL.path, contents: nil)
                }
            }
        }
    }
}
