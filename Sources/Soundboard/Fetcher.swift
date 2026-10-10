import AppKit

/// Downloads a video through the bundled SoundboardFetch helper.
///
/// The main app is sandboxed without network access, so it can't download anything
/// itself. The helper is a separate tiny app that only runs `yt-dlp` when you click
/// Fetch, and talks to this app only through files in the Soundboard downloads folder.
enum Fetcher {
    enum Status {
        case progress(Double, String)
        case done(URL, title: String)
    }

    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/SoundboardFetch.app")
    }

    static var downloads: URL { Paths.root.appending(path: "downloads", directoryHint: .isDirectory) }

    static func fetch(_ link: URL) -> AsyncThrowingStream<Status, Error> {
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
                let request = try JSONSerialization.data(withJSONObject: ["link": link.absoluteString])
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
