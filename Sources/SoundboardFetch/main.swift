import AVFoundation
import Foundation

// SoundboardFetch: the only part of Soundboard that uses the network.
//
// The sandboxed main app can't pass launch arguments to another app, so it writes
// <job>.request.json into the downloads folder and launches this helper:
//
//   {"link": …, "mode": …, "title": optional, "section": optional "start-end" seconds}
//
//   info     Video details only (title, channel, length, thumbnail); nothing else downloaded.
//   preview  Streams the audio to the speakers without saving it. "kind": "video" streams a
//            YouTube/video-site link (via yt-dlp), otherwise the link is an audio file.
//            Seeks when <job>.seek (seconds) appears; stops on <job>.cancel.
//   video    Downloads a small (≤480p) copy via yt-dlp, optionally just "section".
//   page     Lists the sounds on a web page (a soundboard site) as choices. Downloads nothing.
//   direct   Downloads a link straight to an audio/video file.
//   sync     Syncs the Soundboard folder with the Git repository in "link" (see GitSync).
//            Reports {"state": "synced", "message": …} when done.
//
// git also runs this helper as config.json's merge driver: SoundboardFetch --merge-config %O %A %B.
//
// Progress and the result go to <job>.json. Stops early if <job>.cancel appears.
// Files macOS can't play (ogg, webm, opus…) are converted to WAV with ffmpeg.

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--merge-config" {
    let paths = CommandLine.arguments
    exit(ConfigMerge.run(base: paths[2], ours: paths[3], theirs: paths[4]))
}

/// The Soundboard folder. SOUNDBOARD_ROOT points it elsewhere, for testing sync in the shell.
let root = ProcessInfo.processInfo.environment["SOUNDBOARD_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support/Soundboard", directoryHint: .isDirectory)
let folder = root.appending(path: "downloads", directoryHint: .isDirectory)

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

let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

let maxDownloadBytes = 200_000_000

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
        } else if let type = response?.mimeType?.lowercased(), type.hasPrefix("text/") || type.contains("html") {
            outcome = .failure(FetchError(message: "That link is a web page, not a sound file."))
        } else if let temp, let size = try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxDownloadBytes {
            outcome = .failure(FetchError(message: "That file is over \(maxDownloadBytes / 1_000_000) MB, too big for a sound effect."))
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

func fetchText(_ url: URL) throws -> String {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    var text = ""
    var failure: String?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            failure = error.localizedDescription
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = "The site answered with error \(http.statusCode)."
        } else if let data {
            text = String(decoding: data, as: UTF8.self)
        }
        done.signal()
    }.resume()
    done.wait()
    if let failure { throw FetchError(message: failure) }
    return text
}

/// Whether `url` answers with audio/video (a HEAD request, nothing downloaded).
func servesMedia(_ url: URL) -> Bool {
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.httpMethod = "HEAD"
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    var ok = false
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, response, _ in
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            ok = type.hasPrefix("audio/") || type.hasPrefix("video/") || type.contains("octet-stream")
        }
        done.signal()
    }.resume()
    done.wait()
    return ok
}

