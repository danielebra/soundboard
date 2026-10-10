import Foundation

/// `sync` mode: commits the Soundboard folder, merges in the repository's copy and pushes the
/// result. The folder itself is the Git work tree. It runs the Mac's own git, so signing in is
/// whatever git already does (SSH keys, the Keychain) and Soundboard never handles a password.
/// git is never allowed to prompt; a failure comes back as git's own message.
struct GitSync {
    let root: URL
    let remote: String
    let progress: (String) -> Void

    /// This Mac's audio settings, temporary files and backups stay out of the repository.
    static let ignore = """
    # Written by Soundboard.
    local.json
    downloads/
    snapshot.png
    sounds/Deleted/
    icons/Deleted/
    *.bak
    config.*.json
    .DS_Store

    """
    static let attributes = "# Written by Soundboard.\nconfig.json merge=soundboard\n"

    static var machine: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// Returns a summary for the app.
    func run() throws -> String {
        let git = try Git(root: root)
        if !FileManager.default.fileExists(atPath: root.appending(path: ".git").path) {
            progress("Setting up…")
            try git.run(["init", "-q", "-b", "main"])
        }
        try write(Self.ignore, to: ".gitignore")
        try write(Self.attributes, to: ".gitattributes")
        // The driver path is this Mac's copy of the helper, so it's set on every sync.
        let helper = Bundle.main.executablePath ?? CommandLine.arguments[0]
        try git.run(["config", "merge.soundboard.name", "Soundboard config.json merge"])
        try git.run(["config", "merge.soundboard.driver", "'\(helper)' --merge-config %O %A %B"])
        let newRemote = (try? git.run(["remote", "get-url", "origin"])) != remote
        if newRemote {
            _ = try? git.run(["remote", "remove", "origin"])
            try git.run(["remote", "add", "origin", remote])
        }

        try git.run(["add", "-A"])
        if (try? git.run(["diff", "--cached", "--quiet"])) == nil {
            progress("Saving changes…")
            try git.run(["commit", "-q", "-m", "Changes from \(Self.machine)"])
        }
        let before = try git.run(["rev-parse", "HEAD"])

        // Someone else may push between our fetch and push; then merge their change and retry.
        for attempt in 1...3 {
            progress("Connecting…")
            let head = try git.network(["ls-remote", "--symref", "origin", "HEAD"])
            // "ref: refs/heads/main<TAB>HEAD", or nothing for an empty repository.
            let branch = head.split(separator: "\n").first { $0.hasPrefix("ref: refs/heads/") }
                .map { String($0.dropFirst("ref: refs/heads/".count).prefix { $0 != "\t" }) }
            if newRemote, attempt == 1 {
                // Check that we may push before merging anything in (a dry run creates nothing).
                try git.network(["push", "-q", "--dry-run", "origin", "HEAD:refs/heads/soundboard-access-check"])
            }
            if let branch {
                progress("Getting changes…")
                try git.network(["fetch", "-q", "origin", branch])
                guard (try? git.run(["cat-file", "-e", "FETCH_HEAD:config.json"])) != nil else {
                    throw FetchError(message: "That repository already holds something other than a Soundboard. Use a new, empty one.")
                }
                try merge(git)
                if try git.run(["rev-parse", "HEAD"]) == git.run(["rev-parse", "FETCH_HEAD"]) { break }
            }
            progress("Sending changes…")
            do {
                try git.network(["push", "-q", "origin", "HEAD:refs/heads/\(branch ?? "main")"])
                break
            } catch where attempt < 3 {
                continue
            }
        }

        let received = try git.run(["diff", "--name-only", before, "HEAD"]).split(separator: "\n").count
        return received == 0 ? "Up to date" : "Received \(received) changed file\(received == 1 ? "" : "s")"
    }

