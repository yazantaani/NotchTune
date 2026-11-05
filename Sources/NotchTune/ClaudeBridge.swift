import AppKit
import Darwin

// How it works
// ------------
// Claude Code runs "hooks" (commands from ~/.claude/settings.json) at key moments.
// NotchTune registers its own binary as those hooks: `NotchTune --hook <event>`.
// In hook mode the binary only forwards the hook's JSON over a private Unix socket
// (~/Library/Application Support/NotchTune/claude.sock, owner-only) to the running app,
// and for permission/question events waits for your answer from the notch.
// If NotchTune isn't running or you don't answer in time, the hook prints nothing and
// Claude Code carries on exactly as it normally would.

enum ClaudePaths {
    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchTune", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
    static var socket: String { supportDir.appendingPathComponent("claude.sock").path }
    static let claudeDesktopBundle = "com.anthropic.claudefordesktop"
}

// MARK: - Models

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    var project: String
    var host: String?
    var running: Bool
    var startedAt: Date
    var lastEvent: Date
    var finishedAt: Date?
    /// First line of the prompt that's running (or ran last).
    var prompt: String?
}

struct ClaudeQuestion: Equatable {
    let question: String
    let header: String
    let options: [(label: String, description: String)]
    let multiSelect: Bool

    static func == (a: Self, b: Self) -> Bool { a.question == b.question && a.header == b.header }
}

enum ClaudeRequestKind {
    case permission(tool: String, detail: String)
    case question([ClaudeQuestion], rawQuestions: Any)
    case attention(title: String, message: String)
}

struct ClaudeRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let project: String
    let host: String?
    let kind: ClaudeRequestKind
    let created = Date()
    /// When the notch stops waiting and hands the decision back to Claude Code.
    var deadline: Date?
    var isAttention: Bool { if case .attention = kind { return true } else { return false } }
}

enum PermissionChoice { case allow, deny }

// MARK: - Bridge (app side)

