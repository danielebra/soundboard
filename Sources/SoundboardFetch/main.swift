import Foundation

// SoundboardFetch: the only part of Soundboard that uses the network.
//
// The sandboxed main app can't pass launch arguments to another app, so it writes
// <job>.request.json ({"link": …}) into the downloads folder and launches this helper.
// The helper fetches a small (≤480p) copy of the video with yt-dlp, writes progress to
// <job>.json, then exits. It stops early if <job>.cancel appears.

let folder = URL(fileURLWithPath: NSHomeDirectory())
    .appending(path: "Library/Application Support/Soundboard/downloads", directoryHint: .isDirectory)

/// Claims the oldest pending request (renaming it so a second helper won't take it too).
func nextRequest() -> (job: String, link: String)? {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
    let requests = files.filter { $0.lastPathComponent.hasSuffix(".request.json") }
        .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    for request in requests {
        let claimed = request.deletingPathExtension().appendingPathExtension("claimed")
        guard (try? FileManager.default.moveItem(at: request, to: claimed)) != nil else { continue }
        defer { try? FileManager.default.removeItem(at: claimed) }
        guard let data = try? Data(contentsOf: claimed),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let link = json["link"] else { continue }
        let job = request.lastPathComponent.replacingOccurrences(of: ".request.json", with: "")
        return (job, link)
    }
    return nil
}

extension URL {
    var creationDate: Date? { (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate }
}

guard let (job, link) = nextRequest() else { exit(0) }
let statusURL = folder.appending(path: "\(job).json")
let cancelURL = folder.appending(path: "\(job).cancel")

func report(_ status: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: status) else { return }
    try? data.write(to: statusURL, options: .atomic)
}

let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin"]
guard let ytdlp = searchPath.map({ $0 + "/yt-dlp" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    report(["state": "error", "message": "yt-dlp isn't installed. In Terminal, run: brew install yt-dlp"])
    exit(1)
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

let lock = NSLock()
var title = ""
var file: String?
var lastError = ""
var progress = 0.0
var message = "Starting…"
var dirty = true

/// "[download]  42.5% of 10.00MiB …" → 42.5
func percent(in line: String) -> Double? {
    guard let sign = line.firstIndex(of: "%") else { return nil }
    let digits = line[..<sign].reversed().prefix { $0.isNumber || $0 == "." }
    return Double(String(digits.reversed()))
}

func consume(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    if line.hasPrefix("TITLE:") {
        title = String(line.dropFirst(6))
        message = "Downloading “\(title)”"
    } else if line.hasPrefix("FILE:") {
        file = String(line.dropFirst(5))
    } else if line.hasPrefix("[download]"), let value = percent(in: line) {
        progress = value / 100
        message = line.replacingOccurrences(of: "[download]", with: "").trimmingCharacters(in: .whitespaces)
    } else if line.hasPrefix("[Merger]") {
        message = "Finishing up…"
    } else if line.hasPrefix("ERROR:") {
        lastError = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    }
    dirty = true
}

func reader(_ pipe: Pipe) {
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
reader(out)
reader(err)

do {
    try process.run()
} catch {
    report(["state": "error", "message": "Couldn't run yt-dlp: \(error.localizedDescription)"])
    exit(1)
}

while process.isRunning {
    if FileManager.default.fileExists(atPath: cancelURL.path) {
        process.terminate()
        try? FileManager.default.removeItem(at: cancelURL)
        try? FileManager.default.removeItem(at: statusURL)
        exit(0)
    }
    lock.lock()
    if dirty {
        report(["state": "downloading", "progress": progress, "message": message, "title": title])
        dirty = false
    }
    lock.unlock()
    Thread.sleep(forTimeInterval: 0.2)
}
Thread.sleep(forTimeInterval: 0.2) // let the pipes drain

lock.lock()
if process.terminationStatus == 0, let file, FileManager.default.fileExists(atPath: file) {
    report(["state": "done", "file": file, "title": title])
} else {
    report(["state": "error", "message": lastError.isEmpty ? "yt-dlp failed (exit \(process.terminationStatus))" : lastError])
}
lock.unlock()