/// Undoes the escaping pages use when they embed data: HTML entities, Angular's
/// transfer-state codes (&q; for a quote), and JSON's escaped slashes.
/// Sounds on a page. Looks in two places:
/// - embedded data records, e.g. {"name": "Airhorn", "fileName": "abc.mp3", "url": "airhorn-123"},
///   which also give each sound a proper name;
/// - any quoted link ending in an audio/video extension (src, href, onclick="play('/x.mp3')").
/// Bare file names ("abc.mp3") are resolved by asking the site which common folder serves them.
/// If the page is one sound's own page (its address ends in a record's "url"/"slug"), only that
/// sound is returned.
func findMedia(on page: URL) throws -> (choices: [(url: URL, name: String)], pageTitle: String) {
    let html = try fetchText(page)
    let text = unescape(html)

    struct Candidate {
        let raw: String
        var name: String?
        var slug: String?
    }
    var candidates: [Candidate] = []
    var seen = Set<String>()
    func isMediaPath(_ value: String) -> Bool {
        let path = value.split(separator: "?").first.map(String.init) ?? value
        return mediaExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    let objectPattern = try NSRegularExpression(pattern: #"\{[^{}]{0,4000}\}"#)
    for match in objectPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let range = Range(match.range, in: text),
              let object = try? JSONSerialization.jsonObject(with: Data(text[range].utf8)) as? [String: Any] else { continue }
        for case let value as String in object.values where isMediaPath(value) && seen.insert(value).inserted {
            let name = ["name", "title", "label", "text"].lazy.compactMap { object[$0] as? String }.first
            let slug = ["url", "slug", "permalink"].lazy.compactMap { object[$0] as? String }.first { !isMediaPath($0) }
            candidates.append(Candidate(raw: value, name: name?.trimmingCharacters(in: .whitespaces), slug: slug))
        }
    }

    let extensions = mediaExtensions.joined(separator: "|")
    let linkPattern = try NSRegularExpression(
        pattern: #"["'(]((?:https?:)?[^"'()\s<>]+?\.(?:"# + extensions + #"))(?:\?[^"'()\s<>]*)?["')]"#,
        options: [.caseInsensitive])
    for match in linkPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let range = Range(match.range(at: 1), in: text) else { continue }
        let raw = String(text[range])
        if seen.insert(raw).inserted { candidates.append(Candidate(raw: raw)) }
    }

    // A bare file name has no folder; find the one the site serves them from.
    let isBare = { (raw: String) in !raw.contains("/") }
    var bareBase: URL?
    if let sample = candidates.first(where: { isBare($0.raw) })?.raw {
        let origin = URL(string: "/", relativeTo: page)!.absoluteURL
        let folders = [page.deletingLastPathComponent()] + ["uploads/", "sounds/", "audio/", "media/", "files/", "mp3/", ""]
            .compactMap { URL(string: $0, relativeTo: origin)?.absoluteURL }
        bareBase = folders.first { servesMedia($0.appending(path: sample)) }
    }

    var choices: [(url: URL, name: String, slug: String?)] = []
    var urls = Set<String>()
    for candidate in candidates {
        let resolved: URL?
        if isBare(candidate.raw) {
            resolved = bareBase?.appending(path: candidate.raw)
        } else {
            resolved = URL(string: candidate.raw, relativeTo: page)?.absoluteURL
        }
        guard let url = resolved, url.scheme?.hasPrefix("http") == true, urls.insert(url.absoluteString).inserted else { continue }
        let name = candidate.name.flatMap { $0.isEmpty ? nil : $0 } ?? niceName(url)
        choices.append((url, name, candidate.slug))
        if choices.count >= 200 { break }
    }

    // One sound's own page: just that sound.
    let last = page.lastPathComponent
    if !last.isEmpty, let own = choices.first(where: { $0.slug.map { $0 == last || $0.hasSuffix("/" + last) } ?? false }) {
        return ([(own.url, own.name)], "")
    }

    var pageTitle = ""
    if let start = html.range(of: "<title>", options: .caseInsensitive),
       let end = html.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<html.endIndex) {
        pageTitle = unescape(String(html[start.upperBound..<end.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return (choices.map { ($0.url, $0.name) }, pageTitle)
}

// MARK: - yt-dlp

/// Runs yt-dlp and returns what it printed (for --print / -g queries that download nothing).
func ytdlpOutput(_ arguments: [String]) throws -> String {
    guard let ytdlp = tool("yt-dlp") else {
        throw FetchError(message: "yt-dlp isn't installed. In Terminal, run: brew install yt-dlp")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ytdlp)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = searchPath.joined(separator: ":")
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let line = errors.split(separator: "\n").last { $0.hasPrefix("ERROR:") }.map { String($0.dropFirst(6)) }
        throw FetchError(message: line?.trimmingCharacters(in: .whitespaces) ?? "yt-dlp couldn't read that link.")
    }
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func runYtDlp(_ link: String, section: String? = nil) throws -> (file: String, title: String) {
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
    ] + (section.map { ["--download-sections", "*\($0)", "--force-keyframes-at-cuts"] } ?? []) + ["--", link]
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

// MARK: - Video details

/// Title, channel, length and a thumbnail (saved small, for the editor to show).
func videoInfo(_ link: String) throws -> [String: Any] {
    let json = try ytdlpOutput(["--no-playlist", "--skip-download", "--no-warnings",
                                "--print", "%(.{title,uploader,channel,duration,thumbnail})j", "--", link])
    guard let line = json.split(separator: "\n").last,
          let info = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
        throw FetchError(message: "Couldn't read that video's details.")
    }
    var result: [String: Any] = ["state": "info",
                                 "title": info["title"] as? String ?? "",
                                 "uploader": info["uploader"] as? String ?? info["channel"] as? String ?? "",
                                 "duration": info["duration"] as? Double ?? 0]
    if let thumbnail = (info["thumbnail"] as? String).flatMap(URL.init(string:)),
       let image = try? download(thumbnail, title: "") {
        result["thumbnail"] = image.file
    }
    return result
}

// MARK: - Streaming preview

/// Plays a link through the speakers without saving it, until it ends or is cancelled.
func preview(_ url: URL) throws {
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]])
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.play()
    let seekURL = folder.appending(path: "\(job).seek")
    let started = Date()

    // Streamed files often don't report a length on the item; ask the asset instead.
    final class Shared: @unchecked Sendable {
        var ended = false
        var assetDuration = 0.0
    }
    let shared = Shared()
    let observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                          object: item, queue: .main) { _ in shared.ended = true }
    defer { NotificationCenter.default.removeObserver(observer) }
    Task {
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite { shared.assetDuration = seconds }
    }
    while true {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if isCancelled {
            player.pause()
            try? FileManager.default.removeItem(at: cancelURL)
            try? FileManager.default.removeItem(at: statusURL)
            return
        }
        if let text = try? String(contentsOf: seekURL, encoding: .utf8), let seconds = Double(text) {
            try? FileManager.default.removeItem(at: seekURL)
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
            player.play()
        }
        if item.status == .failed {
            throw FetchError(message: "Can't preview this one (\(url.pathExtension.isEmpty ? "unsupported" : url.pathExtension) audio). Use it to load it instead.")
        }
        let duration = item.duration.seconds.isFinite && item.duration.seconds > 0 ? item.duration.seconds : shared.assetDuration
        let position = player.currentTime().seconds
        let buffering = item.status != .readyToPlay || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if item.status != .readyToPlay, Date().timeIntervalSince(started) > 20 {
            throw FetchError(message: "The preview didn't start. The site may be blocking it.")
        }
        if shared.ended || (duration > 0 && position >= duration - 0.05) {
            report(["state": "ended", "position": duration, "duration": duration])
            return
        }
        report(["state": buffering ? "loading" : "playing", "position": position, "duration": duration])
    }
}

