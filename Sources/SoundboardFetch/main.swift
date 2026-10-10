import Foundation

// SoundboardFetch: the only part of Soundboard that uses the network.
//
// The sandboxed main app can't pass launch arguments to another app, so it writes
// <job>.request.json into the downloads folder and launches this helper:
//
//   {"link": …, "mode": "video" | "page" | "direct", "title": optional}
//
//   video   YouTube and other video sites, via yt-dlp (small ≤480p copy).
//   page    A web page such as a soundboard site: finds the audio files on it. One →
//           downloads it; several → reports them as choices; none → tries yt-dlp.
//   direct  A link straight to an audio/video file.
//
// Progress and the result go to <job>.json. Stops early if <job>.cancel appears.
// Files macOS can't play (ogg, webm, opus…) are converted to WAV with ffmpeg.

let folder = URL(fileURLWithPath: NSHomeDirectory())
    .appending(path: "Library/Application Support/Soundboard/downloads", directoryHint: .isDirectory)

struct FetchError: Error {
    let message: String
}

extension URL {
    var creationDate: Date? { (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate }
}

/// Claims the oldest pending request (renaming it so a second helper won't take it too).
func nextRequest() -> (job: String, request: [String: String])? {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
    let requests = files.filter { $0.lastPathComponent.hasSuffix(".request.json") }
        .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    for request in requests {
        let claimed = request.deletingPathExtension().appendingPathExtension("claimed")
        guard (try? FileManager.default.moveItem(at: request, to: claimed)) != nil else { continue }
        defer { try? FileManager.default.removeItem(at: claimed) }
        guard let data = try? Data(contentsOf: claimed),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              json["link"] != nil else { continue }
        return (request.lastPathComponent.replacingOccurrences(of: ".request.json", with: ""), json)
    }
    return nil
}

guard let (job, request) = nextRequest(), let link = request["link"] else { exit(0) }
let statusURL = folder.appending(path: "\(job).json")
let cancelURL = folder.appending(path: "\(job).cancel")
var isCancelled: Bool { FileManager.default.fileExists(atPath: cancelURL.path) }

func report(_ status: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: status) else { return }
    try? data.write(to: statusURL, options: .atomic)
}

func progress(_ fraction: Double, _ message: String, title: String = "") {
    report(["state": "downloading", "progress": fraction, "message": message, "title": title])
}

let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin"]

func tool(_ name: String) -> String? {
    searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

let mediaExtensions: Set<String> = ["mp3", "wav", "ogg", "oga", "m4a", "aac", "opus", "flac", "webm", "mp4", "mov", "m4v", "aif", "aiff", "caf"]
let playableExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "mp4", "mov", "m4v", "aif", "aiff", "caf"]
let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

func isMedia(_ url: URL) -> Bool { mediaExtensions.contains(url.pathExtension.lowercased()) }

func niceName(_ url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
    return stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - Direct downloads

func download(_ url: URL, title: String) throws -> (file: String, title: String) {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
    let target = folder.appending(path: "\(job).\(ext)")

    var outcome: Result<URL, Error>?
    let done = DispatchSemaphore(value: 0)
    let task = URLSession.shared.downloadTask(with: request) { temp, response, error in
        if let error {
            outcome = .failure(error)
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            outcome = .failure(FetchError(message: "The site answered with error \(http.statusCode)."))
        } else if let temp {
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temp, to: target)
                outcome = .success(target)
            } catch {
                outcome = .failure(error)
            }
        }
        done.signal()
    }
    task.resume()
    while done.wait(timeout: .now() + 0.2) == .timedOut {
        if isCancelled {
            task.cancel()
            exit(0)
        }
        progress(task.progress.fractionCompleted, "Downloading \(url.lastPathComponent)…", title: title)
    }
    switch outcome {
    case let .success(file)?: return (file.path, title)
    case let .failure(error as FetchError)?: throw error
    case let .failure(error)?: throw FetchError(message: error.localizedDescription)
    case nil: throw FetchError(message: "Download failed.")
    }
}

// MARK: - Finding sounds on a web page

/// Audio/video file links in a page's HTML: src/href attributes, onclick="play('/x.mp3')",
/// JSON blobs — anything quoted that ends in a media extension.
func findMedia(on page: URL) throws -> (choices: [(url: URL, name: String)], pageTitle: String) {
    var request = URLRequest(url: page)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    var html = ""
    var failure: String?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            failure = error.localizedDescription
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = "The site answered with error \(http.statusCode)."
        } else if let data {
            html = String(decoding: data, as: UTF8.self)
        }
        done.signal()
    }.resume()
    done.wait()
    if let failure { throw FetchError(message: failure) }

    let extensions = mediaExtensions.joined(separator: "|")
    let pattern = #"["'(]((?:https?:)?[^"'()\s<>]+?\.(?:"# + extensions + #"))(?:\?[^"'()\s<>]*)?["')]"#
    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    var seen = Set<String>()
    var choices: [(url: URL, name: String)] = []
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
        guard let range = Range(match.range(at: 1), in: html) else { continue }
        let raw = String(html[range]).replacingOccurrences(of: "\\/", with: "/")
        guard let url = URL(string: raw, relativeTo: page)?.absoluteURL, url.scheme?.hasPrefix("http") == true,
              seen.insert(url.absoluteString).inserted else { continue }
        choices.append((url, niceName(url)))
        if choices.count >= 100 { break }
    }

    var pageTitle = ""
    if let start = html.range(of: "<title>", options: .caseInsensitive),
       let end = html.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<html.endIndex) {
        pageTitle = String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return (choices, pageTitle)
}