@MainActor
final class ClaudeBridge: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var requests: [ClaudeRequest] = []

    /// Called when something new needs the user's attention (used to auto-open the notch).
    var onNewRequest: (() -> Void)?

    private let server = SocketServer()
    private var waiting: [UUID: Int32] = [:] // request → open hook connection
    private var sweepTimer: Timer?

    var runningSessions: [ClaudeSession] { sessions.filter(\.running) }
    var isWorking: Bool { sessions.contains(where: \.running) }
    /// Sessions worth showing: running ones, plus ones that finished in the last 20 minutes.
    var visibleSessions: [ClaudeSession] {
        let now = Date()
        return sessions
            .filter { $0.running || ($0.finishedAt.map { now.timeIntervalSince($0) < 20 * 60 } ?? false) }
            .sorted { a, b in a.running != b.running ? a.running : a.startedAt > b.startedAt }
    }

    /// Start of the longest-running active prompt (for the elapsed timer).
    var workingSince: Date? { runningSessions.map(\.startedAt).min() }
    var recentlyFinished: Bool {
        sessions.contains { !$0.running && ($0.finishedAt.map { Date().timeIntervalSince($0) < 5 } ?? false) }
    }

    init() {
        let ok = server.start(path: ClaudePaths.socket) { [weak self] data, fd in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(data, fd: fd) } }
        }
        if !ok { NSLog("NotchTune: could not open Claude socket") }
        // Forget sessions that went quiet (e.g. a terminal was closed mid-run).
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    // MARK: Incoming hook events

    private func handle(_ data: Data, fd: Int32) {
        guard UserDefaults.standard.bool(forKey: Pref.claudeEnabled),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = msg["event"] as? String else {
            SocketServer.reply(fd, nil); return
        }
        let p = msg["payload"] as? [String: Any] ?? [:]
        let sid = p["session_id"] as? String ?? "unknown"
        let cwd = p["cwd"] as? String ?? ""
        let project = (p["session_title"] as? String)
            ?? (cwd.isEmpty ? "Claude" : URL(fileURLWithPath: cwd).lastPathComponent)
        let host = Self.hostBundle(msg)
        touch(sid, project: project, host: host)

        switch event {
        case "prompt":
            let text = (p["prompt"] as? String)?
                .split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) }
            update(sid) { $0.running = true; $0.startedAt = Date(); $0.finishedAt = nil; $0.prompt = text }
            removeAttention(for: sid)
            SocketServer.reply(fd, nil)

        case "stop":
            update(sid) { $0.running = false; $0.finishedAt = Date() }
            SocketServer.reply(fd, nil)
            scheduleFinishRefresh()

        case "session-end":
            sessions.removeAll { $0.id == sid }
            for r in requests where r.sessionID == sid { finish(r.id, output: nil) }
            SocketServer.reply(fd, nil)

        case "notification":
            SocketServer.reply(fd, nil)
            let type = p["notification_type"] as? String ?? ""
            let wanted = ["permission_prompt", "idle_prompt", "elicitation_dialog",
                          "elicitation_url_dialog", "agent_needs_input"]
            guard wanted.contains(type) else { return }
            // We're already asking about this permission in the notch.
            if type == "permission_prompt", requests.contains(where: { $0.sessionID == sid && !$0.isAttention }) { return }
            if type == "idle_prompt", !UserDefaults.standard.bool(forKey: Pref.claudeIdleAlerts) { return }
            removeAttention(for: sid)
            let title = type == "idle_prompt" ? "Claude is waiting for you" : "Claude needs your input"
            add(ClaudeRequest(sessionID: sid, project: project, host: host,
                              kind: .attention(title: title, message: p["message"] as? String ?? "")), fd: nil)

        case "permission":
            let tool = p["tool_name"] as? String ?? "Tool"
            let input = p["tool_input"] as? [String: Any] ?? [:]
            add(ClaudeRequest(sessionID: sid, project: project, host: host,
                              kind: .permission(tool: tool, detail: Self.describe(tool: tool, input: input)),
                              deadline: waitDeadline), fd: fd)

        case "question":
            let input = p["tool_input"] as? [String: Any] ?? [:]
            let raw = input["questions"] as? [[String: Any]] ?? []
            let qs = raw.map { q in
                ClaudeQuestion(
                    question: q["question"] as? String ?? "",
                    header: q["header"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).map {
                        (label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "")
                    },
                    multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            guard !qs.isEmpty else { SocketServer.reply(fd, nil); return }
            add(ClaudeRequest(sessionID: sid, project: project, host: host,
                              kind: .question(qs, rawQuestions: raw), deadline: waitDeadline), fd: fd)

        default:
            SocketServer.reply(fd, nil)
        }
    }

    private var waitDeadline: Date {
        Date().addingTimeInterval(max(UserDefaults.standard.double(forKey: Pref.claudeWaitSeconds), 5))
    }

    private func add(_ request: ClaudeRequest, fd: Int32?) {
        requests.append(request)
        if let fd { waiting[request.id] = fd }
        if let deadline = request.deadline {
            // Not answered in time → let Claude Code show its own prompt; keep a reminder in the notch.
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline.timeIntervalSinceNow) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.requests.contains(where: { $0.id == request.id }) else { return }
                    self.finish(request.id, output: nil)
                    self.add(ClaudeRequest(sessionID: request.sessionID, project: request.project, host: request.host,
                                           kind: .attention(title: "Claude is waiting for you",
                                                            message: "Answer it in Claude.")), fd: nil)
                }
            }
        }
        onNewRequest?()
    }

    // MARK: Answers from the notch

    func answerPermission(_ id: UUID, _ choice: PermissionChoice) {
        let decision: [String: Any] = choice == .allow
            ? ["behavior": "allow"]
            : ["behavior": "deny", "message": "Denied from the notch (NotchTune)."]
        finish(id, output: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
    }

    /// `answers` maps question text → chosen label(s), joined with ", " for multi-select.
    func answerQuestion(_ id: UUID, answers: [String: String]) {
        guard let req = requests.first(where: { $0.id == id }),
              case .question(_, let raw) = req.kind else { return }
        finish(id, output: ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": ["questions": raw, "answers": answers],
        ]])
    }

    /// Hand the request back to Claude and bring its window forward.
    func open(_ id: UUID) {
        guard let req = requests.first(where: { $0.id == id }) else { return }
        finish(id, output: nil)
        Self.activate(host: req.host)
    }

    func dismiss(_ id: UUID) { finish(id, output: nil) }

    private func finish(_ id: UUID, output: [String: Any]?) {
        requests.removeAll { $0.id == id }
        if let fd = waiting.removeValue(forKey: id) { SocketServer.reply(fd, output) }
    }

    // MARK: Sessions

    private func touch(_ sid: String, project: String, host: String?) {
        if let i = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[i].lastEvent = Date()
            sessions[i].project = project
            if let host { sessions[i].host = host }
        } else {
            sessions.append(ClaudeSession(id: sid, project: project, host: host, running: false,
                                          startedAt: Date(), lastEvent: Date(), finishedAt: nil, prompt: nil))
        }
    }

    private func update(_ sid: String, _ change: (inout ClaudeSession) -> Void) {
        if let i = sessions.firstIndex(where: { $0.id == sid }) { change(&sessions[i]) }
    }

    private func removeAttention(for sid: String) {
        for r in requests where r.sessionID == sid && r.isAttention { finish(r.id, output: nil) }
    }

    private func sweep() {
        let now = Date()
        for i in sessions.indices where sessions[i].running && now.timeIntervalSince(sessions[i].lastEvent) > 30 * 60 {
            sessions[i].running = false
        }
        sessions.removeAll { !$0.running && now.timeIntervalSince($0.lastEvent) > 6 * 3600 }
    }

    /// Re-publish after the "finished" checkmark expires so the notch hides it.
    private func scheduleFinishRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    // MARK: Helpers

    private static func hostBundle(_ msg: [String: Any]) -> String? {
        if let b = msg["host"] as? String, !b.isEmpty { return b }
        switch msg["term"] as? String ?? "" {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        default: return nil
        }
    }

    static func activate(host: String?) {
        let candidates = [host, ClaudePaths.claudeDesktopBundle].compactMap { $0 }
        for bundle in candidates {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                running.activate(options: [.activateAllWindows])
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return
            }
        }
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? input["path"] as? String {
            return path
        }
        if let url = input["url"] as? String { return url }
        if let pattern = input["pattern"] as? String { return pattern }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return String(s.prefix(400))
    }
}