// MARK: - Main

do {
    if request["mode"] == "sync" {
        let summary = try GitSync(root: root, remote: link) { progress(0, $0) }.run()
        report(["state": "synced", "message": summary])
        exit(0)
    }
    guard let url = URL(string: link), url.scheme?.hasPrefix("http") == true else {
        throw FetchError(message: "That doesn't look like a web link.")
    }
    let mode = request["mode"] ?? "video"
    var result: (file: String, title: String)

    switch mode {
    case "info":
        report(try videoInfo(link))
        exit(0)
    case "preview":
        if request["kind"] == "video" {
            // A direct audio stream for the video, played without downloading the file.
            let stream = try ytdlpOutput(["--no-playlist", "--no-warnings", "-g",
                                          "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]", "--", link])
            guard let first = stream.split(separator: "\n").first, let streamURL = URL(string: String(first)) else {
                throw FetchError(message: "Couldn't find an audio stream for that video.")
            }
            try preview(streamURL)
        } else {
            try preview(url)
        }
        exit(0)
    case "direct":
        result = try download(url, title: request["title"] ?? niceName(url))
    case "page":
        // Never downloads: lists what's there so it can be previewed first.
        let found = isMedia(url) ? (choices: [(url: url, name: niceName(url))], pageTitle: "") : try findMedia(on: url)
        if found.choices.isEmpty {
            throw FetchError(message: "No sounds found on that page. If it's a video, try the YouTube tab, which works with many video sites.")
        }
        report(["state": "choices", "title": found.pageTitle,
                "choices": found.choices.map { ["url": $0.url.absoluteString, "name": $0.name] }])
        exit(0)
    default:
        result = try runYtDlp(link, section: request["section"])
    }

    let playable = try ensurePlayable(result.file)
    report(["state": "done", "file": playable, "title": result.title])
} catch let error as FetchError {
    report(["state": "error", "message": error.message])
} catch {
    report(["state": "error", "message": error.localizedDescription])
}