    /// Merges the fetched copy. config.json goes through `ConfigMerge`; for any other file both
    /// Macs changed, the repository's version wins, and a file changed on one Mac but deleted on
    /// the other is kept.
    private func merge(_ git: Git) throws {
        let failure: Error
        do {
            try git.run(["merge", "-q", "--no-edit", "--allow-unrelated-histories", "-X", "theirs", "FETCH_HEAD"])
            return
        } catch {
            failure = error
        }
        let conflicts = try git.run(["diff", "--name-only", "--diff-filter=U", "-z"], trim: false)
            .split(separator: "\0").map(String.init)
        guard !conflicts.isEmpty else {
            _ = try? git.run(["merge", "--abort"])
            throw failure
        }
        do {
            for path in conflicts {
                if (try? git.run(["checkout", "--theirs", "--", path])) != nil
                    || (try? git.run(["checkout", "--ours", "--", path])) != nil {
                    try git.run(["add", "--", path])
                } else {
                    try git.run(["rm", "-q", "--cached", "--ignore-unmatch", "--", path])
                }
            }
            try git.run(["commit", "-q", "--no-edit"])
        } catch {
            _ = try? git.run(["merge", "--abort"])
            throw error
        }
    }

    private func write(_ text: String, to name: String) throws {
        let url = root.appending(path: name)
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Runs git in one folder, without ever letting it wait for input.
struct Git {
    let root: URL
    let executable: String
    private var environment = ProcessInfo.processInfo.environment

    init(root: URL) throws {
        self.root = root
        executable = try Self.find()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["PATH"] = searchPath.joined(separator: ":") // for git-lfs, credential helpers…
        if environment["GIT_SSH_COMMAND"] == nil, (try? run(["config", "core.sshCommand"])) == nil {
            // Fail instead of asking for a passphrase or to trust an unknown server.
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=20"
        }
    }

    /// Homebrew's git, else Apple's. /usr/bin/git is only a stub that offers to install the
    /// developer tools when they're missing.
    private static func find() throws -> String {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] where FileManager.default.isExecutableFile(atPath: "\(dir)/git") {
            return "\(dir)/git"
        }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        check.arguments = ["-p"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        if (try? check.run()) != nil {
            check.waitUntilExit()
            if check.terminationStatus == 0 { return "/usr/bin/git" }
        }
        throw FetchError(message: "Git isn't installed. In Terminal, run: xcode-select --install")
    }

    /// Commands that reach the repository get longer.
    @discardableResult
    func network(_ arguments: [String]) throws -> String {
        do {
            return try run(arguments, timeout: 600)
        } catch let error as FetchError {
            throw FetchError(message: Self.explain(error.message))
        }
    }

    /// Returns what git printed, or throws its error message.
    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 60, trim: Bool = true) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", root.path,
                             // Commits are the app's, made as "Soundboard (<Mac name>)", never signed.
                             "-c", "user.name=Soundboard (\(GitSync.machine))", "-c", "user.email=soundboard@localhost",
                             "-c", "commit.gpgsign=false", "-c", "core.quotepath=false"] + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let killer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errors = Data()
        let readErrors = DispatchGroup()
        readErrors.enter()
        DispatchQueue.global().async {
            errors = err.fileHandleForReading.readDataToEndOfFile()
            readErrors.leave()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        readErrors.wait()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal {
                throw FetchError(message: "git took too long (\(arguments.first ?? "")).")
            }
            let lines = String(decoding: errors, as: UTF8.self).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // The server's or ssh's own reason says more than git's "Could not read from remote repository".
            let reason = lines.first { line in
                ["ERROR:", "remote:", "ssh:", "Permission denied", "Host key verification"].contains { line.hasPrefix($0) }
            }
            let line = reason ?? lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last
            let message = line.map {
                $0.replacingOccurrences(of: "^(fatal|error|ERROR|remote): *", with: "", options: .regularExpression)
            }
            throw FetchError(message: message ?? "git \(arguments.first ?? "") failed.")
        }
        let text = String(decoding: output, as: UTF8.self)
        return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// What to do about the usual sign-in problems.
    private static func explain(_ message: String) -> String {
        let lower = message.lowercased()
        let hint: String? =
            lower.contains("permission denied") ? "Add this Mac's SSH key to your account."
            : lower.contains("host key verification") ? "Run git ls-remote with this address in Terminal once to trust the server."
            : lower.contains("could not read username") || lower.contains("terminal prompts disabled")
            ? "Run git ls-remote with this address in Terminal once, so your login is saved in the Keychain."
            : lower.contains("repository not found") || lower.contains("does not appear to be a git repository")
            ? "Check the address, and that this Mac's key or login can see the repository."
            : nil
        return hint.map { "\(message) \($0)" } ?? message
    }
}