// MARK: - Unix socket server

final class SocketServer: @unchecked Sendable {
    private var listenFD: Int32 = -1

    func start(path: String, onMessage: @escaping @Sendable (Data, Int32) -> Void) -> Bool {
        signal(SIGPIPE, SIG_IGN)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = Self.address(path) else { return false }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return false }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); return false }
        listenFD = fd

        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                // Only accept connections from the same macOS user.
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global(qos: .userInitiated).async {
                    if let line = Self.readLine(client) { onMessage(line, client) } else { close(client) }
                }
            }
        }
        return true
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while data.count < 8 << 20 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.last == 0x0A { break }
        }
        return data.isEmpty ? nil : data
    }

    /// Sends {"output": …} (or {"output": null}) and closes the connection.
    static func reply(_ fd: Int32, _ output: [String: Any]?) {
        let obj: [String: Any] = ["output": output ?? NSNull()]
        if var data = try? JSONSerialization.data(withJSONObject: obj) {
            data.append(0x0A)
            data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        }
        close(fd)
    }
}

// MARK: - Hook mode (runs inside Claude Code's hook, not in the app)

enum HookClient {
    static func run(event: String) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let payload = (try? JSONSerialization.jsonObject(with: input)) ?? [String: Any]()
        let env = ProcessInfo.processInfo.environment
        let msg: [String: Any] = [
            "event": event,
            "payload": payload,
            "host": env["__CFBundleIdentifier"] ?? "",
            "term": env["TERM_PROGRAM"] ?? "",
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: msg),
              var addr = SocketServer.address(ClaudePaths.socket) else { exit(0) }
        data.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { exit(0) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { exit(0) } // app not running → don't interfere
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        // Every event gets a reply; permission/question replies may take a while (user is deciding).
        if let reply = SocketServer.readLine(fd),
           let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
           let output = obj["output"] as? [String: Any],
           let out = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(out)
        }
        close(fd)
        exit(0)
    }
}

// MARK: - Installing the hooks into ~/.claude/settings.json

enum HookInstaller {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }
    private static let marker = "--hook"

    /// (Claude Code event, matcher, NotchTune event, timeout seconds)
    private static let entries: [(String, String?, String, Int)] = [
        ("UserPromptSubmit", nil, "prompt", 5),
        ("Stop", nil, "stop", 5),
        ("SessionEnd", nil, "session-end", 5),
        ("Notification", nil, "notification", 5),
        ("PermissionRequest", nil, "permission", 600),
        ("PreToolUse", "AskUserQuestion", "question", 600),
    ]

    private static func isOurs(_ hook: Any) -> Bool {
        guard let cmd = (hook as? [String: Any])?["command"] as? String else { return false }
        return cmd.contains("NotchTune") && cmd.contains(marker)
    }

    static func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NotchTune", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json isn't a JSON object"])
        }
        return obj
    }

    /// Installed and pointing at this copy of the app.
    static var status: (installed: Bool, currentPath: Bool) {
        guard let settings = try? load(), let hooks = settings["hooks"] as? [String: Any] else { return (false, false) }
        let cmds = hooks.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
            .flatMap { ($0["hooks"] as? [Any]) ?? [] }.filter(isOurs)
            .compactMap { ($0 as? [String: Any])?["command"] as? String }
        return (!cmds.isEmpty, !cmds.isEmpty && cmds.allSatisfy { $0.contains(executable) })
    }

    static func install() throws {
        var settings = try load()
        var hooks = strip(settings["hooks"] as? [String: Any] ?? [:])
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        for (event, matcher, name, timeout) in entries {
            var group: [String: Any] = ["hooks": [["type": "command", "command": "\(quoted) \(marker) \(name)", "timeout": timeout]]]
            if let matcher { group["matcher"] = matcher }
            hooks[event] = (hooks[event] as? [Any] ?? []) + [group]
        }
        settings["hooks"] = hooks
        try save(settings)
    }

    static func uninstall() throws {
        var settings = try load()
        let hooks = strip(settings["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try save(settings)
    }

    /// Removes only NotchTune's hook entries; everything else is left untouched.
    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let list = group["hooks"] as? [Any] else { return group }
                let remaining = list.filter { !isOurs($0) }
                if remaining.isEmpty { return nil }
                var g = group; g["hooks"] = remaining; return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    private static func save(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("notchtune-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
