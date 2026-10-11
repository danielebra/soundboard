import Foundation

// Kept out of main.swift: its top-level globals only exist once the helper's own entry point runs.

let mediaExtensions: Set<String> = ["mp3", "wav", "ogg", "oga", "m4a", "aac", "opus", "flac", "webm", "mp4", "mov", "m4v", "aif", "aiff", "caf"]
let playableExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "mp4", "mov", "m4v", "aif", "aiff", "caf"]

func isMedia(_ url: URL) -> Bool { mediaExtensions.contains(url.pathExtension.lowercased()) }

func niceName(_ url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
    return stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        .trimmingCharacters(in: .whitespaces)
}

func unescape(_ html: String) -> String {
    var text = html
    for (code, value) in [("&q;", "\""), ("&s;", "'"), ("&l;", "<"), ("&g;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                          ("&#x27;", "'"), ("&#x2F;", "/"), ("\\u002F", "/"), ("\\u002f", "/"), ("\\/", "/"),
                          ("&a;", "&"), ("&amp;", "&")] {
        text = text.replacingOccurrences(of: code, with: value)
    }
    return text
}