// MARK: - yt-dlp

func runYtDlp(_ link: String) throws -> (file: String, title: String) {
    guard let ytdlp = tool("yt-dlp") else {
        throw FetchError(message: "yt-dlp isn't installed. In Terminal, run: brew install yt-dlp")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ytdlp)
    process.arguments = [
        "--no-playlist", "--newline", "--progress",
        // Small H.264 copy: enough to see the moment, plays natively, downloads fast.
        "-f", "bv*[height<=480][vcodec^=avc1]+ba[ext=m4a]/b[height<=480][ext=mp4]/bv*[height<=720][vcodec^=avc1]+ba/b[ext=mp4]/b",
        "--merge-output-format", "mp4",
        "--max-filesize", "800M",
        "-o", folder.appending(path: "\(job).%(ext)s").path,
        "--print", "before_dl:TITLE:%(title)s",
        "--print", "after_move:FILE:%(filepath)s",
        "--", link,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = searchPath.joined(separator: ":") // so yt-dlp finds ffmpeg and deno
    process.environment = environment

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var title = "", file: String?, lastError = "", fraction = 0.0, message = "Starting…", dirty = true
    }
    let state = State()

    func consume(_ line: String) {
        state.lock.lock()
        defer { state.lock.unlock() }
        if line.hasPrefix("TITLE:") {
            state.title = String(line.dropFirst(6))
            state.message = "Downloading “\(state.title)”"
        } else if line.hasPrefix("FILE:") {
            state.file = String(line.dropFirst(5))
        } else if line.hasPrefix("[download]"), let sign = line.firstIndex(of: "%") {
            let digits = line[..<sign].reversed().prefix { $0.isNumber || $0 == "." }
            if let value = Double(String(digits.reversed())) { state.fraction = value / 100 }
            state.message = line.replacingOccurrences(of: "[download]", with: "").trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("[Merger]") {
            state.message = "Finishing up…"
        } else if line.hasPrefix("ERROR:") {
            state.lastError = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        state.dirty = true
    }

    func read(_ pipe: Pipe) {
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if !line.isEmpty { consume(line) }
            }
        }
    }

    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    read(out)
    read(err)
    do { try process.run() } catch { throw FetchError(message: "Couldn't run yt-dlp: \(error.localizedDescription)") }

    while process.isRunning {
        if isCancelled {
            process.terminate()
            exit(0)
        }
        state.lock.lock()
        if state.dirty {
            progress(state.fraction, state.message, title: state.title)
            state.dirty = false
        }
        state.lock.unlock()
        Thread.sleep(forTimeInterval: 0.2)
    }
    Thread.sleep(forTimeInterval: 0.2) // let the pipes drain

    state.lock.lock()
    defer { state.lock.unlock() }
    guard process.terminationStatus == 0, let file = state.file, FileManager.default.fileExists(atPath: file) else {
        throw FetchError(message: state.lastError.isEmpty ? "yt-dlp failed (exit \(process.terminationStatus))" : state.lastError)
    }
    return (file, state.title)
}

// MARK: - Making it playable

func ensurePlayable(_ file: String) throws -> String {
    let url = URL(fileURLWithPath: file)
    guard !playableExtensions.contains(url.pathExtension.lowercased()) else { return file }
    guard let ffmpeg = tool("ffmpeg") else {
        throw FetchError(message: "This is a .\(url.pathExtension) file, which needs ffmpeg to convert. In Terminal, run: brew install ffmpeg")
    }
    progress(1, "Converting…")
    let output = folder.appending(path: "\(job)-converted.wav")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = ["-nostdin", "-loglevel", "error", "-y", "-i", file, "-vn", "-c:a", "pcm_s16le", output.path]
    try process.run()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: url)
    guard process.terminationStatus == 0 else { throw FetchError(message: "Couldn't convert the downloaded file.") }
    return output.path
}

// MARK: - Main

do {
    guard let url = URL(string: link), url.scheme?.hasPrefix("http") == true else {
        throw FetchError(message: "That doesn't look like a web link.")
    }
    let mode = request["mode"] ?? "video"
    var result: (file: String, title: String)

    switch mode {
    case "direct":
        result = try download(url, title: request["title"] ?? niceName(url))
    case "page":
        if isMedia(url) {
            result = try download(url, title: niceName(url))
        } else {
            progress(0, "Looking for sounds on the page…")
            let found = try findMedia(on: url)
            if found.choices.count == 1 {
                result = try download(found.choices[0].url, title: found.choices[0].name)
            } else if found.choices.count > 1 {
                report(["state": "choices", "title": found.pageTitle,
                        "choices": found.choices.map { ["url": $0.url.absoluteString, "name": $0.name] }])
                exit(0)
            } else {
                progress(0, "No sound files on the page — trying it as a video…")
                result = try runYtDlp(link)
            }
        }
    default:
        result = try runYtDlp(link)
    }

    let playable = try ensurePlayable(result.file)
    report(["state": "done", "file": playable, "title": result.title])
} catch let error as FetchError {
    report(["state": "error", "message": error.message])
} catch {
    report(["state": "error", "message": error.localizedDescription])
}
