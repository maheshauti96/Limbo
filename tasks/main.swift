// Limbo Tasks: a menu bar panel of your Claude Code sessions, grouped by what
// they need from you.
//
// Reads, and only reads:
//   ~/.claude/sessions/<pid>.json
//       One small file per live Claude Code process: busy or idle, its title,
//       and the desktop app's session id.
//   ~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json
//       One record per desktop session. After each turn the Claude app writes a
//       short summary into it: completed, blocked or ready for review, and what
//       it needs from you.
//   ~/.claude/projects/<folder>/<session>.jsonl
//       Transcripts: only their last 256 KB, and only while the panel or the
//       keep-on-top window shows. What a running session is doing now, how a
//       finished one's latest turn ended (its question, buttons and reply), and
//       the title of one started in a terminal.
// Never opened: the *.key files beside the live records, and every other file
// in those folders (waiting-input/, backlog/, deleted_*, ...).
//
// For sessions started in a terminal, the process table (parents and their
// executables) tells whether Herdr runs them; a click on one runs Herdr's own
// command-line tools to show its terminal (herdr-core ls/get, Herdr do agent.focus).
//
// Writes nothing to those files. With "Answer from Cards" on (off by default), a
// card's button presses the same button in the Claude app through macOS
// Accessibility, only after checking the question on screen (ClaudeAnswerer).
//
// Cost model: no polling while the panel and window are hidden. One FSEvents stream wakes the app when a session file
// changes, and only the changed files are re-read, on a low-priority queue. The
// panel's views exist only while it is open.

import AppKit
import ApplicationServices
import CoreServices
import SQLite3
import SwiftUI

// MARK: - Paths and names

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let live = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        .resolvingSymlinksInPath().path
    static let desk = home
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        .resolvingSymlinksInPath().path
}

private func isASCIIDigit(_ c: Character) -> Bool {
    guard let a = c.asciiValue else { return false }
    return a >= 48 && a <= 57
}

private func isASCIIAlnum(_ c: Character) -> Bool {
    guard let a = c.asciiValue else { return false }
    return (a >= 48 && a <= 57) || (a >= 65 && a <= 90) || (a >= 97 && a <= 122)
}

/// `12345.json`, a live record. Never matches the `<pid>.<hash>.key` files.
func isLiveFileName<S: StringProtocol>(_ n: S) -> Bool {
    guard n.hasSuffix(".json") else { return false }
    let stem = n.dropLast(5)
    return !stem.isEmpty && stem.allSatisfy(isASCIIDigit)
}

/// `local_<letters, digits and dashes>`, a desktop session id.
func isSessionId<S: StringProtocol>(_ s: S) -> Bool {
    guard s.hasPrefix("local_") else { return false }
    let rest = s.dropFirst(6)
    return !rest.isEmpty && rest.count <= 64 && rest.allSatisfy { isASCIIAlnum($0) || $0 == "-" }
}

/// `local_<id>.json`, a desktop session record.
func isDeskFileName<S: StringProtocol>(_ n: S) -> Bool {
    n.hasSuffix(".json") && isSessionId(n.dropLast(5))
}

/// A desktop record must sit exactly at `<root>/<account>/<org>/local_<id>.json`.
/// Files with the same name one level deeper (waiting-input/ holds queued input
/// under the session's own name) must never be read as session records.
func isDeskRecordPath(_ path: String) -> Bool {
    let prefix = Paths.desk + "/"
    guard path.hasPrefix(prefix) else { return false }
    let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 3 && !parts[0].isEmpty && !parts[1].isEmpty && isDeskFileName(parts[2])
}

// MARK: - File access

/// A CLI session id names a transcript file: letters, digits and dashes only.
func isTranscriptId(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 64 && s.allSatisfy { isASCIIAlnum($0) || $0 == "-" }
}

struct FileStamp: Equatable {
    let inode: UInt64
    let mtime: TimeInterval
    let size: Int64
}

/// Regular files only; symlinks are not followed.
func fileStamp(_ path: String) -> FileStamp? {
    var st = stat()
    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    let mtime = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
    return FileStamp(inode: UInt64(st.st_ino), mtime: mtime, size: Int64(st.st_size))
}

/// A file's or folder's stamp, for noticing a change; symlinks are not followed.
func pathStamp(_ path: String) -> FileStamp? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let mtime = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
    return FileStamp(inode: UInt64(st.st_ino), mtime: mtime, size: Int64(st.st_size))
}

/// Reads at most `limit` bytes; nil if the file is larger. Plain reads, no mmap.
func readFile(_ path: String, limit: Int) -> Data? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
    return data
}

/// One line of plain text: markdown marks removed, whitespace collapsed, clipped.
func plainLine(_ s: String?, max: Int, sentence: Bool = false) -> String? {
    guard let s else { return nil }
    let unmarked = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    var t = unmarked.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        .joined(separator: " ")
    t = String(t.drop(while: { $0 == "#" || $0 == "*" || $0 == ">" || $0 == " " }))
    guard !t.isEmpty else { return nil }
    if t.count > max { t = String(t.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" }
    // Sentence case for questions and summaries; titles are shown as written.
    if sentence, let first = t.first, first.isLowercase { t = first.uppercased() + t.dropFirst() }
    return t
}

func dateFromMillis(_ v: Double?) -> Date? {
    guard let v, v > 0 else { return nil }
    return Date(timeIntervalSince1970: v > 100_000_000_000 ? v / 1000 : v)
}

func folderLabel(_ cwd: String) -> String {
    if cwd.contains("/scratch-workspaces/") { return "Scratch" }
    let last = (cwd as NSString).lastPathComponent
    return last.isEmpty ? "No folder" : last
}

// MARK: - Records

/// One live Claude Code process, from ~/.claude/sessions/<pid>.json.
struct LiveRecord: Equatable {
    let pid: Int32
    let key: String             // pid plus start time, so a reused pid is a new record
    let name: String
    let status: String          // busy, idle, shell or waiting
    let waitingFor: String?
    let started: Date
    let statusSince: Date
    let hostId: String?         // desktop session id; nil for sessions started in a terminal
    let cwd: String
    let cliSessionId: String?   // names the transcript file
    /// The name is one Claude Code made up from the folder (like "myapp-3f"),
    /// not one you gave it: the transcript's title is better.
    var nameIsDerived = false
    /// Started in a terminal Herdr runs: a click shows it there.
    var inHerdr = false
    var isBusy: Bool { status == "busy" || status == "shell" }
    var isWaiting: Bool { status == "waiting" }
}

/// One desktop session record, reduced to the fields this app shows.
struct DeskRecord: Equatable {
    let sessionId: String
    let title: String
    let cwd: String
    let lastActivity: Date?
    let lastTurnEdge: Date?     // the latest turn start or end
    let fileTime: Date
    let isArchived: Bool
    let lastAssistantUuid: String?
    let category: String?       // completed, blocked, review_ready, ...
    let statusDetail: String?
    let needsAction: String?
    let summaryFor: String?     // the assistant message the summary describes
    let wrapUp: String?
    let lastReport: String?
    let parentId: String?
    let errorAt: Date?          // set when the session stopped with an error
    let errorText: String?
    /// The CLI session that wrote the latest reply: names its transcript file.
    var transcriptId: String? = nil
    /// When the session last came into view in the Claude app.
    var lastFocused: Date? = nil
}

// Lenient decoding: a field with an unexpected type is dropped, not fatal.
private struct RawSummary: Decodable {
    var category: String?
    var detail: String?
    var needs: String?
    enum CodingKeys: String, CodingKey {
        case category = "status_category", detail = "status_detail", needs = "needs_action"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        needs = try? c.decodeIfPresent(String.self, forKey: .needs)
    }
}

private struct RawWrapUp: Decodable {
    var text: String?
    enum CodingKeys: String, CodingKey { case text = "description" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
    }
}

private struct RawParent: Decodable {
    var sessionId: String?
    enum CodingKeys: String, CodingKey { case sessionId }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
    }
}

/// Only the named fields are decoded; the rest of the file (mostly connector
/// configuration) is never turned into values and never stored.
private struct RawDesk: Decodable {
    var sessionId: String?
    var title: String?
    var cwd: String?
    var lastActivityAt: Double?
    var lastTurnEdgeAt: Double?
    var isArchived: Bool?
    var lastAssistantUuid: String?
    var summary: RawSummary?
    var summaryFor: String?
    var wrapUp: RawWrapUp?
    var lastTurnReport: String?
    var parent: RawParent?
    var error: String?
    var errorAt: Double?
    var errorCategory: String?
    var cliSessionId: String?
    var lastAssistantCliSessionId: String?
    var lastFocusedAt: Double?

    enum CodingKeys: String, CodingKey {
        case sessionId, title, cwd, lastActivityAt, lastTurnEdgeAt, isArchived, lastAssistantUuid
        case summary = "postTurnSummary", summaryFor = "postTurnSummaryFor", wrapUp = "turnWrapUp"
        case lastTurnReport, parent = "spawnedFrom", error, errorAt, errorCategory
        case cliSessionId, lastAssistantCliSessionId, lastFocusedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        lastActivityAt = try? c.decodeIfPresent(Double.self, forKey: .lastActivityAt)
        lastTurnEdgeAt = try? c.decodeIfPresent(Double.self, forKey: .lastTurnEdgeAt)
        isArchived = try? c.decodeIfPresent(Bool.self, forKey: .isArchived)
        lastAssistantUuid = try? c.decodeIfPresent(String.self, forKey: .lastAssistantUuid)
        summary = try? c.decodeIfPresent(RawSummary.self, forKey: .summary)
        summaryFor = try? c.decodeIfPresent(String.self, forKey: .summaryFor)
        wrapUp = try? c.decodeIfPresent(RawWrapUp.self, forKey: .wrapUp)
        lastTurnReport = try? c.decodeIfPresent(String.self, forKey: .lastTurnReport)
        parent = try? c.decodeIfPresent(RawParent.self, forKey: .parent)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        errorAt = try? c.decodeIfPresent(Double.self, forKey: .errorAt)
        errorCategory = try? c.decodeIfPresent(String.self, forKey: .errorCategory)
        cliSessionId = try? c.decodeIfPresent(String.self, forKey: .cliSessionId)
        lastAssistantCliSessionId = try? c.decodeIfPresent(String.self, forKey: .lastAssistantCliSessionId)
        lastFocusedAt = try? c.decodeIfPresent(Double.self, forKey: .lastFocusedAt)
    }
}

let deskFileLimit = 4 * 1024 * 1024

func parseDeskRecord(path: String, stamp: FileStamp) -> DeskRecord? {
    guard stamp.size > 0, stamp.size <= Int64(deskFileLimit),
          let data = readFile(path, limit: deskFileLimit),
          let raw = try? JSONDecoder().decode(RawDesk.self, from: data),
          let id = raw.sessionId, isSessionId(id),
          (path as NSString).lastPathComponent == id + ".json"
    else { return nil }
    let s = raw.summary
    return DeskRecord(
        sessionId: id,
        title: plainLine(raw.title, max: 160) ?? "Untitled session",
        cwd: raw.cwd ?? "",
        lastActivity: dateFromMillis(raw.lastActivityAt),
        lastTurnEdge: dateFromMillis(raw.lastTurnEdgeAt),
        fileTime: Date(timeIntervalSince1970: stamp.mtime),
        isArchived: raw.isArchived ?? false,
        lastAssistantUuid: raw.lastAssistantUuid,
        category: s?.category,
        statusDetail: plainLine(s?.detail, max: 240, sentence: true),
        needsAction: plainLine(s?.needs, max: 600, sentence: true),
        summaryFor: raw.summaryFor,
        wrapUp: plainLine(raw.wrapUp?.text, max: 240, sentence: true),
        lastReport: plainLine(raw.lastTurnReport, max: 200, sentence: true),
        parentId: raw.parent?.sessionId,
        errorAt: raw.error == nil ? nil : dateFromMillis(raw.errorAt),
        errorText: raw.error == nil ? nil
            : plainLine(raw.errorCategory?.replacingOccurrences(of: "_", with: " ") ?? raw.error, max: 120),
        transcriptId: [raw.lastAssistantCliSessionId, raw.cliSessionId].compactMap { $0 }.first(where: isTranscriptId),
        lastFocused: dateFromMillis(raw.lastFocusedAt))
}

/// Kernel start time of a running process, nil if there is none.
func processStartTime(_ pid: Int32) -> TimeInterval? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = info.kp_proc.p_starttime
    return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
}

/// True if `pid` is running and is the process that wrote the record. A record
/// left behind by a crashed process must not come back to life when its pid is
/// reused: the process writes startedAt a second or so after it starts, so a
/// process that started later than that is a different one.
func isSameProcess(pid: Int32, recordStartedMs: Double) -> Bool {
    guard let start = processStartTime(pid) else { return false }
    guard recordStartedMs > 0 else { return true }
    return start <= recordStartedMs / 1000 + 2
}

/// Live records for processes that are still running. `exited` holds the keys
/// of processes the kernel reported as exited; their files can linger.
func readLiveRecords(exited: Set<String>) -> (records: [Int32: LiveRecord], present: Set<String>) {
    var records: [Int32: LiveRecord] = [:]
    var present = Set<String>()
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: Paths.live) else { return (records, present) }
    for name in names where isLiveFileName(name) {
        let path = Paths.live + "/" + name
        guard let st = fileStamp(path), st.size > 0, st.size <= 64 * 1024,
              let data = readFile(path, limit: 64 * 1024),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pidValue = o["pid"] as? Int, pidValue > 1, pidValue <= Int(Int32.max)
        else { continue }
        if (o["spare"] as? Bool) == true { continue }
        if let kind = o["kind"] as? String, kind != "interactive" { continue }
        let pid = Int32(pidValue)
        let startedMs = (o["startedAt"] as? Double) ?? 0
        let key = "\(pid)@\(Int64(startedMs))"
        present.insert(key)
        if exited.contains(key) { continue }
        if !isSameProcess(pid: pid, recordStartedMs: startedMs) { continue }
        let cwd = o["cwd"] as? String ?? ""
        var title = plainLine(o["name"] as? String, max: 160) ?? ""
        let derived = title.isEmpty || (o["nameSource"] as? String) == "derived"
        if title.isEmpty { title = (cwd as NSString).lastPathComponent }
        if title.isEmpty { title = "Session \(pid)" }
        let statusMs = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? startedMs
        let host = (o["hostSessionId"] as? String).flatMap { isSessionId($0) ? $0 : nil }
        records[pid] = LiveRecord(
            pid: pid, key: key, name: title,
            status: (o["status"] as? String) ?? "idle",
            waitingFor: plainLine(o["waitingFor"] as? String, max: 300, sentence: true),
            started: Date(timeIntervalSince1970: startedMs / 1000),
            statusSince: Date(timeIntervalSince1970: statusMs / 1000),
            hostId: host, cwd: cwd,
            cliSessionId: (o["sessionId"] as? String).flatMap { id in
                id.allSatisfy { isASCIIAlnum($0) || $0 == "-" } && !id.isEmpty && id.count <= 64 ? id : nil
            },
            nameIsDerived: derived)
    }
    return (records, present)
}

// MARK: - Live activity

/// ~/.claude/projects/<cwd with every non-alphanumeric character as "-">/<id>.jsonl
func transcriptPath(cwd: String, cliSessionId: String) -> String {
    let encoded = String(cwd.map { isASCIIAlnum($0) ? $0 : "-" })
    return Paths.home.appendingPathComponent(".claude/projects/\(encoded)/\(cliSessionId).jsonl").path
}

/// A short phrase for a tool call, like the Claude app's status line.
func describeTool(_ name: String, _ input: [String: Any]) -> String? {
    func file(_ key: String) -> String {
        ((input[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? "a file"
    }
    func text(_ key: String, _ max: Int) -> String? { plainLine(input[key] as? String, max: max) }
    switch name {
    case "mcp__ccd_turn__update_plan", "mcp__ccd_turn__wrap_up", "TodoWrite", "ToolSearch":
        return nil                                    // bookkeeping; look further back
    case "Bash": return text("description", 120) ?? text("command", 60).map { "Running \($0)" }
    case "Read": return "Reading \(file("file_path"))"
    case "Edit", "MultiEdit", "NotebookEdit": return "Editing \(file("file_path"))"
    case "Write": return "Writing \(file("file_path"))"
    case "Grep": return text("pattern", 40).map { "Searching for “\($0)”" } ?? "Searching"
    case "Glob": return text("pattern", 40).map { "Finding \($0)" } ?? "Finding files"
    case "WebFetch": return (input["url"] as? String).flatMap { URL(string: $0)?.host }.map { "Reading \($0)" } ?? "Reading a web page"
    case "WebSearch": return text("query", 60).map { "Searching the web for “\($0)”" } ?? "Searching the web"
    case "Agent", "Task": return text("description", 120) ?? "Running an agent"
    case "Workflow": return "Running a workflow"
    case "AskUserQuestion": return "Waiting for your answer"
    case "ExitPlanMode": return "Waiting for you to approve the plan"
    default:
        if let described = text("description", 120) ?? text("action_summary", 120) { return described }
        if let host = (input["url"] as? String).flatMap({ URL(string: $0)?.host }) { return "Opening \(host)" }
        guard name.hasPrefix("mcp__") else { return "Using \(name)" }
        // mcp__<server>__<tool> -> "Chrome: navigate"
        let parts = name.dropFirst(5).components(separatedBy: "__")
        let server = parts.first ?? ""
        let tool = (parts.count > 1 ? parts.last! : server).replacingOccurrences(of: "_", with: " ")
        let lower = server.lowercased()
        let label: String
        if lower.contains("chrome") { label = "Chrome" }
        else if lower.contains("browser") { label = "Browser" }
        else if server.count >= 32, server.contains("-") { label = "Connector" }     // an opaque connector id
        else { label = server.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ") }
        return "\(label): \(tool)"
    }
}

/// The title Claude Code gave a session (the one terminal tabs show), from the
/// last 256 KB of its transcript. It writes it again every so often, so the
/// latest one is near the end.
func transcriptTitle(path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let window: UInt64 = 256 * 1024
    let start = size > window ? size - window : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
    let marker = Array(#"{"type":"ai-title""#.utf8)
    for raw in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).reversed()
    where raw.starts(with: marker) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
              let title = plainLine(o["aiTitle"] as? String, max: 160) else { continue }
        return title
    }
    return nil
}

/// What a running session is doing, read from the last 256 KB of its transcript.
func transcriptActivity(path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let window: UInt64 = 256 * 1024
    let start = size > window ? size - window : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    if start > 0, !lines.isEmpty { lines.removeFirst() }    // a partial line
    var parses = 0
    for raw in lines.reversed() {
        guard parses < 20 else { break }
        // Only conversation lines; tool names also appear inside other line types.
        guard raw.starts(with: Array(#"{"parentUuid""#.utf8)) || raw.starts(with: Array(#"{"type":"system""#.utf8))
        else { continue }
        parses += 1
        guard let o = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
        if (o["isSidechain"] as? Bool) == true { continue }
        switch o["type"] as? String {
        case "system":
            if (o["subtype"] as? String) == "stop_hook_summary" { return "Background work still running" }
        case "user":
            if (o["isMeta"] as? Bool) == true { continue }
            return "Thinking"
        case "assistant":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content.reversed() {
                switch block["type"] as? String {
                case "tool_use":
                    if let name = block["name"] as? String,
                       let phrase = describeTool(name, block["input"] as? [String: Any] ?? [:]) { return phrase }
                case "text": return "Writing a reply"
                case "thinking": return "Thinking"
                default: break
                }
            }
        default: continue
        }
    }
    return nil
}

// MARK: - Turn cards

/// How a session's latest turn ended, from its next-step box (Claude's
/// wrap-up): the question and its buttons, the recap, and the reply written
/// after it. Only the latest turn counts: once you send anything, its question
/// is gone.
struct TurnCard: Equatable {
    var ask: String?
    var actions: [String] = []
    var recap: String?
    var reply: String?
    /// The transcript it was read from: answering from the card checks it for your message.
    var transcript: String? = nil

    /// A question always gets a way to answer, even with no buttons of its own.
    var buttons: [String] { ask == nil ? [] : (actions.isEmpty ? [Self.answerInClaude] : actions) }
    /// The button a question with none of its own gets: it always just opens the session.
    static let answerInClaude = "Answer in Claude"
    /// What the response button shows.
    var response: String? { reply ?? recap }
}

/// The Claude app's names for its own action buttons, which carry no label.
func appActionLabel(_ action: String) -> String {
    switch action {
    case "commit": return "Commit"
    case "create_pr": return "Create PR"
    case "merge": return "Merge"
    case "fix_ci": return "Fix CI"
    case "resolve_conflicts": return "Resolve conflicts"
    case "address_comments": return "Address comments"
    case "verify": return "Verify"
    case "archive": return "Archive"
    case "new_session": return "New session"
    default: return action.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// A reply, ready to show in a few lines: code blocks dropped, links to local
/// files turned into their text (web links stay), cut at a word near 900 characters.
func cleanReply(_ parts: [String]) -> String? {
    var t = parts.joined(separator: "\n\n")
    t = t.replacingOccurrences(of: "```[\\s\\S]*?(```|$)", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "\\[([^\\]\\n]+)\\]\\((?!https?://)[^)\\n]*\\)", with: "$1",
                               options: .regularExpression)
    t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    if t.count > 900 {
        var cut = String(t.prefix(900))
        if let space = cut.lastIndex(where: { $0 == " " || $0 == "\n" }) { cut = String(cut[..<space]) }
        t = cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
    return t
}

/// The latest turn's card, from the last 256 KB of a transcript. Walking back
/// from the end: the closing reply (text after the last tool call), then the
/// latest wrap-up that did not fail. A message from you before either means
/// the latest turn has no question; the reply alone is kept.
func turnCard(transcript path: String) -> TurnCard? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let window: UInt64 = 256 * 1024
    let start = size > window ? size - window : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    if start > 0, !lines.isEmpty { lines.removeFirst() }    // a partial line
    var reply: [String] = []
    var replyDone = false
    var failed = Set<String>()      // tool calls whose result was an error
    var parses = 0
    func replyOnly() -> TurnCard? { cleanReply(reply).map { TurnCard(reply: $0) } }
    for raw in lines.reversed() {
        guard raw.starts(with: Array(#"{"parentUuid""#.utf8)) else { continue }
        parses += 1
        guard parses <= 400 else { break }
        guard let o = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
              (o["isSidechain"] as? Bool) != true else { continue }
        let content = (o["message"] as? [String: Any])?["content"]
        switch o["type"] as? String {
        case "user":
            if (o["isMeta"] as? Bool) == true { continue }
            if let blocks = content as? [[String: Any]], !blocks.isEmpty,
               blocks.allSatisfy({ ($0["type"] as? String) == "tool_result" }) {
                for block in blocks where (block["is_error"] as? Bool) == true {
                    if let id = block["tool_use_id"] as? String { failed.insert(id) }
                }
                replyDone = true
                continue
            }
            return replyOnly()      // a message from you: the latest turn starts after it
        case "assistant":
            for block in ((content as? [[String: Any]]) ?? []).reversed() {
                switch block["type"] as? String {
                case "text":
                    if !replyDone, let text = block["text"] as? String { reply.insert(text, at: 0) }
                case "tool_use":
                    replyDone = true
                    guard (block["name"] as? String) == "mcp__ccd_turn__wrap_up",
                          !failed.contains(block["id"] as? String ?? "") else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let actions = (input["actions"] as? [[String: Any]] ?? []).compactMap { item -> String? in
                        if let action = item["action"] as? String, !action.isEmpty { return appActionLabel(action) }
                        return plainLine(item["label"] as? String, max: 40)
                    }
                    return TurnCard(ask: plainLine(input["ask"] as? String, max: 200, sentence: true),
                                    actions: Array(actions.prefix(3)),
                                    recap: plainLine(input["recap"] as? String, max: 400, sentence: true),
                                    reply: cleanReply(reply))
                default: break
                }
            }
        default: continue
        }
    }
    return replyOnly()
}

/// What a running session is doing, and when it last wrote anything.
struct Activity: Equatable {
    var text: String?
    var lastOutput: Date?

    init(text: String?, lastOutput: Date?) {
        self.text = text
        self.lastOutput = lastOutput
    }

    /// Reads both from disk.
    init(transcript path: String) {
        self.init(text: transcriptActivity(path: path), lastOutput: latestWrite(transcript: path))
    }
}

/// When a session last wrote anything: its transcript, its agents'
/// transcripts (<id>/subagents) or its workflows' state (<id>/workflows),
/// whichever is newest. A handful of stats.
func latestWrite(transcript path: String) -> Date? {
    var newest = fileStamp(path)?.mtime
    let side = String(path.dropLast(".jsonl".count))
    for folder in ["subagents", "workflows"] {
        let dir = side + "/" + folder
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        where name.hasSuffix(".jsonl") || name.hasSuffix(".json") {
            if let m = fileStamp(dir + "/" + name)?.mtime, m > (newest ?? 0) { newest = m }
        }
    }
    return newest.map { Date(timeIntervalSince1970: $0) }
}

/// How many of a session's background tasks (Bash commands left running,
/// monitors) are still running. A Bash command holds its output file,
/// …/<session>/tasks/<id>.output, open; a monitor streams to Claude instead,
/// so it is a shell Claude started (its command sources one of Claude's
/// shell snapshots) holding no such file. Either way a child of the session's
/// own process, which can be idle the whole time, between turns. A few system
/// calls per idle session; no process is started, and of a shell's command
/// only whether it has the marker is kept.
func runningBackgroundTasks(parent: Int32, session: String) -> Int {
    var children = [pid_t](repeating: 0, count: 64)
    let count = Int(proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.stride)))
    guard count > 0 else { return 0 }
    let marker = "/\(session)/tasks/"
    var files = Set<String>()
    var shells = 0
    for child in children.prefix(min(count, children.count)) {
        let before = files.count
        defer { if files.count == before && isClaudeShell(child) { shells += 1 } }
        let bytes = proc_pidinfo(child, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { continue }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let got = proc_pidinfo(child, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { continue }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(child, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path.hasSuffix(".output"), path.contains(marker) { files.insert(path) }
        }
    }
    return files.count + shells
}

/// A shell started by Claude's Bash or Monitor tool: its command line
/// sources one of Claude's shell snapshots (~/.claude/shell-snapshots/).
/// Only shells are looked at (not MCP servers), and nothing of the command
/// is kept.
func isClaudeShell(_ pid: pid_t) -> Bool {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
    let exe = String(cString: path)
    guard ["/zsh", "/bash", "/sh"].contains(where: exe.hasSuffix) else { return false }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
    var args = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &args, &size, nil, 0) == 0 else { return false }
    return args.prefix(size).withUnsafeBytes { raw in
        raw.firstRange(of: Array("/.claude/shell-snapshots/snapshot-".utf8)) != nil
    }
}

/// "2 background tasks running"
func backgroundPhrase(_ tasks: Int) -> String {
    tasks == 1 ? "1 background task running" : "\(tasks) background tasks running"
}

/// Re-reads a running session's transcript tail when the file changes, at most
/// once a second, on the engine queue. Every 30 s it also checks the session's
/// agent and workflow files, which change while the main transcript is quiet.
final class ActivityWatcher {
    let key: String
    private let path: String
    private let queue: DispatchQueue
    private let onChange: (Activity) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var sideCheck: DispatchSourceTimer?
    private var last = Activity(text: nil, lastOutput: nil)
    private var pending = false
    private var cancelled = false

    init(key: String, path: String, queue: DispatchQueue, sideCheckEvery: TimeInterval = 30,
         onChange: @escaping (Activity) -> Void) {
        self.key = key
        self.path = path
        self.queue = queue
        self.onChange = onChange
        attach()
        read()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + sideCheckEvery, repeating: sideCheckEvery,
                       leeway: .milliseconds(Int(sideCheckEvery * 300)))
        timer.setEventHandler { [weak self] in
            guard let self, !self.cancelled else { return }
            let newest = latestWrite(transcript: self.path)
            guard newest != self.last.lastOutput else { return }
            self.last.lastOutput = newest
            self.onChange(self.last)
        }
        timer.resume()
        sideCheck = timer
    }

    private func read() {
        last = Activity(transcript: path)
        onChange(last)
    }

    private func attach() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Not written yet: look again shortly.
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.cancelled, self.source == nil else { return }
                self.attach()
                if self.source != nil { self.read() }
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.intersection([.delete, .rename]).isEmpty {
                src.cancel()
                self.source = nil
                self.attach()
                return
            }
            self.scheduleRead()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleRead() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.cancelled else { return }
            self.pending = false
            self.read()
        }
    }

    func cancel() {
        cancelled = true
        source?.cancel()
        source = nil
        sideCheck?.cancel()
        sideCheck = nil
    }
}

// MARK: - Rows

enum Group: Int, Comparable {
    case yourTurn, running, justFinished, review, done, terminal
    static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
}

struct Row: Identifiable, Equatable {
    let id: String
    let group: Group
    let title: String
    var ask: String? = nil
    var detail: String? = nil
    let context: String         // parent session title, or the folder
    let since: Date             // turn end, or when it started running
    var link: String? = nil     // desktop session id, when it can be opened
    var terminal = false
    var activity: String? = nil // what a running session is doing now
    var lastOutput: Date? = nil // when a running session last wrote anything
    var card: TurnCard? = nil   // how its latest turn ended: question, buttons, reply
    var seen: Date? = nil       // when it last came into view in the Claude app
    var tags: [String] = []     // your tags on it, kept by Limbo (SessionTags)
    var snoozedUntil: Date? = nil // snoozed by you until then (SessionSnoozes)
    var hidden = false            // hidden by you until it next changes (SessionHides)
    var agent: RowSource? = nil   // the agent behind a thread another app runs (Orca's), for its icon

    /// Tagged On hold, snoozed or hidden: listed apart, not counted, no glow.
    /// A running session still shows as running, and goes on hold when it stops.
    var held: Bool { group != .running && (snoozedUntil != nil || hidden || tags.contains(SessionTags.onHold)) }

    /// Snoozed: held until a time you picked, then back where it was.
    var snoozed: Bool { group != .running && snoozedUntil != nil }

    /// How long a running session has written nothing, once that passes
    /// `quietAfter`: possibly stuck, or in one long command.
    func quiet(now: Date) -> TimeInterval? {
        guard group == .running, let lastOutput else { return nil }
        let gap = now.timeIntervalSince(lastOutput)
        return gap >= quietAfter ? gap : nil
    }
}

let quietAfter: TimeInterval = 10 * 60

func rowsInOrder(_ rows: [Row]) -> [Row] {
    rows.sorted { a, b in
        if a.group != b.group { return a.group < b.group }
        if a.since != b.since { return a.group == .running ? a.since < b.since : a.since > b.since }
        return a.id < b.id
    }
}

/// Records whose turn ended more than this long ago are left out, unless live.
let dataWindow: TimeInterval = 8 * 86400

/// The grouping rules, first match wins:
///  1. live process busy (or shell)                    -> Running
///  2. live process waiting (not seen in practice yet) -> Your turn
///  3. archived in the Claude app                      -> hidden
///  4. stopped with an error in the last 7 days        -> Your turn
///  5. turn ended but the app has not written its summary yet -> Just finished
///  6. summary: blocked, need_input or failed          -> Your turn
///     review_ready, not opened in Claude since        -> Ready for review
///     (opened in Claude since the turn ended: Done)
///     anything else, or no summary                    -> Done
///  These follow the Claude app's own sidebar rules (blocked/need_input = needs
///  input; failed or an error in the last 7 days = failed).
///  7. terminal session (no desktop id), idle          -> Terminal
func classify(desk: [DeskRecord], live: [Int32: LiveRecord], now: Date,
              activities: [Int32: Activity] = [:], cards: [String: TurnCard] = [:],
              background: [Int32: Int] = [:], titles: [Int32: String] = [:]) -> [Row] {
    var bySession: [String: DeskRecord] = [:]
    for d in desk {
        // The same session can sit under several account folders; keep the newest copy.
        if let old = bySession[d.sessionId] {
            let newer = (d.lastActivity ?? .distantPast, d.fileTime) > (old.lastActivity ?? .distantPast, old.fileTime)
            if !newer { continue }
        }
        bySession[d.sessionId] = d
    }
    var liveByHost: [String: LiveRecord] = [:]
    var terminalLive: [LiveRecord] = []
    for l in live.values {
        guard let host = l.hostId else { terminalLive.append(l); continue }
        if let other = liveByHost[host], other.statusSince >= l.statusSince { continue }
        liveByHost[host] = l
    }

    var rows: [Row] = []
    for d in bySession.values {
        let l = liveByHost[d.sessionId]
        let context = d.parentId.flatMap { bySession[$0]?.title } ?? folderLabel(d.cwd)
        let link = isSessionId(d.sessionId) ? d.sessionId : nil
        if let l, l.isBusy {
            rows.append(Row(id: d.sessionId, group: .running, title: d.title, context: context,
                            since: l.statusSince, link: link, activity: activities[l.pid]?.text,
                            lastOutput: activities[l.pid]?.lastOutput))
            continue
        }
        if let l, l.isWaiting {
            rows.append(Row(id: d.sessionId, group: .yourTurn, title: d.title,
                            ask: l.waitingFor ?? "Waiting for your input", context: context,
                            since: l.statusSince, link: link))
            continue
        }
        // Between turns, but with background work still going (commands left
        // running, monitors): not done or ready for review yet, as the Claude
        // app shows it too. A session asking you something still needs you.
        if let l, let tasks = background[l.pid], !d.isArchived,
           !["blocked", "need_input", "failed"].contains(d.category ?? ""), d.errorAt == nil {
            rows.append(Row(id: d.sessionId, group: .running, title: d.title, context: context,
                            since: l.statusSince, link: link, activity: backgroundPhrase(tasks)))
            continue
        }
        if d.isArchived { continue }
        let anchor = d.lastTurnEdge ?? d.lastActivity ?? d.fileTime
        if l == nil && now.timeIntervalSince(anchor) > dataWindow { continue }
        if let errorAt = d.errorAt, now.timeIntervalSince(errorAt) < 7 * 86400 {
            rows.append(Row(id: d.sessionId, group: .yourTurn, title: d.title,
                            ask: "Stopped with an error" + (d.errorText.map { ": \($0)" } ?? ""),
                            context: context, since: errorAt, link: link, card: cards[d.sessionId],
                            seen: d.lastFocused))
            continue
        }

        let fresh = d.category != nil && d.summaryFor != nil && d.summaryFor == d.lastAssistantUuid
        // The process went idle after the record's last turn edge: the turn has
        // ended but the app has not rewritten the record yet. Ignored for a
        // process that never ran a turn (the app restarts one when you click).
        var lagging = false
        if let l, l.status == "idle", l.statusSince.timeIntervalSince(l.started) > 10 {
            lagging = l.statusSince.timeIntervalSince(d.lastTurnEdge ?? .distantPast) > 15
        }
        if lagging || (!fresh && now.timeIntervalSince(anchor) < 600) {
            rows.append(Row(id: d.sessionId, group: .justFinished, title: d.title, context: context,
                            since: lagging ? (l?.statusSince ?? anchor) : anchor, link: link,
                            card: cards[d.sessionId]))
            continue
        }
        // After the first minutes, an older summary is used as it stands; the
        // Claude app's sidebar does the same.
        switch d.category {
        case "blocked", "need_input", "failed":
            let ask = d.needsAction ?? d.statusDetail ?? "Waiting for your answer"
            rows.append(Row(id: d.sessionId, group: .yourTurn, title: d.title, ask: ask,
                            detail: d.statusDetail == ask ? nil : d.statusDetail,
                            context: context, since: anchor, link: link, card: cards[d.sessionId],
                            seen: d.lastFocused))
        case "review_ready":
            // Opening the session in Claude after its turn ended is the review.
            let reviewed = d.lastFocused.map { $0 >= anchor } ?? false
            rows.append(Row(id: d.sessionId, group: reviewed ? .done : .review, title: d.title,
                            detail: d.statusDetail ?? d.wrapUp, context: context, since: anchor, link: link,
                            card: cards[d.sessionId], seen: d.lastFocused))
        default:
            rows.append(Row(id: d.sessionId, group: .done, title: d.title,
                            detail: d.statusDetail ?? d.wrapUp ?? d.lastReport,
                            context: context, since: anchor, link: link, card: cards[d.sessionId]))
        }
    }

    // A live desktop process whose record is missing or not yet written.
    for (host, l) in liveByHost where bySession[host] == nil {
        let tasks = l.isBusy || l.isWaiting ? nil : background[l.pid]
        let group: Group = l.isBusy || tasks != nil ? .running : (l.isWaiting ? .yourTurn : .done)
        rows.append(Row(id: host, group: group, title: l.name,
                        ask: l.isWaiting ? (l.waitingFor ?? "Waiting for your input") : nil,
                        context: folderLabel(l.cwd), since: l.statusSince, link: host,
                        activity: l.isBusy ? activities[l.pid]?.text : tasks.map(backgroundPhrase),
                        lastOutput: l.isBusy ? activities[l.pid]?.lastOutput : nil))
    }
    // Sessions started in a terminal: no summary, so idle ones never count as your turn.
    for l in terminalLive {
        let tasks = l.isBusy || l.isWaiting ? nil : background[l.pid]
        let group: Group = l.isBusy || tasks != nil ? .running : (l.isWaiting ? .yourTurn : .terminal)
        rows.append(Row(id: "pid:\(l.pid)", group: group, title: titles[l.pid] ?? l.name,
                        ask: l.isWaiting ? (l.waitingFor ?? "Waiting for your input") : nil,
                        context: folderLabel(l.cwd), since: l.statusSince,
                        link: l.inHerdr ? herdrLinkPrefix + "\(l.pid)" : nil, terminal: true,
                        activity: l.isBusy ? activities[l.pid]?.text : tasks.map(backgroundPhrase),
                        lastOutput: l.isBusy ? activities[l.pid]?.lastOutput : nil))
    }
    return rowsInOrder(rows)
}

/// What the panel and the menu bar show at a given moment.
struct Board {
    /// Your-turn sessions older than this go under "Older" and leave the menu bar count.
    static let recentLimit: TimeInterval = 72 * 3600
    static let window: TimeInterval = 7 * 86400

    var yourTurn: [Row] = []
    var older: [Row] = []
    var running: [Row] = []
    var justFinished: [Row] = []
    var review: [Row] = []
    var done: [Row] = []
    var terminal: [Row] = []
    var onHold: [Row] = []
    var snoozed: [Row] = []
    /// Hidden until they next change: only the menu bar panel lists them.
    var hidden: [Row] = []

    init(rows: [Row], now: Date) {
        for r in rows {
            let age = now.timeIntervalSince(r.since)
            if r.hidden && r.group != .running {
                if age <= Board.window { hidden.append(r) }
                continue
            }
            if r.snoozed {
                snoozed.append(r)
                continue
            }
            if r.held {
                if age <= Board.window { onHold.append(r) }
                continue
            }
            switch r.group {
            case .running: running.append(r)
            case .justFinished: justFinished.append(r)
            case .terminal: terminal.append(r)
            case .yourTurn:
                if age <= Board.recentLimit || r.terminal { yourTurn.append(r) }
                else if age <= Board.window { older.append(r) }
            case .review: if age <= Board.window { review.append(r) }
            case .done: if age <= Board.window { done.append(r) }
            }
        }
    }

    var isEmpty: Bool {
        yourTurn.isEmpty && older.isEmpty && running.isEmpty && justFinished.isEmpty
            && review.isEmpty && done.isEmpty && terminal.isEmpty && onHold.isEmpty && snoozed.isEmpty
            && hidden.isEmpty
    }
}

/// Your tags on sessions ("On hold", "Awaiting manual review", your own),
/// kept in Limbo's settings by session id. Claude's files are never touched,
/// so the tags show only in Limbo.
struct SessionTags: Equatable {
    static let key = "sessionTags"
    static let onHold = "On hold"
    static let awaitingReview = "Awaiting manual review"
    static let presets = [onHold, awaitingReview]
    static let maxLength = 30

    var byId: [String: [String]] = [:]

    static func load(_ defaults: UserDefaults = .standard) -> SessionTags {
        SessionTags(byId: defaults.dictionary(forKey: key) as? [String: [String]] ?? [:])
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(byId, forKey: Self.key)
    }

    /// The presets, then your own tags in use, A to Z: on the sessions in
    /// `ids` when given (the ones Limbo lists), so old tags leave the menu.
    func known(among ids: Set<String>? = nil) -> [String] {
        let tagged = ids.map { ids in byId.filter { ids.contains($0.key) } } ?? byId
        let custom = Set(tagged.values.joined()).subtracting(Self.presets)
        return Self.presets + custom.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Drops the tags of these sessions (archived in the Claude app); true if any went.
    mutating func forget(_ ids: Set<String>) -> Bool {
        let before = byId.count
        for id in ids { byId[id] = nil }
        return byId.count != before
    }

    /// A tag name as typed, tidied: spaces collapsed, at most 30 characters,
    /// and the spelling of a tag you already have when only the case differs.
    func clean(_ name: String) -> String? {
        var t = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if t.count > Self.maxLength { t = String(t.prefix(Self.maxLength)).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty else { return nil }
        return known().first { $0.caseInsensitiveCompare(t) == .orderedSame } ?? t
    }

    mutating func toggle(_ tag: String, on id: String) {
        var list = byId[id] ?? []
        if let i = list.firstIndex(of: tag) { list.remove(at: i) } else { list.append(tag) }
        byId[id] = list.isEmpty ? nil : list
    }

    mutating func add(_ tag: String, to id: String) {
        guard !(byId[id] ?? []).contains(tag) else { return }
        byId[id, default: []].append(tag)
    }

    mutating func clear(_ id: String) { byId[id] = nil }

    /// The rows with your tags on them; a row's own tags (sample data) stay
    /// when you have none on it.
    func apply(to rows: [Row]) -> [Row] {
        guard !byId.isEmpty else { return rows }
        return rows.map { row in
            guard let tags = byId[row.id] else { return row }
            var tagged = row
            tagged.tags = tags
            return tagged
        }
    }

    /// Only sessions from the Claude app can be tagged: a terminal session
    /// has no lasting id.
    static func taggable(_ row: Row) -> Bool { row.link.map(isSessionId) ?? false }
}

/// Sessions you snoozed: held (out of the counts and the glow) until the
/// time you picked, or until the session moves on (you answer it, or it
/// ends another turn), whichever comes first. Kept in Limbo's settings by
/// session id, like your tags.
struct SessionSnoozes: Equatable {
    static let key = "sessionSnoozes"

    struct Entry: Equatable {
        var until: Date
        var at: Date        // when you snoozed it: a turn after this ends the snooze
    }

    var byId: [String: Entry] = [:]

    static func load(_ defaults: UserDefaults = .standard) -> SessionSnoozes {
        let raw = defaults.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
        var snoozes = SessionSnoozes()
        for (id, e) in raw {
            guard let until = e["until"], let at = e["at"] else { continue }
            snoozes.byId[id] = Entry(until: Date(timeIntervalSince1970: until), at: Date(timeIntervalSince1970: at))
        }
        return snoozes
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(byId.mapValues { ["until": $0.until.timeIntervalSince1970, "at": $0.at.timeIntervalSince1970] },
                     forKey: Self.key)
    }

    mutating func snooze(_ id: String, until: Date, at: Date) { byId[id] = Entry(until: until, at: at) }

    mutating func wake(_ id: String) { byId[id] = nil }

    /// Ends the snoozes that ran out by `now`: their ids and when each ran out.
    mutating func expire(now: Date) -> [String: Date] {
        let ended = byId.filter { $0.value.until <= now }
        for id in ended.keys { byId[id] = nil }
        return ended.mapValues(\.until)
    }

    /// Ends the snoozes of sessions that moved on since (running again, or a
    /// newer turn); true if any ended.
    mutating func prune(_ rows: [Row]) -> Bool {
        let moved = rows.filter { row in byId[row.id].map { row.since > $0.at } ?? false }
        for row in moved { byId[row.id] = nil }
        return !moved.isEmpty
    }

    /// The rows, with the snoozed ones marked.
    func apply(to rows: [Row], now: Date) -> [Row] {
        guard !byId.isEmpty else { return rows }
        return rows.map { row in
            guard let e = byId[row.id], e.until > now, row.since <= e.at, row.group != .running else { return row }
            var snoozed = row
            snoozed.snoozedUntil = e.until
            return snoozed
        }
    }

    /// When the next snooze runs out.
    var nextEnd: Date? { byId.values.map(\.until).min() }

    /// Drops the snoozes of these sessions (archived in the Claude app); true if any went.
    mutating func forget(_ ids: Set<String>) -> Bool {
        let before = byId.count
        for id in ids { byId[id] = nil }
        return byId.count != before
    }

    /// What can be snoozed: a Claude app session that isn't running (needs
    /// you, to review, or finished), and isn't on hold or hidden.
    static func snoozable(_ row: Row) -> Bool {
        SessionTags.taggable(row) && row.group != .running && row.group != .terminal && !row.held
    }
}

/// Sessions you hid until they next change: out of the keep-on-top window,
/// the counts and the glow until the session runs again or ends a newer
/// turn; the menu bar panel lists them under Hidden. Any app's session or
/// thread can be hidden. Kept in Limbo's settings by id, with when you hid it.
struct SessionHides: Equatable {
    static let key = "sessionHides"

    var byId: [String: Date] = [:]

    static func load(_ defaults: UserDefaults = .standard) -> SessionHides {
        let raw = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return SessionHides(byId: raw.mapValues { Date(timeIntervalSince1970: $0) })
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(byId.mapValues(\.timeIntervalSince1970), forKey: Self.key)
    }

    mutating func hide(_ id: String, at: Date) { byId[id] = at }

    mutating func show(_ id: String) { byId[id] = nil }

    /// Ends the hides of sessions that changed since (running again, or a
    /// newer turn), and ones hidden so long ago that their sessions have
    /// left every list; true if any ended.
    mutating func prune(_ rows: [Row], now: Date) -> Bool {
        let before = byId.count
        for row in rows where byId[row.id].map({ row.group == .running || row.since > $0 }) ?? false {
            byId[row.id] = nil
        }
        byId = byId.filter { now.timeIntervalSince($0.value) <= Board.window + 86400 }
        return byId.count != before
    }

    /// The rows, with the hidden ones marked.
    func apply(to rows: [Row]) -> [Row] {
        guard !byId.isEmpty else { return rows }
        return rows.map { row in
            guard let at = byId[row.id], row.group != .running, row.since <= at else { return row }
            var hidden = row
            hidden.hidden = true
            return hidden
        }
    }

    /// Drops the hides of these sessions (archived in the Claude app); true if any went.
    mutating func forget(_ ids: Set<String>) -> Bool {
        let before = byId.count
        for id in ids { byId[id] = nil }
        return byId.count != before
    }

    /// What can be hidden: any app's session or thread that isn't running,
    /// isn't in a terminal list, and isn't already snoozed or hidden.
    static func hideable(_ row: Row) -> Bool {
        row.group != .running && row.group != .terminal && !row.hidden && !row.snoozed
    }
}

/// How long to snooze: the right-click menu's and the cards' choices.
enum SnoozeChoice: String, CaseIterable, Identifiable {
    case hour, threeHours, tomorrow
    var id: String { rawValue }

    /// For menus.
    var title: String {
        switch self {
        case .hour: return "For 1 Hour"
        case .threeHours: return "For 3 Hours"
        case .tomorrow: return "Until Tomorrow Morning"
        }
    }

    /// For the small buttons on a card.
    var short: String {
        switch self {
        case .hour: return "1h"
        case .threeHours: return "3h"
        case .tomorrow: return "Tomorrow"
        }
    }

    /// Tomorrow morning is 9:00 the next day.
    func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour: return now.addingTimeInterval(3600)
        case .threeHours: return now.addingTimeInterval(3 * 3600)
        case .tomorrow:
            let start = calendar.startOfDay(for: now)
            return calendar.date(byAdding: DateComponents(day: 1, hour: 9), to: start) ?? now.addingTimeInterval(86400)
        }
    }
}

/// "until 3:40 PM", "until tomorrow 9:00 AM", "until Fri 9:00 AM".
func snoozeWhen(_ until: Date, now: Date, calendar: Calendar = .current) -> String {
    let time = until.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(until, inSameDayAs: now) { return "until \(time)" }
    if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(until, inSameDayAs: next) {
        return "until tomorrow \(time)"
    }
    return "until " + until.formatted(.dateTime.weekday(.abbreviated)) + " \(time)"
}

// MARK: - ChatGPT (Codex) threads

/// Codex threads in the ChatGPT app. Its Codex server keeps each loaded
/// thread's rollout file (~/.codex/sessions/…/rollout-…-<id>.jsonl) open;
/// a turn's start and end are lines in it ("task_started", "task_complete",
/// "turn_aborted"). Read only while the window or the panel shows: which
/// files the server holds (a few system calls), then only the new lines of
/// a file that grew. Thread names come from ~/.codex/session_index.jsonl.
enum CodexMarker: Equatable { case started, complete, aborted }

/// What a rollout file has said so far, read up to `offset` (a line end).
struct RolloutScan: Equatable {
    var offset: UInt64 = 0
    var marker: CodexMarker?
    var markerTime: Date?
    var activity: String?       // the last step since the turn started
    var lastWrite: Date?        // the last line's time
}

let codexTime: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Reads the complete lines a rollout file gained since `scan`. The first
/// read of a big file starts in its last 16 MB; a half-written last line is
/// left for next time. Only each line's first bytes are looked at: the
/// structure there ("type":"event_msg","payload":{"type":"task_started")
/// comes before any text, so words inside a message never count.
func scanRollout(path: String, from scan: RolloutScan) -> RolloutScan {
    guard let handle = FileHandle(forReadingAtPath: path) else { return scan }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return scan }
    var next = scan
    if end < scan.offset { next = RolloutScan() }   // rewritten: start over
    var start = next.offset
    if start == 0 && end > 16 << 20 { start = end - (16 << 20) }
    guard end > start else { return next }
    guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(end - start)),
          let lastNewline = data.lastIndex(of: 0x0A) else { return next }
    let body = data[data.startIndex...lastNewline]
    var lineStart = body.startIndex
    // Starting mid-file: the first piece is part of a line.
    if start > 0 && start != scan.offset, let first = body.firstIndex(of: 0x0A) { lineStart = first + 1 }
    while lineStart < body.endIndex {
        let lineEnd = body[lineStart...].firstIndex(of: 0x0A) ?? body.endIndex
        readRolloutLine(body[lineStart..<lineEnd], into: &next)
        lineStart = lineEnd + 1
    }
    next.offset = start + UInt64(lastNewline - data.startIndex + 1)
    return next
}

private let eventPrefix = Array(#""type":"event_msg","payload":{"type":""#.utf8)
private let itemPrefix = Array(#""type":"response_item","payload":{"type":""#.utf8)

/// One rollout line: a turn marker, or a step that says what a running thread is doing.
func readRolloutLine(_ line: Data, into scan: inout RolloutScan) {
    let head = line.prefix(400)
    guard head.starts(with: Array(#"{"timestamp":""#.utf8)) else { return }
    let time = head.dropFirst(14).prefix(30).split(separator: UInt8(ascii: "\""), maxSplits: 1).first
        .flatMap { codexTime.date(from: String(decoding: $0, as: UTF8.self)) }
    if let time { scan.lastWrite = time }
    func kind(after prefix: [UInt8]) -> String? {
        guard let range = head.firstRange(of: prefix) else { return nil }
        let rest = head[range.upperBound...]
        guard let close = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[..<close], as: UTF8.self)
    }
    if let event = kind(after: eventPrefix) {
        let marker: CodexMarker? = event == "task_started" ? .started : event == "task_complete" ? .complete
            : event == "turn_aborted" ? .aborted : nil
        if let marker {
            scan.marker = marker
            scan.markerTime = time
            scan.activity = nil
        }
    } else if let item = kind(after: itemPrefix), scan.marker == .started {
        switch item {
        case "reasoning": scan.activity = "Thinking"
        case "message":
            if head.firstRange(of: Array(#""role":"assistant""#.utf8)) != nil { scan.activity = "Writing" }
        case "web_search_call": scan.activity = "Searching the web"
        case "function_call", "custom_tool_call":
            let name = head.firstRange(of: Array(#""name":""#.utf8)).map { range -> String in
                let rest = head[range.upperBound...]
                return String(decoding: rest.prefix { $0 != UInt8(ascii: "\"") }, as: UTF8.self)
            } ?? ""
            scan.activity = codexToolPhrase(name)
        default: break
        }
    }
}

/// "Running a command", "Editing files", … for a Codex tool call.
func codexToolPhrase(_ name: String) -> String {
    switch name {
    case "exec", "exec_command", "shell", "shell_command", "local_shell": return "Running a command"
    case "apply_patch": return "Editing files"
    case "wait", "write_stdin": return "Waiting on a command"
    case "update_plan": return "Planning"
    case "view_image": return "Looking at an image"
    default: return "Using a tool"
    }
}

/// The first line of a rollout: the thread's id, its folder, and who started
/// it (thread_source). Read from its first 16 KB, which come before the long
/// instructions it carries.
func rolloutHeader(path: String) -> (id: String?, cwd: String?, source: String?) {
    guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil, nil) }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 16 << 10) else { return (nil, nil, nil) }
    let head = data.prefix { $0 != 0x0A }
    func value(_ key: String) -> String? {
        guard let range = head.firstRange(of: Array("\"\(key)\":\"".utf8)) else { return nil }
        var bytes: [UInt8] = [UInt8(ascii: "\"")]
        var escaped = false
        for byte in head[range.upperBound...] {
            bytes.append(byte)
            if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true }
            else if byte == UInt8(ascii: "\"") { break }
        }
        return (try? JSONSerialization.jsonObject(with: Data(bytes), options: .fragmentsAllowed)) as? String
    }
    return (value("id"), value("cwd"), value("thread_source"))
}

/// Threads you started (not Codex's own agents, reviewers or voice sessions).
func codexThreadShown(source: String?) -> Bool {
    guard let source else { return true }
    return !["subagent", "guardian_review", "realtime_voice"].contains(source)
}

/// The thread id in a rollout file's name, right after its start time:
/// rollout-2026-10-14T10-02-20-<id>.jsonl. A long thread's file can carry a
/// second id after it (<id>_<other>.jsonl), so it's the first, not the last.
func codexThreadId(path: String) -> String? {
    let name = (path as NSString).lastPathComponent
    let start = "rollout-2026-10-14T10-02-20-".count
    guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.count >= start + 36 + 6 else { return nil }
    let id = String(name.dropFirst(start).prefix(36))
    return id.allSatisfy { isASCIIAlnum($0) || $0 == "-" } ? id : nil
}

/// A Codex thread as a row: running, or finished (stopped) with when.
func codexRow(id: String, name: String?, cwd: String?, scan: RolloutScan) -> Row? {
    guard let marker = scan.marker, let since = scan.markerTime else { return nil }
    let title = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        ?? "Codex thread"
    let context = cwd.map(folderLabel) ?? "ChatGPT"
    let link = "codex://threads/\(id)"
    switch marker {
    case .started:
        // Written at most once a minute, as Claude's are: the quiet check needs no more.
        let written = scan.lastWrite.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded(.down) * 60) }
        return Row(id: "codex:\(id)", group: .running, title: title, context: context, since: since, link: link,
                   activity: scan.activity, lastOutput: written)
    case .complete, .aborted:
        return Row(id: "codex:\(id)", group: .done, title: title, detail: marker == .aborted ? "Stopped" : nil,
                   context: context, since: since, link: link)
    }
}

/// The app a row's session or thread is in.
enum RowSource { case claude, chatGPT, cursor, antigravity, orca, herdr }

extension Row {
    var source: RowSource {
        if id.hasPrefix("codex:") { return .chatGPT }
        if id.hasPrefix("cursor:") { return .cursor }
        if id.hasPrefix("agy:") { return .antigravity }
        if id.hasPrefix("orca:") { return .orca }
        return .claude
    }

    /// A thread in ChatGPT, Cursor, Antigravity or Orca: listed, never
    /// counted in the menu bar, never tagged or snoozed.
    var fromOtherApp: Bool { source != .claude }

    /// The app a click goes to, from the link. Usually the row's own app;
    /// a Claude session that Orca runs goes to Orca.
    var linkApp: RowSource? {
        guard let link else { return nil }
        if isSessionId(link) { return .claude }
        if link.hasPrefix("codex://threads/") { return .chatGPT }
        if link.hasPrefix(cursorLinkPrefix) { return .cursor }
        if link.hasPrefix(antigravityLinkPrefix) { return .antigravity }
        if link.hasPrefix(orcaLinkPrefix) { return .orca }
        if link.hasPrefix(herdrLinkPrefix) { return .herdr }
        return nil
    }

    /// Where a click goes: the session in Claude, the thread in ChatGPT, or
    /// Cursor, Antigravity or Orca itself. Cursor has no link to one of its
    /// own threads (its /agent link finds only cloud agents, and shows an
    /// error otherwise); Antigravity's are its window's own, unpublished;
    /// Orca's pair devices, open bots and share skills.
    var openURL: URL? {
        guard let link, let app = linkApp else { return nil }
        switch app {
        case .claude: return URL(string: "claude://claude.ai/epitaxy/\(link)")
        case .chatGPT: return URL(string: link)
        case .cursor, .antigravity, .orca, .herdr:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId)
        }
    }

    /// "Claude", "ChatGPT", "Cursor", "Antigravity" or "Orca": the app it's in.
    var appName: String { source.name }

    /// Whose icon leads the row: the agent's for a thread Orca runs (Claude's,
    /// Antigravity's…), else the app's it's in.
    var iconSource: RowSource { agent ?? source }

    /// The app comes forward, not the thread: Cursor, Antigravity and Orca
    /// (and Herdr, with the session's terminal shown).
    var opensAppOnly: Bool { [.cursor, .antigravity, .orca, .herdr].contains(linkApp ?? source) }

    /// What a click does, for menus: "Open in Claude", or "Switch to Orca".
    var openLabel: String {
        let app = (linkApp ?? source).name
        return opensAppOnly ? "Switch to \(app)" : "Open in \(app)"
    }

    /// ", in ChatGPT", ", in Cursor" or ", in Antigravity" for VoiceOver, which can't see the icon;
    /// nothing for Claude's own sessions.
    var spokenApp: String {
        guard fromOtherApp else { return "" }
        if let agent, agent != source { return ", \(agent.name) in \(appName)" }
        return ", in \(appName)"
    }
}

extension RowSource {
    var name: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        case .orca: return "Orca"
        case .herdr: return "Herdr"
        }
    }

    /// The app's bundle id: where its icon comes from.
    var bundleId: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .chatGPT: return "com.openai.codex"
        case .cursor: return cursorBundleId
        case .antigravity: return antigravityBundleId
        case .orca: return orcaBundleId
        case .herdr: return herdrBundleId
        }
    }
}

/// Each app's icon as macOS shows it, looked up once per app. nil when the
/// app isn't installed: its rows then show the state mark alone, as before.
/// Read from the installed app, so no app's logo is kept in this repo.
private var appIcons: [RowSource: (icon: NSImage?, at: Date)] = [:]
func appIcon(_ source: RowSource) -> NSImage? {
    // One not found is looked for again a minute later: an app just installed,
    // or opened from its disk image.
    if let known = appIcons[source], known.icon != nil || Date().timeIntervalSince(known.at) < 60 { return known.icon }
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleId)
        .map { NSWorkspace.shared.icon(forFile: $0.path) }
    appIcons[source] = (icon, Date())
    return icon
}

/// A process's executable path, or "" if it's gone.
func executablePath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
}

/// A process's parent, or nil for launchd or a process that's gone.
func parentPid(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let parent = info.kp_eproc.e_ppid
    return parent > 1 ? parent : nil
}

// MARK: - Herdr

/// Herdr, a terminal app. A Claude session started in one of its terminals is
/// Claude's own terminal session; a click shows that terminal in Herdr.
let herdrBundleId = "dev.herdr.app"
/// A terminal session Herdr runs: "herdr-pid:<pid>". Not openable as is (see Row.openURL).
let herdrLinkPrefix = "herdr-pid:"

/// The herdr-core process (Herdr's terminal server) a session runs under:
/// its executable, and the session's process with its ancestors below it,
/// nearest first. nil if Herdr doesn't run it. Process-table reads only.
func herdrCore(running pid: pid_t, parent: (pid_t) -> pid_t? = parentPid,
               path: (pid_t) -> String = executablePath) -> (core: String, chain: [pid_t])? {
    var chain: [pid_t] = []
    var next: pid_t? = pid
    while let current = next, chain.count < 16 {
        let exe = path(current)
        if (exe as NSString).lastPathComponent == "herdr-core" { return (exe, chain) }
        chain.append(current)
        next = parent(current)
    }
    return nil
}

/// A Herdr terminal's address, like "t7".
func isHerdrAddress(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 64 && s.allSatisfy { isASCIIAlnum($0) || "/-_.".contains($0) }
}

/// Whether a terminal, as `herdr-core get --json` describes it, runs the
/// session whose process chain this is: its shell or the program in front.
func herdrTerminalRuns(_ terminal: [String: Any], chain: [pid_t]) -> Bool {
    let pids = Set(chain.map(Int.init))
    let front = (terminal["foreground"] as? [String: Any])?["pid"] as? Int
    return [terminal["pid"] as? Int, front].contains { $0.map(pids.contains) ?? false }
}

enum Herdr {
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: herdrBundleId) }

    /// Shows a session's terminal in Herdr's window, then brings Herdr
    /// forward. Runs Herdr's own command-line tools, which answer in a few
    /// milliseconds and change only what its window shows. If they can't
    /// find the terminal, Herdr just comes forward.
    static func show(pid: pid_t) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let found = herdrCore(running: pid), let address = terminal(core: found.core, chain: found.chain),
               let app = appURL, let cli = Bundle(url: app)?.executableURL {
                _ = run(cli.path, ["do", "agent.focus", "--terminal", address])
            }
            DispatchQueue.main.async { if let app = appURL { NSWorkspace.shared.open(app) } }
        }
    }

    /// The address of the terminal running the session, asked of herdr-core.
    static func terminal(core: String, chain: [pid_t]) -> String? {
        guard let data = run(core, ["ls", "--json"]),
              let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["terminals"] as? [[String: Any]]
        else { return nil }
        for item in list {
            guard let address = item["address"] as? String, isHerdrAddress(address),
                  let data = run(core, ["get", address, "--json"]),
                  let terminal = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  herdrTerminalRuns(terminal, chain: chain)
            else { continue }
            return address
        }
        return nil
    }

    /// A command's output, nil if it fails or takes over 3 s.
    private static func run(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// Opens a row where it lives: the session in Claude, the thread in ChatGPT,
/// the app for Cursor, Antigravity and Orca, the terminal in Herdr.
func openRow(_ row: Row) {
    if row.linkApp == .herdr, let link = row.link, let pid = pid_t(link.dropFirst(herdrLinkPrefix.count)) {
        Herdr.show(pid: pid)
        return
    }
    guard let url = row.openURL else { return }
    NSWorkspace.shared.open(url)
}

/// Reads the ChatGPT app's Codex threads, on the engine's queue, on the
/// engine's two-second tick while a panel shows. Each tick: is the app's Codex server still
/// there (one call), which rollout files it holds (one call per open file),
/// and a stat of each; a file is read only when it grew, from where the
/// last read stopped. It looks for ChatGPT's servers every 10 s while it
/// knows none, and every 30 s otherwise.
final class CodexWatcher {
    private var servers: [pid_t] = []
    private var lookedForServers = Date.distantPast
    private var scans: [String: RolloutScan] = [:]
    private var headers: [String: (id: String?, cwd: String?, source: String?)] = [:]
    private var names: [String: String] = [:]
    private var namesStamp: FileStamp?
    private(set) var rows: [Row] = []

    static let indexPath = Paths.home.appendingPathComponent(".codex/session_index.jsonl").path

    /// No panel shows: drop the rows (what was read stays, for next time).
    @discardableResult
    func clear() -> Bool {
        guard !rows.isEmpty else { return false }
        rows = []
        return true
    }

    /// Reads once; true if the rows changed.
    @discardableResult
    func refresh() -> Bool {
        let now = Date()
        servers = servers.filter { kill($0, 0) == 0 }
        // Every 10 s while none is known, and every 30 s anyway: ChatGPT can
        // start a new server (after an update) while an old helper lives on.
        if now.timeIntervalSince(lookedForServers) >= (servers.isEmpty ? 10 : 30) {
            lookedForServers = now
            servers = Self.findServers()
        }
        var held = Set<String>()
        for pid in servers { held.formUnion(Self.heldRollouts(pid)) }
        for path in scans.keys where !held.contains(path) {
            scans[path] = nil
            headers[path] = nil
        }
        if !held.isEmpty { loadNames() }
        var fresh: [Row] = []
        for path in held {
            let header = headers[path] ?? rolloutHeader(path: path)
            headers[path] = header
            // The id inside the file is the thread's; the name is the fallback.
            guard let id = header.id ?? codexThreadId(path: path), codexThreadShown(source: header.source)
            else { continue }
            let before = scans[path] ?? RolloutScan()
            let size = fileStamp(path)?.size ?? 0
            let scan = UInt64(size) == before.offset ? before : scanRollout(path: path, from: before)
            scans[path] = scan
            if let row = codexRow(id: id, name: names[id], cwd: header.cwd, scan: scan) { fresh.append(row) }
        }
        fresh = rowsInOrder(fresh)
        guard fresh != rows else { return false }
        rows = fresh
        return true
    }

    /// The ChatGPT app's Codex servers: `codex` processes started by the app
    /// (com.openai.codex, named ChatGPT), directly or through one of its
    /// helpers: since November 2026 the server that holds the threads is
    /// started by "Codex (Aperitif)" inside the app, so it's the app's
    /// grandchild. Looks at every process's path, so only when none is known,
    /// at most every 10 s, and every 30 s otherwise.
    static func findServers() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }
        var found: [pid_t] = []
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            let exe = executablePath(pid)
            guard exe.hasSuffix("/MacOS/codex"), exe.contains(".app/Contents/") else { continue }
            if startedByChatGPT(pid) { found.append(pid) }
        }
        return found
    }

    /// Whether the ChatGPT app is among a process's parent, grandparent or
    /// great-grandparent.
    static func startedByChatGPT(_ pid: pid_t) -> Bool {
        var current = pid
        for _ in 0..<3 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return false }
            current = pid_t(info.pbi_ppid)
            if isChatGPTApp(executablePath(current)) { return true }
        }
        return false
    }

    /// The ChatGPT app's own executable, wherever the app is.
    static func isChatGPTApp(_ path: String) -> Bool { path.hasSuffix(".app/Contents/MacOS/ChatGPT") }

    /// The rollout files a process holds open.
    static func heldRollouts(_ pid: pid_t) -> Set<String> {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return [] }
        var paths = Set<String>()
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path.contains("/.codex/sessions/"), path.hasSuffix(".jsonl") { paths.insert(path) }
        }
        return paths
    }

    /// Thread names: the last name each id got in session_index.jsonl. Read
    /// again only when the file changes.
    private func loadNames() {
        let stamp = fileStamp(Self.indexPath)
        guard stamp != namesStamp else { return }
        namesStamp = stamp
        names = codexNames(index: (try? String(contentsOfFile: Self.indexPath, encoding: .utf8)) ?? "")
    }
}

/// The last name each thread id got, from session_index.jsonl's lines.
func codexNames(index: String) -> [String: String] {
    var names: [String: String] = [:]
    for line in index.split(separator: "\n") {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = object["id"] as? String, let name = object["thread_name"] as? String else { continue }
        names[id] = name
    }
    return names
}

// MARK: - Cursor threads

/// Cursor's bundle id: a click on one of its threads brings it forward.
let cursorBundleId = "com.todesktop.230313mzl4w4u92"

/// A Cursor thread's link: not openable as is (see Row.openURL).
let cursorLinkPrefix = "cursor-thread:"

/// One Cursor agent thread, from Cursor's own list of them: the small
/// composerHeaders table in its state database, a row per thread.
struct CursorThread: Equatable {
    let id: String
    var name: String?
    var subtitle: String?     // what Cursor shows under it: the last step, or your first ask
    var folder: String?
    var updated: Date         // lastUpdatedAt: your last message
    var checkpoint: Date?     // checkpointAt: moves as a run goes, and stamps its end
    var runStarted: Date?     // unfinishedRunAt: set while a run goes, cleared when it ends
    var needsApproval = false // hasBlockingPendingActions
    var planReady = false     // hasPendingPlan
}

/// A Cursor thread as a row: running, waiting on you, or finished. A run
/// that began before this Cursor started was cut short (it quit or
/// crashed mid-run), so it counts as finished.
func cursorRow(_ thread: CursorThread, cursorStarted: Date?) -> Row? {
    let name = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let runStart = thread.runStarted.flatMap { start in
        cursorStarted.map { start >= $0.addingTimeInterval(-60) } ?? true ? start : nil
    }
    guard !name.isEmpty || runStart != nil else { return nil }
    let id = "cursor:\(thread.id)", link = cursorLinkPrefix + thread.id
    let title = name.isEmpty ? "Cursor thread" : name
    let context = thread.folder.map(folderLabel) ?? "Cursor"
    let ended = max(thread.updated, thread.checkpoint ?? thread.updated)
    if let runStart {
        if thread.needsApproval {
            return Row(id: id, group: .yourTurn, title: title, detail: "Waiting for your approval", context: context,
                       since: thread.checkpoint ?? runStart, link: link)
        }
        let activity = thread.subtitle?.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        // Whole minutes, as Claude's and ChatGPT's: the quiet check needs no more.
        let written = thread.checkpoint.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded(.down) * 60) }
        return Row(id: id, group: .running, title: title, context: context, since: runStart, link: link,
                   activity: activity, lastOutput: written)
    }
    if thread.planReady {
        return Row(id: id, group: .yourTurn, title: title, detail: "Plan ready to review", context: context,
                   since: ended, link: link)
    }
    return Row(id: id, group: .done, title: title, context: context, since: ended, link: link)
}

/// Cursor's recent threads, newest first: not archived, not a subagent's,
/// not an unsent draft, touched since `since`. One indexed query on a small
/// table. The database is opened read-only and closed straight after, so
/// no read is left open to hold up Cursor's own writes. nil on any error.
func readCursorThreads(database path: String, since: Date, limit: Int = 30) -> [CursorThread]? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 20)
    let sql = """
        SELECT composerId, lastUpdatedAt, checkpointAt, json_extract(value, '$.name'),
               json_extract(value, '$.subtitle'), json_extract(value, '$.workspaceIdentifier.uri.fsPath'),
               json_extract(value, '$.unfinishedRunAt'), json_extract(value, '$.hasBlockingPendingActions'),
               json_extract(value, '$.hasPendingPlan')
        FROM composerHeaders
        WHERE isArchived = 0 AND isSubagent = 0 AND recency > ?
          AND coalesce(json_extract(value, '$.isDraft'), 0) = 0
        ORDER BY recency DESC LIMIT ?
        """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
    sqlite3_bind_int(statement, 2, Int32(limit))
    func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
    func date(_ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, column)) / 1000)
    }
    var threads: [CursorThread] = []
    while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return threads }
        guard step == SQLITE_ROW, let id = text(0) else { return nil }
        threads.append(CursorThread(id: id, name: text(3), subtitle: text(4), folder: text(5),
                                    updated: date(1) ?? .distantPast, checkpoint: date(2), runStarted: date(6),
                                    needsApproval: sqlite3_column_int(statement, 7) != 0,
                                    planReady: sqlite3_column_int(statement, 8) != 0))
    }
}

/// Reads one app's threads from the app's own database (Cursor's,
/// Antigravity's), on the engine's queue, on the engine's two-second tick
/// while a panel shows. Each tick: is the app still running (one call), and
/// a stat of the database and of its log; the list is read only when one of
/// them changed (about every 15 s while Cursor works), and tried again on
/// the next tick when a read fails. It looks for the app every 10 s while
/// it isn't running, and every 30 s otherwise. Rows show only while the app
/// runs.
final class AppThreadsWatcher {
    /// The app's main executable ends so: ".app/Contents/MacOS/Cursor".
    let executableSuffix: String
    let database: String
    /// The rows from the app's list of threads, given now and when the app started.
    private let read: (_ now: Date, _ appStarted: Date) -> [Row]?
    /// More files or folders whose change means read again (Antigravity's notes).
    private let watched: () -> [String]
    private var app: (pid: pid_t, started: Date)?
    private var lookedForApp = Date.distantPast
    private var stamp: [FileStamp?]?
    private(set) var rows: [Row] = []
    /// Reads of the list of threads, for the bench.
    private(set) var reads = 0

    init(executableSuffix: String, database: String, watched: @escaping () -> [String] = { [] },
         read: @escaping (_ now: Date, _ appStarted: Date) -> [Row]?) {
        self.executableSuffix = executableSuffix
        self.database = database
        self.watched = watched
        self.read = read
    }

    static let cursorDatabase = Paths.home
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    static let antigravityDatabase = Paths.home.appendingPathComponent(".gemini/antigravity/conversation_summaries.db").path

    static func cursor() -> AppThreadsWatcher {
        AppThreadsWatcher(executableSuffix: ".app/Contents/MacOS/Cursor", database: cursorDatabase) { now, started in
            readCursorThreads(database: cursorDatabase, since: now.addingTimeInterval(-Board.window))?
                .compactMap { cursorRow($0, cursorStarted: started) }
        }
    }

    static let orcaDatabase = Paths.home.appendingPathComponent("Library/Application Support/orca/agent-session-domain.db").path
    static let orcaWorktrees = Paths.home.appendingPathComponent("Library/Application Support/orca/orca-usage-worktree-history.json").path

    /// Orca's profile database, which names its folder workspaces and bots.
    static var orcaProfile: String {
        let orca = Paths.home.appendingPathComponent("Library/Application Support/orca")
        let index = readFile(orca.appendingPathComponent("orca-profile-index.json").path, limit: 1 << 20)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let profile = (index?["activeProfileId"] as? String).flatMap { id in
            id.allSatisfy { isASCIIAlnum($0) || $0 == "-" || $0 == "_" } && !id.isEmpty ? id : nil
        } ?? "local-default"
        return orca.appendingPathComponent("profiles/\(profile)/profile-state.db").path
    }

    /// Orca's: the threads open in its tabs, each under its worktree's name,
    /// a bot's chats with the bot's name. `adopted` gets the Orca thread for
    /// each agent's own id, so a Claude session Orca runs is listed once.
    /// The folder workspaces' names are read again only when Orca's profile
    /// changed.
    static func orca(adopted: AdoptedIds) -> AppThreadsWatcher {
        final class Folders { var stamp: [FileStamp?]?; var names: [String: (name: String, bot: Bool)] = [:] }
        let folders = Folders()
        return AppThreadsWatcher(executableSuffix: ".app/Contents/MacOS/Orca", database: orcaDatabase,
                                 watched: { [orcaWorktrees] }) { _, _ in
            guard var threads = readOrcaThreads(database: orcaDatabase) else { return nil }
            let names = orcaWorktreeNames(readFile(orcaWorktrees, limit: 1 << 20))
            let profile = orcaProfile
            let stamp = [pathStamp(profile), pathStamp(profile + "-wal")]
            if stamp != folders.stamp {
                folders.names = readOrcaFolderWorkspaces(database: profile)
                folders.stamp = stamp
            }
            for index in threads.indices {
                let workspace = threads[index].workspace
                threads[index].worktree = names[workspace]
                if workspace.hasPrefix("folder:"), let folder = folders.names[String(workspace.dropFirst(7))] {
                    if folder.bot { threads[index].bot = folder.name } else { threads[index].worktree = folder.name }
                }
            }
            adopted.threads = Dictionary(threads.compactMap { t in t.nativeId.map { ($0, t.id) } }, uniquingKeysWith: { a, _ in a })
            return threads.compactMap(orcaRow)
        }
    }

    static let antigravityNotes = Paths.home.appendingPathComponent(".gemini/antigravity/annotations").path

    /// Antigravity's: its list of conversations, less the ones you archived,
    /// which it marks only in each conversation's note. The notes of the
    /// conversations listed, and their folder, are watched too, so an
    /// archive shows within a tick.
    static func antigravity() -> AppThreadsWatcher {
        final class Listed { var ids: [String] = [] }
        let listed = Listed()
        return AppThreadsWatcher(executableSuffix: ".app/Contents/MacOS/Antigravity", database: antigravityDatabase,
                                 watched: { [antigravityNotes] + listed.ids.map { antigravityNotePath($0) } }) { now, started in
            guard let conversations = readAntigravityConversations(database: antigravityDatabase,
                                                                   since: now.addingTimeInterval(-Board.window))
            else { return nil }
            listed.ids = conversations.map(\.id)
            return conversations.filter { !antigravityArchived(note: readFile(antigravityNotePath($0.id), limit: 64 << 10)) }
                .compactMap { antigravityRow($0, appStarted: started) }
        }
    }

    /// One tick; true if the rows changed.
    @discardableResult
    func refresh(now: Date = Date()) -> Bool {
        if let app, kill(app.pid, 0) != 0 { self.app = nil }
        if now.timeIntervalSince(lookedForApp) >= (app == nil ? 10 : 30) {
            lookedForApp = now
            let found = Self.findApp(suffix: executableSuffix)
            if found?.pid != app?.pid { stamp = nil }
            app = found
        }
        guard let app else { return clear() }
        let current = ([database, database + "-wal"] + watched()).map(pathStamp)
        guard current != stamp else { return false }
        guard let read = read(now, app.started) else {
            // Read again on the next tick: a read can fail while the app writes.
            stamp = nil
            return false
        }
        // Taken again: the read can change what's watched (the conversations listed).
        stamp = ([database, database + "-wal"] + watched()).map(pathStamp)
        reads += 1
        let fresh = rowsInOrder(read)
        guard fresh != rows else { return false }
        rows = fresh
        return true
    }

    /// No panel shows, or the app quit: drop the rows.
    @discardableResult
    func clear() -> Bool {
        stamp = nil
        guard !rows.isEmpty else { return false }
        rows = []
        return true
    }

    /// The app's main process, and when it started.
    static func findApp(suffix: String) -> (pid: pid_t, started: Date)? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return nil }
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            guard executablePath(pid).hasSuffix(suffix) else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let started = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            return (pid, Date(timeIntervalSince1970: started))
        }
        return nil
    }
}

// MARK: - Orca threads

/// Orca's bundle id: a click on one of its threads brings it forward (its
/// orca:// links pair devices, open bots and share skills, none a thread).
let orcaBundleId = "com.stablyai.orca"

/// An Orca thread's link: not openable as is (see Row.openURL).
let orcaLinkPrefix = "orca-thread:"

/// The Orca thread for each agent's own id, kept by the engine so a Claude
/// session Orca runs is listed once.
final class AdoptedIds { var threads: [String: String] = [:] }

/// Orca's names for its worktrees ("Tidy-up session"), by workspace
/// id, from its small worktree history: {"worktrees": [[id, name], …]}.
func orcaWorktreeNames(_ json: Data?) -> [String: String] {
    guard let json, let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
          let pairs = object["worktrees"] as? [[Any]] else { return [:] }
    var names: [String: String] = [:]
    for pair in pairs where pair.count >= 2 {
        if let id = pair[0] as? String, let name = (pair[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            names[id] = name
        }
    }
    return names
}

/// Orca's folder workspaces by id: their names, and whether each is a bot
/// (kept under ~/.orca/bots). From Orca's profile database, read-only.
func readOrcaFolderWorkspaces(database path: String) -> [String: (name: String, bot: Bool)] {
    var db: OpaquePointer?
    guard FileManager.default.fileExists(atPath: path),
          sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
        sqlite3_close(db)
        return [:]
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 20)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT payload FROM profile_state_documents WHERE domain = 'folderWorkspaces'", -1,
                             &statement, nil) == SQLITE_OK, let statement else { return [:] }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return [:] }
    return orcaFolderWorkspaces(Data(String(cString: text).utf8))
}

/// Folder workspaces from their JSON: [{"id", "name", "folderPath"}, …].
func orcaFolderWorkspaces(_ json: Data) -> [String: (name: String, bot: Bool)] {
    guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [:] }
    var names: [String: (name: String, bot: Bool)] = [:]
    for workspace in list {
        guard let id = workspace["id"] as? String,
              let name = (workspace["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { continue }
        let folder = workspace["folderPath"] as? String ?? ""
        names[id] = (name, folder.contains("/.orca/bots/"))
    }
    return names
}

/// Claude's rows and Orca's, with each Claude session that Orca runs listed
/// once: as Claude's own row, which knows when the session waits on you and
/// what it's doing, and whose click goes to Orca. `sessions` is each live
/// terminal session's id by its pid; `orcaThreads` is the Orca thread for
/// each agent's own id.
func mergeOrca(claude: [Row], orca: [Row], sessions: [Int32: String], orcaThreads: [String: String]) -> [Row] {
    var linked: [String: String] = [:]   // "pid:N" -> Orca thread
    for (pid, session) in sessions {
        if let thread = orcaThreads[session] { linked["pid:\(pid)"] = thread }
    }
    let present = Set(claude.map(\.id))
    linked = linked.filter { present.contains($0.key) }
    guard !linked.isEmpty else { return claude + orca }
    let merged = Set(linked.values.map { "orca:\($0)" })
    let orcaById = Dictionary(orca.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return claude.map { row in
        guard let thread = linked[row.id] else { return row }
        var row = row
        row.link = orcaLinkPrefix + thread
        // Orca's name for it ("Home · Ada") and where it runs, with Claude's own state.
        if let named = orcaById["orca:\(thread)"] {
            row = Row(id: row.id, group: row.group, title: named.title, ask: row.ask, detail: row.detail, context: named.context,
                      since: row.since, link: row.link, terminal: row.terminal, activity: row.activity,
                      lastOutput: row.lastOutput, card: row.card, seen: row.seen, tags: row.tags,
                      snoozedUntil: row.snoozedUntil, agent: row.agent)
        }
        return row
    } + orca.filter { !merged.contains($0.id) }
}

/// One thread open in Orca: an agent (Claude, Codex, Antigravity…) Orca
/// runs, from Orca's own record of it (agent_session_records).
struct OrcaThread: Equatable {
    let id: String
    var agent: String          // provider: claude, codex, antigravity…
    var name: String           // conversationName
    var prompt: String         // the last turn's ask
    var workspace: String      // location.workspaceId: "<id>::<folder>", or "folder:<id>"
    var worktree: String? = nil // Orca's name for that worktree, if it has one
    var bot: String? = nil      // the bot's name, for a bot's chat ("Ada")
    var turnOpen = false       // lastTurn.state "open": the turn is going
    var turnAt: Date?          // when it started, or settled
    var outcome: String = ""   // success, failure, cancellation…
    var lastActivity: Date?    // journal_chat_state.last_activity_at
    var nativeId: String?      // the agent's own id for it
}

/// The app whose icon an Orca agent shows: Claude's, ChatGPT's for Codex,
/// Antigravity's, Cursor's. Another agent shows Orca's.
func orcaAgentIcon(_ agent: String) -> RowSource? {
    switch agent {
    case "claude": return .claude
    case "codex": return .chatGPT
    case "antigravity": return .antigravity
    case "cursor": return .cursor
    default: return nil
    }
}

/// "Claude", "Codex", "Antigravity" for an Orca agent.
func orcaAgentName(_ agent: String) -> String {
    switch agent {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "antigravity": return "Antigravity"
    case "gemini": return "Gemini"
    default: return agent.prefix(1).uppercased() + agent.dropFirst()
    }
}

/// An Orca thread as a row: running while its turn is open, else finished
/// ("Failed" or "Stopped" when it ended so). One never used is left out.
func orcaRow(_ t: OrcaThread) -> Row? {
    guard let turnAt = t.turnAt else { return nil }
    let id = "orca:\(t.id)", link = orcaLinkPrefix + t.id
    let ask = t.prompt.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    let base = [t.name.trimmingCharacters(in: .whitespacesAndNewlines), String(ask.prefix(80))].first { !$0.isEmpty }
        ?? "Orca thread"
    // A bot's chats are all "Home": the bot's name says whose.
    let title = t.bot.map { "\(base) · \($0)" } ?? base
    let folder = t.workspace.range(of: "::").map { String(t.workspace[$0.upperBound...]) }.flatMap { $0.isEmpty ? nil : $0 }
    let place = t.worktree ?? folder.map(folderLabel)
    // The agent's icon leads, so the line under it says where it runs; an
    // agent with no icon of its own is named.
    let agent = orcaAgentIcon(t.agent)
    let context = [place, agent == nil ? "\(orcaAgentName(t.agent)) in Orca" : "Orca"].compactMap { $0 }.joined(separator: " · ")
    if t.turnOpen {
        // Whole minutes, as the others: the quiet check needs no more.
        let written = t.lastActivity.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded(.down) * 60) }
        return Row(id: id, group: .running, title: title, context: context, since: turnAt, link: link, lastOutput: written,
                   agent: agent)
    }
    let detail = t.outcome == "failure" ? "Failed" : t.outcome == "cancellation" ? "Stopped" : nil
    return Row(id: id, group: .done, title: title, detail: detail, context: context, since: turnAt, link: link, agent: agent)
}

/// The threads open in Orca's tabs, from its session database, read-only
/// (it's in WAL mode and Orca keeps it open). Only Orca's records and tabs
/// are read, never the conversations. nil on any error.
func readOrcaThreads(database path: String) -> [OrcaThread]? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 20)
    let sql = """
        SELECT r.session_id, json_extract(r.record_json, '$.provider'), json_extract(r.record_json, '$.conversationName'),
               substr(json_extract(r.record_json, '$.lastTurn.prompt'), 1, 300), json_extract(r.record_json, '$.location.workspaceId'),
               json_extract(r.record_json, '$.lastTurn.state'), json_extract(r.record_json, '$.lastTurn.at'),
               json_extract(r.record_json, '$.lastTurn.outcome'), c.last_activity_at, r.adopted_native_id
        FROM agent_session_records r
        LEFT JOIN journal_chat_state c ON c.session_id = r.session_id
        WHERE r.session_id IN (SELECT session_id FROM agent_session_tabs) AND json_valid(r.record_json)
        """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
    defer { sqlite3_finalize(statement) }
    func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    func date(_ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let ms = sqlite3_column_int64(statement, column)
        return ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000) : nil
    }
    var threads: [OrcaThread] = []
    while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return threads }
        guard step == SQLITE_ROW else { return nil }
        let native = text(9)
        threads.append(OrcaThread(id: text(0), agent: text(1), name: text(2), prompt: text(3), workspace: text(4),
                                  turnOpen: text(5) == "open", turnAt: date(6), outcome: text(7), lastActivity: date(8),
                                  nativeId: native.isEmpty ? nil : native))
    }
}

// MARK: - Antigravity conversations

/// Antigravity's bundle id: a click on one of its conversations brings it forward.
let antigravityBundleId = "com.google.antigravity"

/// An Antigravity conversation's link: not openable as is (see Row.openURL).
let antigravityLinkPrefix = "antigravity-conversation:"

/// One Antigravity conversation, from Antigravity's own list of them
/// (conversation_summaries in ~/.gemini/antigravity), a row per conversation.
struct AntigravityConversation: Equatable {
    let id: String
    var title: String
    var preview: String
    var workspaces: String    // workspace_uris: file:// URIs, or empty outside a project
    var modified: Date        // last_modified_time: moves as a run goes
    var lastInput: Date?      // last_user_input_time: your last message
    var status: String        // CASCADE_RUN_STATUS_IDLE, _RUNNING, _BUSY, _CANCELING
    var killed = false
}

/// Antigravity's times: "2026-11-21 07:18:46.384063+00:00".
func antigravityTime(_ text: String) -> Date? {
    let chars = Array(text)
    guard chars.count >= 19 else { return nil }
    var parts = DateComponents()
    func number(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
    guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
          let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else { return nil }
    parts.year = year; parts.month = month; parts.day = day
    parts.hour = hour; parts.minute = minute; parts.second = second
    var index = 19
    var fraction = 0.0
    if index < chars.count, chars[index] == "." {
        index += 1
        var digits = ""
        while index < chars.count, chars[index].isNumber { digits.append(chars[index]); index += 1 }
        fraction = Double("0." + digits) ?? 0
    }
    var offset = 0
    if index < chars.count, chars[index] == "+" || chars[index] == "-" {
        let sign = chars[index] == "-" ? -1 : 1
        let rest = String(chars[(index + 1)...]).replacingOccurrences(of: ":", with: "")
        guard rest.count >= 4, let hours = Int(rest.prefix(2)), let minutes = Int(rest.dropFirst(2).prefix(2)) else { return nil }
        offset = sign * (hours * 3600 + minutes * 60)
    } else if index < chars.count, chars[index] == "Z" {
        offset = 0
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? .gmt
    return calendar.date(from: parts)?.addingTimeInterval(fraction)
}

/// The folder of an Antigravity conversation's first workspace, if any.
func antigravityFolder(_ workspaces: String) -> String? {
    let first = workspaces.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
    guard !first.isEmpty else { return nil }
    let path = URL(string: first)?.path ?? first
    return path.isEmpty ? nil : path
}

/// An Antigravity conversation's note: its title as you set it, when you
/// last looked, and whether you archived it.
func antigravityNotePath(_ id: String) -> String { AppThreadsWatcher.antigravityNotes + "/\(id).pbtxt" }

/// Whether a note (text-format protobuf) says archived: `archived:true`.
func antigravityArchived(note: Data?) -> Bool {
    guard let note, let text = String(data: note, encoding: .utf8) else { return false }
    return text.filter { !$0.isWhitespace }.contains("archived:true")
}

/// An Antigravity conversation as a row: running, or finished. A run whose
/// last change came before this Antigravity started was cut short, so it
/// counts as finished.
func antigravityRow(_ c: AntigravityConversation, appStarted: Date?) -> Row? {
    let id = "agy:\(c.id)", link = antigravityLinkPrefix + c.id
    let title = [c.title, c.preview].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        ?? "Antigravity conversation"
    let context = antigravityFolder(c.workspaces).map(folderLabel) ?? "Antigravity"
    let busy = ["CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING"].contains(c.status)
    let current = appStarted.map { c.modified >= $0.addingTimeInterval(-60) } ?? true
    if busy && !c.killed && current {
        // Whole minutes, as the others: the quiet check needs no more.
        let written = Date(timeIntervalSince1970: (c.modified.timeIntervalSince1970 / 60).rounded(.down) * 60)
        return Row(id: id, group: .running, title: title, context: context, since: c.lastInput ?? c.modified, link: link,
                   lastOutput: written)
    }
    return Row(id: id, group: .done, title: title, detail: c.killed ? "Stopped" : nil, context: context,
               since: c.modified, link: link)
}

/// Antigravity's recent conversations, newest first: not a subagent's, not
/// run by its command-line agent (`agy`, which Orca runs too: Antigravity
/// never marks those running, and Orca's own list has them), changed since
/// `since`. Read-only, like Cursor's. While Antigravity has
/// the database open, its write-ahead log is there and is read too; when it
/// has closed it, the log is gone, a read-only reader can't make one, and
/// the database file itself is current, so it's read as a snapshot that
/// takes no lock (`immutable=1`). nil on any error.
func readAntigravityConversations(database path: String, since: Date, limit: Int = 30) -> [AntigravityConversation]? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let escaped = path.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "?", with: "%3f")
        .replacingOccurrences(of: "#", with: "%23")
    return queryAntigravity("file:\(escaped)", since: since, limit: limit)
        ?? queryAntigravity("file:\(escaped)?immutable=1", since: since, limit: limit)
}

private func queryAntigravity(_ uri: String, since: Date, limit: Int) -> [AntigravityConversation]? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
          let db else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 20)
    let sql = """
        SELECT conversation_id, title, preview, workspace_uris, last_modified_time, last_user_input_time, status, killed
        FROM conversation_summaries
        WHERE nesting_depth = 0 AND parent_conversation_id = '' AND last_modified_time > ?
          AND source != 'CORTEX_TRAJECTORY_SOURCE_CLI'
        ORDER BY last_modified_time DESC LIMIT ?
        """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
    defer { sqlite3_finalize(statement) }
    let cutoff = DateFormatter()
    cutoff.locale = Locale(identifier: "en_US_POSIX")
    cutoff.timeZone = .gmt
    cutoff.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, cutoff.string(from: since), -1, transient)
    sqlite3_bind_int(statement, 2, Int32(limit))
    func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    var conversations: [AntigravityConversation] = []
    while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return conversations }
        guard step == SQLITE_ROW, let modified = antigravityTime(text(4)) else { return nil }
        conversations.append(AntigravityConversation(id: text(0), title: text(1), preview: text(2), workspaces: text(3),
                                                     modified: modified, lastInput: antigravityTime(text(5)),
                                                     status: text(6), killed: sqlite3_column_int(statement, 7) != 0))
    }
}

// MARK: - Engine

/// Owns all file access, on one low-priority serial queue.
final class SessionEngine {
    let queue = DispatchQueue(label: "com.maheshauti.limbo-tasks.data", qos: .utility)
    /// Called on the main queue, only when the rows changed.
    var onRows: (([Row]) -> Void)?
    /// Called on the main queue with the sessions archived in the Claude app, whose tags go.
    var onArchived: ((Set<String>) -> Void)?

    private struct DeskEntry {
        let stamp: FileStamp
        let record: DeskRecord?
    }

    private var stream: FSEventStreamRef?
    private var desk: [String: DeskEntry] = [:]          // by path
    private var live: [Int32: LiveRecord] = [:]
    private var exited = Set<String>()
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var lastRows: [Row]?
    private var statsSignal: DispatchSourceSignal?
    /// Transcripts are read only while a panel that shows the live activity is open.
    private var activityWanted = false
    private var activityWatchers: [Int32: ActivityWatcher] = [:]
    private var activities: [Int32: Activity] = [:]
    private var eventBatches = 0
    private var fileParses = 0
    /// Each recent finished session's turn card, by transcript path: read only
    /// while the window or panel shows, and again only when the transcript changes.
    private var cardCache: [String: (stamp: FileStamp, card: TurnCard?)] = [:]
    private var titleCache: [String: (size: Int64, title: String?, read: Date)] = [:]
    /// Whether Herdr runs each terminal session, by live record key: a process's ancestors don't change.
    private var herdrHosted: [String: Bool] = [:]
    private var cardReads = 0
    /// A record is written about 2 s after its transcript ends, which triggers a
    /// look; this also looks every 30 s in case a transcript ends later.
    private var cardCheck: DispatchSourceTimer?
    /// ChatGPT's and Cursor's threads, read every 2 s, only while a panel shows.
    private let codex = CodexWatcher()
    private let cursor = AppThreadsWatcher.cursor()
    private let antigravity = AppThreadsWatcher.antigravity()
    private let orcaAdopted = AdoptedIds()
    private lazy var orca = AppThreadsWatcher.orca(adopted: orcaAdopted)
    private var otherApps: DispatchSourceTimer?

    func start() {
        queue.async {
            self.scanAll()
            self.publishIfChanged()
            self.startStream()
        }
    }

    /// A full reconcile: on panel open and after wake. Cheap, since unchanged
    /// files are only stat'ed.
    func refresh() {
        queue.async {
            self.scanAll()
            self.publishIfChanged()
        }
    }

    /// One synchronous scan, for --dump, --snapshot and the bench.
    static func scanOnce() -> [Row] {
        let engine = SessionEngine()
        return engine.queue.sync {
            engine.scanAll()
            // One-off checks also read the live activity of running sessions.
            var activities: [Int32: Activity] = [:]
            for (pid, record) in engine.live where record.isBusy {
                if let id = record.cliSessionId {
                    activities[pid] = Activity(transcript: transcriptPath(cwd: record.cwd, cliSessionId: id))
                }
            }
            engine.activityWanted = true
            engine.codex.refresh()
            engine.cursor.refresh()
            engine.antigravity.refresh()
            engine.orca.refresh()
            let claude = classify(desk: engine.desk.values.compactMap(\.record), live: engine.live, now: Date(),
                                  activities: activities, cards: engine.currentCards(), background: engine.backgroundWork(),
                                  titles: engine.terminalTitles())
            return engine.withOtherApps(claude)
        }
    }

    private func reloadLive() {
        let result = readLiveRecords(exited: exited)
        live = result.records
        exited.formIntersection(result.present)
        for (pid, record) in live where record.hostId == nil {
            let hosted = herdrHosted[record.key] ?? (herdrCore(running: pid) != nil)
            herdrHosted[record.key] = hosted
            live[pid]?.inHerdr = hosted
        }
        let keys = Set(live.values.map(\.key))
        herdrHosted = herdrHosted.filter { keys.contains($0.key) }
        for (pid, source) in exitSources where live[pid] == nil {
            source.cancel()
            exitSources[pid] = nil
        }
        for (pid, record) in live where exitSources[pid] == nil {
            // The kernel tells us when the process exits, even if it leaves its file behind.
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let key = record.key
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.exited.insert(key)
                self.reloadLive()
                self.publishIfChanged()
            }
            source.resume()
            exitSources[pid] = source
        }
        syncActivityWatchers()
    }

    /// Called on the main queue when a panel that shows live activity opens or closes.
    func setActivityWanted(_ wanted: Bool) {
        queue.async {
            guard self.activityWanted != wanted else { return }
            self.activityWanted = wanted
            self.cardCheck?.cancel()
            self.cardCheck = nil
            if wanted {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
                timer.setEventHandler { [weak self] in self?.publishIfChanged() }
                timer.resume()
                self.cardCheck = timer
                let apps = DispatchSource.makeTimerSource(queue: self.queue)
                apps.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
                apps.setEventHandler { [weak self] in
                    guard let self else { return }
                    let changed = [self.codex.refresh(), self.cursor.refresh(), self.antigravity.refresh(), self.orca.refresh()]
                    if changed.contains(true) { self.publishIfChanged() }
                }
                apps.resume()
                self.otherApps = apps
            } else {
                self.otherApps?.cancel()
                self.otherApps = nil
                self.codex.clear()
                self.cursor.clear()
                self.antigravity.clear()
                self.orca.clear()
            }
            self.syncActivityWatchers()
            self.publishIfChanged()
        }
    }

    private func syncActivityWatchers() {
        let busy = activityWanted ? live.filter { $0.value.isBusy && $0.value.cliSessionId != nil } : [:]
        for (pid, watcher) in activityWatchers where busy[pid]?.key != watcher.key {
            watcher.cancel()
            activityWatchers[pid] = nil
            activities[pid] = nil
        }
        for (pid, record) in busy where activityWatchers[pid] == nil {
            guard let id = record.cliSessionId else { continue }
            let path = transcriptPath(cwd: record.cwd, cliSessionId: id)
            activityWatchers[pid] = ActivityWatcher(key: record.key, path: path, queue: queue) { [weak self] activity in
                guard let self, self.activityWatchers[pid] != nil || self.activities[pid] == nil else { return }
                // A busy transcript is written every second or so: pass on a new
                // write time only once a minute, which is all the quiet check needs.
                if let old = self.activities[pid], old.text == activity.text,
                   let was = old.lastOutput, let now = activity.lastOutput, now.timeIntervalSince(was) < 60 { return }
                self.activities[pid] = activity
                self.publishIfChanged()
            }
        }
    }

    /// Running background tasks of sessions between turns, by process id. A
    /// finished task wakes its session, which rewrites its live record, so a
    /// change is seen without polling (and every 30 s while a panel shows).
    private func backgroundWork() -> [Int32: Int] {
        var work: [Int32: Int] = [:]
        for (pid, record) in live where !record.isBusy && !record.isWaiting {
            guard let id = record.cliSessionId else { continue }
            let tasks = runningBackgroundTasks(parent: pid, session: id)
            if tasks > 0 { work[pid] = tasks }
        }
        return work
    }

    /// Titles of terminal sessions whose name Claude Code made up from the folder,
    /// by process id. A stat per session; a transcript that grew is read again
    /// at most every 10 s until it has a title, then every minute.
    private func terminalTitles() -> [Int32: String] {
        guard activityWanted else { return [:] }
        let now = Date()
        var titles: [Int32: String] = [:]
        var kept = Set<String>()
        for (pid, record) in live where record.hostId == nil && record.nameIsDerived {
            guard let id = record.cliSessionId else { continue }
            let path = transcriptPath(cwd: record.cwd, cliSessionId: id)
            kept.insert(path)
            guard let size = fileStamp(path)?.size else { continue }
            var entry = titleCache[path]
            if entry == nil || entry!.size != size
                && now.timeIntervalSince(entry!.read) >= (entry!.title == nil ? 10 : 60) {
                let found = autoreleasepool { transcriptTitle(path: path) }
                entry = (size, found ?? entry?.title, now)
                titleCache[path] = entry
            }
            if let title = entry?.title { titles[pid] = title }
        }
        for path in Array(titleCache.keys) where !kept.contains(path) { titleCache[path] = nil }
        return titles
    }

    /// The turn cards of recent sessions that are not running, by session id.
    /// A stat per session; a transcript is read again only when it changed.
    private func currentCards() -> [String: TurnCard] {
        guard activityWanted else { return [:] }
        let now = Date()
        let busy = Set(live.values.filter(\.isBusy).compactMap(\.hostId))
        var cards: [String: TurnCard] = [:]
        var kept = Set<String>()
        for record in desk.values.compactMap(\.record) {
            guard !record.isArchived, !busy.contains(record.sessionId), let id = record.transcriptId,
                  now.timeIntervalSince(record.lastTurnEdge ?? record.lastActivity ?? record.fileTime) <= Board.recentLimit
            else { continue }
            let path = transcriptPath(cwd: record.cwd, cliSessionId: id)
            kept.insert(path)
            guard let stamp = fileStamp(path) else { continue }
            let card: TurnCard?
            if let cached = cardCache[path], cached.stamp == stamp {
                card = cached.card
            } else {
                card = autoreleasepool { turnCard(transcript: path) }
                cardReads += 1
                cardCache[path] = (stamp, card)
            }
            if var card {
                card.transcript = path
                cards[record.sessionId] = card
            }
        }
        for path in Array(cardCache.keys) where !kept.contains(path) { cardCache[path] = nil }
        return cards
    }

    private func refreshDesk(path: String, cutoff: TimeInterval) {
        guard let st = fileStamp(path), st.mtime >= cutoff else {
            desk[path] = nil
            return
        }
        if let old = desk[path], old.stamp == st { return }
        fileParses += 1
        let record = autoreleasepool { parseDeskRecord(path: path, stamp: st) }
        desk[path] = DeskEntry(stamp: st, record: record)
    }

    private func scanAll() {
        reloadLive()
        let fm = FileManager.default
        let cutoff = Date().timeIntervalSince1970 - dataWindow
        var seen = Set<String>()
        for account in (try? fm.contentsOfDirectory(atPath: Paths.desk)) ?? [] where !account.hasPrefix(".") {
            let accountPath = Paths.desk + "/" + account
            for org in (try? fm.contentsOfDirectory(atPath: accountPath)) ?? [] where !org.hasPrefix(".") {
                let orgPath = accountPath + "/" + org
                for name in (try? fm.contentsOfDirectory(atPath: orgPath)) ?? [] where isDeskFileName(name) {
                    let path = orgPath + "/" + name
                    seen.insert(path)
                    refreshDesk(path: path, cutoff: cutoff)
                }
            }
        }
        for path in Array(desk.keys) where !seen.contains(path) { desk[path] = nil }
    }

    /// `kill -USR1 <pid>` writes counts (no titles or text) to
    /// ~/Library/Caches/com.maheshauti.limbo-tasks.stats.json, for checking the
    /// running app without its screen.
    func enableStatsSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
        source.setEventHandler { [weak self] in self?.writeStats() }
        source.resume()
        statsSignal = source
    }

    private func writeStats() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let board = Board(rows: lastRows ?? [], now: Date())
        let stats: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "yourTurn": board.yourTurn.count, "older": board.older.count, "running": board.running.count,
            "justFinished": board.justFinished.count, "review": board.review.count, "done": board.done.count,
            "terminal": board.terminal.count, "deskFilesTracked": desk.count,
            "deskRecordsParsed": desk.values.filter { $0.record != nil }.count, "liveRecords": live.count,
            "eventBatches": eventBatches, "fileParses": fileParses,
            "cardReads": cardReads, "cardsCached": cardCache.count,
            "footprintMB": (footprintMB().now * 10).rounded() / 10, "cpuSeconds": (cpu * 1000).rounded() / 1000,
        ].merging(spinStats.snapshot()) { a, _ in a }
        let url = Paths.home.appendingPathComponent("Library/Caches/\(LoginItem.label).stats.json")
        if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Claude's rows plus the other apps', each Claude session Orca runs listed once.
    private func withOtherApps(_ claude: [Row]) -> [Row] {
        let others = codex.rows + cursor.rows + antigravity.rows
        guard !orca.rows.isEmpty else { return others.isEmpty ? claude : rowsInOrder(claude + others) }
        let sessions = Dictionary(live.values.compactMap { r in r.cliSessionId.map { (r.pid, $0) } },
                                  uniquingKeysWith: { a, _ in a })
        return rowsInOrder(mergeOrca(claude: claude, orca: orca.rows, sessions: sessions, orcaThreads: orcaAdopted.threads)
                           + others)
    }

    private func publishIfChanged() {
        let claude = classify(desk: desk.values.compactMap(\.record), live: live, now: Date(), activities: activities,
                              cards: currentCards(), background: backgroundWork(), titles: terminalTitles())
        let rows = withOtherApps(claude)
        guard rows != lastRows else { return }
        lastRows = rows
        let archived = Set(desk.values.compactMap { $0.record?.isArchived == true ? $0.record?.sessionId : nil })
        DispatchQueue.main.async { [weak self] in
            self?.onRows?(rows)
            self?.onArchived?(archived)
        }
    }

    private func startStream() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let engine = Unmanaged<SessionEngine>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var flagList: [FSEventStreamEventFlags] = []
            for i in 0..<count { flagList.append(flags[i]) }
            engine.handle(paths: list, flags: flagList)
        }
        // Latency 1 s: the first change is delivered at once, a burst becomes one callback.
        let options = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [Paths.live, Paths.desk] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, options)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        eventBatches += 1
        let rescanFlags = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        var rescan = false
        var liveChanged = false
        var deskChanged = Set<String>()
        let livePrefix = Paths.live + "/"
        for (i, path) in paths.enumerated() {
            if i < flags.count, Int(flags[i]) & Int(rescanFlags) != 0 {
                rescan = true
            } else if path.hasPrefix(livePrefix) {
                let rest = path.dropFirst(livePrefix.count)
                if !rest.contains("/") && isLiveFileName(rest) { liveChanged = true }
            } else if isDeskRecordPath(path) {
                deskChanged.insert(path)
            }
        }
        if rescan {
            scanAll()
        } else {
            if liveChanged { reloadLive() }
            let cutoff = Date().timeIntervalSince1970 - dataWindow
            for path in deskChanged { refreshDesk(path: path, cutoff: cutoff) }
            guard liveChanged || !deskChanged.isEmpty else { return }
        }
        publishIfChanged()
    }
}

final class SessionModel: ObservableObject {
    @Published var rows: [Row] = []
    /// The rows as the engine made them, before your tags.
    private var sourceRows: [Row] = []
    private(set) var tags = SessionTags.load()
    private(set) var snoozes: SessionSnoozes
    private(set) var hides: SessionHides
    /// When each snooze ran out on its own: the session glows amber again
    /// for a while, as if it had just asked.
    private(set) var wokeAt: [String: Date] = [:]
    private var wakeTimer: Timer?
    private let defaults: UserDefaults
    /// After a tag or a snooze changes: counts, glow and the window's size follow.
    var onTagsChanged: (() -> Void)?
    /// New Tag…: asks for the name.
    var onNewTag: ((Row) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snoozes = SessionSnoozes.load(defaults)
        hides = SessionHides.load(defaults)
    }

    /// Sets the rows, with your tags and snoozes on them.
    func setRows(_ rows: [Row]) {
        sourceRows = rows
        let ended = snoozes.expire(now: Date())
        wokeAt.merge(ended) { $1 }
        if snoozes.prune(rows) || !ended.isEmpty { snoozes.save(defaults) }
        if hides.prune(rows, now: Date()) { hides.save(defaults) }
        self.rows = decorated()
        scheduleWake()
    }

    private func decorated() -> [Row] {
        hides.apply(to: snoozes.apply(to: tags.apply(to: sourceRows), now: Date()))
    }

    /// Out of the window and the counts until the session next changes.
    func hide(_ row: Row) {
        hides.hide(row.id, at: Date())
        hidesChanged()
    }

    /// Back where it was, without waiting for it to change.
    func unhide(_ row: Row) {
        hides.show(row.id)
        hidesChanged()
    }

    private func hidesChanged() {
        hides.save(defaults)
        rows = decorated()
        onTagsChanged?()
    }

    /// Holds the session until then, or until it moves on.
    func snooze(_ row: Row, until: Date) {
        snoozes.snooze(row.id, until: until, at: Date())
        wokeAt[row.id] = nil
        snoozesChanged()
    }

    func wake(_ row: Row) {
        snoozes.wake(row.id)
        snoozesChanged()
    }

    func wakeAll() {
        snoozes.byId.removeAll()
        snoozesChanged()
    }

    /// Ends the snoozes that ran out. The timer calls it, and so does the
    /// Mac waking from sleep (a timer can run late across sleep).
    func wakeDue() {
        let now = Date()
        let ended = snoozes.expire(now: now)
        guard !ended.isEmpty else { scheduleWake(); return }
        wokeAt.merge(ended) { $1 }
        self.now = now
        snoozesChanged()
    }

    private func snoozesChanged() {
        snoozes.save(defaults)
        rows = decorated()
        scheduleWake()
        onTagsChanged?()
    }

    private func scheduleWake() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard let next = snoozes.nextEnd else { return }
        let timer = Timer(fire: max(next, Date()).addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            self?.wakeDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    func toggleTag(_ tag: String, on row: Row) {
        tags.toggle(tag, on: row.id)
        tagsChanged()
    }

    func addTag(named name: String, to row: Row) {
        guard let tag = tags.clean(name) else { return }
        tags.add(tag, to: row.id)
        tagsChanged()
    }

    func clearTags(on row: Row) {
        tags.clear(row.id)
        tagsChanged()
    }

    /// A session archived in the Claude app loses its tags.
    func forgetArchived(_ ids: Set<String>) {
        let snoozeGone = snoozes.forget(ids)
        if snoozeGone { snoozes.save(defaults) }
        let hideGone = hides.forget(ids)
        if hideGone { hides.save(defaults) }
        if tags.forget(ids) {
            tagsChanged()
        } else if snoozeGone || hideGone {
            rows = decorated()
            onTagsChanged?()
        }
    }

    private func tagsChanged() {
        tags.save()
        rows = decorated()
        onTagsChanged?()
    }

    /// What a row's right-click menu offers.
    var tagActions: TagActions {
        TagActions(enabled: true, known: tags.known(among: Set(sourceRows.map(\.id))),
                   toggle: { [weak self] row, tag in self?.toggleTag(tag, on: row) },
                   newTag: { [weak self] row in self?.onNewTag?(row) },
                   clear: { [weak self] row in self?.clearTags(on: row) },
                   snooze: { [weak self] row, until in self?.snooze(row, until: until) },
                   wake: { [weak self] row in self?.wake(row) },
                   hide: { [weak self] row in self?.hide(row) },
                   unhide: { [weak self] row in self?.unhide(row) })
    }
    /// Drives the "3 min ago" labels. Ticks only while a panel is showing.
    @Published var now = Date()
    /// True while the keep-on-top window is showing.
    @Published var pinned = false {
        didSet { if pinned != oldValue { onVisibilityChange?() } }
    }
    /// True while the menu bar panel is open.
    var panelOpen = false {
        didSet { if panelOpen != oldValue { onVisibilityChange?() } }
    }
    /// Live activity is read only while one of the two is showing.
    var onVisibilityChange: (() -> Void)?
    /// When each session was last opened from here: opening one that needs
    /// you stops its amber glow.
    private(set) var openedAt: [String: Date] = [:]
    var onOpened: (() -> Void)?

    func markOpened(_ row: Row) {
        openedAt[row.id] = Date()
        onOpened?()
    }

    /// Marks sessions as seen without opening them: the Got it button.
    func acknowledge(_ rows: [Row]) {
        let now = Date()
        for row in rows { openedAt[row.id] = now }
    }

    /// Sessions that started waiting for you in the last hour and have not been
    /// opened since, from here or in the Claude app.
    func freshNeedsYou(_ board: Board) -> [Row] {
        board.yourTurn.filter { row in
            let opened = [openedAt[row.id], row.seen].compactMap { $0 }.max()
            // A snooze that ran out counts as asking again then.
            let asked = max(row.since, wokeAt[row.id] ?? .distantPast)
            return now.timeIntervalSince(asked) <= freshFor && (opened.map { $0 < asked } ?? true)
        }
    }
    let freshFor: TimeInterval = 3600
}

// MARK: - Start at login

/// A per-user LaunchAgent that points at this executable.
/// No KeepAlive, so Quit really quits; it comes back at the next login.
enum LoginItem {
    static let label = "com.maheshauti.limbo-tasks"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) throws {
        let fm = FileManager.default
        if on {
            guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
                throw CocoaError(.fileNoSuchFile)
            }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else if fm.fileExists(atPath: plistURL.path) {
            try fm.removeItem(at: plistURL)
        }
    }
}

/// Holds an exclusive lock for the life of the process so a second copy exits at once.
func isOnlyInstance() -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
    let fd = open(dir.appendingPathComponent("\(LoginItem.label).lock").path, O_CREAT | O_RDWR, 0o600)
    if fd < 0 { return true }
    return flock(fd, LOCK_EX | LOCK_NB) == 0
}

// MARK: - Menu bar item

/// The Claude mark, taken at run time from the installed Claude app's own menu
/// bar icon (nothing is copied into this repo); a plain asterisk symbol if the
/// app is not installed.
let claudeMark: NSImage = {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop"),
       let image = Bundle(url: url)?.image(forResource: "TrayIconTemplate") {
        image.isTemplate = true
        return image
    }
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
    return NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        ?? NSImage(size: NSSize(width: 14, height: 14))
}()

/// One template image, so the system tints it for light and dark menu bars:
/// the Claude mark with the number of sessions running, then a speech bubble
/// with the number waiting for you. A check mark when neither. With
/// `drawMark: false` the mark's slot is left empty and returned, so the app can
/// put a separately animated mark there.
func statusImage(needYou: Int, running: Int, angle: CGFloat = 0,
                 drawMark: Bool = true) -> (image: NSImage, markRect: NSRect?) {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let markSize = NSSize(width: 18, height: 18)   // the icon has padding; the mark itself is ~13 pt
    struct Part { let image: NSImage?; let size: NSSize; let spins: Bool; let text: NSAttributedString? }
    var parts: [Part] = []
    if running > 0 {
        parts.append(Part(image: claudeMark, size: markSize, spins: true,
                          text: NSAttributedString(string: "\(running)", attributes: attrs)))
    }
    for (symbol, count) in [("bubble.left.fill", needYou)] where count > 0 {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        parts.append(Part(image: image, size: image?.size ?? .zero, spins: false,
                          text: NSAttributedString(string: "\(count)", attributes: attrs)))
    }
    if parts.isEmpty {
        let image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        parts.append(Part(image: image, size: image?.size ?? .zero, spins: false, text: nil))
    }

    let height: CGFloat = 18, inner: CGFloat = 3, outer: CGFloat = 9
    var width: CGFloat = 0
    for (i, part) in parts.enumerated() {
        if i > 0 { width += outer }
        width += part.size.width
        if let text = part.text { width += inner + ceil(text.size().width) }
    }
    let size = NSSize(width: ceil(width), height: height)
    let scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return (NSImage(size: size), nil) }
    rep.size = size   // before the context, so drawing is in points
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return (NSImage(size: size), nil) }
    var markRect: NSRect?
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    var x: CGFloat = 0
    for (i, part) in parts.enumerated() {
        if i > 0 { x += outer }
        if let image = part.image {
            let rect = NSRect(x: x, y: (height - part.size.height) / 2, width: part.size.width, height: part.size.height)
            if part.spins { markRect = rect }
            if part.spins && !drawMark {
                // Left empty for the animated mark.
            } else if part.spins && angle != 0 {
                let turn = NSAffineTransform()
                turn.translateX(by: rect.midX, yBy: rect.midY)
                turn.rotate(byDegrees: -angle)          // clockwise
                turn.translateX(by: -rect.midX, yBy: -rect.midY)
                NSGraphicsContext.saveGraphicsState()
                turn.concat()
                image.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                image.draw(in: rect)
            }
        }
        x += part.size.width
        if let text = part.text {
            x += inner
            let textSize = text.size()
            text.draw(at: NSPoint(x: x, y: (height - textSize.height) / 2))
            x += ceil(textSize.width)
        }
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = true
    return (image, markRect)
}

/// What the menu bar animation is doing, for the SIGUSR1 counts file.
final class SpinStats {
    private let lock = NSLock()
    private var spinning = false
    func set(spinning: Bool) { lock.lock(); self.spinning = spinning; lock.unlock() }
    func snapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return ["spinning": spinning] }
}
let spinStats = SpinStats()

// MARK: - Panel

/// nil means under a minute.
func elapsed(since d: Date, now: Date) -> String? {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return nil }
    if s < 3600 { return "\(s / 60) min" }
    if s < 86400 { return "\(s / 3600) hr" }
    let days = s / 86400
    return days == 1 ? "1 day" : "\(days) days"
}

/// "45s", "2m 3s", "1h 5m", as the Claude app shows a running turn.
func stopwatch(since d: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

func ago(_ d: Date, _ now: Date) -> String {
    elapsed(since: d, now: now).map { "\($0) ago" } ?? "just now"
}

/// Set by --snapshot: layer animations don't show in a cached drawing, so
/// pictures use the still ring and plain status text.
var staticIndicators = false

/// The running mark: a ring whose arc turns once a second. Core Animation
/// turns it in the window server at a capped frame rate, so the app does no
/// work per frame. Still with Reduce Motion on.
final class SpinnerView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let size: CGFloat
    var color: NSColor = .systemBlue {
        didSet { if color != oldValue { applyColors() } }
    }

    /// A ring of `ring` points across, `lineWidth` thick, centred in a square
    /// of `size`: 16, 11 and 2 for a row's mark; smaller on an app's icon.
    init(size: CGFloat = 16, ring: CGFloat = 11, lineWidth: CGFloat = 2) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        // Set up as is, or the arc animates in from a full ring.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let inset = (size - ring) / 2
        let path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: ring, height: ring), transform: nil)
        for shape in [track, arc] {
            shape.frame = CGRect(x: 0, y: 0, width: size, height: size)
            shape.path = path
            shape.fillColor = nil
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0.3
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the row

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        updateAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    /// Shape layers draw at their own scale: match the screen, or the ring blurs.
    private func applyScale() {
        let scale = window?.backingScaleFactor ?? 2
        track.contentsScale = scale
        arc.contentsScale = scale
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = color.withAlphaComponent(0.24).cgColor
        arc.strokeColor = color.cgColor
        CATransaction.commit()
    }

    func updateAnimation() {
        let still = window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if still {
            arc.removeAllAnimations()
            return
        }
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi   // clockwise
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
        arc.add(spin, forKey: "spin")
    }
}

struct RunningSpinner: NSViewRepresentable {
    let color: Color
    var size: CGFloat = 16
    var ring: CGFloat = 11
    var lineWidth: CGFloat = 2
    func makeNSView(context: Context) -> SpinnerView { SpinnerView(size: size, ring: ring, lineWidth: lineWidth) }
    func updateNSView(_ view: SpinnerView, context: Context) {
        view.color = NSColor(color)
        view.updateAnimation()
    }
}

/// A running row's status line with a light band sweeping across it, like
/// Claude's own "Thinking": a brighter copy of the text shows through a
/// gradient mask that Core Animation moves in the window server, so the app
/// does no work per frame. The label spans the row, so a new status doesn't
/// restart the sweep. Plain text with Reduce Motion on.
final class ShimmerLabel: NSView {
    private let base = CATextLayer()
    private let bright = CATextLayer()
    private let band = CAGradientLayer()
    private static let bandWidth: CGFloat = 60
    private var sweptWidth: CGFloat = -1
    var text = "" { didSet { if text != oldValue { applyText() } } }
    var font = NSFont.systemFont(ofSize: 11) { didSet { if font != oldValue { applyText() } } }
    var baseColor = NSColor.secondaryLabelColor { didSet { if baseColor != oldValue { applyText() } } }
    var brightColor = NSColor.labelColor { didSet { if brightColor != oldValue { applyText() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()   // layer-hosting: the layers below are this view's own
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for line in [base, bright] {
            line.isWrapped = false
            line.truncationMode = .end
            line.alignmentMode = .left
            layer?.addSublayer(line)
        }
        band.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        bright.mask = band
        applyText()
    }

    required init?(coder: NSCoder) { nil }

    /// The brighter text under the moving band, for `--snapshot --live`.
    var bandLayer: CALayer { bright }

    /// One line, as tall as SwiftUI lays out a Text in the same font.
    var lineHeight: CGFloat { ceil(font.ascender) + ceil(-font.descender) }
    var idealWidth: CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the row

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // SwiftUI puts the baseline a whole point below the top; so does this.
        let drop = ceil(font.ascender) - font.ascender
        for line in [base, bright] { line.frame = bounds.offsetBy(dx: 0, dy: -drop) }
        band.bounds = CGRect(x: 0, y: 0, width: Self.bandWidth, height: bounds.height + drop)
        band.position = CGPoint(x: -Self.bandWidth, y: (bounds.height + drop) / 2)   // parked off the left
        CATransaction.commit()
        if abs(bounds.width - sweptWidth) > 0.5 { restart() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        restart()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? 2
        base.contentsScale = scale
        bright.contentsScale = scale
    }

    private func applyText() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (line, color) in [(base, baseColor), (bright, brightColor)] {
            line.font = font
            line.fontSize = font.pointSize
            line.foregroundColor = color.cgColor
            line.string = text
        }
        CATransaction.commit()
    }

    private var wantsMotion: Bool {
        window != nil && bounds.width >= 1 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Reduce Motion may have been turned on or off.
    func refreshMotion() {
        if wantsMotion != (band.animation(forKey: "sweep") != nil) { restart() }
    }

    private func restart() {
        sweptWidth = bounds.width
        band.removeAnimation(forKey: "sweep")
        bright.isHidden = !wantsMotion
        guard wantsMotion else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -Self.bandWidth / 2
        sweep.toValue = bounds.width + Self.bandWidth / 2
        sweep.duration = max(1.2, (bounds.width + Self.bandWidth) / 150)
        let loop = CAAnimationGroup()
        loop.animations = [sweep]
        loop.duration = sweep.duration + 0.4   // a short rest between sweeps
        loop.repeatCount = .infinity
        loop.isRemovedOnCompletion = false
        loop.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
        band.add(loop, forKey: "sweep")
    }
}

struct ShimmerText: NSViewRepresentable {
    let text: String
    var size: CGFloat = 11
    let base: Color
    let bright: Color

    func makeNSView(context: Context) -> ShimmerLabel { ShimmerLabel(frame: .zero) }

    func updateNSView(_ view: ShimmerLabel, context: Context) {
        view.font = .systemFont(ofSize: size)
        view.text = text
        view.baseColor = NSColor(base)
        view.brightColor = NSColor(bright)
        view.refreshMotion()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerLabel, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? nsView.idealWidth
        return CGSize(width: width, height: nsView.lineHeight)
    }
}

/// Increase Contrast as the window and panel draw it. Read from the system,
/// or forced on for snapshots.
private struct HighContrastKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var highContrast: Bool {
        get { self[HighContrastKey.self] }
        set { self[HighContrastKey.self] = newValue }
    }
}

/// The state colours and text greys, chosen to pass contrast on the window's
/// dark and light backgrounds, and stronger with Increase Contrast.
struct Palette {
    let dark: Bool
    let contrast: Bool

    init(_ scheme: ColorScheme, contrast: Bool) {
        dark = scheme == .dark
        self.contrast = contrast
    }

    private func pick(_ d: (Double, Double, Double), _ l: (Double, Double, Double)) -> Color {
        let c = dark ? d : l
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    var needsYou: Color { pick((1.0, 0.62, 0.04), (0.76, 0.37, 0.0)) }       // #FF9F0A, #C25E00
    var needsYouMark: Color { dark ? Color(white: 0.11) : .white }           // the "!" inside it
    var review: Color { pick((0.39, 0.66, 1.0), (0.04, 0.39, 0.84)) }        // #64A8FF, #0A64D6
    var quiet: Color { pick((0.96, 0.66, 0.10), (0.70, 0.42, 0.0)) }         // #F5A81A, #B26B00
    var done: Color { pick((0.20, 0.78, 0.35), (0.12, 0.56, 0.24)) }         // #34C759, #1E8E3E
    /// Running: blue, so it never reads as the green of finished.
    var running: Color { pick((0.25, 0.61, 1.0), (0.0, 0.48, 1.0)) }         // #409CFF, #007AFF
    /// A running row's status line: a little dimmer than other second lines,
    /// so the band sweeping across it (`shimmer`) shows.
    var shimmerBase: Color { contrast ? text2 : (dark ? Color(white: 0.62) : Color(white: 0.42)) }
    var shimmer: Color { dark ? .white : .black }
    /// Second lines.
    var text2: Color { dark ? Color(white: contrast ? 0.92 : 0.78) : Color(white: contrast ? 0.12 : 0.30) }
    /// Times and counts.
    var time: Color { dark ? Color(white: contrast ? 0.88 : 0.64) : Color(white: contrast ? 0.16 : 0.37) }
}

/// "No output for 12 min" (the panel), or "No output for 12m" (the window).
func quietPhrase(_ gap: TimeInterval, compact: Bool = false) -> String {
    let since = Date(timeIntervalSinceNow: -gap)
    return "No output for " + (compact ? compactAge(since: since, now: Date())
                                       : elapsed(since: since, now: Date()) ?? "a while")
}

/// "now", "6m", "18h", "3d": the window's one short style, matching its "4m 12s" clocks.
func compactAge(since d: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

/// A row's right-click menu: Snooze, your tags, New Tag… and Remove Tags.
struct TagActions {
    var enabled = false
    var known: [String] = []
    var toggle: (Row, String) -> Void = { _, _ in }
    var newTag: (Row) -> Void = { _ in }
    var clear: (Row) -> Void = { _ in }
    var snooze: (Row, Date) -> Void = { _, _ in }
    var wake: (Row) -> Void = { _ in }
    var hide: (Row) -> Void = { _ in }
    var unhide: (Row) -> Void = { _ in }
}

private struct TagActionsKey: EnvironmentKey { static let defaultValue = TagActions() }
extension EnvironmentValues {
    var tagActions: TagActions {
        get { self[TagActionsKey.self] }
        set { self[TagActionsKey.self] = newValue }
    }
}

extension View {
    /// Right-click to snooze, hide or tag the session (tags and snoozes
    /// are for Claude app sessions only; any app's can be hidden).
    func tagMenu(_ row: Row) -> some View { modifier(TagMenu(row: row)) }
}

struct TagMenu: ViewModifier {
    let row: Row
    @Environment(\.tagActions) private var actions

    func body(content: Content) -> some View {
        let taggable = SessionTags.taggable(row)
        let hideable = SessionHides.hideable(row)
        if actions.enabled && (taggable || hideable || row.hidden) {
            content.contextMenu {
                if let until = row.snoozedUntil, row.snoozed {
                    Section("Snoozed " + snoozeWhen(until, now: Date())) {
                        Button("Wake Now") { actions.wake(row) }
                    }
                } else if SessionSnoozes.snoozable(row) {
                    Menu {
                        ForEach(SnoozeChoice.allCases) { choice in
                            Button(choice.title) { actions.snooze(row, choice.until(from: Date())) }
                        }
                    } label: {
                        Label("Snooze", systemImage: "moon.zzz")
                    }
                }
                if row.hidden {
                    Button("Show Again") { actions.unhide(row) }
                } else if hideable {
                    Button("Hide Until Next Update") { actions.hide(row) }
                }
                if taggable {
                    Divider()
                    Section("Tags") {
                        ForEach(actions.known, id: \.self) { tag in
                            Toggle(tag, isOn: Binding(get: { row.tags.contains(tag) },
                                                      set: { _ in actions.toggle(row, tag) }))
                        }
                    }
                    Divider()
                    Button("New Tag…") { actions.newTag(row) }
                    if !row.tags.isEmpty { Button("Remove Tags") { actions.clear(row) } }
                }
            }
        } else {
            content
        }
    }
}

/// How tags are drawn: chosen from the keep-on-top window's header menu.
enum TagStyle: String, CaseIterable, Identifiable {
    case outline, filled, dot, text
    static let key = "tagStyle"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .outline: return "Outline"
        case .filled: return "Filled"
        case .dot: return "Dot and label"
        case .text: return "Coloured text"
        }
    }
}

/// A tag as a small label beside a session's title.
struct TagPill: View {
    let tag: String
    @Environment(\.highContrast) private var contrast
    @AppStorage(TagStyle.key) private var style = TagStyle.outline.rawValue

    var body: some View {
        let color = Self.color(tag)
        let label = Text(tag).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
        switch TagStyle(rawValue: style) ?? .outline {
        case .outline:
            label.foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 0.5)
                .overlay(Capsule().strokeBorder(color.opacity(contrast ? 0.95 : 0.6), lineWidth: 1))
                .fixedSize()
        case .filled:
            label.foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(contrast ? 0.26 : 0.16)))
                .fixedSize()
        case .dot:
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                label.foregroundStyle(contrast ? Color.primary : Color.secondary)
            }
            .fixedSize()
        case .text:
            label.foregroundStyle(color).fixedSize()
        }
    }

    /// Grey for On hold, purple for Awaiting manual review, and one of a few
    /// colours kept clear of the states' amber, blue and green for your own.
    static func color(_ tag: String) -> Color {
        if tag == SessionTags.onHold { return .secondary }
        if tag == SessionTags.awaitingReview { return Color(nsColor: .systemPurple) }
        let palette: [NSColor] = [.systemTeal, .systemPink, .systemIndigo, .systemBrown, .systemPurple]
        let index = tag.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % palette.count
        return Color(nsColor: palette[index])
    }
}

/// When a snooze ends, then up to two tags, then "+1" for the rest.
struct TagPills: View {
    let tags: [String]
    var snoozedUntil: Date? = nil
    @AppStorage(TagStyle.key) private var style = TagStyle.outline.rawValue

    var body: some View {
        if !tags.isEmpty || snoozedUntil != nil {
            HStack(spacing: style == TagStyle.dot.rawValue ? 9 : 4) {
                if let snoozedUntil { SnoozePill(until: snoozedUntil) }
                ForEach(tags.prefix(2), id: \.self) { TagPill(tag: $0) }
                if tags.count > 2 {
                    Text("+\(tags.count - 2)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([snoozedUntil.map { "Snoozed " + snoozeWhen($0, now: Date()) }].compactMap { $0 }
                                 + (tags.isEmpty ? [] : ["Tags: " + tags.joined(separator: ", ")])).joined(separator: ", "))
        }
    }
}

/// "Snoozed until 3:40 PM", grey, in the style you chose for tags.
struct SnoozePill: View {
    let until: Date
    @Environment(\.highContrast) private var contrast
    @AppStorage(TagStyle.key) private var style = TagStyle.outline.rawValue

    var body: some View {
        let label = HStack(spacing: 3) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 8, weight: .semibold))
            Text(snoozeWhen(until, now: Date()).capitalizedFirst).font(.system(size: 9.5, weight: .semibold))
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
        switch TagStyle(rawValue: style) ?? .outline {
        case .outline:
            label.padding(.horizontal, 6).padding(.vertical, 0.5)
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(contrast ? 0.95 : 0.6), lineWidth: 1))
                .fixedSize()
        case .filled:
            label.padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(contrast ? 0.26 : 0.16)))
                .fixedSize()
        case .dot, .text:
            label.fixedSize()
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Limbo's mark, the Orbit logo without its square: sessions in the three
/// state colours (running, needs you, finished) around a centre dot, on a
/// faint orbit. The keep-on-top window's header and pill show it.
struct LimboMark: View {
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme
    @Environment(\.highContrast) private var contrast

    var body: some View {
        let p = Palette(scheme, contrast: contrast)
        let r = size * 0.37                 // the orbit's radius
        let d = size * 0.27                 // a session dot
        let corner = r * 0.7071             // 135° and 225°: bottom left, top left
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(contrast ? 0.5 : 0.25), lineWidth: max(1, size * 0.085))
                .frame(width: r * 2, height: r * 2)
            Circle().fill(p.running).frame(width: d, height: d).offset(x: r)
            Circle().fill(p.needsYou).frame(width: d, height: d).offset(x: -corner, y: corner)
            Circle().fill(p.done).frame(width: d, height: d).offset(x: -corner, y: -corner)
            Circle().fill(Color.primary).frame(width: size * 0.2, height: size * 0.2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One mark per state, told apart by shape as well as colour: a turning ring
/// (running), an hourglass (running but quiet), an exclamation (needs you),
/// an eye (ready for review), a check (finished), a ring (idle terminal).
struct Indicator: View {
    let group: Group
    var quiet = false
    var held = false
    var snoozed = false
    /// Whose icon leads, with the state on its bottom-right corner: the
    /// agent's for a thread Orca runs, else the app's it's in. Not installed:
    /// `fallback`'s (the app it's in), else the state mark alone.
    var source: RowSource? = nil
    var fallback: RowSource? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.highContrast) private var forcedContrast

    private var palette: Palette { Palette(scheme, contrast: forcedContrast || systemContrast == .increased) }

    var body: some View {
        SwiftUI.Group {
            if let icon = source.flatMap(appIcon) ?? fallback.flatMap(appIcon) {
                badged(icon)
            } else {
                mark
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    /// The state mark alone, 16 points.
    @ViewBuilder private var mark: some View {
        let p = palette
        ZStack {
            switch group {
            case _ where snoozed:
                Image(systemName: "moon.zzz").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            case _ where held:
                Image(systemName: "pause.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            case .yourTurn:
                Image(systemName: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(p.needsYouMark, p.needsYou)
                    .font(.system(size: 11, weight: .semibold))
            case .running where quiet:
                // Still running, but nothing written for 10 minutes: no turning ring.
                Image(systemName: "hourglass").font(.system(size: 10, weight: .bold)).foregroundStyle(p.quiet)
            case .running:
                if staticIndicators {
                    Circle().stroke(p.running.opacity(0.24), lineWidth: 2).frame(width: 11, height: 11)
                    Circle().trim(from: 0, to: 0.3)
                        .stroke(p.running, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 11, height: 11)
                        .rotationEffect(.degrees(-90))
                } else {
                    RunningSpinner(color: p.running).frame(width: 16, height: 16)
                }
            case .justFinished, .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(p.done)
            case .review:
                Image(systemName: "eye").font(.system(size: 9, weight: .bold)).foregroundStyle(p.review)
            case .terminal:
                Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
    }

    /// Where the state sits on the icon: a 12-point circle centred 13.5
    /// points in, cut out of the icon so it reads on any background, and
    /// reaching 3.5 points past the icon's corner.
    private static let badgeCut: CGFloat = 12
    private static let badgeCentre: CGFloat = 13.5

    /// The app's icon, faded when on hold or snoozed, with the state on its corner.
    private func badged(_ icon: NSImage) -> some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
            .opacity(held || snoozed ? 0.45 : 1)
            .mask {
                ZStack {
                    Rectangle()
                    Circle()
                        .frame(width: Self.badgeCut, height: Self.badgeCut)
                        .position(x: Self.badgeCentre, y: Self.badgeCentre)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .overlay(alignment: .topLeading) {
                badge
                    .frame(width: Self.badgeCut, height: Self.badgeCut)
                    .offset(x: Self.badgeCentre - Self.badgeCut / 2, y: Self.badgeCentre - Self.badgeCut / 2)
            }
    }

    /// The state, small enough for the icon's corner: the turning blue ring
    /// while running, a filled circle with its sign once it needs you or ends.
    @ViewBuilder private var badge: some View {
        let p = palette
        let grey = Color(white: scheme == .dark ? 0.52 : 0.56)
        switch group {
        case _ where snoozed:
            ZStack {
                Circle().fill(grey)
                Image(systemName: "moon.fill").font(.system(size: 5, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 9, height: 9)
        case _ where held:
            Image(systemName: "pause.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, grey)
                .font(.system(size: 9.5, weight: .bold))
        case .yourTurn:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(p.needsYouMark, p.needsYou)
                .font(.system(size: 9.5, weight: .bold))
        case .running where quiet:
            // Still running, but nothing written for 10 minutes: a still amber ring.
            Circle().strokeBorder(p.quiet, lineWidth: 1.6).frame(width: 9, height: 9)
        case .running:
            if staticIndicators {
                ZStack {
                    Circle().stroke(p.running.opacity(0.24), lineWidth: 1.6)
                    Circle().trim(from: 0, to: 0.3)
                        .stroke(p.running, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 7.6, height: 7.6)
            } else {
                RunningSpinner(color: p.running, size: Self.badgeCut, ring: 7.6, lineWidth: 1.6)
                    .frame(width: Self.badgeCut, height: Self.badgeCut)
            }
        case .justFinished, .done:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, p.done)
                .font(.system(size: 9.5, weight: .bold))
        case .review:
            ZStack {
                Circle().fill(p.review)
                Circle().fill(.white).frame(width: 3, height: 3)
            }
            .frame(width: 9, height: 9)
        case .terminal:
            Circle().strokeBorder(grey, lineWidth: 1.3).frame(width: 8, height: 8)
        }
    }
}

struct SessionRow: View {
    let row: Row
    let now: Date
    let open: (Row) -> Void
    var dimmed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: Bool { systemContrast == .increased }
    @State private var hovering = false

    private var canOpen: Bool { row.link != nil }

    private var quiet: TimeInterval? { row.quiet(now: now) }

    private var secondLine: String? {
        switch row.group {
        case .yourTurn: return row.ask
        case .review, .done: return row.detail
        case .running:
            guard let quiet else { return row.activity }
            return [quietPhrase(quiet), row.activity].compactMap { $0 }.joined(separator: " · ")
        case .justFinished, .terminal: return nil
        }
    }

    private var meta: String {
        switch row.group {
        case .running:
            return "\(row.context) · " + (elapsed(since: row.since, now: now).map { "working for \($0)" } ?? "just started")
        case .justFinished:
            return "\(row.context) · finished \(ago(row.since, now)) · summary pending"
        case .terminal:
            return "\(row.context) · idle for " + (elapsed(since: row.since, now: now) ?? "under a minute")
        case .yourTurn, .review, .done:
            return "\(row.context) · \(ago(row.since, now))"
        }
    }

    private var stateWord: String {
        switch row.group {
        case .yourTurn: return "waiting for you"
        case .running: return "running"
        case .justFinished: return "just finished"
        case .review: return "ready for review"
        case .done: return "done"
        case .terminal: return "idle in a terminal"
        }
    }

    private var tooltip: String {
        var parts = [row.title]
        if let line = secondLine { parts.append(line) }
        parts.append(canOpen ? "Click to " + row.openLabel.prefix(1).lowercased() + row.openLabel.dropFirst() : "Started in a terminal, so it can't be opened from here")
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        Button { if canOpen { open(row) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Indicator(group: row.group, quiet: quiet != nil, held: row.held, snoozed: row.snoozed,
                          source: row.iconSource, fallback: row.source)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(.system(size: 13, weight: row.group == .done ? .regular : .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        trailing
                    }
                    TagPills(tags: row.tags, snoozedUntil: row.snoozedUntil)
                    if let line = secondLine {
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(row.group == .yourTurn ? AnyShapeStyle(.primary)
                                             : quiet != nil ? AnyShapeStyle(Palette(scheme, contrast: contrast).quiet)
                                             : AnyShapeStyle(.secondary))
                            .lineLimit(row.group == .running ? 2 : nil)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if row.group != .done {
                        Text(meta)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering && canOpen ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .linkPointer(canOpen)
        .onHover { hovering = $0 }
        .opacity(dimmed || row.held ? 0.72 : 1)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title)\(row.spokenApp), \(row.snoozed ? "snoozed" : row.held ? "on hold" : stateWord)"
                            + (row.tags.isEmpty ? "" : ", tagged " + row.tags.joined(separator: ", ")))
        .tagMenu(row)
        .accessibilityValue(secondLine ?? meta)
        .accessibilityHint(canOpen ? row.openLabel : "")
    }

    @ViewBuilder private var trailing: some View {
        if row.group == .done {
            Text(elapsed(since: row.since, now: now) ?? "now")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        if row.terminal && row.group == .running {
            Text("Terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        if canOpen {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
        }
    }
}

struct SectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A section title that expands and collapses its rows.
struct DisclosureTitle: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer()
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isHeader)
    }
}

/// "3 older" inside the Your turn group.
struct OlderToggle: View {
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(spacing: 4) {
                Text(expanded ? "Hide \(count) older than 3 days" : "\(count) older than 3 days")
                    .font(.system(size: 11))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 34)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer()
    }
}

struct CaughtUpRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .frame(width: 16, height: 16)
            Text("Nothing needs you right now").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct EmptyBoard: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("No Claude sessions this week").font(.system(size: 13, weight: .medium))
            Text("Sessions show up here as soon as you start one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

struct PanelView: View {
    @ObservedObject var model: SessionModel
    let open: (Row) -> Void
    var expandAll = false
    var pin: (() -> Void)? = nil
    @AppStorage("showDone") private var showDone = false
    @AppStorage("showTerminal") private var showTerminal = false
    @AppStorage("showOlder") private var showOlder = false
    @AppStorage("showHeld") private var showHeld = false
    @AppStorage("showHidden") private var showHidden = false
    @AppStorage("showSnoozed") private var showSnoozed = false
    @State private var loginOn = LoginItem.isEnabled

    var body: some View {
        let board = Board(rows: model.rows, now: model.now)
        VStack(spacing: 0) {
            header(board)
            ScrollView(.vertical) {
                sections(board, now: model.now)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
            }
            .frame(maxHeight: 560)
            Divider()
            footer
        }
        .frame(width: 380)
        .environment(\.tagActions, model.tagActions)
    }

    private func header(_ b: Board) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Claude sessions").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(summary(b)).font(.system(size: 11)).foregroundStyle(.secondary)
            if let pin {
                Button(action: pin) {
                    Image(systemName: model.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.pinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.pinned ? "Stop keeping on top" : "Keep on top of other windows, even full-screen videos and games")
                .accessibilityLabel(model.pinned ? "Stop keeping on top" : "Keep on top")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private func summary(_ b: Board) -> String {
        var parts: [String] = []
        if !b.running.isEmpty { parts.append("\(b.running.count) running") }
        if !b.yourTurn.isEmpty { parts.append(b.yourTurn.count == 1 ? "1 needs you" : "\(b.yourTurn.count) need you") }
        return parts.isEmpty ? "All caught up" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func sections(_ b: Board, now: Date) -> some View {
        if b.isEmpty {
            EmptyBoard()
        } else {
            VStack(alignment: .leading, spacing: 1) {
                if !b.running.isEmpty {
                    SectionTitle(title: "Running", count: b.running.count)
                    ForEach(b.running) { SessionRow(row: $0, now: now, open: open) }
                }
                SectionTitle(title: "Your turn", count: b.yourTurn.count)
                if b.yourTurn.isEmpty { CaughtUpRow() }
                ForEach(b.yourTurn) { SessionRow(row: $0, now: now, open: open) }
                if !b.older.isEmpty {
                    OlderToggle(count: b.older.count, expanded: $showOlder)
                    if showOlder || expandAll {
                        ForEach(b.older) { SessionRow(row: $0, now: now, open: open, dimmed: true) }
                    }
                }
                if !b.justFinished.isEmpty {
                    SectionTitle(title: "Just finished", count: b.justFinished.count)
                    ForEach(b.justFinished) { SessionRow(row: $0, now: now, open: open) }
                }
                if !b.review.isEmpty {
                    SectionTitle(title: "Ready for review", count: b.review.count)
                    ForEach(b.review) { SessionRow(row: $0, now: now, open: open) }
                }
                if !b.snoozed.isEmpty {
                    DisclosureTitle(title: "Snoozed", count: b.snoozed.count, expanded: $showSnoozed)
                    if showSnoozed || expandAll {
                        ForEach(b.snoozed) { SessionRow(row: $0, now: now, open: open) }
                    }
                }
                if !b.onHold.isEmpty {
                    DisclosureTitle(title: "On hold", count: b.onHold.count, expanded: $showHeld)
                    if showHeld || expandAll {
                        ForEach(b.onHold) { SessionRow(row: $0, now: now, open: open) }
                    }
                }
                if !b.hidden.isEmpty {
                    DisclosureTitle(title: "Hidden", count: b.hidden.count, expanded: $showHidden)
                    if showHidden || expandAll {
                        ForEach(b.hidden) { SessionRow(row: $0, now: now, open: open) }
                    }
                }
                if !b.done.isEmpty {
                    DisclosureTitle(title: "Done", count: b.done.count, expanded: $showDone)
                    if showDone || expandAll {
                        ForEach(b.done) { SessionRow(row: $0, now: now, open: open) }
                    }
                }
                if !b.terminal.isEmpty {
                    DisclosureTitle(title: "In a terminal", count: b.terminal.count, expanded: $showTerminal)
                    if showTerminal || expandAll {
                        ForEach(b.terminal) { SessionRow(row: $0, now: now, open: open) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Start at login", isOn: Binding(
                get: { loginOn },
                set: { on in
                    try? LoginItem.setEnabled(on)
                    loginOn = LoginItem.isEnabled
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Panel window

final class PanelController: NSObject, NSPopoverDelegate {
    private let model: SessionModel
    private let reuse: Bool
    private let animates: Bool
    private let willOpen: () -> Void
    private let pin: (() -> Void)?
    private var popover: NSPopover?
    /// The app in front when the panel opened (opening it makes Limbo active).
    private(set) var appBeforeOpening: NSRunningApplication?

    private var clock: Timer?

    init(model: SessionModel, reuse: Bool = true, animates: Bool = true, pin: (() -> Void)? = nil,
         willOpen: @escaping () -> Void) {
        self.model = model
        self.reuse = reuse
        self.animates = animates
        self.pin = pin
        self.willOpen = willOpen
    }

    func toggle(from view: NSView, activate: Bool = true) {
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        willOpen()
        let p = popover ?? makePopover()
        popover = p
        let front = NSWorkspace.shared.frontmostApplication
        appBeforeOpening = front?.processIdentifier == getpid() ? appBeforeOpening : front
        if activate { NSApp.activate() }
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    func close() { popover?.performClose(nil) }

    private func makePopover() -> NSPopover {
        let pinAction: (() -> Void)? = pin.map { action in { [weak self] in self?.close(); action() } }
        let host = NSHostingController(rootView: PanelView(
            model: model, open: { [weak self] row in self?.open(row) }, pin: pinAction))
        host.sizingOptions = [.preferredContentSize]
        let p = NSPopover()
        p.behavior = .transient
        p.animates = animates
        p.delegate = self
        p.contentViewController = host
        return p
    }

    func popoverWillShow(_ notification: Notification) {
        model.panelOpen = true
        model.now = Date()
        clock?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.model.now = Date() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func popoverDidClose(_ notification: Notification) {
        model.panelOpen = false
        clock?.invalidate()
        clock = nil
        // One popover is kept and reused: building a new one per open leaked
        // about 8 MB each time (measured with --bench-panel).
        guard !reuse else { return }
        popover?.contentViewController = nil
        popover = nil
    }

    private func open(_ row: Row) {
        guard row.openURL != nil else { return }
        popover?.performClose(nil)
        model.markOpened(row)
        openRow(row)
    }
}

// MARK: - Keep on top

struct CompactRow: View {
    let row: Row
    let now: Date
    let open: (Row) -> Void
    /// The response button, on rows that have a reply to show; the reply opens under the row.
    var responseShown = false
    var toggleResponse: (() -> Void)? = nil
    /// The eye under the pointer; off where Hide is a button of its own (a chip's card).
    var hideButton = true
    @State private var hovering = false
    /// The pointer anywhere on the row, its buttons included.
    @State private var rowHover = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.highContrast) private var contrast
    @Environment(\.tagActions) private var actions

    private var response: String? { toggleResponse == nil ? nil : row.card?.response }

    /// Hide, in the time's place, while the pointer is on a row that can be hidden.
    private var showHide: Bool {
        hideButton && (rowHover || forcedHover == row.id) && actions.enabled && SessionHides.hideable(row)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line
                // Beside the row's own button, not inside it, so a click here never opens the session.
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 0) {
                        if showHide {
                            HideToggle { actions.hide(row) }.testFrame("row-hide:\(row.id)")
                        }
                        if let toggleResponse, response != nil {
                            ResponseToggle(shown: responseShown, action: toggleResponse)
                                .testFrame("response:\(row.id)")
                        }
                    }
                    .padding(.top, 2)
                    .padding(.trailing, 4)
                }
            if responseShown, let response {
                ResponseDrawer(text: response, open: { open(row) })
                    .padding(.leading, 32)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
            }
        }
        .onHover { rowHover = $0 }
        .tagMenu(row)
        .accessibilityAction(named: "Hide Until Next Update") {
            if actions.enabled && SessionHides.hideable(row) { actions.hide(row) }
        }
    }

    private var line: some View {
        let quiet = row.quiet(now: now)
        let p = Palette(scheme, contrast: contrast)
        // A question from the session's next-step box, when it is not shown as a card.
        let question = row.group == .running ? nil : row.card?.ask
        let detail = question ?? (row.group == .yourTurn ? row.ask
            : (row.group == .review ? row.detail : (row.group == .running ? row.activity : nil)))
        // A row with nothing under its title (a finished one) is a single line,
        // its tags beside the title; sessions still going are a little stronger.
        let oneLine = quiet == nil && detail == nil
        let active = !row.held && (row.group == .running || row.group == .yourTurn)
        return Button { if row.link != nil { open(row) } } label: {
            HStack(alignment: .top, spacing: 8) {
                Indicator(group: row.group, quiet: quiet != nil, held: row.held, snoozed: row.snoozed,
                          source: row.iconSource, fallback: row.source)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        let title = Text(row.title)
                            .font(.system(size: active ? 13 : 12.5,
                                          weight: contrast ? .bold : (active ? .semibold : .medium)))
                            .lineLimit(1).truncationMode(.tail)
                            .accessibilityLabel(row.title + row.spokenApp)
                        if oneLine && (!row.tags.isEmpty || row.snoozed) {
                            // Tags beside the title when the whole title still fits, else under it.
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    title.fixedSize(horizontal: true, vertical: false)
                                    TagPills(tags: row.tags, snoozedUntil: row.snoozedUntil)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    title
                                    TagPills(tags: row.tags, snoozedUntil: row.snoozedUntil)
                                }
                            }
                        } else {
                            title
                        }
                        Spacer(minLength: 4)
                        // One short style for every time: "4m 12s" ticking for running rows
                        // (only while this window shows), "6m", "18h", "now" for the rest.
                        if row.group == .running {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(stopwatch(since: row.since, now: context.date))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(p.time)
                            }
                        } else {
                            Text(compactAge(since: row.since, now: now))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(p.time)
                                .opacity(showHide ? 0 : 1)   // Hide sits here under the pointer
                        }
                        if response != nil { Color.clear.frame(width: 18, height: 1) }   // room for the response button
                    }
                    // Rows with a second line: tags on their own line, so a long one never squeezes the title.
                    if !oneLine { TagPills(tags: row.tags, snoozedUntil: row.snoozedUntil).padding(.vertical, 1) }
                    if let quiet {
                        Text([quietPhrase(quiet, compact: true), row.activity].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(p.quiet).lineLimit(1).truncationMode(.tail)
                    } else if let line = detail {
                        if row.group == .running && !staticIndicators {
                            ShimmerText(text: line, base: p.shimmerBase, bright: p.shimmer)
                                .accessibilityLabel(line)
                        } else {
                            // Questions and summaries wrap in full (at most a few lines);
                            // a running line stays on one, so the row doesn't jump as it changes.
                            Text(line).font(.system(size: 11))
                                .foregroundStyle(row.group == .yourTurn || question != nil ? Color.primary
                                                 : row.group == .running ? p.shimmerBase : p.text2)
                                .lineLimit(row.group == .running ? 1 : nil).truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, oneLine ? 4 : 6)
            .opacity(row.held ? 0.72 : 1)
            .contentShape(Rectangle())
            .background(
                // A running session sits on a light blue backing; any row lights up under the pointer.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(row.group == .running && !row.held && !contrast ? p.running.opacity(hovering ? 0.17 : 0.11)
                          : Color.primary.opacity(hovering && row.link != nil ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .linkPointer(row.link != nil)
        .onHover { hovering = $0 }
        .help([row.title, question ?? row.ask ?? row.detail,
               quiet.map { quietPhrase($0) + ": it may be stuck, or in one long command" }]
            .compactMap { $0 }.joined(separator: "\n\n"))
    }
}

/// --gesture-check: where some controls sit, so it can click them. Off in the app.
var recordTestFrames = false
var testFrames: [String: CGRect] = [:]

extension View {
    @ViewBuilder func testFrame(_ name: String) -> some View {
        if recordTestFrames {
            background(GeometryReader { proxy in
                Color.clear
                    .onAppear { testFrames[name] = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in testFrames[name] = frame }
            })
        } else {
            self
        }
    }
}

/// The response button on a row or card: shows the session's latest reply in place.
/// Hide Until Next Update in one click, on a row or card under the pointer.
struct HideToggle: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help("Hide until it next updates")
        .backgroundHint("Hide until it next updates")
        .accessibilityLabel("Hide until it next updates")
    }
}

/// --snapshot … --hover-row <id>: draws that row or card as if the pointer were on it.
var forcedHover: String? = nil
/// --snapshot … --hint: draws the tooltips of the controls under that pointer.
var forcedHints = false

extension View {
    /// A tooltip for a control in the keep-on-top window, drawn here, to its
    /// left: macOS shows no tooltips for an app that isn't in front, which
    /// Limbo never is.
    func backgroundHint(_ text: String) -> some View { modifier(BackgroundHint(text: text)) }

    /// The pointing hand over a link or button, even while another app is
    /// in front (see HandCursor). Off when `on` is false.
    func linkPointer(_ on: Bool = true) -> some View { modifier(LinkPointer(on: on)) }
}

/// The pointing hand over the window's links and buttons. macOS changes the
/// cursor only for the app in front, which Limbo never is, so while the
/// pointer is on one of them the window server's background-cursor setting
/// is on, as on the resize edges. Nested ones (Hide inside a row) are
/// counted, so moving from one to the other never drops the hand.
enum HandCursor {
    private(set) static var regions = 0

    static func enter() {
        regions += 1
        show()
    }

    /// The pointer moved inside: the hand again (a resize edge or SwiftUI may have set another).
    static func moved() { if regions > 0 { show() } }

    static func leave() {
        regions = max(0, regions - 1)
        if regions > 0 {
            show()
        } else {
            NSCursor.arrow.set()
            BackgroundCursor.allow(false)
        }
    }

    private static func show() {
        BackgroundCursor.allow(true)
        NSCursor.pointingHand.set()
    }
}

struct LinkPointer: ViewModifier {
    let on: Bool
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .pointerStyle(on ? .link : nil)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard on else { leave(); return }
                    if inside {
                        HandCursor.moved()
                    } else {
                        inside = true
                        HandCursor.enter()
                    }
                case .ended:
                    leave()
                }
            }
            .onChange(of: on) { _, now in if !now { leave() } }
            .onDisappear { leave() }   // a click that hides or opens it can take it away under the pointer
    }

    private func leave() {
        guard inside else { return }
        inside = false
        HandCursor.leave()
    }
}

struct BackgroundHint: ViewModifier {
    let text: String
    @State private var inside = false
    @State private var tipShown = false
    @State private var tipDelay: Task<Void, Never>?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if tipShown || forcedHints {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(scheme == .dark ? Color(white: 0.2) : Color(white: 0.97)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15)))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .fixedSize()
                        // Hung from a zero-width box at the control's left edge, so it reaches left, into the window.
                        .frame(width: 0, alignment: .trailing)
                        .offset(x: -4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard !inside else { return }
                    inside = true
                    tipDelay = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        if !Task.isCancelled && inside { tipShown = true }
                    }
                case .ended:
                    leave()
                }
            }
            .onDisappear { leave() }
    }

    private func leave() {
        tipDelay?.cancel()
        tipShown = false
        inside = false
    }
}

struct ResponseToggle: View {
    let shown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(shown ? Color.primary : Color.secondary)
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(shown ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help(shown ? "Hide the latest response" : "Show the latest response")
        .accessibilityLabel(shown ? "Hide the latest response" : "Show the latest response")
    }
}

/// A session's latest reply, a dozen lines of it at most, and a way to open the
/// rest in Claude.
struct ResponseDrawer: View {
    let text: String
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.highContrast) private var contrast

    var body: some View {
        let p = Palette(scheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.markdown(text))
                .font(.system(size: 11))
                .foregroundStyle(p.text2)
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Only web links open, even if another kind slipped through.
                .environment(\.openURL, OpenURLAction { url in
                    Self.isWebLink(url) ? .systemAction : .discarded
                })
            Button(action: open) {
                HStack(spacing: 3) {
                    Text("Open in Claude")
                    Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p.review)
            }
            .buttonStyle(.plain)
            .linkPointer()
            .accessibilityLabel("Open the session in Claude")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(contrast ? 0.1 : 0.06)))
    }

    /// Bold, italics, code and web links; the reply's line breaks are kept.
    /// The reply is Claude's text, which can carry what a page or file it read
    /// put there: any link that isn't http or https (file://, an app's own
    /// scheme) becomes plain text, so a click can't open a local file or app.
    static func markdown(_ s: String) -> AttributedString {
        var text = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        for run in text.runs {
            if let link = run.link, !isWebLink(link) { text[run.range].link = nil }
        }
        return text
    }

    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

/// A session waiting on your answer: its question and the buttons from its
/// next-step box. Each button opens the session in Claude, where you answer:
/// Claude has no way to take an answer from another app.
struct AnswerCard: View {
    let row: Row
    let card: TurnCard
    let now: Date
    let open: (Row) -> Void
    var responseShown = false
    var toggleResponse: () -> Void = {}
    /// With "Answer from Cards" on: presses the button in Claude for you.
    var answer: ((String) -> Void)? = nil
    /// The pointer reached the card: gets Claude ready for a press.
    var warm: (() -> Void)? = nil
    /// The button being pressed right now, and why the last click only opened the session.
    var answering: String? = nil
    var note: String? = nil
    /// The eye under the pointer; off where Hide is a button of its own (a chip's card).
    var hideButton = true
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.highContrast) private var contrast
    @Environment(\.tagActions) private var actions

    var body: some View {
        let p = Palette(scheme, contrast: contrast)
        let showHide = hovering || forcedHover == row.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { open(row) } label: {
                    HStack(spacing: 6) {
                        Indicator(group: row.group, source: row.iconSource, fallback: row.source)
                        Text(row.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(compactAge(since: row.since, now: now))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(p.time)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkPointer()
                .help("Open in Claude")
                if hideButton && actions.enabled && SessionHides.hideable(row) {
                    // Its place is kept, so the time doesn't move as the pointer comes and goes.
                    HideToggle { actions.hide(row) }
                        .opacity(showHide ? 1 : 0)
                        .allowsHitTesting(showHide)
                        .accessibilityHidden(!showHide)
                        .testFrame("card-hide:\(row.id)")
                }
                if card.response != nil {
                    ResponseToggle(shown: responseShown, action: toggleResponse).testFrame("response:\(row.id)")
                }
            }
            if !row.tags.isEmpty { TagPills(tags: row.tags, snoozedUntil: row.snoozedUntil).padding(.leading, 22) }
            if responseShown, let response = card.response {
                ResponseDrawer(text: response, open: { open(row) })
            }
            if let ask = card.ask {
                Text(ask)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WrapRow { buttons }
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.time)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(contrast ? 0.1 : 0.06)))
        .overlay {
            if contrast {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.5))
            }
        }
        .onHover { inside in
            hovering = inside
            if inside { warm?() }
        }
        .tagMenu(row)
        .accessibilityAction(named: "Hide Until Next Update") {
            if actions.enabled && SessionHides.hideable(row) { actions.hide(row) }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Array(card.buttons.enumerated()), id: \.offset) { index, label in
            let inPlace = answer != nil && label != TurnCard.answerInClaude
            AnswerButton(label: label, primary: index == 0, answersHere: inPlace, busy: answering == label) {
                if inPlace, let answer { answer(label) } else { open(row) }
            }
            .disabled(answering != nil)
            .testFrame("answer:\(row.id):\(index)")
        }
    }
}

/// Buttons side by side, moving to a new line when the next one doesn't fit.
/// Each is measured once.
struct WrapRow: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = rows(subviews, width: proposal.width ?? .infinity)
        let width = lines.map { line in line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, line.count - 1)) }.max() ?? 0
        let height = lines.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += (line.map(\.size.height).max() ?? 0) + spacing
        }
    }
}

/// One of a card's buttons, drawn like the next-step box's, the first one solid.
/// The arrow says it goes to Claude.
struct AnswerButton: View {
    let label: String
    let primary: Bool
    /// Presses this button in Claude for you; otherwise it opens the session (the arrow).
    var answersHere = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label).lineLimit(1)
                if busy {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 9, height: 9)
                } else if !answersHere {
                    Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold)).opacity(0.7)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(primary ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(primary ? Color.primary : Color.primary.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .linkPointer()
        .fixedSize()
        .help(answersHere ? "Answers “\(label)” in Claude" : "Opens the session in Claude, where you answer")
        .accessibilityLabel(answersHere ? "\(label). Answers in Claude" : "\(label). Opens the session in Claude")
    }
}

/// How far back the keep-on-top window looks for sessions waiting for you.
enum WaitingWindow: Int, CaseIterable, Identifiable {
    case hour = 1, fourHours = 4, day = 24, threeDays = 72, week = 168
    var id: Int { rawValue }
    var hours: Double { Double(rawValue) }
    var menuTitle: String {
        switch self {
        case .hour: return "Last hour"
        case .fourHours: return "Last 4 hours"
        case .day: return "Last 24 hours"
        case .threeDays: return "Last 3 days"
        case .week: return "Last 7 days"
        }
    }
    var short: String {
        switch self {
        case .hour: return "1 hr"
        case .fourHours: return "4 hr"
        case .day: return "24 hr"
        case .threeDays: return "3 days"
        case .week: return "7 days"
        }
    }
}

/// What the header's count chips narrow the list to.
enum RowFilter: String, CaseIterable {
    case running, needsYou, review
}

/// What the keep-on-top window lists, in order, and what its header counts.
struct FloatingRows {
    let running: [Row]
    let waiting: [Row]
    let review: [Row]
    let finished: [Row]
    /// Sessions you put on hold, within the header's time choice; listed last.
    let onHold: [Row]
    /// Sessions you snoozed, until they wake: never listed, only a moon and
    /// a count in the header (and the strip, bar and dots), whose menu wakes them.
    let snoozed: [Row]
    /// Waiting or review sessions older than the header's time choice.
    let hidden: Int

    /// `woke`: when snoozes ran out; a finished session counts from then.
    init(board: Board, now: Date, within limit: TimeInterval, finishedWithin: TimeInterval, woke: [String: Date] = [:]) {
        let allWaiting = board.yourTurn + board.older
        running = board.running
        waiting = allWaiting.filter { now.timeIntervalSince($0.since) <= limit }
        review = board.review.filter { now.timeIntervalSince($0.since) <= limit }
        finished = board.justFinished + board.done.filter {
            now.timeIntervalSince(max($0.since, woke[$0.id] ?? .distantPast)) <= finishedWithin
        }
        onHold = board.onHold.filter { now.timeIntervalSince($0.since) <= limit }
        snoozed = board.snoozed.sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
        hidden = (allWaiting + board.review).filter { now.timeIntervalSince($0.since) > limit }.count
    }

    var all: [Row] { running + waiting + review + finished + onHold }

    func rows(_ filter: RowFilter?) -> [Row] {
        switch filter {
        case .running?: return running
        case .needsYou?: return waiting
        case .review?: return review
        case nil: return all
        }
    }

    func count(_ filter: RowFilter) -> Int { rows(filter).count }

    /// A filter whose rows have all gone shows everything again.
    func effective(_ filter: RowFilter?) -> RowFilter? {
        filter.flatMap { count($0) > 0 ? $0 : nil }
    }
}

/// What the glow shows, for the window's header and pill: Got it appears
/// while it is amber or green.
final class GlowStatus: ObservableObject {
    @Published var mode: GlowMode = .off
    @Published var previewing = false
}

/// The keep-on-top window's frame at a new size: the top stays put, and so
/// does whichever side is nearer its screen's edge, so collapsing to the pill
/// keeps it in its corner.
func anchoredFrame(_ old: NSRect, size: NSSize, screen: NSRect) -> NSRect {
    let x = old.midX > screen.midX ? old.maxX - size.width : old.minX
    return NSRect(x: x, y: old.maxY - size.height, width: size.width, height: size.height)
}

/// The small window that stays on top: running sessions, the ones waiting for
/// you or ready for review, and recently finished ones, one line each. The
/// header's counts filter the list; double-click the header for the pill.
struct FloatingView: View {
    @ObservedObject var model: SessionModel
    let open: (Row) -> Void
    let unpin: () -> Void
    var refit: () -> Void = {}
    var glowChanged: (GlowPreview) -> Void = { _ in }
    /// The Got it button: stops the green or amber without opening anything.
    var acknowledge: () -> Void = {}
    /// A layout picked, or the full-screen switch flipped: the window checks
    /// its display and fits the new shape.
    var layoutChanged: () -> Void = {}
    /// Drawn between the window's material and the rows, so text stays crisp.
    var glow: RunningGlowView?
    @ObservedObject var layout = FloatingLayout()
    @ObservedObject var status = GlowStatus()
    /// Snapshots: draw as with Increase Contrast or Reduce Transparency on,
    /// or with a filter chosen.
    var forceContrast: Bool? = nil
    var forceSolid: Bool? = nil
    var initialFilter: RowFilter? = nil
    var initialResponse: String? = nil
    /// Snapshots: the session whose hover card shows in the strip, dots or bar.
    var initialHover: String? = nil
    /// Answering from a card: presses its button in Claude (when the switch is on).
    var answer: ((Row, String) -> Void)? = nil
    var warm: (() -> Void)? = nil
    @ObservedObject var answers = AnswerStatus()
    @State private var filter: RowFilter?
    /// The row or card whose latest reply is showing; one at a time.
    @State private var openResponse: String?
    /// The strip's, the dots' or the bar's session under the pointer: its card shows.
    @State private var hovered: String?
    /// Where each chip, mark or bar item sits in its row, and the row's width,
    /// to hang the hover card under (or over) it.
    @State private var spots: [String: CGRect] = [:]
    @State private var rowWidth: CGFloat = 0
    @AppStorage(KeepOnTopLayout.autoStripKey) private var autoStrip = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("keepOnTopWaitingHours") private var waitingHours = WaitingWindow.day.rawValue
    @AppStorage(GlowStyle.key) private var glowStyle = GlowStyle.calm.rawValue
    @AppStorage(TagStyle.key) private var tagStyle = TagStyle.outline.rawValue
    @AppStorage(GlowColor.key) private var glowColor = GlowColor.red.rawValue
    @AppStorage(GlowSignal.needsYouKey) private var needsYouGlow = true
    @AppStorage(GlowSignal.doneFlashKey) private var doneFlash = true
    @AppStorage(ClaudeAnswerer.enabledKey) private var answerFromCards = false
    static let maxRows = 8
    /// Questions shown as cards; any more stay rows, the question as their second line.
    static let maxCards = 3
    /// Finished sessions stay listed, with a green check, for this long.
    static let doneShownFor: TimeInterval = 2 * 3600

    private var window: WaitingWindow { WaitingWindow(rawValue: waitingHours) ?? .day }
    private var contrast: Bool { forceContrast ?? (systemContrast == .increased) }
    /// A solid background only with Reduce Transparency on.
    private var solid: Bool { forceSolid ?? reduceTransparency }
    private var palette: Palette { Palette(scheme, contrast: contrast) }
    private var showGotIt: Bool { !status.previewing && (status.mode == .done || status.mode == .needsYou) }

    var body: some View {
        let list = FloatingRows(board: Board(rows: model.rows, now: model.now), now: model.now,
                                within: window.hours * 3600, finishedWithin: Self.doneShownFor, woke: model.wokeAt)
        SwiftUI.Group {
            switch layout.current {
            case .list: full(list)
            case .pill: pill(list)
            case .strip: strip(list)
            case .dots: dots(list)
            case .bar: bar(list)
            case .columns: columns(list)
            }
        }
        .fontDesign(.rounded)
        .environment(\.highContrast, contrast)
        .environment(\.tagActions, model.tagActions)
        .onAppear {
            if let initialFilter { filter = initialFilter }
            if let initialResponse { openResponse = initialResponse }
            if let initialHover { hovered = initialHover }
        }
        .onChange(of: waitingHours) { refit() }
        .onChange(of: layout.width) { refit() }
        .onChange(of: layout.height) { refit() }
        .onChange(of: layout.current) { hovered = nil; refit() }
        .onChange(of: layout.chosen) { layoutChanged() }
        .onChange(of: autoStrip) { refit(); layoutChanged() }
        .onChange(of: layout.barWidth) { refit() }
        .onChange(of: layout.columnsWidth) { refit() }
        .onChange(of: hovered) { refit() }
        .onChange(of: filter) { refit() }
        .onChange(of: showGotIt) { refit() }
        .onChange(of: openResponse) { refit() }
        .onChange(of: answers.notes) { refit() }
        .onChange(of: answerFromCards) { _, on in if on { ClaudeAnswerer.requestPermission() } }
        .onChange(of: glowStyle) { glowChanged(.running) }
        .onChange(of: glowColor) { glowChanged(.running) }
        .onChange(of: needsYouGlow) { glowChanged(needsYouGlow ? .needsYou : .none) }
        .onChange(of: doneFlash) { glowChanged(doneFlash ? .done : .none) }
    }

    // MARK: The window

    private func full(_ list: FloatingRows) -> some View {
        let active = list.effective(filter)
        let rows = list.rows(active)
        // Sessions whose latest turn asked you something: cards on top, newest first.
        let carded = Array(rows.filter { $0.group != .running && !$0.held && $0.card?.ask != nil }
            .sorted { $0.since > $1.since }.prefix(Self.maxCards))
        let cardIds = Set(carded.map(\.id))
        let listRows = rows.filter { !cardIds.contains($0.id) }
        // With a height you set, every row shows and the list scrolls.
        let fixedHeight = layout.height != nil
        let shown = fixedHeight ? listRows : Array(listRows.prefix(Self.maxRows))
        return VStack(alignment: .leading, spacing: 0) {
            header(list, filter: active)
            if rows.isEmpty {
                Text(list.hidden > 0 ? "Nothing running or waiting in the \(window.menuTitle.lowercased())"
                                     : "Nothing running and nothing needs you")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.text2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if fixedHeight {
                ScrollView { content(carded, shown) }
                    .background { if carded.isEmpty { scrim } }
            } else {
                content(carded, shown)
                    .background { if carded.isEmpty { scrim } }
            }
            if active != nil {
                HStack(spacing: 6) {
                    Text("Showing \(rows.count) of \(list.all.count)")
                        .foregroundStyle(palette.time)
                    Button("Show all") { filter = nil }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.review)
                        .linkPointer()
                }
                .font(.system(size: 11))
                .padding(.leading, 36)
                .padding(.bottom, 8)
            } else if listRows.count > shown.count {
                Text("\(listRows.count - shown.count) more in the menu bar panel")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.time)
                    .padding(.leading, 36)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .background { if let glow { GlowBackdrop(view: glow) } }
        .background { surface(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)) }
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            .strokeBorder(Color.primary.opacity(contrast ? 0.7 : 0.1)))
    }

    /// The window's corners, and the glow's.
    static let corner: CGFloat = 16

    /// The cards ("Waiting on you"), then the other sessions under small
    /// headings: Running, Needs you, Ready for review, Finished, On hold.
    /// Snoozed sessions aren't listed: the header's moon counts them.
    private func content(_ carded: [Row], _ rows: [Row]) -> some View {
        let sections: [(title: String, rows: [Row])] = [
            ("Running", rows.filter { $0.group == .running && !$0.held }),
            ("Needs you", rows.filter { $0.group == .yourTurn && !$0.held }),
            ("Ready for review", rows.filter { $0.group == .review && !$0.held }),
            ("Finished", rows.filter { ($0.group == .justFinished || $0.group == .done) && !$0.held }),
            ("On hold", rows.filter { $0.held && !$0.snoozed }),
        ].filter { !$0.rows.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            if !carded.isEmpty {
                sectionHeader("Waiting on you", count: carded.count)
                ForEach(carded) { row in
                    if let card = row.card {
                        AnswerCard(row: row, card: card, now: model.now, open: open,
                                   responseShown: openResponse == row.id,
                                   toggleResponse: { toggleResponse(row.id) },
                                   answer: answerFromCards && answer != nil ? { label in answer?(row, label) } : nil,
                                   warm: answerFromCards ? warm : nil,
                                   answering: answers.answering?.row == row.id ? answers.answering?.label : nil,
                                   note: answers.notes[row.id])
                    }
                }
            }
            // With cards, the band sits behind the rows only: the cards have their own fill.
            ForEach(sections, id: \.title) { section in
                sectionHeader(section.title, count: section.rows.count)
                rowStack(section.rows).background { if !carded.isEmpty { scrim } }
            }
        }
        .padding(.bottom, 4)
    }

    /// A small capitals heading, its count, and a hairline to the edge.
    private func sectionHeader(_ text: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(palette.time)
                .lineLimit(1)
                .layoutPriority(1)   // the hairline gives way first
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.time)
            Rectangle()
                .fill(Color.primary.opacity(contrast ? 0.35 : 0.09))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text), \(count)")
        .accessibilityAddTraits(.isHeader)
    }

    private func toggleResponse(_ id: String) {
        openResponse = openResponse == id ? nil : id
    }

    private func rowStack(_ rows: [Row]) -> some View {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                CompactRow(row: row, now: model.now, open: open, responseShown: openResponse == row.id,
                           toggleResponse: row.group == .running ? nil : { toggleResponse(row.id) })
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    /// A soft band behind the text while a running glow moves under it. Outside
    /// the scroll view, so its blurred edge is never cut off.
    @ViewBuilder private var scrim: some View {
        if status.mode == .running && !contrast && glowStyle != GlowStyle.calm.rawValue {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(scheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.4))
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .blur(radius: 18)
        }
    }

    /// The window's background: the system's glass, like other macOS windows
    /// and alerts (the blurred material before macOS 26), or a solid one with
    /// Reduce Transparency on. In Dark Mode the glass is darkened, as Control
    /// Center's panels are, so a bright page behind it never makes it pale.
    @ViewBuilder private func surface<S: Shape>(_ shape: S) -> some View {
        if solid {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
                .overlay(shape.fill(Color.black.opacity(Self.glassShade(scheme))))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    /// How much black sits on the glass: most of it in Dark Mode, none in Light.
    static func glassShade(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.8 : 0 }

    /// The window's top line. The columns leave out the counts (each column
    /// has its own), and a double-click there goes back to the list.
    private func header(_ list: FloatingRows, filter active: RowFilter?, counts: Bool = true,
                        doubleClick: KeepOnTopLayout = .pill) -> some View {
        HStack(spacing: 6) {
            LimboMark(size: 16)
            // Full chips when they fit, then compact ones (mark and number),
            // then a check for Got it, then only the chosen filter's chip: the
            // header never grows past the window. Snoozed sessions aren't
            // listed: a moon counts them (its menu wakes them), and gives way
            // to the counts when there isn't room for both.
            // (In a stack of its own: a priority set inside an `if` is lost.)
            HStack(spacing: 0) {
                if counts {
                    ViewThatFits(in: .horizontal) {
                        headerCounts(list, filter: active, fit: .full, moon: true)
                        headerCounts(list, filter: active, fit: .compact, moon: true)
                        headerCounts(list, filter: active, fit: .compactIcon, moon: true)
                        headerCounts(list, filter: active, fit: .compact, moon: false)
                        headerCounts(list, filter: active, fit: .compactIcon, moon: false)
                        headerCounts(list, filter: active, fit: .minimal, moon: false)
                    }
                } else {
                    headerMoon(list)
                }
            }
            .layoutPriority(1)
            // The empty middle: double-click it for the pill, or drag the window.
            // (On the empty part only, so double-clicking a chip stays a chip click.)
            Color.clear
                .frame(minWidth: 4, maxWidth: .infinity, minHeight: 18, maxHeight: 18)   // never taller
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { layout.choose(doubleClick) }
                .gesture(WindowDragGesture())
                .testFrame("header-middle")
                .help(doubleClick == .pill ? "Double-click to shrink to a pill" : "Double-click for the list")
            HStack(spacing: 2) {   // close together: the counts need the room more
                layoutMenu
                glowMenu
            }
            Menu {
                Picker("Show sessions waiting for you from", selection: $waitingHours) {
                    ForEach(WaitingWindow.allCases) { Text($0.menuTitle).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 2) {
                    Text(window.short).font(.system(size: 10, weight: .medium).monospacedDigit())
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(contrast ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast ? 0.6 : 0)))
            }
            .menuStyle(.button)
            .linkPointer()
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How far back to show sessions waiting for you. Running sessions always show.")
            .accessibilityLabel("Show sessions waiting for you from the \(window.menuTitle.lowercased())")
            Button(action: unpin) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(contrast ? Color.primary : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop keeping on top")
            .linkPointer()
            .accessibilityLabel("Stop keeping on top")
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())   // drag the window by its header
        .contextMenu {
            Button("Shrink to Pill") { layout.choose(.pill) }
            Divider()
            Button("Fit to Content") { layout.height = nil; layout.save() }
                .disabled(layout.height == nil)
            Button("Default Size") { layout.width = FloatingLayout.defaultWidth; layout.height = nil; layout.save() }
                .disabled(layout.height == nil && layout.width == FloatingLayout.defaultWidth)
            Divider()
            Toggle("Answer from Cards (uses Accessibility)", isOn: $answerFromCards)
            Picker("Tag Style", selection: $tagStyle) {
                ForEach(TagStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }
    }

    /// How much of the header's middle fits, widest first.
    enum HeaderFit { case full, compact, compactIcon, minimal }

    /// The counts as chips that filter the list, "All finished" or "All
    /// caught up" when there are none, and Got it while it glows amber or green.
    private func headerCounts(_ list: FloatingRows, filter active: RowFilter?, fit: HeaderFit, moon: Bool) -> some View {
        let all = RowFilter.allCases.filter { list.count($0) > 0 }
        let kinds = fit == .minimal ? all.filter { $0 == active } : all
        let compact = fit != .full
        let iconGotIt = fit == .compactIcon || (fit == .minimal && !kinds.isEmpty)
        let title = all.isEmpty || ((fit == .full || fit == .compact) && status.mode == .done)
        // Everything finished, still green: one green chip that is also Got it.
        let doneChip = showGotIt && status.mode == .done && (fit == .full || fit == .compact)
        return HStack(spacing: 5) {
            if doneChip {
                Button(action: acknowledge) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
                        Text("All finished")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.done)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.done.opacity(0.16)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .linkPointer()
                .help("Got it: stop the green, you've seen that everything finished")
                .accessibilityLabel("All finished. Got it")
            } else if title {
                Text(status.mode == .done ? "All finished" : "All caught up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.mode == .done ? Color.primary : palette.time)
                    .lineLimit(1)
            }
            ForEach(kinds, id: \.self) { kind in
                countChip(kind, list.count(kind), selected: active == kind, compact: compact)
            }
            if showGotIt && !doneChip {
                Button(action: acknowledge) {
                    if iconGotIt {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 20, height: 17)
                            .background(Capsule().fill(Color.primary.opacity(0.16)))
                            .contentShape(Capsule())
                    } else {
                        Text("Got it")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.16)))
                            .contentShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .linkPointer()
                .help(status.mode == .done ? "Got it: stop the green, you've seen that everything finished"
                                           : "Got it: stop the amber glow without opening the session")
                .accessibilityLabel("Got it")
            }
            if moon { headerMoon(list) }
        }
        .fixedSize()
    }

    /// The header's moon: how many sessions are snoozed, none of them listed.
    @ViewBuilder private func headerMoon(_ list: FloatingRows) -> some View {
        snoozedChip(list.snoozed, height: 18)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
    }

    private func chipTitle(_ kind: RowFilter, _ n: Int) -> String {
        switch kind {
        case .running: return "\(n) running"
        case .needsYou: return n == 1 ? "1 needs you" : "\(n) need you"
        case .review: return "\(n) to review"
        }
    }

    private func countChip(_ kind: RowFilter, _ n: Int, selected: Bool, compact: Bool) -> some View {
        let p = palette
        let tint = kind == .running ? p.running : kind == .needsYou ? p.needsYou : p.review
        return Button {
            filter = selected ? nil : kind
        } label: {
            HStack(spacing: 5) {
                if compact {
                    chipMark(kind)
                    Text("\(n)")
                } else {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(chipTitle(kind, n))
                }
                if selected { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(selected ? tint : Color.primary)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(selected ? tint.opacity(0.2) : Color.primary.opacity(0.1)))
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.7) : Color.primary.opacity(contrast ? 0.6 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help(selected ? "Show all sessions" : "Show only: \(chipTitle(kind, n))")
        .accessibilityLabel(selected ? "Showing only \(chipTitle(kind, n)); show all" : "Show only \(chipTitle(kind, n))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: The pill

    /// Mini mode: just the counts, with the glow, in a pill. Double-click to expand.
    private func pill(_ list: FloatingRows) -> some View {
        let p = palette
        let running = list.running.count, waiting = list.waiting.count
        return HStack(spacing: 6) {
            if running == 0 && status.mode == .done {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(p.done)
                Text("All finished")
            } else {
                LimboMark(size: 15)
                if running == 0 && waiting == 0 { Text("All caught up").foregroundStyle(p.time) }
                if running > 0 { Text("\(running) running") }
                if running > 0 && waiting > 0 { Text("·").foregroundStyle(p.time) }
                if waiting > 0 {
                    chipMark(.needsYou)
                    Text("\(waiting)")
                }
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 12)
        .frame(height: 32)
        .fixedSize()
        .background { if let glow { GlowBackdrop(view: glow) } }
        .background { surface(Capsule()) }
        .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast ? 0.7 : 0.1)))
        .contentShape(Capsule())
        .onTapGesture(count: 2) { layout.choose(.list) }
        .gesture(WindowDragGesture())
        .help("Double-click to expand")
        .contextMenu {
            Button("Expand") { layout.choose(.list) }
            Divider()
            layoutMenuItems(inline: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-click to expand")
    }

    /// The small mark for a count: a dot, an exclamation or an eye.
    @ViewBuilder private func chipMark(_ kind: RowFilter) -> some View {
        switch kind {
        case .running:
            Circle().fill(palette.running).frame(width: 6, height: 6)
        case .needsYou:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(palette.needsYouMark, palette.needsYou)
                .font(.system(size: 10, weight: .semibold))
        case .review:
            Image(systemName: "eye").font(.system(size: 8, weight: .bold)).foregroundStyle(palette.review)
        }
    }

    // MARK: The layout menu

    /// Picks the window's layout; also in the right-click menu of the ones without a header.
    private var layoutMenu: some View {
        Menu { layoutMenuItems(inline: true) } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(contrast ? Color.primary : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .linkPointer()
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Layout: \(layout.chosen.title)")
        .accessibilityLabel("Layout: \(layout.chosen.title)")
    }

    @ViewBuilder private func layoutMenuItems(inline: Bool) -> some View {
        let picker = Picker("Layout", selection: Binding(get: { layout.chosen }, set: { layout.choose($0) })) {
            ForEach(KeepOnTopLayout.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        if inline { picker.pickerStyle(.inline) } else { picker }
        Divider()
        Toggle("Strip while an app is full screen", isOn: $autoStrip)
    }

    // MARK: The strip, the dots and the bar

    /// The coordinate space chips, marks and bar items report their places in.
    private static let chipSpace = "chips"
    static let maxChips = 6
    /// Places in the strip kept for finished sessions, so one that just
    /// finished is a click away even with many running.
    static let keptForFinished = 2
    static let maxDots = 12
    static let hoverCardWidth: CGFloat = 290

    /// A session whose latest turn asked you something: a "Waiting on you"
    /// card in the list, whether it needs you, is to review or has finished.
    static func asks(_ row: Row) -> Bool { row.group != .running && !row.held && row.card?.ask != nil }

    /// The strip's, the bar's, the dots' and the columns' groups. Sessions
    /// that asked you something are waiting on you, newest first, as the
    /// list's cards are, then the ones that need you.
    struct Compact {
        let running, waiting, review, finished: [Row]

        init(_ list: FloatingRows) {
            let asking = (list.waiting + list.review + list.finished).filter(FloatingView.asks)
                .sorted { $0.since > $1.since }
            let ids = Set(asking.map(\.id))
            running = list.running
            waiting = asking + list.waiting.filter { !ids.contains($0.id) }
            review = list.review.filter { !ids.contains($0.id) }
            finished = list.finished.filter { !ids.contains($0.id) }
        }
    }

    /// The strip's sessions: running, waiting on you, then ready for review,
    /// then the finished ones, newest first: at most `maxChips` in all, with
    /// up to `keptForFinished` places kept for finished ones. When they don't
    /// all fit, the ones waiting on you win, then review, then running; the
    /// rest of each are only counted.
    static func stripRows(_ list: FloatingRows) -> (shown: [Row], more: Int, finished: [Row], moreFinished: Int) {
        let g = Compact(list)
        let active = g.running + g.waiting + g.review
        let room = maxChips - min(g.finished.count, keptForFinished)
        let picked = Set((g.waiting + g.review + g.running).prefix(room).map(\.id))
        let shown = active.filter { picked.contains($0.id) }
        let finished = Array(g.finished.prefix(maxChips - shown.count))
        return (shown, active.count - shown.count, finished, g.finished.count - finished.count)
    }

    /// The dots' sessions in groups (running, waiting on you, review,
    /// finished), at most `maxDots` in all; the rest only counted.
    static func dotGroups(_ list: FloatingRows) -> (groups: [[Row]], more: Int) {
        let g = Compact(list)
        var left = maxDots
        let groups = [g.running, g.waiting, g.review, g.finished].map { rows -> [Row] in
            let taken = Array(rows.prefix(left))
            left -= taken.count
            return taken
        }
        let total = g.running.count + g.waiting.count + g.review.count + g.finished.count
        return (groups.filter { !$0.isEmpty }, max(0, total - maxDots))
    }

    /// The mark for a session in the strip, the bar or the dots: one that
    /// asked you something shows the amber "!", whatever its state.
    private func compactMark(_ row: Row) -> some View {
        Indicator(group: Self.asks(row) ? .yourTurn : row.group, quiet: row.quiet(now: model.now) != nil,
                  held: row.held, snoozed: row.snoozed, source: row.iconSource, fallback: row.source)
            .frame(width: 16, height: 16)
    }

    /// Where a hover card's left edge goes, measured from the left of the row
    /// it hangs from: centred on its chip when the row is wider than the card,
    /// else lined up with the side the window keeps fixed.
    static func hoverCardX(chipMidX: CGFloat, rowWidth: CGFloat, card: CGFloat, trailing: Bool) -> CGFloat {
        guard rowWidth >= card else { return trailing ? rowWidth - card : 0 }
        return min(max(chipMidX - card / 2, 0), rowWidth - card)
    }

    /// The hovered session's card: its question and buttons, or its row,
    /// then the snooze choices.
    @ViewBuilder private func hoverCard(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if row.group != .running, !row.held, let card = row.card, card.ask != nil {
                AnswerCard(row: row, card: card, now: model.now, open: open,
                           responseShown: openResponse == row.id,
                           toggleResponse: { toggleResponse(row.id) },
                           answer: answerFromCards && answer != nil ? { label in answer?(row, label) } : nil,
                           warm: answerFromCards ? warm : nil,
                           answering: answers.answering?.row == row.id ? answers.answering?.label : nil,
                           note: answers.notes[row.id], hideButton: false)
            } else {
                CompactRow(row: row, now: model.now, open: open, responseShown: openResponse == row.id,
                           toggleResponse: row.group == .running ? nil : { toggleResponse(row.id) }, hideButton: false)
                    .padding(4)
            }
            if SessionSnoozes.snoozable(row) || SessionHides.hideable(row) { cardActions(row) }
        }
        .frame(width: Self.hoverCardWidth, alignment: .leading)
        .background { surface(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(contrast ? 0.7 : 0.1)))
        .testFrame("card:\(row.id)")
    }

    /// The hover card under (or over) its chip; `trailing` when the window
    /// keeps its right edge fixed.
    private func placedCard(_ row: Row, trailing: Bool) -> some View {
        let x = Self.hoverCardX(chipMidX: spots[row.id]?.midX ?? 0, rowWidth: rowWidth,
                                card: Self.hoverCardWidth, trailing: trailing)
        return hoverCard(row)
            .alignmentGuide(trailing ? HorizontalAlignment.trailing : HorizontalAlignment.leading) { _ in
                trailing ? rowWidth - x : -x
            }
    }

    /// "Snooze 1h 3h Tomorrow" and "Hide" under a hover card: out of the
    /// strip and the counts until then, or until the session next changes.
    private func cardActions(_ row: Row) -> some View {
        let p = palette
        return HStack(spacing: 5) {
            if SessionSnoozes.snoozable(row) {
                // The word "Snooze" goes first when Hide needs the room.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        Image(systemName: "moon.zzz").font(.system(size: 10, weight: .semibold))
                        Text("Snooze")
                        snoozeChoices(row)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "moon.zzz").font(.system(size: 10, weight: .semibold))
                            .accessibilityLabel("Snooze")
                        snoozeChoices(row)
                    }
                }
            }
            Spacer(minLength: 0)
            if SessionHides.hideable(row) {
                Button {
                    hovered = nil
                    model.hide(row)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.slash").font(.system(size: 9.5, weight: .semibold))
                        Text("Hide")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.primary.opacity(contrast ? 0.2 : 0.09)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast ? 0.6 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary)
                .fixedSize()
                .help("Hide until it next updates")
                .backgroundHint("Hide until it next updates")
                .linkPointer()
                .testFrame("hide:\(row.id)")
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(p.time)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 9)
    }

    private func snoozeChoices(_ row: Row) -> some View {
        ForEach(SnoozeChoice.allCases) { choice in
                Button {
                    hovered = nil
                    model.snooze(row, until: choice.until(from: Date()))
                } label: {
                    Text(choice.short)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.primary.opacity(contrast ? 0.2 : 0.09)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast ? 0.6 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary)
                .help("Snooze " + snoozeWhen(choice.until(from: model.now), now: model.now))
                .linkPointer()
                .testFrame("snooze:\(row.id):\(choice.rawValue)")
        }
    }

    /// The snoozed sessions as a moon and a count; its menu wakes them.
    @ViewBuilder private func snoozedChip(_ rows: [Row], height: CGFloat = 24) -> some View {
        if !rows.isEmpty {
            let p = palette
            let label = rows.count == 1 ? "1 snoozed" : "\(rows.count) snoozed"
            Menu {
                ForEach(rows) { row in
                    Menu(row.title) {
                        if let until = row.snoozedUntil { Text("Snoozed " + snoozeWhen(until, now: model.now)) }
                        Button("Wake Now") { model.wake(row) }
                        if row.link != nil { Button(row.openLabel) { open(row) } }
                    }
                }
                if rows.count > 1 {
                    Divider()
                    Button("Wake All") { model.wakeAll() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(p.time)
                    Text("\(rows.count)")
                }
                .padding(.horizontal, 8)
                .frame(height: height)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .linkPointer()
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(label + ": click to wake one")
            .testFrame("snoozed-chip")
            .accessibilityLabel(label)
        }
    }

    /// Records where a chip sits, for its card, and makes the pointer on it show the card.
    private func hoverSpot(_ row: Row) -> HoverSpot {
        HoverSpot(id: row.id, space: Self.chipSpace,
                  hover: { hovered = row.id }, place: { spots[row.id] = $0 })
    }

    /// Double-click to go back to the list (on the mark, so a chip's click stays a chip's).
    private func backToList(_ view: some View) -> some View {
        view
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { layout.choose(.list) }
            .help("Double-click for the list")
    }

    private var listButton: some View {
        Button { layout.choose(.list) } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(contrast ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to the list")
        .linkPointer()
        .accessibilityLabel("Back to the list")
    }

    private func spotDivider(_ height: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(contrast ? 0.4 : 0.14)).frame(width: 1, height: height)
    }

    /// Sessions as one line of chips, for the black bar above a movie: running,
    /// then waiting, then ready for review, then finished. The pointer on a
    /// chip shows its card underneath; a click opens it.
    private func strip(_ list: FloatingRows) -> some View {
        let p = palette
        let (shown, more, finished, moreFinished) = Self.stripRows(list)
        let trailing = layout.trailing
        let card = hovered.flatMap { id in (shown + finished).first { $0.id == id } }
        return VStack(alignment: trailing ? .trailing : .leading, spacing: 6) {
            if let card, layout.upward { placedCard(card, trailing: trailing) }
            HStack(spacing: 4) {
                backToList(LimboMark(size: 15).padding(.leading, 5).padding(.trailing, 2).frame(height: 32))
                spotDivider(14)
                if shown.isEmpty && finished.isEmpty {
                    Text("All caught up").foregroundStyle(p.time).padding(.horizontal, 4)
                }
                ForEach(shown) { chip($0) }
                if more > 0 { Text("+\(more)").foregroundStyle(p.time).padding(.horizontal, 4) }
                if !shown.isEmpty && !finished.isEmpty { spotDivider(14) }
                ForEach(finished) { chip($0) }
                if moreFinished > 0 {
                    Text("+\(moreFinished)")
                        .foregroundStyle(p.time)
                        .padding(.horizontal, 4)
                        .help(moreFinished == 1 ? "1 more finished" : "\(moreFinished) more finished")
                        .accessibilityLabel(moreFinished == 1 ? "1 more finished" : "\(moreFinished) more finished")
                }
                snoozedChip(list.snoozed)
                listButton.padding(.trailing, 2)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 4)
            .frame(height: 32)
            .fixedSize()
            .coordinateSpace(name: Self.chipSpace)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .background { if let glow { GlowBackdrop(view: glow) } }
            .background { surface(Capsule()) }
            .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast ? 0.7 : 0.1)))
            .contentShape(Capsule())
            .gesture(WindowDragGesture())
            .contextMenu { layoutMenuItems(inline: false) }
            if let card, !layout.upward { placedCard(card, trailing: trailing) }
        }
        .fixedSize()
        .onHover { if !$0 { hovered = nil } }
    }

    /// A strip chip: the session's mark, its title (clipped) and how long ago.
    private func chip(_ row: Row) -> some View {
        let p = palette
        let waiting = row.group == .yourTurn || Self.asks(row)
        let finished = !waiting && (row.group == .justFinished || row.group == .done)
        let tint = row.group == .running ? p.running : waiting ? p.needsYou : finished ? Color.primary : p.review
        return Button { if row.link != nil { open(row) } } label: {
            HStack(spacing: 5) {
                compactMark(row)
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
                Text(compactAge(since: row.since, now: model.now))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(p.time)
            }
            .padding(.leading, 5)
            .padding(.trailing, 9)
            .frame(height: 24)
            .background(Capsule().fill(tint.opacity(contrast ? 0 : (waiting ? 0.16 : finished ? 0.07 : 0.12))))
            .overlay(Capsule().strokeBorder(waiting ? tint.opacity(0.6)
                                            : Color.primary.opacity(contrast ? 0.6 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkPointer(row.link != nil)
        .modifier(hoverSpot(row))
        .tagMenu(row)
        .testFrame("chip:\(row.id)")
        .accessibilityLabel("\(row.title)\(row.spokenApp), \(spokenState(row)), \(compactAge(since: row.since, now: model.now))")
    }

    /// Running, needs you, ready for review, finished: for VoiceOver.
    private func spokenState(_ row: Row) -> String {
        if let until = row.snoozedUntil, row.snoozed { return "snoozed " + snoozeWhen(until, now: model.now) }
        if row.held { return "on hold" }
        if Self.asks(row) { return "waiting on you" }
        switch row.group {
        case .running: return "running"
        case .yourTurn: return "needs you"
        case .review: return "ready for review"
        default: return "finished"
        }
    }

    /// The smallest layout: one mark per session, in groups. The pointer on a
    /// mark shows its card underneath; a click opens it.
    private func dots(_ list: FloatingRows) -> some View {
        let p = palette
        let (groups, more) = Self.dotGroups(list)
        let trailing = layout.trailing
        let card = hovered.flatMap { id in groups.joined().first { $0.id == id } }
        return VStack(alignment: trailing ? .trailing : .leading, spacing: 6) {
            if let card, layout.upward { placedCard(card, trailing: trailing) }
            HStack(spacing: 7) {
                backToList(LimboMark(size: 14).padding(.leading, 1).frame(height: 26))
                if groups.isEmpty {
                    spotDivider(12)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(p.time)
                        .help("All caught up")
                }
                ForEach(groups.indices, id: \.self) { index in
                    spotDivider(12)
                    ForEach(groups[index]) { row in
                        Button { if row.link != nil { open(row) } } label: {
                            compactMark(row).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .linkPointer(row.link != nil)
                        .modifier(hoverSpot(row))
                        .tagMenu(row)
                        .testFrame("dot:\(row.id)")
                        .accessibilityLabel("\(row.title)\(row.spokenApp), \(spokenState(row)), \(compactAge(since: row.since, now: model.now))")
                    }
                }
                if more > 0 {
                    Text("+\(more)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(p.time)
                }
                if !list.snoozed.isEmpty {
                    spotDivider(12)
                    snoozedChip(list.snoozed, height: 18)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, -4)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .fixedSize()
            .coordinateSpace(name: Self.chipSpace)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .background { if let glow { GlowBackdrop(view: glow) } }
            .background { surface(Capsule()) }
            .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast ? 0.7 : 0.1)))
            .contentShape(Capsule())
            .gesture(WindowDragGesture())
            .contextMenu { layoutMenuItems(inline: false) }
            if let card, !layout.upward { placedCard(card, trailing: trailing) }
        }
        .fixedSize()
        .onHover { if !$0 { hovered = nil } }
    }

    static let barRunning = 4, barWaiting = 3, barReview = 2

    /// A thin bar along the bottom of the screen, its full width: running
    /// sessions with what they're doing, then the ones waiting and to review,
    /// then a count of finished ones. The pointer on one shows its card above.
    private func bar(_ list: FloatingRows) -> some View {
        let p = palette
        let g = Compact(list)
        let running = Array(g.running.prefix(Self.barRunning))
        let waiting = Array(g.waiting.prefix(Self.barWaiting))
        let review = Array(g.review.prefix(Self.barReview))
        let shown = running + waiting + review
        let more = g.running.count + g.waiting.count + g.review.count - shown.count
        let card = hovered.flatMap { id in shown.first { $0.id == id } }
        let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 12, topTrailing: 12), style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if let card { placedCard(card, trailing: false) }
            HStack(spacing: 12) {
                backToList(LimboMark(size: 16).frame(height: 30))
                if shown.isEmpty && g.finished.isEmpty {
                    Text("All caught up").foregroundStyle(p.time)
                }
                if !running.isEmpty {
                    barLabel("Running", g.running.count)
                    ForEach(running) { barItem($0) }
                }
                if !waiting.isEmpty {
                    if !running.isEmpty { spotDivider(14) }
                    barLabel("Waiting on you", g.waiting.count)
                    ForEach(waiting) { barItem($0) }
                }
                if !review.isEmpty {
                    if !running.isEmpty || !waiting.isEmpty { spotDivider(14) }
                    barLabel("To review", g.review.count)
                    ForEach(review) { barItem($0) }
                }
                if more > 0 { Text("+\(more)").foregroundStyle(p.time).fixedSize() }
                if !g.finished.isEmpty {
                    if !shown.isEmpty { spotDivider(14) }
                    barLabel("Finished", nil)
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(p.done)
                        Text("\(g.finished.count)")
                    }
                    .fixedSize()
                }
                if !list.snoozed.isEmpty {
                    if !shown.isEmpty || !g.finished.isEmpty { spotDivider(14) }
                    snoozedChip(list.snoozed, height: 22)
                }
                // The empty part: double-click for the list.
                backToList(Color.clear.frame(minWidth: 8, maxWidth: .infinity, minHeight: 22, maxHeight: 22))
                    .layoutPriority(-1)   // the sessions take the room first
                listButton
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(width: layout.barWidth, height: 30)
            .coordinateSpace(name: Self.chipSpace)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .background { if let glow { GlowBackdrop(view: glow) } }
            .background { surface(shape) }
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast ? 0.7 : 0.1)))
            .contextMenu { layoutMenuItems(inline: false) }
        }
        .frame(width: layout.barWidth, alignment: .leading)
        .onHover { if !$0 { hovered = nil } }
    }

    /// A small capitals label in the bar, and its count.
    private func barLabel(_ text: String, _ count: Int?) -> some View {
        Text(count.map { "\(text.uppercased()) \($0)" } ?? text.uppercased())
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .tracking(0.7)
            .foregroundStyle(palette.time)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    /// One session in the bar: mark, title, what it's doing (running) or its
    /// first tag, and how long ago. Titles give way first to the rest.
    private func barItem(_ row: Row) -> some View {
        let p = palette
        let waiting = row.group == .yourTurn || Self.asks(row)
        return Button { if row.link != nil { open(row) } } label: {
            HStack(spacing: 6) {
                compactMark(row)
                Text(row.title).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                // What it's doing, or its first tag: whole, or left out when there's no room.
                ViewThatFits(in: .horizontal) {
                    if row.group == .running, let activity = row.activity {
                        Text(activity).font(.system(size: 11)).foregroundStyle(p.text2).fixedSize()
                    } else if let tag = row.tags.first {
                        TagPill(tag: tag).fixedSize()
                    }
                    Color.clear.frame(width: 0, height: 0)
                }
                Text(compactAge(since: row.since, now: model.now))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(p.time)
                    .fixedSize()
            }
            .padding(.horizontal, waiting ? 8 : 2)
            .frame(height: 22)
            .background(Capsule().fill(waiting && !contrast ? p.needsYou.opacity(0.14) : .clear))
            .overlay(Capsule().strokeBorder(waiting ? p.needsYou.opacity(0.55) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkPointer(row.link != nil)
        .modifier(hoverSpot(row))
        .tagMenu(row)
        .testFrame("bar:\(row.id)")
        .accessibilityLabel("\(row.title)\(row.spokenApp), \(spokenState(row)), \(compactAge(since: row.since, now: model.now))")
    }

    // MARK: The columns

    static let columnRows = 4

    /// Wide and short: running, needs you (and to review), and finished side by side.
    private func columns(_ list: FloatingRows) -> some View {
        let g = Compact(list)
        return VStack(alignment: .leading, spacing: 0) {
            header(list, filter: nil, counts: false, doubleClick: .list)
            HStack(alignment: .top, spacing: 0) {
                column("Running", g.running)
                columnDivider
                column("Waiting on you", g.waiting + g.review)
                columnDivider
                column("Finished", g.finished + list.onHold)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 6)
        }
        .frame(width: layout.columnsWidth, alignment: .top)
        .background { if let glow { GlowBackdrop(view: glow) } }
        .background { surface(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)) }
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
            .strokeBorder(Color.primary.opacity(contrast ? 0.7 : 0.1)))
    }

    private var columnDivider: some View {
        Rectangle().fill(Color.primary.opacity(contrast ? 0.35 : 0.08)).frame(width: 1)
            .frame(maxHeight: .infinity).padding(.vertical, 8)
    }

    private func column(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title, count: rows.count)
            if rows.isEmpty {
                Text("None")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.time)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                rowStack(Array(rows.prefix(Self.columnRows)))
                if rows.count > Self.columnRows {
                    Text("\(rows.count - Self.columnRows) more")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.time)
                        .padding(.leading, 36)
                        .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Picks how the window glows while a session runs, and in what colour.
    private var glowMenu: some View {
        let style = GlowStyle(rawValue: glowStyle) ?? .calm
        return Menu {
            Picker("Glow while a session runs", selection: $glowStyle) {
                ForEach(GlowStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Colour", selection: $glowColor) {
                ForEach(GlowColor.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .disabled(style == .none)
            Divider()
            Toggle("Amber glow when a session needs you", isOn: $needsYouGlow)
            Toggle("Green when everything finishes", isOn: $doneFlash)
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(contrast ? Color.primary : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .linkPointer()
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Glow while a session runs: \(style.title)")
        .accessibilityLabel("Glow while a session runs: \(style.title)")
    }
}

/// A chip's place in its row, and the pointer reaching it.
struct HoverSpot: ViewModifier {
    let id: String
    let space: String
    let hover: () -> Void
    let place: (CGRect) -> Void

    func body(content: Content) -> some View {
        content
            .onHover { if $0 { hover() } }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { place($0) }
    }
}

// MARK: - Running glow

/// How the keep-on-top window shows that a session is running: colour that
/// comes in from its edges, with no border line. Picked from the sparkle menu
/// in the window's header.
enum GlowStyle: String, CaseIterable, Identifiable {
    case calm, aurora, ember, corners, tide, rise, heartbeat, random, none
    static let key = "runningGlow"
    /// The effects themselves, the ones Random picks from.
    static let effects: [GlowStyle] = [.aurora, .ember, .corners, .tide, .rise, .heartbeat]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calm: return "Calm rim"
        case .aurora: return "Aurora drift"
        case .ember: return "Ember breath"
        case .corners: return "Corner bloom"
        case .tide: return "Tide sweep"
        case .rise: return "Rising warmth"
        case .heartbeat: return "Heartbeat"
        case .random: return "Random, a new one every 5 seconds"
        case .none: return "No glow"
        }
    }
    static var saved: GlowStyle {
        UserDefaults.standard.string(forKey: key).flatMap(GlowStyle.init(rawValue:)) ?? .calm
    }
}

/// The two other signals, each on unless turned off in the sparkle menu.
enum GlowSignal {
    static let needsYouKey = "needsYouGlow"
    static let doneFlashKey = "doneFlash"
    static var needsYou: Bool { UserDefaults.standard.object(forKey: needsYouKey) as? Bool ?? true }
    static var doneFlash: Bool { UserDefaults.standard.object(forKey: doneFlashKey) as? Bool ?? true }
}

/// What the glow should show, and whether the green flash plays: amber while a
/// session newly needs you, else the running effect while any session runs; a
/// flash when the last running session stops. A choice just made in the
/// sparkle menu shows for a few seconds.
/// `finished` is whether everything had finished at the last update: it
/// turns on when the last running session stops and off when one runs again
/// (or, outside this function, when you open a session). While it is on, the
/// whole window stays green.
func glowDecision(pinned: Bool, running: Int, wasRunning: Int, finished: Bool, needsYou: Bool,
                  previewing: GlowPreview?, needsYouOn: Bool, doneOn: Bool)
    -> (mode: GlowMode, flash: Bool, finished: Bool) {
    guard pinned else { return (.off, false, finished) }
    let justFinished = running == 0 && wasRunning > 0
    let allFinished = running == 0 && (finished || justFinished)
    let flash = doneOn && justFinished
    let mode: GlowMode
    switch previewing {
    case .needsYou?: mode = .needsYou
    case .running?: mode = .running
    case .done?: mode = .done
    default:
        if needsYouOn && needsYou { mode = .needsYou }
        else if running > 0 { mode = .running }
        else if doneOn && allFinished { mode = .done }
        else { mode = .off }
    }
    return (mode, flash, allFinished)
}

/// What changed in the sparkle menu, so it can be shown straight away.
enum GlowPreview {
    case running, needsYou, done, none
}

enum GlowColor: String, CaseIterable, Identifiable {
    case red, orange, rose, green
    static let key = "runningGlowColor"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 1.00, green: 0.30, blue: 0.24, alpha: 1)      // #FF4D3D
        case .orange: return NSColor(srgbRed: 1.00, green: 0.54, blue: 0.24, alpha: 1)   // #FF8A3D
        case .rose: return NSColor(srgbRed: 0.89, green: 0.28, blue: 0.48, alpha: 1)     // #E2477A
        case .green: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)    // #34C759
        }
    }
    static var saved: GlowColor {
        UserDefaults.standard.string(forKey: key).flatMap(GlowColor.init(rawValue:)) ?? .red
    }
}

extension NSColor {
    /// The same colour turned a little around the colour wheel.
    func shifted(hue dh: CGFloat, saturation ds: CGFloat = 0, brightness db: CGFloat = 0) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        let h = c.hueComponent + dh
        return NSColor(colorSpace: .sRGB, hue: h - floor(h),
                       saturation: min(1, max(0, c.saturationComponent + ds)),
                       brightness: min(1, max(0, c.brightnessComponent + db)), alpha: c.alphaComponent)
    }
}

/// A small image for the edges of a window of any size: `alpha` gets the
/// distance in points from the nearest left or right edge and from the nearest
/// top or bottom edge. Its middle pixel stretches (the returned contentsCenter),
/// so the picture is the same few kilobytes however big the window gets.
func stretchableEdgeImage(depth: CGFloat, scale: CGFloat, color: NSColor,
                          alpha: (Double, Double) -> Double) -> (image: CGImage, center: CGRect)? {
    let points = 2 * depth + 1
    let side = Int((points * scale).rounded())
    guard side > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data else { return nil }
    let c = color.usingColorSpace(.sRGB) ?? color
    let rgb = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
    let distance = (0..<side).map { (Double(min($0, side - 1 - $0)) + 0.5) / Double(scale) }
    let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
    for y in 0..<side {
        for x in 0..<side {
            let a = max(0, min(1, alpha(distance[x], distance[y])))
            let o = (y * side + x) * 4
            for i in 0..<3 { pixels[o + i] = UInt8((rgb[i] * a * 255).rounded()) }
            pixels[o + 3] = UInt8((a * 255).rounded())
        }
    }
    guard let image = context.makeImage() else { return nil }
    let unit = 1 / points
    return (image, CGRect(x: depth * unit, y: depth * unit, width: unit, height: unit))
}

/// A glow along every edge that fades inward, as CSS draws
/// `box-shadow: inset 0 0 <blur> <spread>`: one minus a Gaussian-blurred
/// rectangle, which is a row profile times a column profile.
func insetGlowImage(color: NSColor, blur: CGFloat, spread: CGFloat, scale: CGFloat) -> (image: CGImage, center: CGRect)? {
    let sigma = Double(blur) / 2, s = Double(spread)
    func inside(_ d: Double) -> Double { 0.5 * erfc(-(d - s) / (sigma * 2.0.squareRoot())) }
    return stretchableEdgeImage(depth: ceil(spread + 1.5 * blur), scale: scale, color: color) { dx, dy in
        1 - inside(dx) * inside(dy)
    }
}

/// What the keep-on-top window's glow shows.
enum GlowMode: String {
    case off, running, needsYou, done
}

/// Amber, for a session that needs you; yellower than the orange glow colour.
let needsYouColor = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.16, alpha: 1)

/// The keep-on-top window's light. While a session runs, colour moves in from
/// its edges in the chosen style; while a session newly needs you, a slow
/// amber breath takes over; when the last running session stops, a green glow
/// sweeps across once and fades. Core Animation runs it all at a capped frame
/// rate, so the app does no work per frame; steady glows with Reduce Motion on.
/// Random cross-fades to a different running effect every 5 seconds.
final class RunningGlowView: NSView {
    private struct Effect {
        var layout: (CGRect) -> Void = { _ in }
        /// Sets the starting look and adds the animations (none when still).
        var start: (_ bounds: CGRect, _ still: Bool) -> Void = { _, _ in }
        /// A layer that carries an animation while the effect moves.
        var probe: CALayer?
    }

    private let clip = CALayer()
    /// The done flash has its own layer, so it plays over whatever comes next.
    private let flashClip = CALayer()
    private var chosen: GlowStyle = .none
    private var tint: GlowColor = .red
    private var mode: GlowMode = .off
    /// The running effect; Random changes it every 5 seconds.
    private var showing: GlowStyle = .none
    private var effect = Effect()
    private var builtScale: CGFloat = 0
    private var laidOut: CGSize = .zero
    private var shuffle: Timer?
    private var restart: DispatchWorkItem?
    /// Snapshots draw the effect moving even with Reduce Motion on.
    var forceMotion = false
    /// Snapshots draw it as with Increase Contrast on (or off).
    var forceContrast: Bool?
    /// 12 for the window, 16 for the pill.
    var cornerRadius: CGFloat = 12 {
        didSet {
            guard cornerRadius != oldValue else { return }
            for layer in [clip, flashClip] { layer.cornerRadius = cornerRadius }
            if mode != .off && highContrast { render(fade: false) }   // the ring follows the corners
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for layer in [clip, flashClip] {
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            self.layer?.addSublayer(layer)
        }
        clip.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    // Clicks go through to the rows underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var still: Bool { !forceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Increase Contrast: a steady 2 pt ring in the glow's colour instead of
    /// moving light.
    private var highContrast: Bool { forceContrast ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    private var isLight: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua }

    /// On a light background the glow colours are deepened, so they still show.
    private func deepen(_ color: NSColor) -> NSColor {
        isLight ? color.shifted(hue: 0, saturation: 0.08, brightness: -0.12) : color
    }
    /// The effect is as it should be: moving, or meant to be still.
    private var settled: Bool { still || effect.probe.map { $0.animationKeys()?.isEmpty == false } ?? true }

    func configure(style: GlowStyle, color: GlowColor) {
        guard style != chosen || color != tint else { return }
        chosen = style
        tint = color
        showing = style == .random ? GlowStyle.effects.randomElement()! : style
        if mode == .running { render(fade: false) }
        updateShuffle()
    }

    func setMode(_ new: GlowMode) {
        guard new != mode || !settled else { return }
        let fade = mode != .off && new != .off && mode != new
        mode = new
        render(fade: fade)
    }

    /// On means running; for the snapshot and the Random check.
    func setActive(_ on: Bool) { setMode(on ? .running : .off) }

    /// Reduce Motion or Increase Contrast was turned on or off.
    func motionChanged() { render(fade: false) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if mode != .off { render(fade: false) }
    }

    /// The last running session stopped: a green glow sweeps across once and
    /// fades, in about 2 seconds (a plain fade with Reduce Motion on).
    func celebrate() {
        let b = bounds
        let green = deepen(GlowColor.green.color)
        let calm = still || highContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flashClip.sublayers = nil
        let holder = CALayer()
        holder.frame = b
        holder.opacity = 0
        let wash = CAGradientLayer()
        if chosen == .calm {
            // Calm rim: the ring lights up green, nothing sweeps behind the text.
            let ring = CALayer()
            ring.frame = b
            ring.borderWidth = 2
            ring.borderColor = green.cgColor
            ring.cornerRadius = cornerRadius
            ring.cornerCurve = .continuous
            holder.addSublayer(ring)
        } else {
            let edge = imageLayer(insetGlowImage(color: green, blur: 26, spread: 3, scale: scale))
            edge.frame = b
            wash.colors = washColors(green)
            wash.locations = [0, 0.3, 0.5, 0.7, 1]
            layoutWash(wash, in: b)
            wash.opacity = calm ? 0 : 0.5
            holder.addSublayer(edge)
            holder.addSublayer(wash)
        }
        flashClip.addSublayer(holder)
        let fade = keyframes("opacity", values: [0, 1, 1, 0], times: [0, 0.12, 0.5, 1], duration: 2.2)
        fade.repeatCount = 1
        CATransaction.setCompletionBlock { [weak holder] in holder?.removeFromSuperlayer() }
        holder.add(fade, forKey: "flash")
        if !calm && chosen != .calm {
            let sweep = loop("position.x", from: b.minX - 0.54 * b.width, to: b.minX + 1.54 * b.width,
                             duration: 1.4, autoreverses: false)
            sweep.repeatCount = 1
            wash.add(sweep, forKey: "flash")
        }
        CATransaction.commit()
    }

    /// For diagnostics: what was picked, what shows, and whether it moves.
    var state: [String: Any] {
        ["mode": mode.rawValue, "chosen": chosen.rawValue, "showing": showing.rawValue, "color": tint.rawValue,
         "active": mode != .off, "animating": effect.probe?.animationKeys()?.isEmpty == false, "still": still,
         "flashing": flashClip.sublayers?.isEmpty == false, "contrast": highContrast, "light": isLight,
         "cornerRadius": Int(cornerRadius),
         "width": Int(bounds.width), "height": Int(bounds.height)]
    }

    /// Snapshots: stop the clock, then `phase(_:)` picks the moment drawn.
    func freeze() { for layer in [clip, flashClip] { layer.speed = 0; layer.timeOffset = 0 } }
    func phase(_ seconds: CFTimeInterval) { for layer in [clip, flashClip] { layer.timeOffset = seconds } }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        flashClip.frame = bounds
        effect.layout(bounds)
        CATransaction.commit()
        // Some animations have the size baked in: restart them once a resize
        // settles, not on every step of the drag.
        guard bounds.size != laidOut else { return }
        let first = laidOut == .zero
        laidOut = bounds.size
        guard mode != .off else { return }
        restart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode != .off else { return }
            self.stopAnimations(self.clip)
            self.effect.start(self.bounds, self.still)
        }
        restart = work
        if first { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if builtScale != scale { render(fade: false) }
    }

    private func updateShuffle() {
        guard mode == .running, chosen == .random, !still, !highContrast else { stopShuffle(); return }
        guard shuffle == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.showing = GlowStyle.effects.filter { $0 != self.showing }.randomElement()!
            self.render(fade: true)
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        shuffle = timer
    }

    private func stopShuffle() {
        shuffle?.invalidate()
        shuffle = nil
    }

    private func stopAnimations(_ layer: CALayer) {
        layer.sublayers?.forEach { $0.removeAllAnimations(); stopAnimations($0) }
    }

    /// Rebuilds the layers for the current mode, cross-fading when asked.
    private func render(fade: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopAnimations(clip)
        if fade {
            let swap = CATransition()
            swap.type = .fade
            swap.duration = 0.9
            clip.add(swap, forKey: "swap")
        }
        clip.sublayers = nil
        builtScale = scale
        switch (mode, highContrast) {
        case (.off, _): effect = Effect()
        case (_, false) where chosen == .calm:
            // Calm rim: every state as a thin ring and a top edge, in its colour.
            let color = mode == .running ? tint.color : mode == .needsYou ? needsYouColor : GlowColor.green.color
            effect = buildCalm(deepen(color), breathe: mode == .needsYou ? 1.6 : mode == .running ? 2.4 : 3)
        case (.running, false): effect = build(showing)
        case (.needsYou, false): effect = buildNeedsYou()
        case (.done, false): effect = buildDone()
        case (.running, true): effect = chosen == .none ? Effect() : buildRing(deepen(tint.color))
        case (.needsYou, true): effect = buildRing(deepen(needsYouColor))
        case (.done, true): effect = buildRing(deepen(GlowColor.green.color), fill: 0.22)
        }
        effect.layout(bounds)
        clip.isHidden = mode == .off
        if mode != .off { effect.start(bounds, still) }
        CATransaction.commit()
        updateShuffle()
    }

    /// Calm rim: a thin ring just inside the edge and a 2 pt band along the
    /// top, with a faint inner glow, breathing slowly; nothing behind the text,
    /// which stays on a solid background.
    private func buildCalm(_ color: NSColor, breathe: CFTimeInterval) -> Effect {
        let holder = CALayer()
        let soft = imageLayer(insetGlowImage(color: color, blur: 10, spread: 1, scale: builtScale))
        soft.opacity = 0.5
        let ring = CALayer()
        ring.borderWidth = 1.5
        ring.borderColor = color.cgColor
        ring.cornerRadius = cornerRadius
        ring.cornerCurve = .continuous
        let band = CALayer()
        band.backgroundColor = color.cgColor
        holder.addSublayer(soft)
        holder.addSublayer(ring)
        holder.addSublayer(band)
        clip.addSublayer(holder)
        var effect = Effect()
        effect.layout = { b in
            holder.frame = b
            let local = CGRect(origin: .zero, size: b.size)
            soft.frame = local
            ring.frame = local
            band.frame = CGRect(x: 0, y: b.height - 2, width: b.width, height: 2)   // the top edge
        }
        effect.start = { _, still in
            holder.opacity = 1
            guard !still else { return }
            holder.add(loop("opacity", from: 0.55, to: 1.0, duration: breathe), forKey: "glow")
        }
        effect.probe = holder
        return effect
    }

    /// Increase Contrast: a steady ring just inside the edge (and, for "all
    /// finished", a light fill), no motion.
    private func buildRing(_ color: NSColor, fill: CGFloat = 0) -> Effect {
        let ring = CALayer()
        ring.borderWidth = 2
        ring.borderColor = color.cgColor
        ring.cornerRadius = cornerRadius
        ring.cornerCurve = .continuous
        if fill > 0 { ring.backgroundColor = color.withAlphaComponent(fill).cgColor }
        clip.addSublayer(ring)
        var effect = Effect()
        effect.layout = { ring.frame = $0 }
        return effect
    }

    /// A session needs you: a slow amber breath along the edges.
    private func buildNeedsYou() -> Effect {
        let edge = imageLayer(insetGlowImage(color: deepen(needsYouColor), blur: 30, spread: 3, scale: builtScale))
        clip.addSublayer(edge)
        var effect = Effect()
        effect.layout = { edge.frame = $0 }
        effect.start = { _, still in
            edge.opacity = still ? 0.65 : 0.25
            guard !still else { return }
            edge.add(loop("opacity", from: 0.25, to: 0.9, duration: 1.6), forKey: "glow")
        }
        effect.probe = edge
        return effect
    }

    /// Everything has finished: the whole window turns green behind the rows,
    /// a little stronger at the edges, breathing slowly.
    private func buildDone() -> Effect {
        let green = deepen(GlowColor.green.color)
        let holder = CALayer()
        let fill = CALayer()
        fill.backgroundColor = green.withAlphaComponent(0.34).cgColor
        let edge = imageLayer(insetGlowImage(color: green, blur: 26, spread: 3, scale: builtScale))
        holder.addSublayer(fill)
        holder.addSublayer(edge)
        clip.addSublayer(holder)
        var effect = Effect()
        effect.layout = { b in
            holder.frame = b
            fill.frame = CGRect(origin: .zero, size: b.size)
            edge.frame = CGRect(origin: .zero, size: b.size)
        }
        effect.start = { _, still in
            holder.opacity = still ? 0.9 : 0.7
            guard !still else { return }
            holder.add(loop("opacity", from: 0.7, to: 1.0, duration: 2.5), forKey: "glow")
        }
        effect.probe = holder
        return effect
    }

    /// A band of colour 2.6 times the window's width, leaning 10°.
    private func layoutWash(_ wash: CAGradientLayer, in b: CGRect) {
        let width = b.width * 2.6
        wash.bounds = CGRect(x: 0, y: 0, width: width, height: b.height)
        wash.position = CGPoint(x: b.midX, y: b.midY)
        let tilt = width * tan(10 * Double.pi / 180) / 2 / max(b.height, 1)
        wash.startPoint = CGPoint(x: 0, y: 0.5 + tilt)
        wash.endPoint = CGPoint(x: 1, y: 0.5 - tilt)
    }

    private func washColors(_ color: NSColor) -> [CGColor] {
        let clear = color.withAlphaComponent(0).cgColor
        return [clear, clear, color.cgColor, clear, clear]
    }

    private func build(_ style: GlowStyle) -> Effect {
        let accent = deepen(tint.color)
        let cg = accent.cgColor, clear = accent.withAlphaComponent(0).cgColor
        var effect = Effect()
        switch style {
        case .ember, .heartbeat:
            // A soft inset glow that breathes, or beats twice and rests.
            let ember = style == .ember
            let edge = imageLayer(insetGlowImage(color: accent, blur: ember ? 26 : 30, spread: ember ? 3 : 4, scale: builtScale))
            clip.addSublayer(edge)
            effect.layout = { edge.frame = $0 }
            effect.start = { _, still in
                edge.opacity = still ? (ember ? 0.7 : 0.6) : (ember ? 0.3 : 0.2)
                guard !still else { return }
                edge.add(ember ? loop("opacity", from: 0.3, to: 1.0, duration: 1.2)
                               : keyframes("opacity", values: [0.2, 1, 0.35, 0.85, 0.2, 0.2],
                                           times: [0, 0.1, 0.22, 0.32, 0.5, 1], duration: 1.6, timing: .easeOut),
                         forKey: "glow")
            }
            effect.probe = edge

        case .aurora:
            // Red, coral and rose turning slowly, seen only near the edges.
            let holder = CALayer()
            let edges = imageLayer(stretchableEdgeImage(depth: 38, scale: builtScale, color: .white) { dx, dy in
                max(0, 1 - dx / 38) + max(0, 1 - dy / 30)
            })
            holder.mask = edges
            holder.opacity = 0.95
            let band = CAGradientLayer()
            band.type = .conic
            band.startPoint = CGPoint(x: 0.5, y: 0.5)
            band.endPoint = CGPoint(x: 0.5, y: 1)
            band.colors = [accent, accent.shifted(hue: 0.05, saturation: -0.25, brightness: 0.05),
                           accent.shifted(hue: -0.07, saturation: -0.05, brightness: -0.1),
                           accent.withAlphaComponent(0.25), accent].map(\.cgColor)
            holder.addSublayer(band)
            clip.addSublayer(holder)
            effect.layout = { bounds in
                holder.frame = bounds
                edges.frame = CGRect(origin: .zero, size: bounds.size)
                let side = max(560, hypot(bounds.width, bounds.height) + 40)   // covers the corners while turning
                band.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                band.position = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            effect.start = { _, still in
                guard !still else { return }
                band.add(loop("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: 4,
                              autoreverses: false, timing: .linear), forKey: "glow")
            }
            effect.probe = band

        case .corners:
            // Soft light blooming from each corner in turn, clockwise.
            let blooms = (0..<4).map { _ -> CAGradientLayer in
                let bloom = CAGradientLayer()
                bloom.type = .radial
                bloom.colors = [cg, clear]
                bloom.locations = [0, 0.96]
                bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
                bloom.endPoint = CGPoint(x: 1, y: 1)
                bloom.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
                bloom.opacity = 0
                clip.addSublayer(bloom)
                return bloom
            }
            effect.layout = { b in
                // Top left, top right, bottom right, bottom left (y goes up).
                let spots = [CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY),
                             CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.minY)]
                for (bloom, spot) in zip(blooms, spots) { bloom.position = spot }
            }
            effect.start = { _, still in
                for (i, bloom) in blooms.enumerated() {
                    bloom.opacity = still ? 0.5 : 0
                    guard !still else { continue }
                    let pulse = keyframes("opacity", values: [0, 0.9, 0, 0], times: [0, 0.25, 0.55, 1], duration: 3.2)
                    pulse.timeOffset = 3.2 * Double((4 - i) % 4) / 4   // each a quarter turn after the last
                    bloom.add(pulse, forKey: "glow")
                }
            }
            effect.probe = blooms[0]

        case .tide:
            // A faint edge glow with a wash of colour sweeping across.
            let edge = imageLayer(insetGlowImage(color: accent, blur: 18, spread: 1, scale: builtScale))
            edge.opacity = 0.35
            let wash = CAGradientLayer()
            wash.colors = washColors(accent)
            wash.locations = [0, 0.3, 0.5, 0.7, 1]
            clip.addSublayer(edge)
            clip.addSublayer(wash)
            effect.layout = { [weak self] b in
                edge.frame = b
                self?.layoutWash(wash, in: b)
            }
            effect.start = { b, still in
                wash.opacity = still ? 0 : 0.32
                guard !still else { return }
                wash.add(loop("position.x", from: b.minX - 0.54 * b.width, to: b.minX + 1.54 * b.width,
                              duration: 3, autoreverses: false), forKey: "glow")
            }
            effect.probe = wash

        case .rise:
            // Warmth rising from the bottom edge and settling back.
            let heat = CAGradientLayer()
            heat.type = .radial
            heat.colors = [cg, clear]
            heat.locations = [0, 0.62]
            heat.startPoint = CGPoint(x: 0.5, y: 0)                 // bottom centre
            heat.endPoint = CGPoint(x: 0.5 + 0.707, y: 1.414)
            heat.anchorPoint = CGPoint(x: 0.5, y: 0)
            clip.addSublayer(heat)
            effect.layout = { b in
                heat.bounds = CGRect(x: 0, y: 0, width: b.width * 1.2, height: b.height * 1.4)
                heat.position = CGPoint(x: b.midX, y: b.minY - 20)
            }
            effect.start = { _, still in
                heat.transform = CATransform3DMakeScale(1, still ? 0.5 : 0.35, 1)
                heat.opacity = still ? 0.6 : 0.45
                guard !still else { return }
                let group = CAAnimationGroup()
                group.animations = [("transform.scale.y", 0.35, 0.75), ("opacity", 0.45, 0.95)].map {
                    let part = CABasicAnimation(keyPath: $0.0)
                    part.fromValue = $0.1
                    part.toValue = $0.2
                    part.duration = 1.5
                    return part
                }
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                group.duration = 1.5
                group.autoreverses = true
                group.repeatCount = .infinity
                group.isRemovedOnCompletion = false
                group.preferredFrameRateRange = glowFrameRate
                heat.add(group, forKey: "glow")
            }
            effect.probe = heat

        case .calm, .random, .none:
            break
        }
        return effect
    }

    private func imageLayer(_ made: (image: CGImage, center: CGRect)?) -> CALayer {
        let layer = CALayer()
        if let made {
            layer.contents = made.image
            layer.contentsCenter = made.center
            layer.contentsScale = scale
        }
        return layer
    }
}

/// Puts the controller's glow view behind the rows.
struct GlowBackdrop: NSViewRepresentable {
    let view: RunningGlowView
    func makeNSView(context: Context) -> RunningGlowView { view }
    func updateNSView(_ nsView: RunningGlowView, context: Context) {}
}

/// Smooth enough for slow light, light on the GPU.
let glowFrameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)

private func loop(_ keyPath: String, from: Double, to: Double, duration: CFTimeInterval,
                  autoreverses: Bool = true, timing: CAMediaTimingFunctionName = .easeInEaseOut) -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.fromValue = from
    animation.toValue = to
    animation.duration = duration
    animation.autoreverses = autoreverses
    animation.timingFunction = CAMediaTimingFunction(name: timing)
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    animation.preferredFrameRateRange = glowFrameRate
    return animation
}

private func keyframes(_ keyPath: String, values: [Double], times: [Double], duration: CFTimeInterval,
                       timing: CAMediaTimingFunctionName = .easeInEaseOut) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values
    animation.keyTimes = times.map { NSNumber(value: $0) }
    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: timing), count: values.count - 1)
    animation.duration = duration
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    animation.preferredFrameRateRange = glowFrameRate
    return animation
}

/// Takes the first click, so a row opens without first focusing the window.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The keep-on-top window's shapes, picked from the layout menu in its header
/// (or its right-click menu). Only the list and columns can be resized.
enum KeepOnTopLayout: String, CaseIterable, Identifiable {
    case list, strip, bar, dots, columns, pill
    static let autoStripKey = "keepOnTopStripWhenFullScreen"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .list: return "List"
        case .strip: return "Strip"
        case .bar: return "Bar"
        case .dots: return "Dots"
        case .columns: return "Columns"
        case .pill: return "Pill"
        }
    }
    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .strip: return "rectangle.split.3x1"
        case .bar: return "rectangle.bottomthird.inset.filled"
        case .dots: return "ellipsis"
        case .columns: return "rectangle.grid.3x2"
        case .pill: return "capsule"
        }
    }
    /// The edges a drag resizes: all of the list's, the sides of the columns.
    var resizable: ResizeEdges {
        switch self {
        case .list: return [.left, .right, .top, .bottom]
        case .columns: return [.left, .right]
        default: return []
        }
    }
    /// How round the glow's corners are: the window's, or half a capsule's height.
    var glowCorner: CGFloat {
        switch self {
        case .dots: return 13
        case .bar: return 12
        default: return 16
        }
    }

    /// What shows: the layout you chose, or the strip in place of the list or
    /// the columns while an app is full screen on the window's display (with
    /// that switch on), unless you picked a layout since it went full screen.
    static func effective(chosen: KeepOnTopLayout, fullScreen: Bool, autoStrip: Bool,
                          kept: Bool) -> KeepOnTopLayout {
        guard autoStrip, fullScreen, !kept, chosen == .list || chosen == .columns else { return chosen }
        return .strip
    }

    /// The saved choice; before layouts there was only the pill switch.
    static func saved(raw: String?, legacyMini: Bool) -> KeepOnTopLayout {
        raw.flatMap(KeepOnTopLayout.init(rawValue:)) ?? (legacyMini ? .pill : .list)
    }
}

/// The keep-on-top window's layout and size as you left them: any width, and
/// a height only after you drag its top or bottom edge (until then it fits the rows).
final class FloatingLayout: ObservableObject {
    static let defaultWidth: CGFloat = 300
    static let minSize = NSSize(width: 220, height: 64)
    static let defaultColumnsWidth: CGFloat = 660
    static let minColumnsWidth: CGFloat = 480
    private static let widthKey = "keepOnTopWidth", heightKey = "keepOnTopHeight", miniKey = "keepOnTopMini"
    private static let layoutKey = "keepOnTopLayout", columnsKey = "keepOnTopColumnsWidth"
    @Published var width: CGFloat
    @Published var height: CGFloat?
    @Published var columnsWidth: CGFloat
    /// The layout you picked.
    @Published var chosen: KeepOnTopLayout
    /// Set by the window: another app is full screen on its display.
    @Published var fullScreen = false
    /// You picked a layout while that was so: it stays until full screen ends.
    @Published var keptInFullScreen = false
    /// Set by the window: it sits in the right half of its screen, so a hover
    /// card lines up with its right edge and it grows to the left.
    @Published var trailing = false
    /// Set by the window: the strip or the dots sit in the lower half of their
    /// screen, so the hover card opens above and the bottom edge stays put.
    @Published var upward = false
    /// Set by the window: the bar spans its screen.
    @Published var barWidth: CGFloat = 1200

    init(width: CGFloat = FloatingLayout.defaultWidth, height: CGFloat? = nil, mini: Bool = false,
         chosen: KeepOnTopLayout? = nil, columnsWidth: CGFloat = FloatingLayout.defaultColumnsWidth) {
        self.width = width
        self.height = height
        self.chosen = chosen ?? (mini ? .pill : .list)
        self.columnsWidth = columnsWidth
    }

    /// Shrunk to a pill with just the counts.
    var mini: Bool {
        get { chosen == .pill }
        set { chosen = newValue ? .pill : .list }
    }

    /// The layout showing now.
    var current: KeepOnTopLayout {
        KeepOnTopLayout.effective(chosen: chosen, fullScreen: fullScreen,
                                  autoStrip: UserDefaults.standard.bool(forKey: KeepOnTopLayout.autoStripKey),
                                  kept: keptInFullScreen)
    }

    /// Picks a layout from a menu or a double-click, and remembers it.
    func choose(_ layout: KeepOnTopLayout) {
        chosen = layout
        if fullScreen { keptInFullScreen = true }
        save()
    }

    static func saved() -> FloatingLayout {
        let d = UserDefaults.standard
        let w = d.double(forKey: widthKey), h = d.double(forKey: heightKey), c = d.double(forKey: columnsKey)
        return FloatingLayout(width: w >= minSize.width ? w : defaultWidth, height: h >= minSize.height ? h : nil,
                              chosen: KeepOnTopLayout.saved(raw: d.string(forKey: layoutKey),
                                                            legacyMini: d.bool(forKey: miniKey)),
                              columnsWidth: c >= minColumnsWidth ? c : defaultColumnsWidth)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Double(width), forKey: Self.widthKey)
        d.set(Double(height ?? 0), forKey: Self.heightKey)
        d.set(Double(columnsWidth), forKey: Self.columnsKey)
        d.set(chosen.rawValue, forKey: Self.layoutKey)
        d.set(chosen == .pill, forKey: Self.miniKey)
    }
}

/// Whether another app is full screen on a display: its Space is a full-screen
/// app's, or a normal window covers the whole display (a game, say).
func fullScreenShown(on screen: NSScreen) -> Bool {
    if DisplaySpaces.isFullScreen(screen) == true { return true }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
    return windowCovers(screen.frame, primaryHeight: primary, windows: windows, me: getpid())
}

/// A normal window (layer 0, not ours, not see-through) exactly the size of a
/// display. Window bounds run from the primary display's top-left; reading
/// them needs no Screen Recording permission (only titles do).
func windowCovers(_ screen: NSRect, primaryHeight: CGFloat, windows: [[String: Any]], me: pid_t) -> Bool {
    let target = CGRect(x: screen.minX, y: primaryHeight - screen.maxY, width: screen.width, height: screen.height)
    return windows.contains { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) != me,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let bounds = (w[kCGWindowBounds as String] as? NSDictionary)
                  .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return false }
        return abs(bounds.minX - target.minX) < 1 && abs(bounds.minY - target.minY) < 1
            && abs(bounds.width - target.width) < 1 && abs(bounds.height - target.height) < 1
    }
}

/// The bar's frame: along the bottom of `area`, its full width.
func barFrame(area: NSRect, height: CGFloat) -> NSRect {
    NSRect(x: area.minX, y: area.minY, width: area.width, height: height)
}

/// A frame moved just enough to sit inside `area`; the top edge wins when
/// it is taller than the area.
func keptOnScreen(_ frame: NSRect, area: NSRect) -> NSRect {
    var r = frame
    if r.maxX > area.maxX { r.origin.x = area.maxX - r.width }
    if r.minX < area.minX { r.origin.x = area.minX }
    if r.minY < area.minY { r.origin.y = area.minY }
    if r.maxY > area.maxY { r.origin.y = area.maxY - r.height }
    return r
}

/// Which edges of the keep-on-top window a drag resizes.
struct ResizeEdges: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    static let left = ResizeEdges(rawValue: 1)
    static let right = ResizeEdges(rawValue: 2)
    static let top = ResizeEdges(rawValue: 4)
    static let bottom = ResizeEdges(rawValue: 8)

    /// The edges a point (y up) is on: within 6 pt of an edge, or within 14 pt
    /// of a corner along either side, so corners are easy to grab.
    init(at p: NSPoint, in size: NSSize, band: CGFloat = 6, corner: CGFloat = 14) {
        let nearLeft = p.x <= band, nearRight = p.x >= size.width - band
        let nearBottom = p.y <= band, nearTop = p.y >= size.height - band
        let alongSide = nearLeft || nearRight, alongEnd = nearTop || nearBottom
        var edges: ResizeEdges = []
        if nearLeft || (alongEnd && p.x <= corner) { edges.insert(.left) }
        if nearRight || (alongEnd && p.x >= size.width - corner) { edges.insert(.right) }
        if nearBottom || (alongSide && p.y <= corner) { edges.insert(.bottom) }
        if nearTop || (alongSide && p.y >= size.height - corner) { edges.insert(.top) }
        self.init(rawValue: edges.rawValue)
    }

    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch self {
        case [.top, .left]: position = .topLeft
        case [.top, .right]: position = .topRight
        case [.bottom, .left]: position = .bottomLeft
        case [.bottom, .right]: position = .bottomRight
        case .left: position = .left
        case .right: position = .right
        case .top: position = .top
        default: position = .bottom
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}

/// The frame after dragging `edges` by `delta` (screen points, y up): the
/// opposite edges stay put, and the size stays at least `minSize` and inside `limit`.
func resizedFrame(_ start: NSRect, edges: ResizeEdges, delta: NSPoint, minSize: NSSize, limit: NSRect) -> NSRect {
    var f = start
    if edges.contains(.right) {
        f.size.width = max(minSize.width, min(start.width + delta.x, limit.maxX - start.minX))
    }
    if edges.contains(.left) {
        let width = max(minSize.width, min(start.width - delta.x, start.maxX - limit.minX))
        f.origin.x = start.maxX - width
        f.size.width = width
    }
    if edges.contains(.top) {
        f.size.height = max(minSize.height, min(start.height + delta.y, limit.maxY - start.minY))
    }
    if edges.contains(.bottom) {
        let height = max(minSize.height, min(start.height - delta.y, start.maxY - limit.minY))
        f.origin.y = start.maxY - height
        f.size.height = height
    }
    return f
}

/// Lets this app's cursor show while another app is in front, through the
/// window server's private SetsCursorInBackground setting (looked up at run
/// time; if it's missing, the cursor just stays as macOS leaves it). macOS
/// otherwise ignores NSCursor.set() from a background app, and the
/// keep-on-top window never makes Limbo Tasks frontmost. Kept on only while
/// the pointer is on a resize edge, so the app never overrides other apps'
/// cursors. Turn it off only after setting the arrow: a set made while it is
/// off is ignored, which would leave a resize cursor stuck over the next app.
enum BackgroundCursor {
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias MainConnection = @convention(c) () -> Int32
    private static let apply: ((Bool) -> Void)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty"),
              let mainSymbol = dlsym(handle, "CGSMainConnectionID") else { return nil }
        let setProperty = unsafeBitCast(setSymbol, to: SetProperty.self)
        let connection = unsafeBitCast(mainSymbol, to: MainConnection.self)()
        return { on in
            _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString,
                            on ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }()
    private(set) static var allowed = false
    static var available: Bool { apply != nil }

    static func allow(_ on: Bool) {
        guard on != allowed, let apply else { return }
        allowed = on
        apply(on)
    }
}

/// Resizing for the borderless keep-on-top window: a thin band inside each
/// edge takes the drag; anywhere else clicks fall through to the rows. On the
/// band the pointer becomes the resize cursor, even while another app is in
/// front (see BackgroundCursor), without making Limbo Tasks frontmost.
final class ResizeEdgesView: NSView {
    var minSize = FloatingLayout.minSize
    /// The edges that resize: the columns' sides only, say.
    var allowed: ResizeEdges = [.left, .right, .top, .bottom]
    var onResize: (NSRect, ResizeEdges) -> Void = { _, _ in }
    var onResizeEnd: () -> Void = {}
    /// The pointer in screen points; a check can stand in for the real mouse.
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var drag: (edges: ResizeEdges, frame: NSRect, mouse: NSPoint)?
    private var showingResizeCursor = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        ResizeEdges(at: convert(point, from: superview), in: bounds.size).intersection(allowed).isEmpty ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                              .inVisibleRect], owner: self))
    }

    private func edges(_ event: NSEvent) -> ResizeEdges {
        ResizeEdges(at: convert(event.locationInWindow, from: nil), in: bounds.size).intersection(allowed)
    }

    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    /// The pointer is at `point` (this view's coordinates), or has left (nil):
    /// the resize cursor on an edge, the arrow again off it.
    func hover(at point: NSPoint?) {
        guard drag == nil else { return }
        let edges = point.map { ResizeEdges(at: $0, in: bounds.size).intersection(allowed) } ?? []
        if edges.isEmpty { endResizeCursor() } else { showResizeCursor(edges) }
    }

    private func showResizeCursor(_ edges: ResizeEdges) {
        BackgroundCursor.allow(true)
        edges.cursor.set()
        showingResizeCursor = true
    }

    /// Back to the arrow, then the background setting off (in that order).
    func endResizeCursor() {
        guard showingResizeCursor else { return }
        showingResizeCursor = false
        NSCursor.arrow.set()
        BackgroundCursor.allow(false)
    }

    override func viewDidHide() {
        super.viewDidHide()
        endResizeCursor()
    }

    override func mouseDown(with event: NSEvent) {
        let edges = edges(event)
        guard let window, !edges.isEmpty else { return }
        showResizeCursor(edges)
        drag = (edges, window.frame, mouseLocation())
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let window else { return }
        let mouse = mouseLocation()
        let limit = window.screen?.frame ?? NSScreen.main?.frame ?? .infinite
        let frame = resizedFrame(drag.frame, edges: drag.edges,
                                 delta: NSPoint(x: mouse.x - drag.mouse.x, y: mouse.y - drag.mouse.y),
                                 minSize: minSize, limit: limit)
        drag.edges.cursor.set()
        onResize(frame, drag.edges)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        onResizeEnd()
        hover(at: convert(event.locationInWindow, from: nil))   // still on an edge: keep the resize cursor
    }
}

/// A borderless panel that never takes keyboard focus from a game or video.
final class KeepOnTopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The one place Limbo takes the keyboard: typing a new tag's name. A panel
/// that takes key without making Limbo the active app, so the app you were in
/// stays in front and gets the keyboard back when it closes (Return, Esc, or
/// a click elsewhere).
final class TagPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TagPrompt: NSObject, NSWindowDelegate {
    private var panel: TagPromptPanel?

    var isShowing: Bool { panel != nil }
    /// For --gesture-check.
    var window: NSWindow? { panel }

    /// Asks for a tag name next to the pointer; `done` gets what was typed.
    private var closed: (() -> Void)?

    func show(for title: String, done: @escaping (String) -> Void, closed: (() -> Void)? = nil) {
        close()
        self.closed = closed
        let view = TagPromptView(title: title,
                                 submit: { [weak self] name in self?.close(); done(name) },
                                 cancel: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let panel = TagPromptPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // above the window
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.delegate = self
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let x = min(max(mouse.x - 16, area.minX + 8), area.maxX - size.width - 8)
        let y = min(max(mouse.y - size.height - 10, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
        let closed = self.closed
        self.closed = nil
        closed?()
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

struct TagPromptView: View {
    let title: String
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New tag for “\(title)”")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            TextField("e.g. Waiting on design", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(add)
                .onChange(of: name) { _, typed in
                    if typed.count > SessionTags.maxLength { name = String(typed.prefix(SessionTags.maxLength)) }
                }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .onExitCommand(perform: cancel)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        submit(trimmed)
    }
}

/// The keep-on-top window: above other windows, full-screen videos and games
/// included, on every Space, without taking focus. Its position is remembered,
/// and so is whether it was showing, across launches.
final class FloatingController {
    private let model: SessionModel
    private var panel: KeepOnTopPanel?
    private var host: FirstClickHostingView<FloatingView>?
    private let glow = RunningGlowView(frame: .zero)
    private var clock: Timer?
    private var preview: DispatchWorkItem?
    private var previewing: GlowPreview?
    /// Running sessions at the last update, to catch the moment the last one stops.
    private var wasRunning = 0
    /// Everything has finished and you have not opened a session since.
    private var finished = false
    private let layout = FloatingLayout.saved()
    private let status = GlowStatus()
    private let answerer = ClaudeAnswerer()
    private let answers = AnswerStatus()
    private var edges: ResizeEdgesView?
    /// While an edge is being dragged, the window follows the mouse, not the rows.
    private var resizing = false
    /// The layout last fitted, and where the window's top-left was before the
    /// bar took it to the bottom of the screen.
    private var lastShape: KeepOnTopLayout?
    private var beforeBar: NSPoint?
    private var observers: [NSObjectProtocol] = []
    private static let shownKey = "keepOnTop"
    private static let frameName = "LimboTasksKeepOnTop"

    init(model: SessionModel) { self.model = model }

    var wasShown: Bool { UserDefaults.standard.bool(forKey: Self.shownKey) }

    func toggle() { model.pinned ? hide() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.pinned = true
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        model.now = Date()
        clock?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.model.now = Date()
            self?.checkFullScreen()
            self?.fitToContent()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        checkFullScreen()
        fitToContent()
        panel.orderFrontRegardless()
        updateGlow()
    }

    /// The glow: amber while a session newly needs you, else the chosen effect
    /// while any session runs; a green flash when the last one stops. A choice
    /// just made in the sparkle menu shows for 4 seconds.
    func updateGlow() {
        glow.configure(style: .saved, color: .saved)
        let board = Board(rows: model.rows, now: model.now)
        // A running session you put on hold starts no glow, and its end no green.
        let running = board.running.filter { !$0.tags.contains(SessionTags.onHold) }.count
        let decision = glowDecision(pinned: model.pinned, running: running, wasRunning: wasRunning,
                                    finished: finished, needsYou: !model.freshNeedsYou(board).isEmpty,
                                    previewing: previewing, needsYouOn: GlowSignal.needsYou,
                                    doneOn: GlowSignal.doneFlash)
        wasRunning = model.pinned ? running : 0
        finished = decision.finished
        if decision.flash { glow.celebrate() }
        glow.setMode(decision.mode)
        if status.mode != decision.mode { status.mode = decision.mode }
        if status.previewing != (previewing != nil) { status.previewing = previewing != nil }
    }

    /// Got it: the amber and the green stop until something new happens,
    /// without opening any session.
    private func acknowledgeGlow() {
        finished = false
        model.acknowledge(model.freshNeedsYou(Board(rows: model.rows, now: model.now)))
        updateGlow()
    }

    private func glowChanged(_ what: GlowPreview) {
        preview?.cancel()
        previewing = nil
        switch what {
        case .running, .needsYou: previewing = what
        case .done:
            previewing = .done
            glow.celebrate()
        case .none: break
        }
        updateGlow()
        guard previewing != nil else { return }
        let done = DispatchWorkItem { [weak self] in
            self?.previewing = nil
            self?.updateGlow()
        }
        preview = done
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: done)
    }

    func motionChanged() { glow.motionChanged() }

    /// You opened a session: the green "all finished" window has been seen.
    func sessionOpened() {
        finished = false
        updateGlow()
    }

    var glowState: [String: Any] {
        let board = Board(rows: model.rows, now: model.now)
        return glow.state.merging(["previewing": previewing.map { "\($0)" } ?? "", "finished": finished,
                                   "freshNeedsYou": model.freshNeedsYou(board).map(\.title)]) { a, _ in a }
    }

    func hide() {
        preview?.cancel()
        previewing = nil
        wasRunning = 0
        glow.setMode(.off)
        edges?.endResizeCursor()
        panel?.orderOut(nil)
        model.pinned = false
        UserDefaults.standard.set(false, forKey: Self.shownKey)
        clock?.invalidate()
        clock = nil
    }

    /// Resizes to the content, keeping the top edge where it is and the window
    /// on its screen; the bar instead spans the bottom of the screen.
    func fitToContent() {
        guard model.pinned else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let host = self.host else { return }
            self.updateGlow()
            guard !self.resizing else { return }
            let shape = self.layout.current
            self.glow.cornerRadius = shape.glowCorner
            self.edges?.isHidden = shape.resizable.isEmpty
            self.edges?.allowed = shape.resizable
            self.edges?.minSize = shape == .columns
                ? NSSize(width: FloatingLayout.minColumnsWidth, height: FloatingLayout.minSize.height)
                : FloatingLayout.minSize
            let screen = panel.screen ?? NSScreen.main
            let full = screen?.frame ?? panel.frame
            // In full screen the whole display is free; otherwise not the menu bar or the Dock.
            let area = self.layout.fullScreen ? full : (screen?.visibleFrame ?? full)
            let shapeChanged = self.lastShape != shape
            if shape == .bar && self.lastShape != .bar {
                self.beforeBar = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            } else if shape != .bar && self.lastShape == .bar, let corner = self.beforeBar {
                panel.setFrameTopLeftPoint(corner)   // back where it was before the bar
            }
            self.lastShape = shape
            if shape == .bar {
                guard self.layout.barWidth == area.width else {
                    self.layout.barWidth = area.width   // the bar refits at its new width
                    return
                }
                let frame = barFrame(area: area, height: host.fittingSize.height)
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                return
            }
            self.updateAnchors(shapeChanged: shapeChanged)
            var frame = anchoredFrame(panel.frame, size: host.fittingSize, screen: full)
            // A card opening above: the bottom stays put (not after a change of layout, which keeps the top).
            if self.layout.upward && !shapeChanged { frame.origin.y = panel.frame.minY }
            frame = keptOnScreen(frame, area: area)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
    }

    /// Which way the window grows: away from the side nearer its screen's
    /// edge, and for the strip and the dots in the lower half, upward. Taken
    /// from the edge the line of chips sits on, so an open card never flips it.
    private func updateAnchors(shapeChanged: Bool = false) {
        guard let panel else { return }
        let full = (panel.screen ?? NSScreen.main)?.frame ?? panel.frame
        let shape = layout.current
        let line = layout.upward && !shapeChanged ? panel.frame.minY + 16 : panel.frame.maxY - 16
        let upward = (shape == .strip || shape == .dots) && line < full.midY
        let trailing = panel.frame.midX > full.midX
        if layout.trailing != trailing { layout.trailing = trailing }
        if layout.upward != upward { layout.upward = upward }
    }

    /// A layout picked, or the full-screen switch flipped.
    private func layoutChanged() {
        checkFullScreen()
        fitToContent()
    }

    /// Whether another app is full screen on the window's display, when that
    /// matters: for "Strip while an app is full screen", and for where the bar sits.
    func checkFullScreen() {
        guard model.pinned, let panel else { return }
        let wanted = UserDefaults.standard.bool(forKey: KeepOnTopLayout.autoStripKey) || layout.chosen == .bar
        let on = wanted && (panel.screen ?? NSScreen.main).map { fullScreenShown(on: $0) } == true
        guard layout.fullScreen != on else { return }
        layout.fullScreen = on
        if !on { layout.keptInFullScreen = false }
        fitToContent()
    }

    /// Checks again when the Space or the app in front changes (going full
    /// screen is a new Space), and once the slide into it has finished.
    private func watchFullScreen(_ panel: NSPanel) {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkFullScreen()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.checkFullScreen() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.checkFullScreen()
                self?.fitToContent()
            })
        // Dragged: which way it grows from here; onto another display: check that one.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                self?.updateAnchors()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main) { [weak self] _ in
                self?.checkFullScreen()
                self?.fitToContent()
            })
    }

    /// Side edges change only the width, so the height keeps fitting the rows;
    /// the top or bottom edge sets the height too, and the list scrolls in it.
    private func userResized(to frame: NSRect, edges: ResizeEdges) {
        resizing = true
        if layout.current == .columns {
            layout.columnsWidth = frame.width
        } else {
            if !edges.isDisjoint(with: [.top, .bottom]) { layout.height = frame.height }
            layout.width = frame.width
        }
        panel?.setFrame(frame, display: true)
    }

    private func resizeEnded() {
        resizing = false
        layout.save()
        fitToContent()
    }

    /// Turns Claude's accessibility tree off now, for quitting.
    func shutdownAnswerer() { answerer.shutdown() }

    /// A card's button with "Answer from Cards" on: pressed in Claude for you.
    private func answer(_ row: Row, _ label: String) {
        guard let ask = row.card?.ask, let session = row.link, !answerer.busy else { return }
        model.markOpened(row)
        answers.answering = AnswerStatus.Answering(row: row.id, label: label)
        answerer.answer(session: session, ask: ask, button: label,
                        transcript: row.card?.transcript) { [weak self] outcome in
            guard let self else { return }
            self.answers.answering = nil
            if case .opened(let why) = outcome { self.answers.note(row.id, "Opened in Claude: \(why)") }
        }
    }

    private func makePanel() -> KeepOnTopPanel {
        let view = FloatingView(model: model,
                                open: { [weak self] row in
                                    guard row.openURL != nil else { return }
                                    self?.model.markOpened(row)
                                    openRow(row)
                                },
                                unpin: { [weak self] in self?.hide() },
                                refit: { [weak self] in self?.fitToContent() },
                                glowChanged: { [weak self] in self?.glowChanged($0) },
                                acknowledge: { [weak self] in self?.acknowledgeGlow() },
                                layoutChanged: { [weak self] in self?.layoutChanged() },
                                glow: glow,
                                layout: layout,
                                status: status,
                                answer: { [weak self] row, label in self?.answer(row, label) },
                                warm: { [weak self] in self?.answerer.warm() },
                                answers: answers)
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        let panel = KeepOnTopPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // The rows, with the resize band on top of them along the edges.
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        let edges = ResizeEdgesView(frame: content.bounds)
        edges.autoresizingMask = [.width, .height]
        edges.onResize = { [weak self] frame, moved in self?.userResized(to: frame, edges: moved) }
        edges.onResizeEnd = { [weak self] in self?.resizeEnded() }
        edges.isHidden = layout.current.resizable.isEmpty
        edges.allowed = layout.current.resizable
        content.addSubview(host)
        content.addSubview(edges)
        self.edges = edges
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .statusBar                      // above full-screen windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - 12))
        }
        panel.setFrameAutosaveName(Self.frameName)
        self.host = host
        watchFullScreen(panel)
        return panel
    }
}

// MARK: - Answering from a card (Accessibility)

/// What answering from a card is doing, for the cards to show.
final class AnswerStatus: ObservableObject {
    struct Answering: Equatable { let row: String; let label: String }
    @Published var answering: Answering?
    /// Why a click only opened the session, shown on its card for a few seconds.
    @Published var notes: [String: String] = [:]

    func note(_ row: String, _ text: String) {
        notes[row] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.notes[row] == text { self?.notes[row] = nil }
        }
    }
}

/// Presses a card's button in the Claude app, so you can answer from here.
/// Off unless "Answer from Cards" is on (the window header's right-click menu),
/// and it needs the Accessibility permission. Claude offers no other way in:
/// its session links carry no message and it runs no local API. So this opens
/// the session in Claude, waits for its next-step box, and presses a button
/// only when the question on screen matches the card word for word and the
/// button right after it has exactly that label. On any doubt it presses
/// nothing and leaves the session open. After an answer it brings back the app
/// you were in.
/// Which Space each display shows, and the window in front on it, so a display
/// that Claude's full-screen Space took over can be put back. The window
/// server's Space calls are private: read through dlsym, and nothing happens
/// without them.
enum DisplaySpaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let handle = dlopen(nil, RTLD_NOW)
    private static let connection: Int32? = dlsym(handle, "CGSMainConnectionID")
        .map { unsafeBitCast($0, to: MainConnection.self)() }
    private static let currentSpace: CurrentSpace? = dlsym(handle, "CGSManagedDisplayGetCurrentSpace")
        .map { unsafeBitCast($0, to: CurrentSpace.self) }
    private static let windowNumber: WindowNumber? = dlsym(handle, "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: WindowNumber.self) }
    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    private static let spaceType: SpaceType? = (dlsym(handle, "CGSSpaceGetType") ?? dlsym(handle, "SLSSpaceGetType"))
        .map { unsafeBitCast($0, to: SpaceType.self) }

    /// Whether a display shows a full-screen app's own Space (type 4), or nil
    /// when the window server won't say.
    static func isFullScreen(_ screen: NSScreen) -> Bool? {
        guard let connection, let spaceType,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let uuid = CFUUIDCreateString(nil, cfUUID) as String?,
              let space = space(of: uuid) else { return nil }
        return spaceType(connection, space) == 4
    }

    /// One display when you clicked: its Space, and the app and window in front there.
    struct Shown {
        let uuid: String
        let space: UInt64
        let pid: pid_t?
        let window: AXUIElement?
    }

    static func space(of uuid: String) -> UInt64? {
        guard let connection, let currentSpace else { return nil }
        let id = currentSpace(connection, uuid as CFString)
        return id == 0 ? nil : id
    }

    /// Every display's Space and front window (not Limbo's, not `skip`).
    static func snapshot(skip: pid_t) -> [Shown] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let me = getpid()
        return ids.prefix(Int(count)).compactMap { display -> Shown? in
            guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
                  let uuid = CFUUIDCreateString(nil, cfUUID) as String?,
                  let space = space(of: uuid) else { return nil }
            let frame = CGDisplayBounds(display)
            // The front window filling most of this display (front to back in the list).
            let front = list.first { w in
                guard (w[kCGWindowLayer as String] as? Int) == 0,
                      let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me, pid != skip,
                      let bounds = (w[kCGWindowBounds as String] as? NSDictionary)
                          .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
                else { return false }
                return frame.contains(CGPoint(x: bounds.midX, y: bounds.midY))
                    && bounds.width * bounds.height >= frame.width * frame.height / 4
            }
            let pid = front?[kCGWindowOwnerPID as String] as? pid_t
            let number = front?[kCGWindowNumber as String] as? CGWindowID
            return Shown(uuid: uuid, space: space, pid: pid, window: pid.flatMap { axWindow(pid: $0, number: number) })
        }
    }

    /// The app's accessibility element for a window, while it is on screen.
    private static func axWindow(pid: pid_t, number: CGWindowID?) -> AXUIElement? {
        guard let number, let windowNumber else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            var id: CGWindowID = 0
            return windowNumber(window, &id) == .success && id == number
        }
    }

    /// Brings a window and its app to the front; macOS shows its Space.
    static func raise(_ window: AXUIElement, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}

final class ClaudeAnswerer {
    enum Outcome: Equatable {
        case answered
        case opened(String)     // only opened the session, and why
    }

    static let enabledKey = "answerFromCards"
    static let claudeBundleId = "com.anthropic.claudefordesktop"
    private struct Node { let role: String; let label: String; let element: AXUIElement }
    private let queue = DispatchQueue(label: "com.maheshauti.limbo-tasks.answer", qos: .userInitiated)
    private(set) var busy = false

    /// The steps of one answer, each with the time since the click.
    final class Log {
        let start = Date()
        private(set) var lines: [String] = []
        func add(_ line: String) { lines.append(String(format: "%5.2f s  ", Date().timeIntervalSince(start)) + line) }
    }

    // Claude's window content (Chromium) builds its accessibility tree only when
    // asked, and costs Claude some work while it is on: on from when the pointer
    // reaches a card, or a click, until a few seconds after. Queue only.
    private var tree: AXUIElement?
    private var treePid: pid_t = 0
    private var treeSince = Date.distantPast
    private var treeUntil = Date.distantPast
    private var treeWasOn = false
    private static let keepTree: TimeInterval = 12

    /// The pointer is over a card: start Claude's tree now, so it has settled
    /// by the time a button is clicked.
    func warm() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), AXIsProcessTrusted() else { return }
        queue.async { _ = self.openTree() }
    }

    /// Turns the tree off now, for quitting.
    func shutdown() {
        queue.sync { self.treeUntil = .distantPast; self.closeTree() }
    }

    /// Claude's app element, its tree on for `keepTree` seconds more.
    private func openTree() -> AXUIElement? {
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleId).first
        else { return nil }
        if tree == nil || treePid != claude.processIdentifier {
            let app = AXUIElementCreateApplication(claude.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 1)
            treeWasOn = attribute(app, "AXManualAccessibility") as? Bool == true
            if !treeWasOn { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
            tree = app
            treePid = claude.processIdentifier
            treeSince = Date()
        }
        holdTree()
        return tree
    }

    private func holdTree() {
        treeUntil = Date().addingTimeInterval(Self.keepTree)
        queue.asyncAfter(deadline: .now() + Self.keepTree + 0.2) { self.closeTree() }
    }

    private func closeTree() {
        guard let app = tree, Date() >= treeUntil else { return }
        if !treeWasOn { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse) }
        tree = nil
    }

    /// Shows the system's request for the permission when it is missing.
    @discardableResult static func requestPermission() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Calls `done` on the main queue.
    func answer(session: String, ask: String, button: String, transcript: String?,
                done: @escaping (Outcome) -> Void) {
        guard !busy, isSessionId(session), let url = URL(string: "claude://claude.ai/epitaxy/\(session)") else { return }
        guard AXIsProcessTrusted() else {
            Self.requestPermission()
            NSWorkspace.shared.open(url)
            return done(.opened("allow Limbo Tasks in Privacy & Security, Accessibility"))
        }
        busy = true
        let previous = NSWorkspace.shared.frontmostApplication
        let log = Log()
        queue.async {
            log.add("\(log.start) answer “\(button)”")
            let outcome = self.press(session: session, url: url, ask: ask, button: button, transcript: transcript,
                                     previous: previous, log: log)
            self.holdTree()
            log.add("outcome: \(outcome)")
            Self.writeLog(log.lines)
            DispatchQueue.main.async {
                self.busy = false
                done(outcome)
            }
        }
    }

    /// The steps of the last answer, without any message text, for finding out
    /// why one did not land: ~/Library/Caches/<label>.answer.log.
    static let logFile = Paths.home.appendingPathComponent("Library/Caches/\(LoginItem.label).answer.log")
    private static func writeLog(_ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n").write(to: logFile, atomically: true, encoding: .utf8)
    }

    /// Claude's page says which session it shows (https://claude.ai/epitaxy/<id>):
    /// a press happens only while that is the session being answered. Claude
    /// acts on a press only while its window is visible (behind other windows,
    /// or on a hidden full-screen Space, its page is paused). So: if it already
    /// shows the session and some of its window is on screen, the press happens
    /// in the background and nothing moves. Otherwise Claude comes to the front
    /// (switching sessions through its link if needed), the press happens, and
    /// the app you were in comes back. Anything unexpected leaves Claude in
    /// front on that session, for you to answer.
    private func press(session: String, url: URL, ask: String, button: String, transcript: String?,
                       previous: NSRunningApplication?, log: Log) -> Outcome {
        let open = { DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) } }
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleId).first,
              let app = openTree() else {
            open()
            return .opened("Claude was not running")
        }
        // What each display shows, to put back if Claude's Space takes one over.
        let shown = claudeIsHiddenSnapshot(claude: claude)
        // The window you were in, to put back in front afterwards.
        let yourWindow = previous.flatMap { previous -> AXUIElement? in
            guard previous.bundleIdentifier != Self.claudeBundleId else { return nil }
            let element = AXUIElementCreateApplication(previous.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            return attribute(element, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        }
        var onScreen = scan(app)
        for _ in 0..<30 where onScreen.count < 50 {     // the tree takes a moment to build
            Thread.sleep(forTimeInterval: 0.1)
            onScreen = scan(app)
        }
        let claudeInFront = previous?.bundleIdentifier == Self.claudeBundleId
        let shownBefore = onScreen.count >= 50 ? currentSession(app) : nil
        let visible = claudeInFront || Self.windowVisible(pid: claude.processIdentifier)
        log.add("before: \(onScreen.count) texts and buttons; Claude in front: \(claudeInFront); visible: \(visible); showing it already: \(shownBefore == session); tree on for \(String(format: "%.1f", Date().timeIntervalSince(treeSince))) s")

        // Quietly: shown already and visible, Claude stays where it is.
        if shownBefore == session && visible {
            let outcome = pressShown(session: session, ask: ask, button: button, transcript: transcript, app: app,
                                     attempts: claudeInFront ? 2 : 1, switched: false, log: log)
            if outcome == .answered || claudeInFront || outcome != .opened(Self.notTaken) {
                if outcome != .answered { open() }
                return outcome
            }
            log.add("the background press did not land: bringing Claude forward")
        }

        // Claude has to be in front for the press to count.
        if currentSession(app) != session {
            open()                                       // switches the session and brings Claude forward
        } else if !claude.isActive, let bundle = claude.bundleURL {
            DispatchQueue.main.sync {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
            }
        }
        var ready = false
        for _ in 0..<120 {                               // up to 6 s, including a Space switch
            Thread.sleep(forTimeInterval: 0.05)
            if claude.isActive && currentSession(app) == session { ready = true; break }
        }
        log.add("Claude in front on the session: \(ready)")
        let frontSince = Date()
        guard ready else {
            open()
            return .opened("Claude did not switch to the session")
        }
        let outcome = pressShown(session: session, ask: ask, button: button, transcript: transcript, app: app,
                                 attempts: 2, switched: true, frontSince: frontSince, log: log)
        guard outcome == .answered else {
            open()                                       // in front, on the session, for you to answer
            return outcome
        }
        if claudeInFront {
            // You were reading another session in Claude: back to it.
            if let shownBefore, shownBefore != session, isSessionId(shownBefore),
               let back = URL(string: "claude://claude.ai/epitaxy/\(shownBefore)") {
                DispatchQueue.main.sync { _ = NSWorkspace.shared.open(back) }
                log.add("switched Claude back to the session it showed")
            }
        } else {
            restore(shown, log: log)
            giveBack(previous, window: yourWindow, log: log)
        }
        return .answered
    }

    static let notTaken = "Claude did not take the press"

    /// Whether some of Claude's main window is on screen and not covered by
    /// other windows (sampled on a grid). A window on a hidden full-screen
    /// Space is not on screen at all.
    static func windowVisible(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        func bounds(_ w: [String: Any]) -> CGRect? {
            (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
        guard let index = list.firstIndex(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                      && (bounds($0)?.width ?? 0) > 300 && (bounds($0)?.height ?? 0) > 200 }),
              let main = bounds(list[index]) else { return false }
        let me = getpid()
        let above = list[..<index].filter {
            let owner = $0[kCGWindowOwnerPID as String] as? pid_t
            return owner != pid && owner != me && (($0[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05
        }.compactMap(bounds)
        var uncovered = 0
        for i in 0..<16 {
            for j in 0..<10 {
                let point = CGPoint(x: main.minX + (CGFloat(i) + 0.5) * main.width / 16,
                                    y: main.minY + (CGFloat(j) + 0.5) * main.height / 10)
                if !above.contains(where: { $0.contains(point) }) { uncovered += 1 }
            }
        }
        return uncovered >= 3
    }

    /// With Claude showing the session: wait for its box to settle, press the
    /// button, and confirm the answer landed.
    private func pressShown(session: String, ask: String, button: String, transcript: String?, app: AXUIElement,
                            attempts: Int, switched: Bool, frontSince: Date? = nil, log: Log) -> Outcome {
        // Press only a button that stays the same element for a moment: right
        // after a switch, or while the tree is new, the page is still being
        // drawn and a press on it can be lost. A look takes about 0.15 s.
        // After a switch, Claude ignores a press for a moment after it comes to
        // the front (seen lost at 0.5 s, taken from 0.8 s): a second in front,
        // and two looks agreeing. Its page waking up counts toward that.
        let settle: TimeInterval = switched ? 0.1 : (Date().timeIntervalSince(treeSince) < 1.5 ? 0.4 : 0.1)
        let inFrontFor: TimeInterval = switched ? 1.0 : 0
        var last: AXUIElement?
        var firstSeen = Date()
        var questionSeen = false
        let deadline = Date().addingTimeInterval(7)
        var look = 0
        var looks: [String] = []        // per look: when, how long, texts and buttons, and what it found
        defer { if !looks.isEmpty { log.add("looks: " + looks.joined(separator: ", ")) } }
        while Date() < deadline {
            look += 1
            if look > 1 { Thread.sleep(forTimeInterval: 0.08) }
            let lookStart = Date()
            guard currentSession(app) == session else { last = nil; looks.append("\(look) other session"); continue }
            let nodes = scan(app)
            let found = liveButton(ask, button, in: nodes)
            looks.append(String(format: "%d @%.2f %dms %dn %@", look, lookStart.timeIntervalSince(log.start),
                                Int(Date().timeIntervalSince(lookStart) * 1000), nodes.count,
                                found == nil ? "none" : (last.map { CFEqual($0, found!.element) } == true ? "same" : "new")))
            let asked = questions(ask, in: nodes)
            if !asked.isEmpty { questionSeen = true }
            // Claude keeps the questions of answered boxes in the conversation,
            // without their buttons: the live box is the copy that has the button.
            guard let target = found else {
                if let q = asked.last, Date().addingTimeInterval(0.3) >= deadline {
                    log.add("look \(look): \(asked.count) copies of the question; buttons after the last: "
                            + buttons(after: q, in: nodes).map { "“\($0.label.prefix(30))”" }.joined(separator: ", "))
                }
                last = nil
                continue
            }
            if let previousLook = last, CFEqual(previousLook, target.element) {
                guard Date().timeIntervalSince(firstSeen) >= settle,
                      Date().timeIntervalSince(frontSince ?? .distantPast) >= inFrontFor else { continue }
            } else {
                last = target.element
                firstSeen = Date()
                continue
            }
            log.add("look \(look): settled")
            let mark = transcript.flatMap { fileStamp($0)?.size }
            for attempt in 1...attempts {
                guard currentSession(app) == session else { return .opened("Claude moved to another session") }
                var element: AXUIElement? = target.element
                if attempt > 1 { element = liveButton(ask, button, in: scan(app))?.element }
                guard let element else {
                    log.add("attempt \(attempt): the button is gone")
                    return .answered
                }
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                log.add("attempt \(attempt): press \(result == .success ? "ok" : "error \(result.rawValue)")")
                guard result == .success else { return .opened(Self.notTaken) }
                switch confirm(ask: ask, button: button, app: app, transcript: transcript, mark: mark,
                               within: attempt == 1 ? 1.5 : 5, log: log) {
                case .yes: return .answered
                case .unknown: return .opened("the box did not change after the press")
                case .no: continue            // the transcript shows nothing arrived: try once more
                }
            }
            return .opened(Self.notTaken)
        }
        log.add(questionSeen ? "the button never showed next to the question" : "the question did not show")
        return .opened(questionSeen ? "its button was not next to the question" : "the question did not show in Claude")
    }

    /// The button right after a copy of the question, the newest copy first.
    private func liveButton(_ ask: String, _ button: String, in nodes: [Node]) -> Node? {
        for q in questions(ask, in: nodes).reversed() {
            if let hit = buttons(after: q, in: nodes).first(where: { Self.isButton($0.label, button) }) { return hit }
        }
        return nil
    }

    /// The session id in Claude's page address, if it shows one.
    private func currentSession(_ app: AXUIElement) -> String? {
        var stack = windows(app).reversed().map { ($0, 0) }
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 400 {
            visited += 1
            if (attribute(element, kAXRoleAttribute) as? String) == "AXWebArea",
               let url = attribute(element, "AXURL") as? URL, url.host == "claude.ai",
               url.pathComponents.count == 3, url.pathComponents[1] == "epitaxy" {
                let id = url.pathComponents[2]
                return isSessionId(id) ? id : nil
            }
            if depth < 14, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children.reversed() { stack.append((child, depth + 1)) }
            }
        }
        return nil
    }

    /// Brings back the app you were in.
    /// The displays' Spaces and front windows, read only when Claude's window
    /// is not on screen (so it will have to come forward).
    private func claudeIsHiddenSnapshot(claude: NSRunningApplication) -> [DisplaySpaces.Shown] {
        Self.windowVisible(pid: claude.processIdentifier) ? [] : DisplaySpaces.snapshot(skip: claude.processIdentifier)
    }

    /// A display that now shows another Space than when you clicked (Claude's,
    /// full screen) goes back: its front window then is raised, which makes
    /// macOS show that window's Space again.
    private func restore(_ shown: [DisplaySpaces.Shown], log: Log) {
        for display in shown {
            guard let now = DisplaySpaces.space(of: display.uuid), now != display.space else { continue }
            guard let pid = display.pid, let window = display.window else {
                log.add("a display stays on Claude's Space: no window to bring back there")
                continue
            }
            DisplaySpaces.raise(window, pid: pid)
            var back = false
            for _ in 0..<24 {
                Thread.sleep(forTimeInterval: 0.05)
                if DisplaySpaces.space(of: display.uuid) == display.space { back = true; break }
            }
            log.add(back ? "a display back on its Space" : "a display did not go back to its Space")
        }
    }

    /// Puts the app and window you were in back in front (macOS switches back
    /// to its Space), and checks that it is. Through Accessibility first: a
    /// request from an app in the background to open another can be ignored.
    private func giveBack(_ previous: NSRunningApplication?, window: AXUIElement?, log: Log) {
        guard let previous, previous.bundleIdentifier != Self.claudeBundleId else { return }
        let name = previous.bundleIdentifier ?? "the app"
        let element = AXUIElementCreateApplication(previous.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let inFront = { DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier } }
        for attempt in 1...3 {
            if attempt < 3 {
                if let window {
                    DisplaySpaces.raise(window, pid: previous.processIdentifier)
                } else {
                    AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                }
            } else if let app = previous.bundleURL {
                DispatchQueue.main.sync {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: app, configuration: configuration)
                }
            }
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.05)
                if inFront() == previous.processIdentifier {
                    log.add("\(name) back in front (try \(attempt)\(window == nil ? ", no window to raise" : ""))")
                    return
                }
            }
        }
        log.add("could not bring back \(name); in front: \(DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier } ?? "?")")
    }

    private enum Confirmation { case yes, no, unknown }

    /// Whether the answer landed `within` so many seconds: the transcript gained a
    /// message from you with the label (checked every 0.1 s), or the box's
    /// buttons went away (every third check). `.no` only when the transcript
    /// says nothing arrived, so a second press can't answer twice.
    private func confirm(ask: String, button: String, app: AXUIElement, transcript: String?, mark: Int64?,
                         within: TimeInterval, log: Log) -> Confirmation {
        let pressed = Date()
        var tick = 0
        while Date().timeIntervalSince(pressed) < within {
            tick += 1
            Thread.sleep(forTimeInterval: 0.1)
            if let transcript, let mark, Self.sent(in: transcript, after: mark).contains(where: { Self.sameText($0, button) }) {
                log.add("confirmed by the transcript")
                return .yes
            }
            if tick % 3 == 0, liveButton(ask, button, in: scan(app)) == nil {
                log.add("confirmed by the box")
                return .yes
            }
        }
        log.add("no change in \(within) s")
        return transcript != nil && mark != nil ? .no : .unknown
    }

    /// Messages from you written to a transcript after byte `offset`.
    static func sent(in path: String, after offset: Int64) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(max(0, offset)))
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { raw -> String? in
            guard raw.starts(with: Array(#"{"parentUuid""#.utf8)),
                  let o = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
                  (o["type"] as? String) == "user", (o["isMeta"] as? Bool) != true,
                  (o["isSidechain"] as? Bool) != true else { return nil }
            let content = (o["message"] as? [String: Any])?["content"]
            if let text = content as? String { return text }
            let texts = ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: " ")
        }
    }

    /// The texts matching the question, in order.
    private func questions(_ ask: String, in nodes: [Node]) -> [Node] {
        nodes.filter { $0.role == "AXStaticText" && Self.sameText($0.label, ask) }
    }

    /// The buttons right after a question.
    private func buttons(after question: Node, in nodes: [Node]) -> [Node] {
        guard let q = nodes.firstIndex(where: { CFEqual($0.element, question.element) }) else { return [] }
        return nodes[(q + 1)...].prefix(12).filter { $0.role == "AXButton" }
    }

    /// Claude's windows. macOS lists none for an app whose (full-screen) window
    /// sits on another Space; its main or focused window may still answer.
    private func windows(_ app: AXUIElement) -> [AXUIElement] {
        var found = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if found.isEmpty {
            let extra = [attribute(app, kAXMainWindowAttribute), attribute(app, kAXFocusedWindowAttribute)]
                .compactMap { $0.map { $0 as! AXUIElement } }
                + (attribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                    .filter { (attribute($0, kAXRoleAttribute) as? String) == "AXWindow" }
            for window in extra where !found.contains(where: { CFEqual($0, window) }) { found.append(window) }
        }
        return found
    }

    /// Every window's text and buttons, in order. At most 3 s and 40,000 elements.
    private func scan(_ app: AXUIElement) -> [Node] {
        let start = Date()
        var stack = windows(app).reversed().map { ($0, 0) }
        var nodes: [Node] = []
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 40_000, Date().timeIntervalSince(start) < 3 {
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if role == "AXStaticText" || role == "AXButton" {
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .lazy.compactMap { self.attribute(element, $0) as? String }.first { !$0.isEmpty } ?? ""
                nodes.append(Node(role: role, label: label, element: element))
            }
            if depth < 90, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children.reversed() { stack.append((child, depth + 1)) }
            }
        }
        return nodes
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func normal(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The same words, ignoring case and spacing.
    static func sameText(_ a: String, _ b: String) -> Bool { !a.isEmpty && normal(a) == normal(b) }

    /// A button with exactly this label; a keyboard shortcut drawn after it is allowed.
    static func isButton(_ label: String, _ wanted: String) -> Bool {
        let l = normal(label), w = normal(wanted)
        guard !w.isEmpty, l.hasPrefix(w) else { return false }
        return l.dropFirst(w.count).allSatisfy { " ⌘⇧⌥⌃↩⏎⎋".contains($0) }
    }
}







// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let model = SessionModel()
    private let engine = SessionEngine()
    private var panel: PanelController!
    private var floating: FloatingController!
    private var expiry: DispatchSourceTimer?
    private var shownCounts: (Int, Int)?
    // The Claude mark turns while sessions run, once every 3 s. It is its own
    // image view over an empty slot in the button's image, rotated by Core
    // Animation, so the app does no work per frame. (Swapping pre-drawn images
    // 8 times a second cost about 5% of a core, measured.) It stops while the
    // screens sleep or are locked, and stays still with Reduce Motion on.
    private let markView = NSImageView()
    private var markRect: NSRect?
    private var screensAsleep = false
    private var snapshotSignal: DispatchSourceSignal?
    private let tagPrompt = TagPrompt()

    func applicationWillTerminate(_ note: Notification) {
        floating?.shutdownAnswerer()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        if let button = statusItem.button {
            markView.image = claudeMark
            markView.imageScaling = .scaleProportionallyUpOrDown
            markView.wantsLayer = true
            markView.isHidden = true
            button.addSubview(markView)
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(buttonFrameChanged), name: NSView.frameDidChangeNotification, object: button)
        }
        // kill -USR1 also saves a picture of the menu bar button, to check the
        // mark's placement without screen access.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signalSource.setEventHandler { [weak self] in self?.writeButtonSnapshot() }
        signalSource.resume()
        snapshotSignal = signalSource
        floating = FloatingController(model: model)
        model.onOpened = { [weak self] in self?.floating.sessionOpened() }
        model.onTagsChanged = { [weak self] in
            self?.updateStatusItem()
            self?.floating.fitToContent()
        }
        model.onNewTag = { [weak self] row in
            guard let self else { return }
            // From the menu bar panel Limbo is the active app: after the box,
            // the app you were in before the panel gets the keyboard back.
            let fromPanel = NSApp.isActive
            let before = self.panel.appBeforeOpening
            self.panel.close()
            self.tagPrompt.show(for: row.title, done: { [weak self] name in self?.model.addTag(named: name, to: row) },
                                closed: {
                                    guard fromPanel else { return }
                                    if let before, !before.isTerminated { before.activate() } else { NSApp.deactivate() }
                                })
        }
        model.onVisibilityChange = { [weak self] in
            guard let self else { return }
            self.engine.setActivityWanted(self.model.panelOpen || self.model.pinned)
        }
        panel = PanelController(model: model, pin: { [weak self] in self?.floating.toggle() }) { [weak self] in
            self?.engine.refresh()
        }
        updateStatusItem()
        engine.onRows = { [weak self] rows in
            self?.model.setRows(rows)
            self?.updateStatusItem()
            self?.floating.fitToContent()
        }
        engine.onArchived = { [weak self] ids in self?.model.forgetArchived(ids) }
        if floating.wasShown { floating.show() }
        // Answer from Cards is on but the permission is missing (say, after a reset): ask again.
        if UserDefaults.standard.bool(forKey: ClaudeAnswerer.enabledKey) && !AXIsProcessTrusted() {
            ClaudeAnswerer.requestPermission()
        }
        engine.enableStatsSignal()
        engine.start()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(motionSettingChanged),
                              name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screensSlept), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screensWoke), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func screensSlept() {
        screensAsleep = true
        updateSpinner()
    }

    @objc private func screensWoke() {
        screensAsleep = false
        updateSpinner()
    }

    @objc private func motionSettingChanged() {
        updateSpinner()
        floating.motionChanged()
    }

    @objc private func buttonFrameChanged() {
        placeMark()
    }

    /// Puts the mark view over its slot. The button draws its image centred.
    private func placeMark() {
        guard let button = statusItem.button, let image = button.image, let slot = markRect else {
            markView.isHidden = true
            return
        }
        let bounds = button.bounds
        let origin = NSPoint(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2)
        let frame = button.backingAlignedRect(slot.offsetBy(dx: origin.x, dy: origin.y), options: .alignAllEdgesNearest)
        markView.frame = frame
        markView.isHidden = false
        // Rotate about the centre: AppKit places a view's layer by its corner.
        if let layer = markView.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
        }
    }

    /// Starts or stops the menu bar animation to match the running count.
    private func updateSpinner() {
        let running = shownCounts?.1 ?? 0
        let spin = running > 0 && !screensAsleep && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        spinStats.set(spinning: spin)
        guard let layer = markView.layer else { return }
        if !spin {
            layer.removeAnimation(forKey: "spin")
            return
        }
        guard layer.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi              // clockwise
        turn.duration = 3
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        // A slow turn needs few frames; this keeps the window server's work small.
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        layer.add(turn, forKey: "spin")
    }

    private func writeButtonSnapshot() {
        guard let button = statusItem.button,
              let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
        button.cacheDisplay(in: button.bounds, to: rep)
        let url = Paths.home.appendingPathComponent("Library/Caches/\(LoginItem.label).menubar.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        // And the keep-on-top window's glow.
        if let json = try? JSONSerialization.data(withJSONObject: floating.glowState, options: [.sortedKeys]) {
            try? json.write(to: Paths.home.appendingPathComponent("Library/Caches/\(LoginItem.label).glow.json"))
        }
    }

    @objc private func didWake() {
        model.wakeDue()
        engine.refresh()
        updateStatusItem()
    }

    private func updateStatusItem() {
        let now = Date()
        // Claude's sessions only: ChatGPT's and Cursor's threads are read only while a panel shows.
        let board = Board(rows: model.rows.filter { !$0.fromOtherApp }, now: now)
        let counts = (board.yourTurn.count, board.running.count)
        if shownCounts.map({ $0 != counts }) ?? true {
            shownCounts = counts
            let drawn = statusImage(needYou: counts.0, running: counts.1, drawMark: false)
            statusItem.button?.image = drawn.image
            markRect = drawn.markRect
            statusItem.button?.layoutSubtreeIfNeeded()
            placeMark()
            updateSpinner()
            let text = "\(counts.0) waiting for you, \(counts.1) running"
            statusItem.button?.toolTip = "Claude sessions: \(text)"
            statusItem.button?.setAccessibilityLabel("Claude sessions: \(text)")
        }
        // Wake once when the oldest "your turn" session crosses the 3-day line, so
        // the count stays right without polling.
        expiry?.cancel()
        expiry = nil
        if let next = board.yourTurn.filter({ !$0.terminal })
            .map({ $0.since.addingTimeInterval(Board.recentLimit) }).min() {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + max(1, next.timeIntervalSince(now) + 1), leeway: .seconds(60))
            timer.setEventHandler { [weak self] in self?.updateStatusItem() }
            timer.resume()
            expiry = timer
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        panel.toggle(from: button)
    }
}

// MARK: - Checks without the screen

func footprintMB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (-1, -1) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

/// Made-up sessions that cover every state, for design checks.
func sampleRows(now: Date) -> [Row] {
    func minutesAgo(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
    return rowsInOrder([
        Row(id: "local_s1", group: .yourTurn, title: "Plan the billing export migration",
            ask: "Which of the three migration orders should I use, and is a 20-minute write freeze on Sunday night acceptable?",
            detail: "Migration plan drafted; three options compared", context: "billing-service",
            since: minutesAgo(6), link: "local_s1",
            card: TurnCard(ask: "Start with the read-only replica on Sunday night?",
                           actions: ["Yes, start Sunday", "Pick another night"],
                           recap: "The migration plan compares three orders; replica first needs a 20-minute write freeze.",
                           reply: "**Recommendation:** replica first. It keeps the export running during the copy and needs only a 20-minute write freeze.\n\n**Other orders:** schema first is faster but blocks writes for about an hour; dual-write needs a code change first.")),
        Row(id: "local_s2", group: .yourTurn, title: "Go-live readiness",
            ask: "Answer plan section 12: first customer tenant date; OK to re-upload the dashboard if prod restarts; Slack channels for prod and dev alerts; OK to create short-lived DNS and load balancers; alert thresholds; who runs the cluster steps. Also: start the dev gate tests, and OK to create embed users on dev?",
            detail: "Cutover plan drafted; 6 decisions needed", context: "web-platform",
            since: minutesAgo(26 * 60), link: "local_s2"),
        Row(id: "local_s3", group: .yourTurn, title: "btw: give me the queries for this",
            ask: "Run the step 3 check and tell me whether it returns recent rows.",
            context: "Go-live readiness", since: minutesAgo(4 * 1440), link: "local_s3"),
        Row(id: "local_s3b", group: .yourTurn, title: "Rename the billing exports",
            ask: "Which naming scheme should the new export files use?",
            context: "billing-service", since: minutesAgo(50), link: "local_s3b", tags: [SessionTags.onHold]),
        Row(id: "local_s3c", group: .yourTurn, title: "Rotate the staging API keys",
            ask: "OK to revoke the old keys now?", context: "web-platform", since: minutesAgo(70),
            link: "local_s3c", snoozedUntil: now.addingTimeInterval(45 * 60)),
        Row(id: "local_s4", group: .running, title: "Audit traffic before the old site is shut down",
            context: "Documents", since: minutesAgo(12), link: "local_s4",
            activity: "Scanning the app logs for scope errors"),
        Row(id: "codex:sample1", group: .running, title: "Refactor the payments client", context: "payments",
            since: minutesAgo(3), link: "codex://threads/sample1", activity: "Running a command",
            lastOutput: minutesAgo(0)),
        Row(id: "pid:5", group: .running, title: "data-pipeline", context: "data-pipeline",
            since: minutesAgo(31), terminal: true, activity: "Running the nightly export",
            lastOutput: minutesAgo(14)),
        Row(id: "local_s6", group: .justFinished, title: "Fix the flaky checkout test", context: "web-app",
            since: minutesAgo(0.2), link: "local_s6",
            card: TurnCard(ask: "Commit and push this change?", actions: ["Commit and push", "Not yet"],
                           recap: "The checkout test now waits for the cart total before paying; 20 runs in a row passed.",
                           reply: "The test clicked Pay before the cart total had loaded. It now waits for the total, and 20 runs in a row passed locally. Nothing is committed yet.")),
        Row(id: "local_s7", group: .review, title: "Move dashboards to the new BI tool",
            detail: "Two schema PRs open; will validate after they merge", context: "analytics",
            since: minutesAgo(19 * 60), link: "local_s7",
            card: TurnCard(reply: "Both schema PRs are open. Once they merge, I'll point the dashboards at the new tables and compare a week of numbers."),
            tags: [SessionTags.awaitingReview]),
        Row(id: "local_s8", group: .done, title: "Chrome tabs cleanup",
            detail: "Closed 5 tabs for merged PRs; one PR still open", context: "Scratch",
            since: minutesAgo(40), link: "local_s8",
            card: TurnCard(reply: "Closed five tabs for merged PRs. One PR is still open, so its tab stays."),
            tags: ["Needs revisiting"]),
        Row(id: "local_s9", group: .done, title: "Draft the release notes for 4.2",
            detail: "Notes drafted; screenshots still needed", context: "web-app",
            since: minutesAgo(1500), link: "local_s9"),
        Row(id: "pid:10", group: .terminal, title: "documents-72", context: "Documents",
            since: minutesAgo(18 * 60), terminal: true),
    ])
}

/// --sample-apps: made-up sessions from every app Limbo reads (Claude,
/// ChatGPT, Cursor, Antigravity, Orca), for pictures of it.
func sampleAppRows(now: Date) -> [Row] {
    func minutesAgo(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
    return rowsInOrder([
        Row(id: "local_a1", group: .yourTurn, title: "Fix the flaky checkout test", ask: "Commit and push this change?",
            context: "web-app",
            since: minutesAgo(0.3), link: "local_a1",
            card: TurnCard(ask: "Commit and push this change?", actions: ["Commit and push", "Not yet"],
                           recap: "The checkout test now waits for the cart total before paying; 20 runs in a row passed.",
                           reply: "The test clicked Pay before the cart total had loaded. It now waits for the total, and 20 runs in a row passed locally.")),
        Row(id: "cursor:a2", group: .yourTurn, title: "Rename the config keys", detail: "Waiting for your approval",
            context: "settings", since: minutesAgo(2), link: cursorLinkPrefix + "a2"),
        Row(id: "local_a3", group: .running, title: "Audit traffic before the old site goes", context: "web-platform",
            since: minutesAgo(12), link: "local_a3", activity: "Scanning the app logs for scope errors",
            lastOutput: minutesAgo(0)),
        Row(id: "codex:a4", group: .running, title: "Refactor the payments client", context: "payments",
            since: minutesAgo(3), link: "codex://threads/a4", activity: "Running a command", lastOutput: minutesAgo(0)),
        Row(id: "cursor:a5", group: .running, title: "Tidy the build scripts", context: "build-tools",
            since: minutesAgo(5), link: cursorLinkPrefix + "a5", activity: "Read Makefile, build.sh",
            lastOutput: minutesAgo(0)),
        Row(id: "agy:a6", group: .running, title: "Profile the image pipeline", context: "media",
            since: minutesAgo(1.5), link: antigravityLinkPrefix + "a6", lastOutput: minutesAgo(0)),
        Row(id: "orca:a7", group: .running, title: "Home · Ada", context: "Orca", since: minutesAgo(0.5),
            link: orcaLinkPrefix + "a7", lastOutput: minutesAgo(0), agent: .claude),
        Row(id: "codex:a8", group: .done, title: "Summarize this week's PRs", context: "web-app",
            since: minutesAgo(35), link: "codex://threads/a8"),
        Row(id: "agy:a9", group: .done, title: "Free up disk space", context: "Antigravity",
            since: minutesAgo(70), link: antigravityLinkPrefix + "a9"),
    ])
}

/// --size 380x260, or 380xauto: the keep-on-top window's size in a snapshot.
func snapshotLayout() -> FloatingLayout {
    let parts = (argument(after: "--size") ?? "").split(separator: "x").map(String.init)
    let width = parts.first.flatMap(Double.init).map { CGFloat($0) } ?? FloatingLayout.defaultWidth
    let height = parts.count > 1 ? Double(parts[1]).map { CGFloat($0) } : nil
    let layout = FloatingLayout(width: width, height: height, mini: arguments.contains("--mini"),
                                chosen: argument(after: "--layout").flatMap(KeepOnTopLayout.init(rawValue:)))
    if layout.chosen == .bar { layout.barWidth = width > 600 ? width : 1200 }
    return layout
}

/// Renders the panel and the menu bar item to PNG files.
func writeSnapshot(to path: String, dark: Bool, sample: Bool, expand: Bool, limit: Int?) {
    _ = NSApplication.shared
    // --live: the real turning rings and shimmering status lines, frozen mid-animation.
    staticIndicators = !arguments.contains("--live")
    forcedHover = argument(after: "--hover-row")
    forcedHints = arguments.contains("--hint")
    let model = SessionModel()
    let rows = sample ? (arguments.contains("--sample-apps") ? sampleAppRows(now: Date()) : sampleRows(now: Date()))
                      : SessionEngine.scanOnce()
    model.setRows(limit.map { Array(rows.prefix($0)) } ?? rows)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // The running glow, frozen at --phase seconds (default 1) into its loop.
    let floating = arguments.contains("--floating")
    let glowFlags = ["--glow", "--attention", "--flash", "--done"].contains { arguments.contains($0) }
    let glow: RunningGlowView? = floating && (glowFlags
        || !Board(rows: model.rows, now: Date()).running.isEmpty) ? RunningGlowView(frame: .zero) : nil
    glow?.forceMotion = true
    // --contrast and --solid: as with Increase Contrast and Reduce Transparency;
    // --filter running|needsYou|review: a header chip chosen; --mini: the pill.
    let contrast = arguments.contains("--contrast")
    glow?.forceContrast = contrast
    if arguments.contains("--mini") { glow?.cornerRadius = 16 }
    let status = GlowStatus()
    status.mode = arguments.contains("--done") ? .done : arguments.contains("--attention") ? .needsYou
        : glow != nil && !arguments.contains("--flash") ? .running : .off
    let host: NSView = floating
        ? NSHostingView(rootView: FloatingView(model: model, open: { _ in }, unpin: {}, glow: glow,
                                               layout: snapshotLayout(), status: status,
                                               forceContrast: contrast, forceSolid: arguments.contains("--solid"),
                                               initialFilter: argument(after: "--filter").flatMap(RowFilter.init(rawValue:)),
                                               initialResponse: argument(after: "--response"),
                                               initialHover: argument(after: "--hover"))
            .padding(16).background(Color(white: dark ? 0.1 : 0.85)))
        : NSHostingView(rootView: PanelView(model: model, open: { _ in }, expandAll: expand, pin: {})
            .background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    if let glow {
        glow.freeze()
        glow.configure(style: argument(after: "--glow").flatMap(GlowStyle.init(rawValue:)) ?? .saved,
                       color: argument(after: "--tint").flatMap(GlowColor.init(rawValue:)) ?? .saved)
        // --attention: the amber needs-you glow; --flash: the green done flash.
        glow.setMode(arguments.contains("--done") ? .done : arguments.contains("--attention") ? .needsYou
                     : arguments.contains("--flash") && !arguments.contains("--glow") ? .off : .running)
        if arguments.contains("--flash") { glow.celebrate() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        glow.phase(argument(after: "--phase").flatMap(Double.init) ?? 1)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: rep)
    // The glow layer is not drawn by cacheDisplay. Screen blending (multiply
    // in light mode) puts it over the background while leaving the text about
    // as it is, close to how it shows behind the rows in the real window.
    if let glow, let layer = glow.layer?.presentation() ?? glow.layer,
       let context = NSGraphicsContext(bitmapImageRep: rep) {
        let place = glow.convert(glow.bounds, to: nil)
        context.cgContext.translateBy(x: place.minX, y: place.minY)
        context.cgContext.setBlendMode(dark ? .screen : .multiply)
        layer.render(in: context.cgContext)
        context.flushGraphics()
    }
    // cacheDisplay draws the rings and status lines as they rest; the band
    // moving across a status line it leaves out, so draw that where it sits.
    if !staticIndicators, let context = NSGraphicsContext(bitmapImageRep: rep) {
        func labels(in view: NSView) -> [ShimmerLabel] {
            view.subviews.flatMap { ($0 as? ShimmerLabel).map { [$0] } ?? labels(in: $0) }
        }
        for view in labels(in: host) {
            guard let layer = view.bandLayer.presentation() else { continue }
            let place = view.convert(view.bounds, to: nil)
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: place.minX, y: place.minY)
            layer.render(in: context.cgContext)
            context.cgContext.restoreGState()
        }
        context.flushGraphics()
    }
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))

    // The menu bar item, drawn the way a template image appears on each bar.
    let board = Board(rows: model.rows, now: Date())
    let angle = argument(after: "--angle").flatMap(Double.init).map { CGFloat($0) } ?? 0
    let bar = statusImage(needYou: board.yourTurn.count, running: board.running.count, angle: angle).image
    // Drawn at 2x so the check shows real menu bar pixels.
    let stripSize = NSSize(width: bar.size.width + 24, height: 24)
    if let strip = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(stripSize.width * 2), pixelsHigh: Int(stripSize.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
        strip.size = stripSize   // before the context, so drawing is in points
        guard let context = NSGraphicsContext(bitmapImageRep: strip) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: stripSize).fill()
        let target = NSRect(x: 12, y: 3, width: bar.size.width, height: bar.size.height)
        // A template image is drawn as a mask, tinted for the bar.
        if let cg = bar.cgImage(forProposedRect: nil, context: context, hints: nil) {
            context.cgContext.saveGState()
            context.cgContext.clip(to: target, mask: cg)
            (dark ? NSColor.white : NSColor.black).setFill()
            target.fill()
            context.cgContext.restoreGState()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        try? strip.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".bar.png"))
    }
}

/// Group and title per row, plus counts. No asks or summaries.
/// --codex-bench: what reading ChatGPT's threads costs, on this Mac's real
/// threads: the first read, then a tick with nothing new.
func runCodexBench() {
    let watcher = CodexWatcher()
    let clock = ContinuousClock()
    let first = clock.measure { watcher.refresh() }
    let ticks = 200
    let rest = clock.measure { for _ in 0..<ticks { watcher.refresh() } }
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    let look = clock.measure { _ = CodexWatcher.findServers() }
    print(String(format: "threads open in ChatGPT: %d", watcher.rows.count))
    print(String(format: "looking for ChatGPT's server (every 30 s): %.1f ms", ms(look)))
    print(String(format: "first read (finds the server, reads each thread's file): %.1f ms", ms(first)))
    print(String(format: "a tick with nothing new: %.3f ms (%.4f%% of one core at one tick every 2 s)",
                 ms(rest) / Double(ticks), ms(rest) / Double(ticks) / 2000 * 100))
}

/// --cursor-bench and --antigravity-bench: what reading an app's threads
/// costs, on this Mac's real app: the first read, a tick when nothing
/// changed, and one read of its list.
func runAppBench(_ watcher: AppThreadsWatcher, name: String) {
    let clock = ContinuousClock()
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    var found: (pid: pid_t, started: Date)?
    let look = clock.measure { found = AppThreadsWatcher.findApp(suffix: watcher.executableSuffix) }
    let first = clock.measure { watcher.refresh() }
    let ticks = 200
    let rest = clock.measure { for _ in 0..<ticks { watcher.refresh() } }
    var reading: [Row]?
    let reads = 20
    let started = found?.started ?? Date()
    let read = clock.measure {
        for _ in 0..<reads {
            switch name {
            case "Cursor":
                reading = readCursorThreads(database: watcher.database, since: Date().addingTimeInterval(-Board.window))?
                    .compactMap { cursorRow($0, cursorStarted: started) }
            case "Orca":
                reading = readOrcaThreads(database: watcher.database)?.compactMap(orcaRow)
            default:
                reading = readAntigravityConversations(database: watcher.database, since: Date().addingTimeInterval(-Board.window))?
                    .compactMap { antigravityRow($0, appStarted: started) }
            }
        }
    }
    print(found == nil ? "\(name) isn't running: no rows" : "\(name) threads shown: \(watcher.rows.count)"
          + " (\(watcher.rows.filter { $0.group == .running }.count) running)")
    print(reading == nil ? "reading the list failed" : "rows read from the list: \(reading?.count ?? 0)")
    print(String(format: "looking for \(name) (every 30 s): %.1f ms", ms(look)))
    print(String(format: "first read (finds \(name), reads its list): %.1f ms", ms(first)))
    print(String(format: "reading the list (open, query, close; only when \(name) wrote): %.2f ms", ms(read) / Double(reads)))
    print(String(format: "a tick when \(name) wrote nothing: %.3f ms (%.4f%% of one core at one tick every 2 s)",
                 ms(rest) / Double(ticks), ms(rest) / Double(ticks) / 2000 * 100))
    print("reads during \(ticks) ticks: \(max(0, watcher.reads - 1))")
}

func runDump() {
    let now = Date()
    let board = Board(rows: SessionEngine.scanOnce(), now: now)
    let groups: [(String, [Row])] = [
        ("your-turn", board.yourTurn), ("your-turn-older", board.older), ("running", board.running),
        ("just-finished", board.justFinished), ("review", board.review), ("done", board.done),
        ("terminal", board.terminal), ("on-hold", board.onHold), ("snoozed", board.snoozed),
        ("hidden", board.hidden),
    ]
    for (name, rows) in groups {
        for r in rows {
            print("\(name)\t\(String(format: "%.1f", now.timeIntervalSince(r.since) / 3600))h\t\(r.title)"
                  + (r.activity.map { "\t[\($0)]" } ?? "") + (r.fromOtherApp ? "\t(\(r.appName))" : ""))
        }
    }
    print("counts: " + groups.map { "\($0.0)=\($0.1.count)" }.joined(separator: " "))
}

/// Opens and closes the real panel `cycles` times in an off-screen window and
/// prints the process's memory after each step.
func runPanelBench(cycles: Int, reuse: Bool, real: Bool, hold: Double) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = SessionModel()
    model.setRows(real ? SessionEngine.scanOnce() : sampleRows(now: Date()))
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 32, height: 32),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    window.contentView = anchor
    window.orderFrontRegardless()
    let controller = PanelController(model: model, reuse: reuse, animates: false) {}
    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    spin(0.5)
    print(String(format: "baseline %.1f MB (%@, %@ rows)", footprintMB().now,
                 reuse ? "reuse" : "fresh", real ? "real" : "sample"))
    for i in 1...max(1, cycles) {
        controller.toggle(from: anchor, activate: false)
        spin(0.4)
        let open = footprintMB().now
        controller.close()
        spin(0.4)
        let closed = footprintMB()
        print(String(format: "cycle %2d: open %.1f MB, closed %.1f MB, peak %.1f MB", i, open, closed.now, closed.peak))
    }
    if hold > 0 {
        print("holding \(Int(hold)) s, pid \(getpid())")
        fflush(stdout)
        spin(hold)
        print(String(format: "after hold %.1f MB", footprintMB().now))
    }
    exit(0)
}

// MARK: - Entry point

let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

// Scriptable switches for the login item, so `make install-tasks` can set it.
for (flag, on) in [("--login-item-on", true), ("--login-item-off", false)] where arguments.contains(flag) {
    do {
        try LoginItem.setEnabled(on)
        print(on ? "Start at login is on: \(LoginItem.plistURL.path)" : "Start at login is off")
        exit(0)
    } catch {
        FileHandle.standardError.write("Could not change the login item: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// Checks the glow decision, the "needs you" freshness rule, the quiet rule and
/// the agent-file check. Exits 1 if any fails.
func runSelfTest() {
    var failed = 0
    func check(_ name: String, _ ok: Bool) {
        print(ok ? "pass" : "FAIL", name)
        if !ok { failed += 1 }
    }
    func decide(pinned: Bool = true, running: Int = 0, was: Int = 0, finished: Bool = false, needsYou: Bool = false,
                previewing: GlowPreview? = nil, needsYouOn: Bool = true, doneOn: Bool = true) -> (GlowMode, Bool, Bool) {
        let d = glowDecision(pinned: pinned, running: running, wasRunning: was, finished: finished, needsYou: needsYou,
                             previewing: previewing, needsYouOn: needsYouOn, doneOn: doneOn)
        return (d.mode, d.flash, d.finished)
    }
    check("last session stops: flash, then the window stays green", decide(running: 0, was: 2) == (.done, true, true))
    check("still all finished later: stays green, no new flash", decide(running: 0, was: 0, finished: true) == (.done, false, true))
    check("nothing has run: no green", decide(running: 0, was: 0) == (.off, false, false))
    check("one of two stops: no flash, still running", decide(running: 1, was: 2) == (.running, false, false))
    check("a session runs again: green ends", decide(running: 1, was: 0, finished: true) == (.running, false, false))
    check("window hidden: off, state kept", decide(pinned: false, running: 0, was: 2, finished: true) == (.off, false, true))
    check("green turned off: no flash, no green", decide(running: 0, was: 1, doneOn: false) == (.off, false, true))
    check("needs you beats running", decide(running: 1, was: 1, needsYou: true) == (.needsYou, false, false))
    check("stops and needs you: flash, amber over green", decide(running: 0, was: 1, needsYou: true) == (.needsYou, true, true))
    check("amber turned off: running shows", decide(running: 1, needsYou: true, needsYouOn: false) == (.running, false, false))
    check("previewing running beats amber", decide(needsYou: true, previewing: .running) == (.running, false, false))
    check("previewing amber with nothing going on", decide(previewing: .needsYou) == (.needsYou, false, false))
    check("previewing green with nothing going on", decide(previewing: .done) == (.done, false, false))

    let now = Date()
    let model = SessionModel()
    model.now = now
    let recent = Row(id: "a", group: .yourTurn, title: "recent", context: "", since: now.addingTimeInterval(-600))
    let old = Row(id: "b", group: .yourTurn, title: "old", context: "", since: now.addingTimeInterval(-7200))
    let board = Board(rows: [recent, old], now: now)
    check("waiting 10 min is fresh, 2 h is not", model.freshNeedsYou(board).map(\.id) == ["a"])
    model.markOpened(recent)
    check("opened from here: no longer fresh", model.freshNeedsYou(board).isEmpty)
    let askedAgain = Row(id: "a", group: .yourTurn, title: "recent", context: "", since: now.addingTimeInterval(60))
    model.now = now.addingTimeInterval(120)
    check("asks again after being opened: fresh again",
          model.freshNeedsYou(Board(rows: [askedAgain], now: model.now)).map(\.id) == ["a"])
    // Tags: kept by Limbo; On hold takes a session out of the counts.
    var tagSet = SessionTags()
    check("the presets are offered first", tagSet.known() == SessionTags.presets)
    check("a typed tag is tidied", tagSet.clean("  waiting   on  design ") == "waiting on design")
    check("a tag that differs only in case is the same tag", tagSet.clean("on HOLD") == SessionTags.onHold)
    check("an empty tag is nothing", tagSet.clean("   ") == nil)
    check("a long tag is cut to 30 characters", tagSet.clean(String(repeating: "x", count: 50))?.count == 30)
    tagSet.toggle(SessionTags.onHold, on: "local_t1")
    tagSet.add("Waiting on design", to: "local_t2")
    check("your own tags are offered after the presets", tagSet.known() == SessionTags.presets + ["Waiting on design"])
    check("only tags on sessions Limbo lists are offered", tagSet.known(among: ["local_t1"]) == SessionTags.presets)
    let heldRow = Row(id: "local_t1", group: .yourTurn, title: "t1", context: "", since: now.addingTimeInterval(-300),
                      link: "local_t1")
    let labelled = Row(id: "local_t2", group: .review, title: "t2", context: "", since: now.addingTimeInterval(-300),
                       link: "local_t2")
    let runningHeld = Row(id: "local_t3", group: .running, title: "t3", context: "", since: now.addingTimeInterval(-60),
                          link: "local_t3", tags: [SessionTags.onHold])
    let tagged = tagSet.apply(to: [heldRow, labelled, runningHeld])
    let tagBoard = Board(rows: tagged, now: now)
    check("on hold leaves Your turn for On hold", tagBoard.yourTurn.isEmpty && tagBoard.onHold.map(\.id) == ["local_t1"])
    check("another tag only labels the session",
          tagBoard.review.map(\.id) == ["local_t2"] && tagged[1].tags == ["Waiting on design"])
    check("a running session on hold still shows as running", tagBoard.running.map(\.id) == ["local_t3"])
    check("on hold: no amber glow", model.freshNeedsYou(tagBoard).isEmpty)
    tagSet.toggle(SessionTags.onHold, on: "local_t1")
    check("choosing it again removes it", tagSet.byId["local_t1"] == nil)
    check("archiving a session in Claude drops its tags",
          tagSet.forget(["local_t2", "local_x"]) && tagSet.byId.isEmpty && !tagSet.forget(["local_t2"]))
    check("a terminal session can't be tagged",
          !SessionTags.taggable(Row(id: "pid:9", group: .terminal, title: "t", context: "", since: now, terminal: true)))

    var seenInClaude = askedAgain
    seenInClaude.seen = now.addingTimeInterval(90)
    check("opened in Claude since it asked: no longer fresh",
          model.freshNeedsYou(Board(rows: [seenInClaude], now: model.now)).isEmpty)

    let running = Row(id: "r", group: .running, title: "r", context: "", since: now.addingTimeInterval(-3600),
                      lastOutput: now.addingTimeInterval(-660))
    check("11 min without output is quiet", (running.quiet(now: now) ?? 0) >= 600)
    check("5 min without output is not", Row(id: "r", group: .running, title: "r", context: "", since: now,
                                             lastOutput: now.addingTimeInterval(-300)).quiet(now: now) == nil)
    check("not running: never quiet", Row(id: "w", group: .yourTurn, title: "w", context: "", since: now,
                                          lastOutput: now.addingTimeInterval(-3600)).quiet(now: now) == nil)

    // A session whose main transcript is quiet while an agent writes.
    let dir = NSTemporaryDirectory() + "limbo-selftest-\(getpid())"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir + "/s/subagents", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let transcript = dir + "/s.jsonl", agent = dir + "/s/subagents/agent-1.jsonl"
    fm.createFile(atPath: transcript, contents: Data("{}\n".utf8))
    fm.createFile(atPath: agent, contents: Data("{}\n".utf8))
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-1200)], ofItemAtPath: transcript)
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-900)], ofItemAtPath: agent)
    let first = latestWrite(transcript: transcript)?.timeIntervalSince(now) ?? 0
    check("newest write counts the agent's file", abs(first + 900) < 2)
    let queue = DispatchQueue(label: "selftest")
    let seen = DispatchSemaphore(value: 0)
    var reports: [Activity] = []
    let watcher = ActivityWatcher(key: "k", path: transcript, queue: queue, sideCheckEvery: 1) { activity in
        reports.append(activity)
        if reports.count == 2 { seen.signal() }
    }
    queue.sync {}
    try? fm.setAttributes([.modificationDate: now], ofItemAtPath: agent)   // the agent writes; the transcript doesn't
    let updated = seen.wait(timeout: .now() + 4) == .success
    queue.sync { watcher.cancel() }
    check("agent writing alone is picked up by the watcher",
          updated && abs((reports.last?.lastOutput?.timeIntervalSince(now)) ?? 99) < 2)

    let size = NSSize(width: 300, height: 120)
    check("left edge", ResizeEdges(at: NSPoint(x: 2, y: 60), in: size) == .left)
    check("bottom edge", ResizeEdges(at: NSPoint(x: 150, y: 3), in: size) == .bottom)
    check("top-right corner from 12 pt along the top", ResizeEdges(at: NSPoint(x: 288, y: 118), in: size) == [.top, .right])
    check("inside: no edge", ResizeEdges(at: NSPoint(x: 150, y: 60), in: size).isEmpty)
    check("right edge from 6 pt in", ResizeEdges(at: NSPoint(x: 294, y: 60), in: size) == .right)
    check("7 pt in is still the rows", ResizeEdges(at: NSPoint(x: 293, y: 60), in: size).isEmpty)
    check("bottom edge from 6 pt up", ResizeEdges(at: NSPoint(x: 150, y: 6), in: size) == .bottom)
    let start = NSRect(x: 100, y: 100, width: 300, height: 120), screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let minimum = FloatingLayout.minSize
    check("right edge widens", resizedFrame(start, edges: .right, delta: NSPoint(x: 50, y: 0), minSize: minimum,
                                            limit: screen) == NSRect(x: 100, y: 100, width: 350, height: 120))
    check("left edge keeps the right side", resizedFrame(start, edges: .left, delta: NSPoint(x: -40, y: 0),
                                                         minSize: minimum, limit: screen) == NSRect(x: 60, y: 100, width: 340, height: 120))
    check("bottom edge down keeps the top", resizedFrame(start, edges: .bottom, delta: NSPoint(x: 0, y: -80),
                                                         minSize: minimum, limit: screen) == NSRect(x: 100, y: 20, width: 300, height: 200))
    check("never below the minimum", resizedFrame(start, edges: [.top, .left], delta: NSPoint(x: 500, y: -500),
                                                  minSize: minimum, limit: screen).size == minimum)
    check("never past the screen", resizedFrame(start, edges: .right, delta: NSPoint(x: 5000, y: 0), minSize: minimum,
                                                limit: screen).maxX == 1440)

    // Turn cards, read from a transcript's tail (a big first line makes the read start mid-file).
    let cardFile = NSTemporaryDirectory() + "limbo-card-\(getpid()).jsonl"
    func transcriptFile(_ lines: [String]) -> String {
        let filler = #"{"type":"summary","pad":""# + String(repeating: "x", count: 300_000) + #""}"#
        try? (([filler] + lines).joined(separator: "\n") + "\n").write(toFile: cardFile, atomically: true, encoding: .utf8)
        return cardFile
    }
    func saidLine(_ text: String) -> String {
        #"{"parentUuid":"p","type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }
    func wrapLine(_ id: String, _ input: String, sidechain: Bool = false) -> String {
        #"{"parentUuid":"p","isSidechain":\#(sidechain),"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"mcp__ccd_turn__wrap_up","input":\#(input)}]}}"#
    }
    func resultLine(_ id: String, error: Bool = false) -> String {
        #"{"parentUuid":"p","type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":"ok"}]}}"#
    }
    func replyLine(_ text: String) -> String {
        #"{"parentUuid":"p","type":"assistant","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    let shipIt = #"{"recap":"All set.","ask":"Ship it?","actions":[{"label":"Yes"},{"action":"commit"}]}"#
    let ended = [saidLine("do it"), wrapLine("w1", shipIt), resultLine("w1"), replyLine("Done. **All** good: [main.swift](src/main.swift).")]
    let turn = turnCard(transcript: transcriptFile(ended))
    check("a turn card has the question and buttons", turn?.ask == "Ship it?" && turn?.actions == ["Yes", "Commit"])
    check("its reply keeps bold and drops local file links", turn?.reply == "Done. **All** good: main.swift.")
    check("its recap", turn?.recap == "All set.")
    check("a message after it means no question", turnCard(transcript: transcriptFile(ended + [saidLine("thanks")])) == nil)
    let retried = [saidLine("go"), wrapLine("a", #"{"ask":"Good?"}"#), resultLine("a"),
                   wrapLine("b", #"{"ask":"Bad?"}"#), resultLine("b", error: true), replyLine("Bye")]
    check("a wrap-up that failed is skipped", turnCard(transcript: transcriptFile(retried))?.ask == "Good?")
    check("agent lines are ignored",
          turnCard(transcript: transcriptFile(ended + [wrapLine("s", #"{"ask":"An agent's?"}"#, sidechain: true)]))?.ask == "Ship it?")
    check("a turn without a wrap-up keeps its reply",
          turnCard(transcript: transcriptFile([saidLine("hi"), replyLine("Hello")])) == TurnCard(reply: "Hello"))
    check("a question with no buttons gets one", TurnCard(ask: "Go?").buttons == ["Answer in Claude"])
    // Background work: a child shell holding …/<session>/tasks/<id>.output
    // counts, and so does a monitor: a shell Claude started, holding no file.
    let taskDir = NSTemporaryDirectory() + "limbo-bg-\(getpid())/s-123/tasks"
    try? FileManager.default.createDirectory(atPath: taskDir, withIntermediateDirectories: true)
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "exec 3>>'\(taskDir)/b1.output'; sleep 5"]
    try? shell.run()
    Thread.sleep(forTimeInterval: 0.3)
    check("a background task holding its output file counts", runningBackgroundTasks(parent: getpid(), session: "s-123") == 1)
    check("another session's tasks don't", runningBackgroundTasks(parent: getpid(), session: "s-999") == 0)
    shell.terminate()
    shell.waitUntilExit()
    check("a finished task doesn't", runningBackgroundTasks(parent: getpid(), session: "s-123") == 0)
    let monitor = Process()
    monitor.executableURL = URL(fileURLWithPath: "/bin/zsh")   // sh in POSIX mode quits when source finds no file
    monitor.arguments = ["-c", "source /nowhere/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && sleep 5; :"]
    let plainShell = Process()
    plainShell.executableURL = URL(fileURLWithPath: "/bin/sh")
    plainShell.arguments = ["-c", "sleep 5"]
    try? plainShell.run()
    Thread.sleep(forTimeInterval: 0.3)
    check("a shell Claude didn't start doesn't count", runningBackgroundTasks(parent: getpid(), session: "s-123") == 0)
    try? monitor.run()
    Thread.sleep(forTimeInterval: 0.3)
    check("a monitor (a shell Claude started, streaming, no output file) counts",
          runningBackgroundTasks(parent: getpid(), session: "s-123") == 1)
    for process in [monitor, plainShell] { process.terminate(); process.waitUntilExit() }
    try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "limbo-bg-\(getpid())")
    let reviewDesk = DeskRecord(sessionId: "local_bg1", title: "Watch the deploys", cwd: "/tmp", lastActivity: now,
                                lastTurnEdge: now.addingTimeInterval(-30), fileTime: now, isArchived: false,
                                lastAssistantUuid: "u1", category: "review_ready", statusDetail: "Deploys running",
                                needsAction: nil, summaryFor: "u1", wrapUp: nil, lastReport: nil, parentId: nil,
                                errorAt: nil, errorText: nil)
    let idleLive = LiveRecord(pid: 4242, key: "4242:1", name: "Watch the deploys", status: "idle", waitingFor: nil,
                              started: now.addingTimeInterval(-3600), statusSince: now.addingTimeInterval(-60),
                              hostId: "local_bg1", cwd: "/tmp", cliSessionId: "c1")
    let withWork = classify(desk: [reviewDesk], live: [4242: idleLive], now: now, background: [4242: 2]).first
    check("background work keeps a session running, not ready for review",
          withWork?.group == .running && withWork?.activity == "2 background tasks running")
    check("without it, it is ready for review",
          classify(desk: [reviewDesk], live: [4242: idleLive], now: now).first?.group == .review)
    var openedDesk = reviewDesk
    openedDesk.lastFocused = now.addingTimeInterval(-10)
    check("opened in Claude after the turn ended: done, not ready for review",
          classify(desk: [openedDesk], live: [4242: idleLive], now: now).first?.group == .done)
    openedDesk.lastFocused = now.addingTimeInterval(-300)
    check("opened only before the turn ended: still ready for review",
          classify(desk: [openedDesk], live: [4242: idleLive], now: now).first?.group == .review)

    // Terminal sessions: Claude Code names them after the folder ("myapp-3f")
    // and keeps the real title in the transcript.
    let titleFile = NSTemporaryDirectory() + "limbo-title-\(getpid()).jsonl"
    let titleLines = [
        #"{"type":"ai-title","aiTitle":"First topic","sessionId":"s"}"#,
        #"{"parentUuid":"p","type":"user","message":{"role":"user","content":"mentions {\"type\":\"ai-title\"} inline"}}"#,
        #"{"type":"ai-title","aiTitle":"GitHub bot user audit","sessionId":"s"}"#,
        #"{"parentUuid":"p","type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#,
    ]
    try? (titleLines.joined(separator: "\n") + "\n").write(toFile: titleFile, atomically: true, encoding: .utf8)
    check("a transcript's latest title is read", transcriptTitle(path: titleFile) == "GitHub bot user audit")
    try? (titleLines[3] + "\n").write(toFile: titleFile, atomically: true, encoding: .utf8)
    check("a transcript without a title has none", transcriptTitle(path: titleFile) == nil)
    try? FileManager.default.removeItem(atPath: titleFile)
    let termLive = LiveRecord(pid: 4343, key: "4343:1", name: "myapp-3f", status: "busy", waitingFor: nil,
                              started: now.addingTimeInterval(-600), statusSince: now.addingTimeInterval(-60),
                              hostId: nil, cwd: "/tmp/documents", cliSessionId: "c2", nameIsDerived: true)
    check("a terminal session shows its title",
          classify(desk: [], live: [4343: termLive], now: now, titles: [4343: "GitHub bot user audit"]).first?.title
              == "GitHub bot user audit")
    check("without one, its name",
          classify(desk: [], live: [4343: termLive], now: now).first?.title == "myapp-3f")

    // Herdr: a terminal session under herdr-core opens there.
    let tree: [pid_t: pid_t] = [100: 90, 90: 80, 80: 1, 200: 190, 190: 1]
    let exes: [pid_t: String] = [100: "/usr/local/bin/claude", 90: "/bin/zsh",
                                 80: "/Applications/Example/Herdr Core.app/Contents/MacOS/herdr-core",
                                 200: "/usr/local/bin/claude", 190: "/bin/zsh"]
    let hosted = herdrCore(running: 100, parent: { tree[$0] }, path: { exes[$0] ?? "" })
    check("a session under herdr-core is in Herdr, with its chain below the core",
          hosted?.core.hasSuffix("/herdr-core") == true && hosted?.chain == [100, 90])
    check("one under a plain terminal isn't", herdrCore(running: 200, parent: { tree[$0] }, path: { exes[$0] ?? "" }) == nil)
    check("Herdr's terminal is found by its shell or the program in front",
          herdrTerminalRuns(["pid": 90, "foreground": ["pid": 100]], chain: [100, 90])
              && herdrTerminalRuns(["pid": 55, "foreground": ["pid": 100]], chain: [100, 90])
              && !herdrTerminalRuns(["pid": 70, "foreground": ["pid": 71]], chain: [100, 90]))
    check("only plain terminal addresses are passed to Herdr",
          isHerdrAddress("t7") && isHerdrAddress("box/t7") && !isHerdrAddress("t1 --x") && !isHerdrAddress(""))
    var herdrLive = termLive
    herdrLive.inHerdr = true
    let herdrRow = classify(desk: [], live: [4343: herdrLive], now: now).first
    check("a session Herdr runs switches to Herdr",
          herdrRow?.link == "herdr-pid:4343" && herdrRow?.linkApp == .herdr && herdrRow?.openLabel == "Switch to Herdr"
              && herdrRow?.source == .claude && herdrRow?.terminal == true && !SessionTags.taggable(herdrRow!))
    check("one in another terminal still can't be opened",
          classify(desk: [], live: [4343: termLive], now: now).first?.link == nil)

    // Links in a reply: only web links stay links.
    func links(_ s: String) -> [String] {
        ResponseDrawer.markdown(cleanReply([s]) ?? "").runs.compactMap { $0.link?.absoluteString }
    }
    check("a reply's angle-bracket file link is plain text", links("see <file:///Applications/Calculator.app>").isEmpty)
    check("so is an app's own link", links("open <vscode://file/tmp/x>").isEmpty)
    check("so is a link whose text has brackets", links("[safe [nested]](file:///tmp/evil.command)").isEmpty)
    check("a web link stays a link", links("[docs](https://example.com) and <https://example.org>")
            == ["https://example.com", "https://example.org"])

    // The window's glass: dark in Dark Mode, plain in Light Mode.
    check("Dark Mode darkens the glass", FloatingView.glassShade(.dark) >= 0.5)
    check("Light Mode leaves the glass plain", FloatingView.glassShade(.light) == 0)

    // Layouts: the saved choice, and what shows while an app is full screen.
    check("an old pill setting comes back as the pill", KeepOnTopLayout.saved(raw: nil, legacyMini: true) == .pill)
    check("no setting is the list", KeepOnTopLayout.saved(raw: nil, legacyMini: false) == .list)
    check("a saved layout wins over the old pill setting", KeepOnTopLayout.saved(raw: "bar", legacyMini: true) == .bar)
    check("an unknown saved layout is the list", KeepOnTopLayout.saved(raw: "grid", legacyMini: false) == .list)
    check("the pill switch still works", FloatingLayout(mini: true).chosen == .pill
              && { let l = FloatingLayout(mini: true); l.mini = false; return l.chosen == .list }())
    check("full screen turns the list into the strip",
          KeepOnTopLayout.effective(chosen: .list, fullScreen: true, autoStrip: true, kept: false) == .strip)
    check("and the columns", KeepOnTopLayout.effective(chosen: .columns, fullScreen: true, autoStrip: true, kept: false) == .strip)
    check("the dots stay the dots", KeepOnTopLayout.effective(chosen: .dots, fullScreen: true, autoStrip: true, kept: false) == .dots)
    check("with the switch off, full screen changes nothing",
          KeepOnTopLayout.effective(chosen: .list, fullScreen: true, autoStrip: false, kept: false) == .list)
    check("a layout picked in full screen stays",
          KeepOnTopLayout.effective(chosen: .list, fullScreen: true, autoStrip: true, kept: true) == .list)
    check("out of full screen, the layout you chose",
          KeepOnTopLayout.effective(chosen: .columns, fullScreen: false, autoStrip: true, kept: false) == .columns)
    check("only the list and the columns resize", KeepOnTopLayout.allCases.filter { !$0.resizable.isEmpty } == [.list, .columns]
              && KeepOnTopLayout.columns.resizable == [.left, .right])
    let screenArea = NSRect(x: 0, y: 70, width: 1512, height: 875)
    check("the bar spans the bottom of the screen",
          barFrame(area: screenArea, height: 30) == NSRect(x: 0, y: 70, width: 1512, height: 30))
    check("a window past the bottom moves up onto the screen",
          keptOnScreen(NSRect(x: 1200, y: 20, width: 300, height: 200), area: screenArea) == NSRect(x: 1200, y: 70, width: 300, height: 200))
    check("past the right edge, it moves left",
          keptOnScreen(NSRect(x: 1400, y: 400, width: 300, height: 200), area: screenArea).maxX == 1512)
    check("taller than the screen, its top stays on it",
          keptOnScreen(NSRect(x: 10, y: 0, width: 300, height: 1200), area: screenArea).maxY == screenArea.maxY)
    check("a window on the screen stays put",
          keptOnScreen(NSRect(x: 10, y: 300, width: 300, height: 200), area: screenArea) == NSRect(x: 10, y: 300, width: 300, height: 200))
    // The strip and the dots never outgrow the screen.
    let many = (0..<9).map { Row(id: "r\($0)", group: .running, title: "Session \($0)", context: "", since: Date()) }
    let crowd = FloatingRows(board: Board(rows: many + many.map { Row(id: $0.id + "d", group: .done, title: $0.title,
                                                                     context: "", since: Date()) }, now: Date()),
                             now: Date(), within: 86400, finishedWithin: 7200)
    let stripped = FloatingView.stripRows(crowd)
    check("the strip shows six chips, two of them finished, and counts the rest",
          stripped.shown.count == 4 && stripped.more == 5 && stripped.finished.count == 2 && stripped.moreFinished == 7)
    let fewRunning = FloatingRows(board: Board(rows: [many[0]] + many.prefix(3).map {
                                      Row(id: $0.id + "d", group: .done, title: $0.title, context: "", since: Date()) },
                                                now: Date()),
                                  now: Date(), within: 86400, finishedWithin: 7200)
    let fewStripped = FloatingView.stripRows(fewRunning)
    check("with room, every finished session is a chip in the strip",
          fewStripped.shown.count == 1 && fewStripped.finished.count == 3 && fewStripped.moreFinished == 0)
    let appsStrip = FloatingView.stripRows(FloatingRows(board: Board(rows: sampleAppRows(now: Date()), now: Date()),
                                                        now: Date(), within: 86400, finishedWithin: 7200))
    check("in a full strip, the sessions waiting on you win over running ones, shown in order",
          appsStrip.shown.map(\.id) == ["local_a3", "cursor:a5", "local_a1", "cursor:a2"] && appsStrip.more == 3
              && appsStrip.finished.map(\.id) == ["codex:a8", "agy:a9"])
    let dotted = FloatingView.dotGroups(crowd)
    check("the dots show twelve marks and count the rest",
          dotted.groups.joined().count == FloatingView.maxDots && dotted.more == 18 - FloatingView.maxDots)
    // A finished session that asked something is waiting on you, as its card is in the list.
    let asked = Row(id: "asked", group: .justFinished, title: "Fix the test", context: "", since: Date(),
                    card: TurnCard(ask: "Commit and push this change?", actions: ["Commit and push"]))
    let quietDone = Row(id: "quiet", group: .done, title: "Tidy up", context: "", since: Date())
    let asking = FloatingView.Compact(FloatingRows(board: Board(rows: [asked, quietDone], now: Date()), now: Date(),
                                                   within: 86400, finishedWithin: 7200))
    check("a finished session's question puts it with the ones waiting on you",
          asking.waiting.map(\.id) == ["asked"] && asking.finished.map(\.id) == ["quiet"])
    // A hover card hangs under its chip, inside the row.
    check("a card centres under its chip", FloatingView.hoverCardX(chipMidX: 400, rowWidth: 800, card: 290, trailing: false) == 255)
    check("near the left end it lines up with the row", FloatingView.hoverCardX(chipMidX: 50, rowWidth: 800, card: 290, trailing: false) == 0)
    check("near the right end too", FloatingView.hoverCardX(chipMidX: 790, rowWidth: 800, card: 290, trailing: true) == 510)
    check("under a short row it keeps to the fixed side",
          FloatingView.hoverCardX(chipMidX: 60, rowWidth: 200, card: 290, trailing: true) == -90
              && FloatingView.hoverCardX(chipMidX: 60, rowWidth: 200, card: 290, trailing: false) == 0)
    // Full screen: a normal window from another app exactly covering the display.
    func window(_ x: Int, _ y: Int, _ w: Int, _ h: Int, layer: Int = 0, pid: Int = 42) -> [String: Any] {
        [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as NSDictionary]
    }
    let display = NSRect(x: 0, y: 0, width: 1512, height: 982)
    check("a window covering the display is full screen",
          windowCovers(display, primaryHeight: 982, windows: [window(0, 0, 1512, 982)], me: 7))
    check("a zoomed window is not", !windowCovers(display, primaryHeight: 982, windows: [window(0, 37, 1512, 880)], me: 7))
    check("nor one of ours", !windowCovers(display, primaryHeight: 982, windows: [window(0, 0, 1512, 982, pid: 7)], me: 7))
    check("nor a shield above the windows", !windowCovers(display, primaryHeight: 982, windows: [window(0, 0, 1512, 982, layer: 25)], me: 7))
    check("on a display above the main one, bounds count from the main one's top",
          windowCovers(NSRect(x: 0, y: 982, width: 1920, height: 1080), primaryHeight: 982,
                       windows: [window(0, -1080, 1920, 1080)], me: 7))
    check("every layout symbol exists",
          (KeepOnTopLayout.allCases.map(\.symbol) + ["rectangle.3.group", "arrow.up.left.and.arrow.down.right"])
              .allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })

    // Answering from a card presses only an exact match.
    check("the same question, ignoring case and spacing",
          ClaudeAnswerer.sameText("Commit and push  this change?", "commit and push this change?"))
    check("a button with exactly the label", ClaudeAnswerer.isButton("Yes, post it", "Yes, post it"))
    check("a button with its shortcut drawn after it", ClaudeAnswerer.isButton("Yes, post it ⌘↩", "Yes, post it"))
    check("not a button whose label only starts the same", !ClaudeAnswerer.isButton("Yes, post it later", "Yes, post it"))
    check("not an empty label", !ClaudeAnswerer.isButton("Send", ""))
    // An answer is confirmed by the transcript: a message from you after the press.
    let sentFile = NSTemporaryDirectory() + "limbo-sent-\(getpid()).jsonl"
    try? (replyLine("Commit and push this change?") + "\n").write(toFile: sentFile, atomically: true, encoding: .utf8)
    let mark = fileStamp(sentFile)?.size ?? 0
    if let handle = FileHandle(forWritingAtPath: sentFile) {
        handle.seekToEndOfFile()
        handle.write(Data((saidLine("Commit and push") + "\n" + resultLine("x") + "\n").utf8))
        try? handle.close()
    }
    check("a message from you after the press is found", ClaudeAnswerer.sent(in: sentFile, after: mark) == ["Commit and push"])
    check("nothing before the press counts", ClaudeAnswerer.sent(in: sentFile, after: fileStamp(sentFile)?.size ?? 0).isEmpty)
    try? FileManager.default.removeItem(atPath: sentFile)
    try? FileManager.default.removeItem(atPath: cardFile)

    check("short ages", [30.0, 360, 18 * 3600, 3 * 86400].map { compactAge(since: now.addingTimeInterval(-$0), now: now) }
                        == ["now", "6m", "18h", "3d"])
    let waitingRow = Row(id: "w1", group: .yourTurn, title: "w", context: "", since: now.addingTimeInterval(-300))
    let list = FloatingRows(board: Board(rows: [waitingRow, running], now: now), now: now, within: 86400,
                            finishedWithin: 7200)
    check("filter to needs you", list.rows(list.effective(.needsYou)).map(\.id) == ["w1"])
    check("a filter with nothing left shows everything", list.effective(.review) == nil && list.rows(nil).count == 2)
    let acknowledging = SessionModel()
    acknowledging.now = now
    acknowledging.acknowledge([waitingRow])
    check("Got it stops the amber without opening", acknowledging.freshNeedsYou(Board(rows: [waitingRow], now: now)).isEmpty)
    let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    check("shrinking on the right keeps the right edge",
          anchoredFrame(NSRect(x: 1100, y: 600, width: 320, height: 200), size: NSSize(width: 150, height: 32),
                        screen: screenFrame) == NSRect(x: 1270, y: 768, width: 150, height: 32))
    check("shrinking on the left keeps the left edge",
          anchoredFrame(NSRect(x: 40, y: 600, width: 320, height: 200), size: NSSize(width: 150, height: 32),
                        screen: screenFrame) == NSRect(x: 40, y: 768, width: 150, height: 32))

    // ChatGPT (Codex) threads: a turn's start and end lines in its rollout file.
    let codexDir = NSTemporaryDirectory() + "limbo-codex-\(getpid())/.codex/sessions/2026/11/19"
    try? FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
    let threadId = "01a1f000-0000-7000-8000-000000000001"
    let rollout = codexDir + "/rollout-2026-11-19T08-00-00-\(threadId).jsonl"
    func codexLine(_ time: String, _ type: String, _ payload: String) -> String {
        #"{"timestamp":"2026-11-19T\#(time)Z","ordinal":7,"type":"\#(type)","payload":{"type":\#(payload)}}"# + "\n"
    }
    let header = #"{"timestamp":"2026-11-19T02:30:00.000Z","type":"session_meta","payload":{"id":"\#(threadId)","cwd":"\/tmp\/web-app","originator":"Codex Desktop","thread_source":"user","base_instructions":{"text":"long"}}}"# + "\n"
    let started = codexLine("02:30:01.000", "event_msg", #""task_started","turn_id":"t1""#)
    let thinking = codexLine("02:30:02.000", "response_item", #""reasoning","summary":[]"#)
    let command = codexLine("02:30:03.000", "response_item", #""custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"ls""#)
    // A reply that quotes a turn's end line: words inside a message never count.
    let quoting = codexLine("02:31:00.000", "response_item",
                            #""message","role":"assistant","content":[{"type":"output_text","text":"see {\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}"}]"#)
    try? (header + started + thinking + command).write(toFile: rollout, atomically: true, encoding: .utf8)
    var scan = scanRollout(path: rollout, from: RolloutScan())
    check("a turn started and not ended is running, doing what its last step did",
          scan.marker == .started && scan.activity == "Running a command"
              && scan.markerTime == codexTime.date(from: "2026-11-19T02:30:01.000Z"))
    func append(_ text: String) {
        if let handle = FileHandle(forWritingAtPath: rollout) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        }
    }
    append(quoting)
    scan = scanRollout(path: rollout, from: scan)
    check("a reply quoting an end line doesn't end the turn", scan.marker == .started && scan.activity == "Writing")
    let turnEnd = codexLine("02:32:00.000", "event_msg", #""task_complete","turn_id":"t1","last_agent_message":"done""#)
    append(String(turnEnd.dropLast(10)))
    let partly = scanRollout(path: rollout, from: scan)
    check("a half-written last line waits", partly.marker == .started && partly.offset == scan.offset)
    append(String(turnEnd.suffix(10)))
    scan = scanRollout(path: rollout, from: partly)
    check("the turn's end line ends it", scan.marker == .complete
              && scan.markerTime == codexTime.date(from: "2026-11-19T02:32:00.000Z"))
    check("read from where it stopped: a fresh read agrees", scanRollout(path: rollout, from: RolloutScan()) == scan)
    let head = rolloutHeader(path: rollout)
    check("the first line gives the thread, its folder and who started it",
          head.id == threadId && head.cwd == "/tmp/web-app" && head.source == "user")
    check("Codex's own agents and reviewers are left out",
          codexThreadShown(source: "user") && codexThreadShown(source: nil) && !codexThreadShown(source: "subagent")
              && !codexThreadShown(source: "guardian_review"))
    check("the thread id comes from the file name", codexThreadId(path: rollout) == threadId)
    check("ChatGPT's own process is what starts its Codex servers, not one of its helpers",
          CodexWatcher.isChatGPTApp("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
              && !CodexWatcher.isChatGPTApp("/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Aperitif).app/Contents/MacOS/Codex (Aperitif)"))
    check("a long thread's file with a second id still gives the first",
          codexThreadId(path: codexDir + "/rollout-2026-10-14T10-02-20-\(threadId)_01a1f000-0000-7000-8000-000000000002.jsonl")
              == threadId)
    check("a thread's name is the last one it got",
          codexNames(index: #"{"id":"a","thread_name":"First","updated_at":"x"}"# + "\n"
                     + #"{"id":"a","thread_name":"Renamed","updated_at":"y"}"#) == ["a": "Renamed"])
    let finishedRow = codexRow(id: threadId, name: "Fix the export", cwd: head.cwd, scan: scan)
    check("a finished thread is a finished row that opens in ChatGPT",
          finishedRow?.group == .done && finishedRow?.source == .chatGPT && finishedRow?.tags == []
              && finishedRow?.openURL?.absoluteString == "codex://threads/\(threadId)" && finishedRow?.context == "web-app")
    check("it can't be tagged or snoozed", finishedRow.map { !SessionTags.taggable($0) && !SessionSnoozes.snoozable($0) } == true)
    append(codexLine("02:33:00.000", "event_msg", #""task_started","turn_id":"t2""#)
           + codexLine("02:33:40.000", "event_msg", #""turn_aborted","turn_id":"t2""#))
    scan = scanRollout(path: rollout, from: scan)
    check("a stopped turn is finished, marked Stopped",
          codexRow(id: threadId, name: nil, cwd: nil, scan: scan).map { $0.group == .done && $0.detail == "Stopped"
              && $0.title == "Codex thread" } == true)
    var runningScan = scan
    runningScan.marker = .started
    runningScan.lastWrite = codexTime.date(from: "2026-11-19T02:33:41.500Z")
    check("a running thread's last write is kept to the minute",
          codexRow(id: threadId, name: "x", cwd: nil, scan: runningScan)?.lastOutput == codexTime.date(from: "2026-11-19T02:33:00.000Z"))
    check("a Claude session still opens in Claude",
          Row(id: "local_a1", group: .done, title: "t", context: "", since: now, link: "local_a1").openURL?.absoluteString
              == "claude://claude.ai/epitaxy/local_a1")
    try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "limbo-codex-\(getpid())")

    // Cursor threads: its list of threads, in a database shaped like Cursor's.
    let cursorDatabase = NSTemporaryDirectory() + "limbo-cursor-\(getpid()).vscdb"
    try? FileManager.default.removeItem(atPath: cursorDatabase)
    var setup: OpaquePointer?
    _ = sqlite3_open(cursorDatabase, &setup)
    func ms(_ secondsAgo: TimeInterval) -> Int64 { Int64(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000) }
    func cursorHeader(_ id: String, updated: TimeInterval, checkpoint: TimeInterval? = nil, archived: Int = 0,
                      subagent: Int = 0, _ fields: String) -> String {
        let value = #"{"type":"head","composerId":"\#(id)",\#(fields)"workspaceIdentifier":{"uri":{"fsPath":"/tmp/build-tools"}}}"#
        return "INSERT INTO composerHeaders VALUES ('\(id)', 'w1', \(ms(updated)), \(ms(updated)), \(archived), \(subagent), "
            + "\(ms(updated)), \(checkpoint.map { String(ms($0)) } ?? "NULL"), '\(value)', NULL);"
    }
    let cursorSQL = [
        "CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT);",
        cursorHeader("c-run", updated: 120, checkpoint: 90,
                     #""name":"Tidy the build scripts","subtitle":"Read Makefile, build.sh","unfinishedRunAt":\#(ms(120)),"hasBlockingPendingActions":false,"#),
        cursorHeader("c-wait", updated: 300, checkpoint: 200,
                     #""name":"Rename the config keys","unfinishedRunAt":\#(ms(300)),"hasBlockingPendingActions":true,"#),
        cursorHeader("c-done", updated: 3600, checkpoint: 3000, #""name":"Explain the cache","hasBlockingPendingActions":false,"#),
        cursorHeader("c-plan", updated: 4000, checkpoint: 3900, #""name":"Plan the migration","hasPendingPlan":true,"#),
        cursorHeader("c-cut", updated: 5000, checkpoint: 4900, #""name":"Cut short","unfinishedRunAt":\#(ms(5000)),"#),
        cursorHeader("c-noname", updated: 6000, #""name":"","#),
        cursorHeader("c-draft", updated: 60, #""name":"","subtitle":"half a question","isDraft":true,"#),
        cursorHeader("c-archived", updated: 60, archived: 1, #""name":"Archived","#),
        cursorHeader("c-subagent", updated: 60, subagent: 1, #""name":"A subagent","#),
        cursorHeader("c-old", updated: 30 * 86400, #""name":"Last month","#),
    ]
    for sql in cursorSQL { _ = sqlite3_exec(setup, sql, nil, nil, nil) }
    sqlite3_close(setup)
    let cursorThreads = readCursorThreads(database: cursorDatabase, since: now.addingTimeInterval(-Board.window)) ?? []
    check("Cursor's list: recent threads, newest first; no drafts, archived, subagents or old ones",
          cursorThreads.map(\.id) == ["c-run", "c-wait", "c-done", "c-plan", "c-cut", "c-noname"])
    check("no database, no list", readCursorThreads(database: cursorDatabase + "-missing", since: now) == nil)
    let cursorStarted = now.addingTimeInterval(-1800)
    let cursorRows = Dictionary(uniqueKeysWithValues: cursorThreads.compactMap { thread in
        cursorRow(thread, cursorStarted: cursorStarted).map { (thread.id, $0) }
    })
    let cursorRunning = cursorRows["c-run"]
    check("a run going is a running row, doing what Cursor says under it",
          cursorRunning?.group == .running && cursorRunning?.since == Date(timeIntervalSince1970: Double(ms(120)) / 1000)
              && cursorRunning?.activity == "Read Makefile, build.sh" && cursorRunning?.context == "build-tools"
              && cursorRunning?.lastOutput.map { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 } == true)
    check("it's Cursor's, says so, and can't be tagged or snoozed",
          cursorRunning?.source == .cursor && cursorRunning?.fromOtherApp == true && cursorRunning?.tags == []
              && cursorRunning?.appName == "Cursor" && cursorRunning?.openLabel == "Switch to Cursor"
              && cursorRunning.map { !SessionTags.taggable($0) && !SessionSnoozes.snoozable($0) } == true)
    check("a run waiting for approval waits on you", cursorRows["c-wait"]?.group == .yourTurn
              && cursorRows["c-wait"]?.detail == "Waiting for your approval")
    check("a plan ready waits on you", cursorRows["c-plan"]?.group == .yourTurn && cursorRows["c-plan"]?.detail == "Plan ready to review")
    check("a finished thread is finished when its run ended", cursorRows["c-done"]?.group == .done
              && cursorRows["c-done"]?.since == Date(timeIntervalSince1970: Double(ms(3000)) / 1000))
    check("a run from before Cursor started was cut short: finished", cursorRows["c-cut"]?.group == .done)
    check("a thread with no name and no run isn't listed", cursorRows["c-noname"] == nil)
    check("ChatGPT's and Claude's rows say where they open",
          Row(id: "codex:x", group: .done, title: "t", context: "", since: now).openLabel == "Open in ChatGPT"
              && Row(id: "local_a1", group: .done, title: "t", context: "", since: now).source == .claude)
    try? FileManager.default.removeItem(atPath: cursorDatabase)

    // Antigravity conversations: its list, in a database shaped like Antigravity's.
    let agyDatabase = NSTemporaryDirectory() + "limbo-agy-\(getpid()).db"
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: agyDatabase + suffix) }
    let agyStamp = DateFormatter()
    agyStamp.locale = Locale(identifier: "en_US_POSIX")
    agyStamp.timeZone = .gmt
    agyStamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
    func agyTimeText(_ secondsAgo: TimeInterval) -> String { agyStamp.string(from: now.addingTimeInterval(-secondsAgo)) + "+00:00" }
    func agyRow(_ id: String, title: String, preview: String = "", workspaces: String = "", modified: TimeInterval,
                input: TimeInterval, status: String, killed: Int = 0, depth: Int = 0, parent: String = "",
                source: String = "") -> String {
        "INSERT INTO conversation_summaries VALUES ('\(id)', '\(title)', '\(preview)', '\(workspaces)', "
            + "'\(agyTimeText(modified))', '\(agyTimeText(input))', '\(status)', \(killed), \(depth), '\(parent)', '\(source)');"
    }
    var agySetup: OpaquePointer?
    _ = sqlite3_open(agyDatabase, &agySetup)
    let agySQL = [
        "PRAGMA journal_mode = WAL;",
        "CREATE TABLE conversation_summaries (conversation_id text, title text NOT NULL DEFAULT '', preview text NOT NULL DEFAULT '', workspace_uris text NOT NULL, last_modified_time datetime NOT NULL, last_user_input_time datetime NOT NULL, status text NOT NULL DEFAULT '', killed numeric NOT NULL DEFAULT false, nesting_depth integer NOT NULL DEFAULT 0, parent_conversation_id text NOT NULL DEFAULT '', source text NOT NULL DEFAULT '', PRIMARY KEY (conversation_id));",
        agyRow("a-run", title: "Sort out the release notes", workspaces: "file:///tmp/web-app", modified: 30, input: 200,
               status: "CASCADE_RUN_STATUS_RUNNING"),
        agyRow("a-idle", title: "", preview: "Why is the cache cold?", modified: 3600, input: 3700, status: "CASCADE_RUN_STATUS_IDLE"),
        agyRow("a-killed", title: "Bump the SDK", modified: 4000, input: 4100, status: "CASCADE_RUN_STATUS_IDLE", killed: 1),
        agyRow("a-stale", title: "Cut short", modified: 5000, input: 5100, status: "CASCADE_RUN_STATUS_RUNNING"),
        agyRow("a-sub", title: "A subagent", modified: 20, input: 20, status: "CASCADE_RUN_STATUS_RUNNING", depth: 1, parent: "a-run"),
        agyRow("a-old", title: "Last month", modified: 30 * 86400, input: 30 * 86400, status: "CASCADE_RUN_STATUS_IDLE"),
        agyRow("a-cli", title: "", preview: "Run by the command-line agent", modified: 10, input: 10,
               status: "CASCADE_RUN_STATUS_IDLE", source: "CORTEX_TRAJECTORY_SOURCE_CLI"),
    ]
    for sql in agySQL { _ = sqlite3_exec(agySetup, sql, nil, nil, nil) }
    sqlite3_close(agySetup)
    // Closing the last connection takes the log away, as when Antigravity has
    // the database closed: a read-only reader then can't open it normally.
    let agyConversations = readAntigravityConversations(database: agyDatabase, since: now.addingTimeInterval(-Board.window)) ?? []
    check("Antigravity's list: recent conversations, newest first; no subagents, old or command-line ones, even with its log gone",
          agyConversations.map(\.id) == ["a-run", "a-idle", "a-killed", "a-stale"])
    check("Antigravity's times read to the microsecond, in their own zone",
          antigravityTime("2026-11-21 07:18:46.384063+00:00").map { abs($0.timeIntervalSince1970 - 1795245526.384063) < 0.001 } == true
              && antigravityTime("2026-11-21 12:48:46+05:30").map { abs($0.timeIntervalSince1970 - 1795245526) < 0.001 } == true)
    let agyStarted = now.addingTimeInterval(-1800)
    let agyRows = Dictionary(uniqueKeysWithValues: agyConversations.compactMap { c in
        antigravityRow(c, appStarted: agyStarted).map { (c.id, $0) }
    })
    let agyRunning = agyRows["a-run"]
    check("a running conversation is a running row, from your last message, in its folder",
          agyRunning?.group == .running && agyRunning?.context == "web-app"
              && agyRunning.map { abs($0.since.timeIntervalSince(now.addingTimeInterval(-200))) < 0.01 } == true
              && agyRunning?.lastOutput.map { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 } == true)
    check("it's Antigravity's, switches to it, and can't be tagged or snoozed",
          agyRunning?.source == .antigravity && agyRunning?.openLabel == "Switch to Antigravity"
              && agyRunning.map { !SessionTags.taggable($0) && !SessionSnoozes.snoozable($0) } == true)
    check("an idle one is finished, named from its first ask when it has no title",
          agyRows["a-idle"]?.group == .done && agyRows["a-idle"]?.title == "Why is the cache cold?"
              && agyRows["a-idle"]?.context == "Antigravity")
    check("a stopped one says so", agyRows["a-killed"]?.group == .done && agyRows["a-killed"]?.detail == "Stopped")
    check("a run last changed before Antigravity started was cut short: finished", agyRows["a-stale"]?.group == .done)
    check("an archived conversation's note says so; an unarchived or missing one doesn't",
          antigravityArchived(note: Data(#"title:"Bump the SDK" archived:true archival_status_timestamp:{seconds:1}"#.utf8))
              && antigravityArchived(note: Data("title:\"x\"\narchived: true\n".utf8))
              && !antigravityArchived(note: Data(#"title:"x" archived:false archival_status_timestamp:{seconds:1}"#.utf8))
              && !antigravityArchived(note: Data(#"title:"x" plan_execute:true"#.utf8)) && !antigravityArchived(note: nil))
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: agyDatabase + suffix) }

    // Orca threads: the ones open in its tabs, in a database shaped like Orca's.
    let orcaDb = NSTemporaryDirectory() + "limbo-orca-\(getpid()).db"
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: orcaDb + suffix) }
    func orcaMs(_ secondsAgo: TimeInterval) -> Int64 { Int64(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000) }
    func orcaRecord(_ id: String, _ json: String) -> String {
        "INSERT INTO agent_session_records(session_id, record_json) VALUES ('\(id)', '\(json)');"
    }
    var orcaSetup: OpaquePointer?
    _ = sqlite3_open(orcaDb, &orcaSetup)
    let orcaSQL = [
        """
        CREATE TABLE agent_session_records (session_id TEXT PRIMARY KEY, record_json TEXT NOT NULL,
          adopted_native_id TEXT GENERATED ALWAYS AS (CASE WHEN json_valid(record_json) THEN COALESCE(
            json_extract(record_json,'$.providerHandleChain[#-1].handle.nativeId'),
            json_extract(record_json,'$.providerHandleChain[#-1].handle.sessionId')) END) VIRTUAL);
        """,
        "CREATE TABLE agent_session_tabs (tab_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, position INTEGER NOT NULL);",
        "CREATE TABLE journal_chat_state (session_id TEXT PRIMARY KEY, last_activity_at INTEGER NOT NULL DEFAULT 0);",
        orcaRecord("o-run", #"{"provider":"antigravity","conversationName":"Tidy the README","location":{"workspaceId":"w1::/tmp/web-app"},"providerHandleChain":[{"handle":{"nativeId":"n-agy"}}],"lastTurn":{"state":"open","at":\#(orcaMs(300)),"prompt":"tidy it"}}"#),
        orcaRecord("o-done", #"{"provider":"claude","conversationName":"","location":{"workspaceId":"folder:abc"},"providerHandleChain":[{"handle":{"sessionId":"n-claude"}}],"lastTurn":{"state":"settled","at":\#(orcaMs(600)),"outcome":"success","prompt":"Explain the build\nin detail"}}"#),
        orcaRecord("o-fail", #"{"provider":"codex","conversationName":"Bump the SDK","location":{"workspaceId":"w2::/tmp/sdk"},"providerHandleChain":[],"lastTurn":{"state":"settled","at":\#(orcaMs(900)),"outcome":"failure","prompt":"bump"}}"#),
        orcaRecord("o-new", #"{"provider":"claude","conversationName":"","location":{"workspaceId":"w1::/tmp/web-app"},"providerHandleChain":[]}"#),
        orcaRecord("o-closed", #"{"provider":"claude","conversationName":"Closed tab","location":{"workspaceId":"w1::/tmp/web-app"},"providerHandleChain":[],"lastTurn":{"state":"open","at":\#(orcaMs(60))}}"#),
        "INSERT INTO agent_session_tabs VALUES ('t1', 'o-run', 0), ('t2', 'o-done', 1), ('t3', 'o-fail', 2), ('t4', 'o-new', 3);",
        "INSERT INTO journal_chat_state VALUES ('o-run', \(orcaMs(45)));",
    ]
    for sql in orcaSQL { _ = sqlite3_exec(orcaSetup, sql, nil, nil, nil) }
    sqlite3_close(orcaSetup)
    let orcaThreads = readOrcaThreads(database: orcaDb) ?? []
    check("Orca's list: only the threads open in its tabs", Set(orcaThreads.map(\.id)) == ["o-run", "o-done", "o-fail", "o-new"])
    check("each with the agent's own id for it, when it has one",
          Set(orcaThreads.compactMap(\.nativeId)) == ["n-agy", "n-claude"])
    let orcaRows = Dictionary(uniqueKeysWithValues: orcaThreads.compactMap { t in orcaRow(t).map { (t.id, $0) } })
    let orcaRunning = orcaRows["o-run"]
    check("an open turn is a running row, in its folder and with its agent",
          orcaRunning?.group == .running && orcaRunning?.title == "Tidy the README" && orcaRunning?.context == "web-app · Orca"
              && orcaRunning?.lastOutput.map { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 } == true)
    check("it shows its agent's icon, and VoiceOver says both",
          orcaRunning?.iconSource == .antigravity && orcaRunning?.spokenApp == ", Antigravity in Orca")
    check("it's Orca's, switches to it, and can't be tagged or snoozed",
          orcaRunning?.source == .orca && orcaRunning?.openLabel == "Switch to Orca"
              && orcaRunning.map { !SessionTags.taggable($0) && !SessionSnoozes.snoozable($0) } == true)
    check("a settled one is finished, named from its ask's first line when it has no name",
          orcaRows["o-done"]?.group == .done && orcaRows["o-done"]?.title == "Explain the build"
              && orcaRows["o-done"]?.context == "Orca" && orcaRows["o-done"]?.iconSource == .claude)
    check("Codex shows ChatGPT's icon; an agent with no app of its own shows Orca's, and is named",
          orcaRows["o-fail"]?.iconSource == .chatGPT
              && orcaRow(OrcaThread(id: "o-x", agent: "grok", name: "x", prompt: "", workspace: "w::/tmp/a", turnAt: now))
                  .map { $0.iconSource == .orca && $0.context == "a · Grok in Orca" } == true)
    check("a failed one says so", orcaRows["o-fail"]?.group == .done && orcaRows["o-fail"]?.detail == "Failed")
    check("a thread never used isn't listed", orcaRows["o-new"] == nil)
    check("Orca's worktree names, by workspace",
          orcaWorktreeNames(Data(#"{"schemaVersion":1,"worktrees":[["w1::/tmp/web-app","Tidy-up session"],["w2::/tmp/sdk",""]]}"#.utf8))
              == ["w1::/tmp/web-app": "Tidy-up session"])
    var named = orcaThreads.first { $0.id == "o-run" }
    named?.worktree = "Tidy-up session"
    check("a thread sits under its worktree's name when Orca has one",
          named.flatMap(orcaRow)?.context == "Tidy-up session · Orca")
    let folderNames = orcaFolderWorkspaces(Data(#"[{"id":"b1","name":"Ada","folderPath":"/Users/x/.orca/bots/ada-1"},{"id":"f1","name":"Notes","folderPath":"/Users/x/notes"},{"id":"f2","name":""}]"#.utf8))
    check("Orca's folder workspaces: bots by their folder, others by name",
          folderNames["b1"]?.name == "Ada" && folderNames["b1"]?.bot == true && folderNames["f1"]?.bot == false
              && folderNames["f2"] == nil)
    var botChat = orcaThreads.first { $0.id == "o-done" }
    botChat?.name = "Home"
    botChat?.bot = "Ada"
    check("a bot's chat carries the bot's name", botChat.flatMap(orcaRow)?.title == "Home · Ada")
    let waitingClaude = Row(id: "pid:42", group: .yourTurn, title: "Fix the flaky test", ask: "Allow the edit?",
                            context: "web-app", since: now, terminal: true)
    let orcaClaude = Row(id: "orca:o-done", group: .running, title: "Home · Ada", context: "Orca",
                         since: now, link: orcaLinkPrefix + "o-done")
    let merged = mergeOrca(claude: [waitingClaude], orca: [orcaClaude, orcaRunning!],
                           sessions: [42: "n-claude"], orcaThreads: ["n-claude": "o-done", "n-agy": "o-run"])
    check("a Claude session Orca runs is listed once, as Claude's own row, still waiting on you, by Orca's name",
          merged.map(\.id) == ["pid:42", "orca:o-run"] && merged.first?.group == .yourTurn
              && merged.first?.ask == "Allow the edit?" && merged.first?.title == "Home · Ada" && merged.first?.context == "Orca")
    check("and a click on it switches to Orca",
          merged.first?.linkApp == .orca && merged.first?.openLabel == "Switch to Orca" && merged.first?.source == .claude
              && !SessionTags.taggable(merged.first!))
    check("a terminal session Orca doesn't run keeps no link",
          mergeOrca(claude: [waitingClaude], orca: [orcaClaude], sessions: [42: "other"], orcaThreads: ["n-claude": "o-done"])
              .first?.link == nil)
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: orcaDb + suffix) }

    // Snooze: held until a time you pick, or until the session moves on.
    let snoozeSuite = "limbo-tasks-selftest-snooze"
    let snoozeDefaults = UserDefaults(suiteName: snoozeSuite)!
    snoozeDefaults.removePersistentDomain(forName: snoozeSuite)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let today = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
    let morning = SnoozeChoice.tomorrow.until(from: today, calendar: calendar)
    check("tomorrow morning is 9:00 the next day",
          calendar.dateComponents([.day, .hour, .minute], from: morning) == DateComponents(day: 16, hour: 9, minute: 0))
    check("an hour is an hour", SnoozeChoice.hour.until(from: today) == today.addingTimeInterval(3600))
    check("a snooze ending today says only the time",
          snoozeWhen(today.addingTimeInterval(3600), now: today, calendar: calendar).hasPrefix("until ")
              && !snoozeWhen(today.addingTimeInterval(3600), now: today, calendar: calendar).contains("tomorrow"))
    check("one ending tomorrow says tomorrow",
          snoozeWhen(morning, now: today, calendar: calendar).hasPrefix("until tomorrow "))
    let asker = Row(id: "local_z1", group: .yourTurn, title: "Rotate the keys", ask: "OK to revoke?", context: "",
                    since: Date().addingTimeInterval(-600), link: "local_z1")
    let reviewAsk = Row(id: "local_z2", group: .review, title: "Ship the fix", context: "",
                        since: Date().addingTimeInterval(-900), link: "local_z2",
                        card: TurnCard(ask: "Merge it?", actions: ["Merge"]))
    let busy = Row(id: "local_z3", group: .running, title: "Busy", context: "", since: Date().addingTimeInterval(-60),
                   link: "local_z3")
    check("needs you, to review and asking rows can be snoozed",
          SessionSnoozes.snoozable(asker) && SessionSnoozes.snoozable(reviewAsk))
    check("running, quiet finished and terminal rows can't",
          !SessionSnoozes.snoozable(busy) && !SessionSnoozes.snoozable(quietDone)
              && !SessionSnoozes.snoozable(Row(id: "pid:9", group: .yourTurn, title: "t", context: "", since: Date(),
                                               terminal: true)))
    let snoozer = SessionModel(defaults: snoozeDefaults)
    snoozer.setRows([asker, reviewAsk, busy])
    snoozer.now = Date()
    snoozer.snooze(asker, until: Date().addingTimeInterval(3600))
    snoozer.snooze(reviewAsk, until: Date().addingTimeInterval(7200))
    let snoozedBoard = Board(rows: snoozer.rows, now: snoozer.now)
    check("a snoozed session leaves Your turn for Snoozed",
          snoozedBoard.yourTurn.isEmpty && Set(snoozedBoard.snoozed.map(\.id)) == ["local_z1", "local_z2"])
    check("snoozed: no amber glow", snoozer.freshNeedsYou(snoozedBoard).isEmpty)
    let snoozedList = FloatingRows(board: snoozedBoard, now: snoozer.now, within: 86400, finishedWithin: 7200)
    check("snoozed asking rows leave the strip",
          FloatingView.Compact(snoozedList).waiting.isEmpty && FloatingView.stripRows(snoozedList).shown.map(\.id) == ["local_z3"])
    check("Snoozed lists the soonest to wake first", snoozedList.snoozed.map(\.id) == ["local_z1", "local_z2"])
    check("snoozed sessions aren't listed in the window", !snoozedList.all.contains(where: \.snoozed))
    check("a snooze is kept in the settings", Set(SessionSnoozes.load(snoozeDefaults).byId.keys) == ["local_z1", "local_z2"])
    check("a snooze leaves running rows alone",
          SessionSnoozes(byId: ["local_z3": .init(until: .distantFuture, at: Date())]).apply(to: [busy], now: Date())[0].snoozedUntil == nil)
    // You answer it (or it ends another turn): the snooze is over.
    let movedOn = Row(id: "local_z2", group: .running, title: "Ship the fix", context: "", since: Date().addingTimeInterval(5),
                      link: "local_z2")
    snoozer.setRows([asker, movedOn, busy])
    check("a session that moves on wakes", snoozer.snoozes.byId["local_z2"] == nil
              && Board(rows: snoozer.rows, now: snoozer.now).snoozed.map(\.id) == ["local_z1"])
    snoozer.wake(asker)
    check("Wake Now brings it back", Board(rows: snoozer.rows, now: snoozer.now).yourTurn.map(\.id) == ["local_z1"])
    // A snooze that runs out: back in Your turn, glowing amber as if it had just asked.
    let oldAsk = Row(id: "local_z4", group: .yourTurn, title: "Old question", context: "",
                     since: Date().addingTimeInterval(-5 * 3600), link: "local_z4")
    snoozer.setRows([oldAsk])
    snoozer.snooze(oldAsk, until: Date().addingTimeInterval(-1))
    snoozer.wakeDue()
    let wokenBoard = Board(rows: snoozer.rows, now: snoozer.now)
    check("a snooze that ran out wakes and glows amber again",
          wokenBoard.yourTurn.map(\.id) == ["local_z4"] && snoozer.freshNeedsYou(wokenBoard).map(\.id) == ["local_z4"])
    snoozer.snooze(oldAsk, until: Date().addingTimeInterval(3600))
    snoozer.forgetArchived(["local_z4"])
    check("archiving drops its snooze", snoozer.snoozes.byId.isEmpty && Board(rows: snoozer.rows, now: snoozer.now).snoozed.isEmpty)
    check("the snooze symbols exist", ["moon.zzz", "moon.zzz.fill", "eye.slash"].allSatisfy {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
    // A finished session can be snoozed too, and comes back to the window's
    // Finished when it wakes, however long ago it finished.
    let oldDone = Row(id: "local_z5", group: .done, title: "Tidy the tabs", context: "",
                      since: Date().addingTimeInterval(-3 * 3600), link: "local_z5")
    check("a finished Claude session can be snoozed", SessionSnoozes.snoozable(oldDone))
    snoozer.setRows([oldDone])
    snoozer.snooze(oldDone, until: Date().addingTimeInterval(-1))
    snoozer.wakeDue()
    let wokenDone = FloatingRows(board: Board(rows: snoozer.rows, now: Date()), now: Date(), within: 86400,
                                 finishedWithin: 7200, woke: snoozer.wokeAt)
    check("a finished session that wakes is back in the window's Finished, with no amber",
          wokenDone.finished.map(\.id) == ["local_z5"]
              && snoozer.freshNeedsYou(Board(rows: snoozer.rows, now: Date())).isEmpty)
    snoozeDefaults.removePersistentDomain(forName: snoozeSuite)

    // Hide: out of the window and the counts until the session next changes.
    let hideSuite = "limbo-tasks-selftest-hide"
    let hideDefaults = UserDefaults(suiteName: hideSuite)!
    hideDefaults.removePersistentDomain(forName: hideSuite)
    let doneTabs = Row(id: "local_h1", group: .done, title: "Chrome tabs cleanup", context: "",
                       since: Date().addingTimeInterval(-120), link: "local_h1")
    let cursorDone = Row(id: "cursor:h2", group: .done, title: "Rename the keys", context: "",
                         since: Date().addingTimeInterval(-300), link: cursorLinkPrefix + "h2")
    let askingDone = Row(id: "local_h3", group: .yourTurn, title: "Plan it", ask: "Which order?", context: "",
                         since: Date().addingTimeInterval(-60), link: "local_h3")
    let busyHide = Row(id: "local_h4", group: .running, title: "Busy", context: "", since: Date(), link: "local_h4")
    check("finished, waiting and other apps' rows can be hidden; running ones can't",
          SessionHides.hideable(doneTabs) && SessionHides.hideable(cursorDone) && SessionHides.hideable(askingDone)
              && !SessionHides.hideable(busyHide))
    let hider = SessionModel(defaults: hideDefaults)
    hider.now = Date()
    hider.setRows([doneTabs, cursorDone, askingDone, busyHide])
    hider.hide(doneTabs)
    hider.hide(cursorDone)
    hider.hide(askingDone)
    let hiddenBoard = Board(rows: hider.rows, now: hider.now)
    let hiddenList = FloatingRows(board: hiddenBoard, now: hider.now, within: 86400, finishedWithin: 7200)
    check("hidden sessions leave the window, the strip and the counts, and the panel lists them",
          Set(hiddenBoard.hidden.map(\.id)) == ["local_h1", "cursor:h2", "local_h3"]
              && hiddenBoard.done.isEmpty && hiddenBoard.yourTurn.isEmpty
              && hiddenList.all.map(\.id) == ["local_h4"] && hiddenList.snoozed.isEmpty
              && FloatingView.stripRows(hiddenList).finished.isEmpty && hider.freshNeedsYou(hiddenBoard).isEmpty)
    check("a hide is kept in the settings",
          Set(SessionHides.load(hideDefaults).byId.keys) == ["local_h1", "cursor:h2", "local_h3"])
    // It changes: running again, or a newer turn. Back where it was, and the hide is gone.
    let tabsAgain = Row(id: "local_h1", group: .running, title: "Chrome tabs cleanup", context: "",
                        since: Date().addingTimeInterval(1), link: "local_h1")
    let cursorNewer = Row(id: "cursor:h2", group: .done, title: "Rename the keys", context: "",
                          since: Date().addingTimeInterval(2), link: cursorLinkPrefix + "h2")
    hider.setRows([tabsAgain, cursorNewer, askingDone, busyHide])
    let changedBoard = Board(rows: hider.rows, now: Date().addingTimeInterval(3))
    check("a hidden session that runs again, or ends a newer turn, comes back",
          changedBoard.hidden.map(\.id) == ["local_h3"] && Set(changedBoard.running.map(\.id)) == ["local_h1", "local_h4"]
              && changedBoard.done.map(\.id) == ["cursor:h2"] && Set(hider.hides.byId.keys) == ["local_h3"])
    hider.unhide(askingDone)
    check("Show Again brings it back at once", Board(rows: hider.rows, now: Date()).yourTurn.map(\.id) == ["local_h3"])
    hider.hide(askingDone)
    hider.forgetArchived(["local_h3"])
    check("archiving drops its hide", hider.hides.byId.isEmpty)
    var staleHides = SessionHides(byId: ["gone": Date().addingTimeInterval(-9 * 86400), "kept": Date()])
    _ = staleHides.prune([], now: Date())
    check("a hide whose session has left every list is dropped", Set(staleHides.byId.keys) == ["kept"])
    hideDefaults.removePersistentDomain(forName: hideSuite)

    print(failed == 0 ? "all passed" : "\(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

/// Runs Random in an offscreen window: prints the effect showing each second,
/// then the CPU the process used meanwhile. Checks the 5-second shuffle.
func runGlowCycle(seconds: Int) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let glow = RunningGlowView(frame: window.contentView?.bounds ?? .zero)
    glow.forceMotion = true
    window.contentView?.addSubview(glow)
    glow.layoutSubtreeIfNeeded()
    glow.configure(style: .random, color: .red)
    glow.setActive(true)
    func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    let start = cpu()
    for second in 0...seconds {
        let state = glow.state
        print(second, state["showing"] ?? "", "animating:", state["animating"] ?? "", "size:", state["width"] ?? "", state["height"] ?? "")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }
    print(String(format: "cpu %.3f s over %d s", cpu() - start, seconds))
    exit(0)
}

/// Drags the keep-on-top window's right and bottom edges and its corner with
/// synthetic clicks on the same views as the real window (rows, resize band
/// on top), then checks the background cursor setting is on only while on an
/// edge and the app never becomes frontmost. The window is on screen (a resize
/// stays inside the screen) but invisible and click-through. Which cursor
/// macOS shows can only be read with the real pointer resting on the window
/// (NSCursor.currentSystem); synthetic moves don't drive tracking areas.
func runResizeCheck() {
    _ = NSApplication.shared
    let model = SessionModel()
    model.setRows(sampleRows(now: Date()))
    let layout = FloatingLayout()
    let host = FirstClickHostingView(rootView: FloatingView(model: model, open: { _ in }, unpin: {},
                                                            glow: RunningGlowView(frame: .zero), layout: layout))
    let size = host.fittingSize
    let panel = KeepOnTopPanel(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let content = NSView(frame: NSRect(origin: .zero, size: size))
    host.frame = content.bounds
    host.autoresizingMask = [.width, .height]
    let edges = ResizeEdgesView(frame: content.bounds)
    edges.autoresizingMask = [.width, .height]
    content.addSubview(host)
    content.addSubview(edges)
    panel.contentView = content
    panel.alphaValue = 0
    panel.ignoresMouseEvents = true
    panel.orderFrontRegardless()
    var mouse = NSPoint.zero
    edges.mouseLocation = { mouse }
    edges.onResize = { frame, _ in panel.setFrame(frame, display: true) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print(ok ? "pass" : "FAIL", name, detail)
        if !ok { failed += 1 }
    }
    func send(_ type: NSEvent.EventType, at point: NSPoint) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        panel.sendEvent(event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    /// Presses at `point` (window coordinates) and drags by `delta`.
    func drag(from point: NSPoint, by delta: NSPoint) -> (before: NSRect, after: NSRect) {
        let before = panel.frame
        mouse = panel.convertPoint(toScreen: point)
        send(.leftMouseDown, at: point)
        mouse = NSPoint(x: mouse.x + delta.x, y: mouse.y + delta.y)
        let to = NSPoint(x: point.x + delta.x, y: point.y + delta.y)
        send(.leftMouseDragged, at: to)
        send(.leftMouseUp, at: to)
        return (before, panel.frame)
    }

    let w = size.width, h = size.height
    check("the right edge takes the click", content.hitTest(NSPoint(x: w - 2, y: h / 2)) === edges)
    check("the bottom edge takes the click", content.hitTest(NSPoint(x: w / 2, y: 2)) === edges)
    check("inside, clicks reach the rows", content.hitTest(NSPoint(x: w / 2, y: h / 2)) !== edges)
    var moved = drag(from: NSPoint(x: w - 2, y: h / 2), by: NSPoint(x: 60, y: 0))
    check("dragging the right edge widens", moved.after.width == moved.before.width + 60
              && moved.after.minX == moved.before.minX && moved.after.height == moved.before.height,
          "(\(NSStringFromRect(moved.before)) -> \(NSStringFromRect(moved.after)))")
    moved = drag(from: NSPoint(x: panel.frame.width / 2, y: 2), by: NSPoint(x: 0, y: -50))
    check("dragging the bottom edge down makes it taller, top fixed", moved.after.height == moved.before.height + 50
              && moved.after.maxY == moved.before.maxY && moved.after.width == moved.before.width,
          "(\(NSStringFromRect(moved.before)) -> \(NSStringFromRect(moved.after)))")
    moved = drag(from: NSPoint(x: panel.frame.width - 2, y: 2), by: NSPoint(x: -30, y: 20))
    check("dragging the bottom-right corner does both", moved.after.width == moved.before.width - 30
              && moved.after.height == moved.before.height - 20 && moved.after.maxY == moved.before.maxY,
          "(\(NSStringFromRect(moved.before)) -> \(NSStringFromRect(moved.after)))")

    let me = ProcessInfo.processInfo.processIdentifier
    func frontmostIsMe() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == me }
    let w2 = panel.frame.width, h2 = panel.frame.height
    check("the background cursor setting is available", BackgroundCursor.available)
    edges.hover(at: NSPoint(x: w2 - 2, y: h2 / 2))
    check("on the right edge the background cursor setting is on", BackgroundCursor.allowed)
    edges.hover(at: NSPoint(x: w2 / 2, y: h2 / 2))
    check("moving inside turns it off", !BackgroundCursor.allowed)
    edges.hover(at: NSPoint(x: w2 - 3, y: 4))
    check("on the corner it is on", BackgroundCursor.allowed)
    edges.hover(at: nil)
    check("leaving turns it off", !BackgroundCursor.allowed)
    _ = drag(from: NSPoint(x: w2 / 2, y: 2), by: NSPoint(x: 0, y: 30))
    check("a drag that ends off the edges leaves it off", !BackgroundCursor.allowed)
    check("Limbo Tasks never became the frontmost app", !frontmostIsMe(),
          "(in front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
    panel.orderOut(nil)
    print(failed == 0 ? "all passed" : "\(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

/// Double-clicks the keep-on-top window's header, then the pill, with
/// synthetic clicks in an off-screen window, and reports the mini setting.
func runGestureCheck() {
    _ = NSApplication.shared
    recordTestFrames = true
    let model = SessionModel()
    model.setRows(sampleRows(now: Date()))
    let layout = FloatingLayout()
    let glow = RunningGlowView(frame: .zero)
    var unpinned = false
    var opened: [String] = []
    var answered: [String] = []
    let host = FirstClickHostingView(rootView: FloatingView(model: model, open: { opened.append($0.id) },
                                                            unpin: { unpinned = true },
                                                            glow: glow, layout: layout,
                                                            answer: { row, label in answered.append("\(row.id):\(label)") }))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let panel = KeepOnTopPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
    panel.contentView = host
    panel.setFrameOrigin(NSPoint(x: -6000, y: -6000))
    panel.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    glow.configure(style: .aurora, color: .red)
    glow.setMode(.running)
    func refit() {
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.frame.size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    func click(at point: NSPoint, times: Int = 1) {
        for count in 1...times {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
                panel.sendEvent(event)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    func glowState() -> String {
        "glow in window: \(glow.window != nil), size \(Int(glow.bounds.width))x\(Int(glow.bounds.height)), animating: \(glow.state["animating"] ?? "-")"
    }
    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print(ok ? "pass" : "FAIL", name, detail)
        if !ok { failed += 1 }
    }
    let fullHeight = host.frame.height
    let headerY = host.frame.height - 18
    // A single click on the first count chip filters the list.
    click(at: NSPoint(x: 45, y: headerY))
    refit()
    check("a single click on a chip filters", host.frame.height < fullHeight,
          "(height \(Int(fullHeight)) -> \(Int(host.frame.height)))")
    click(at: NSPoint(x: 45, y: host.frame.height - 18))
    refit()
    check("clicking it again shows everything", host.frame.height == fullHeight)
    // A double-click on a chip doesn't shrink the window.
    click(at: NSPoint(x: 45, y: host.frame.height - 18), times: 2)
    refit()
    check("a double-click on a chip doesn't shrink to the pill", !layout.mini)
    if host.frame.height != fullHeight { click(at: NSPoint(x: 45, y: host.frame.height - 18)); refit() }
    // Double-click the header's empty middle: the pill, with the glow.
    let middle = testFrames["header-middle"].map { NSPoint(x: $0.midX, y: host.frame.height - $0.midY) }
    click(at: middle ?? NSPoint(x: 175, y: host.frame.height - 18), times: 2)   // between the chips and the menus
    refit()
    check("double-clicking the header shrinks to the pill", layout.mini, "(\(NSStringFromSize(host.frame.size)))")
    check("the glow comes along to the pill", glow.window != nil && Int(glow.bounds.height) == 32, glowState())
    click(at: NSPoint(x: host.frame.width / 2, y: host.frame.height / 2), times: 2)
    refit()
    check("double-clicking the pill expands it", !layout.mini)
    check("the glow comes back to the window", glow.window != nil && glow.bounds.height == host.frame.height
              && glow.bounds.height > 100, glowState())
    // The other layouts: one line for the strip, smaller still for the dots,
    // full width for the bar, wide and short for the columns. A click on a
    // session opens it; a double-click on the mark goes back to the list.
    func point(_ name: String) -> NSPoint? {
        testFrames[name].map { NSPoint(x: $0.midX, y: host.frame.height - $0.midY) }
    }
    let listHeight = host.frame.height
    layout.choose(.strip)
    refit()
    check("the strip is one line", host.frame.height == 32 && host.frame.width > 300, "(\(NSStringFromSize(host.frame.size)))")
    check("the glow comes along to the strip", glow.window != nil && Int(glow.bounds.height) == 32, glowState())
    opened.removeAll()
    if let chip = point("chip:local_s4") { click(at: chip) }
    check("a click on a chip opens its session", opened == ["local_s4"], "(opened \(opened))")
    click(at: NSPoint(x: 14, y: host.frame.height / 2), times: 2)
    refit()
    check("double-clicking the strip's mark goes back to the list", layout.chosen == .list && host.frame.height == listHeight)
    layout.choose(.dots)
    refit()
    check("the dots are smaller still", host.frame.height == 26 && host.frame.width < 300, "(\(NSStringFromSize(host.frame.size)))")
    opened.removeAll()
    if let dot = point("dot:local_s1") { click(at: dot) }
    check("a click on a mark opens its session", opened == ["local_s1"], "(opened \(opened))")
    layout.choose(.bar)
    refit()
    check("the bar is as wide as it's told and one line", host.frame.width == layout.barWidth && host.frame.height == 30,
          "(\(NSStringFromSize(host.frame.size)))")
    opened.removeAll()
    if let item = point("bar:local_s1") { click(at: item) }
    check("a click in the bar opens its session", opened == ["local_s1"], "(opened \(opened))")
    layout.choose(.columns)
    refit()
    check("the columns are wide and shorter than the list",
          host.frame.width == layout.columnsWidth && host.frame.height < listHeight, "(\(NSStringFromSize(host.frame.size)))")
    layout.choose(.list)
    refit()
    check("and back to the list", host.frame.height == listHeight)
    // A card's button opens its session; the response button shows the reply
    // without opening anything. Their places are recorded as they are laid out.
    func place(of name: String) -> NSPoint? {
        testFrames[name].map { NSPoint(x: $0.midX, y: host.frame.height - $0.midY) }   // SwiftUI's y runs down
    }
    if let point = place(of: "answer:local_s6:0") {
        click(at: point)
        check("a card's button opens its session", opened.last == "local_s6", "(opened \(opened))")
    } else {
        check("a card's button opens its session", false, "(button not found)")
    }
    // With "Answer from Cards" on (this binary's own settings, put back after),
    // the same button answers in place and opens nothing.
    let wasOn = UserDefaults.standard.bool(forKey: ClaudeAnswerer.enabledKey)
    UserDefaults.standard.set(true, forKey: ClaudeAnswerer.enabledKey)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    opened.removeAll()
    if let point = place(of: "answer:local_s6:0") {
        click(at: point)
        check("with Answer from Cards on, the button answers instead of opening",
              answered == ["local_s6:Commit and push"] && opened.isEmpty, "(answered \(answered), opened \(opened))")
    }
    UserDefaults.standard.set(wasOn, forKey: ClaudeAnswerer.enabledKey)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    opened.removeAll()
    let closedHeight = host.frame.height
    if let point = place(of: "response:local_s7") {
        click(at: point)
        refit()
        check("the response button shows the reply without opening the session",
              host.frame.height > closedHeight && opened.isEmpty,
              "(height \(Int(closedHeight)) -> \(Int(host.frame.height)), opened \(opened))")
        if let again = place(of: "response:local_s7") { click(at: again); refit() }
        check("and hides it again", host.frame.height == closedHeight && opened.isEmpty)
    } else {
        check("the response button shows the reply without opening the session", false, "(button not found)")
    }
    // Snooze from a hover card: the session leaves the strip for the moon's
    // count, and the moon's menu can wake it. Own settings, cleared after.
    let snoozeSuite = "limbo-tasks-gesture-snooze"
    let snoozeDefaults = UserDefaults(suiteName: snoozeSuite)!
    snoozeDefaults.removePersistentDomain(forName: snoozeSuite)
    let snoozeModel = SessionModel(defaults: snoozeDefaults)
    snoozeModel.setRows(sampleRows(now: Date()).filter { $0.snoozedUntil == nil })
    let stripLayout = FloatingLayout(chosen: .strip)
    let stripHost = FirstClickHostingView(rootView: FloatingView(model: snoozeModel, open: { _ in }, unpin: {},
                                                                 glow: nil, layout: stripLayout,
                                                                 initialHover: "local_s1"))
    stripHost.frame = NSRect(origin: .zero, size: stripHost.fittingSize)
    let stripPanel = KeepOnTopPanel(contentRect: stripHost.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
    stripPanel.contentView = stripHost
    stripPanel.setFrameOrigin(NSPoint(x: -6000, y: -5000))
    stripPanel.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    stripHost.frame = NSRect(origin: .zero, size: stripHost.fittingSize)
    stripPanel.setContentSize(stripHost.frame.size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if let button = testFrames["snooze:local_s1:hour"] {
        let at = NSPoint(x: button.midX, y: stripHost.frame.height - button.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: stripPanel.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            stripPanel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let until = snoozeModel.snoozes.byId["local_s1"]?.until.timeIntervalSinceNow ?? 0
        check("a hover card's 1h button snoozes the session for an hour", (3590...3600).contains(until),
              "(\(Int(until)) s)")
        stripHost.frame = NSRect(origin: .zero, size: stripHost.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let stillThere = FloatingView.stripRows(FloatingRows(board: Board(rows: snoozeModel.rows, now: Date()), now: Date(),
                                                             within: 86400, finishedWithin: 7200)).shown.map(\.id)
        check("it leaves the strip, and the moon counts it",
              !stillThere.contains("local_s1") && testFrames["snoozed-chip"] != nil && stripHost.frame.height == 32,
              "(strip \(stillThere), height \(Int(stripHost.frame.height)))")
    } else {
        check("a hover card's 1h button snoozes the session for an hour", false, "(button not found)")
    }
    stripPanel.orderOut(nil)
    snoozeDefaults.removePersistentDomain(forName: snoozeSuite)
    // Hide from a finished chip's hover card: the session leaves the strip
    // until it next changes. Own settings, cleared after.
    let hideSuite = "limbo-tasks-gesture-hide"
    let hideDefaults = UserDefaults(suiteName: hideSuite)!
    hideDefaults.removePersistentDomain(forName: hideSuite)
    let hideModel = SessionModel(defaults: hideDefaults)
    hideModel.setRows(sampleRows(now: Date()).filter { $0.snoozedUntil == nil })
    let hideHost = FirstClickHostingView(rootView: FloatingView(model: hideModel, open: { _ in }, unpin: {},
                                                               glow: nil, layout: FloatingLayout(chosen: .strip),
                                                               initialHover: "local_s8"))
    hideHost.frame = NSRect(origin: .zero, size: hideHost.fittingSize)
    let hidePanel = KeepOnTopPanel(contentRect: hideHost.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
    hidePanel.contentView = hideHost
    hidePanel.setFrameOrigin(NSPoint(x: -6000, y: -4000))
    hidePanel.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    hideHost.frame = NSRect(origin: .zero, size: hideHost.fittingSize)
    hidePanel.setContentSize(hideHost.frame.size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if let button = testFrames["hide:local_s8"] {
        let at = NSPoint(x: button.midX, y: hideHost.frame.height - button.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: hidePanel.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            hidePanel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let left = FloatingView.stripRows(FloatingRows(board: Board(rows: hideModel.rows, now: Date()), now: Date(),
                                                       within: 86400, finishedWithin: 7200))
        check("a finished chip's Hide button hides it until it changes",
              hideModel.hides.byId["local_s8"] != nil && !(left.shown + left.finished).contains { $0.id == "local_s8" },
              "(finished chips \(left.finished.map(\.id)))")
    } else {
        check("a finished chip's Hide button hides it until it changes", false, "(button not found)")
    }
    hidePanel.orderOut(nil)
    hideDefaults.removePersistentDomain(forName: hideSuite)
    // Hide on a row in the list, under the pointer (drawn as if hovered): one click.
    let rowHideSuite = "limbo-tasks-gesture-row-hide"
    let rowHideDefaults = UserDefaults(suiteName: rowHideSuite)!
    rowHideDefaults.removePersistentDomain(forName: rowHideSuite)
    let rowHideModel = SessionModel(defaults: rowHideDefaults)
    rowHideModel.setRows(sampleRows(now: Date()).filter { $0.snoozedUntil == nil })
    forcedHover = "local_s8"
    let rowHost = FirstClickHostingView(rootView: FloatingView(model: rowHideModel, open: { opened.append($0.id) }, unpin: {},
                                                              glow: nil, layout: FloatingLayout()))
    rowHost.frame = NSRect(origin: .zero, size: rowHost.fittingSize)
    let rowPanel = KeepOnTopPanel(contentRect: rowHost.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
    rowPanel.contentView = rowHost
    rowPanel.setFrameOrigin(NSPoint(x: -6000, y: -3000))
    rowPanel.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    rowHost.frame = NSRect(origin: .zero, size: rowHost.fittingSize)
    rowPanel.setContentSize(rowHost.frame.size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let openedBefore = opened
    if let button = testFrames["row-hide:local_s8"] {
        let at = NSPoint(x: button.midX, y: rowHost.frame.height - button.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: rowPanel.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            rowPanel.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let listed = FloatingRows(board: Board(rows: rowHideModel.rows, now: Date()), now: Date(), within: 86400,
                                  finishedWithin: 7200).all.map(\.id)
        check("a row's Hide button hides it in one click, without opening it",
              rowHideModel.hides.byId["local_s8"] != nil && !listed.contains("local_s8") && opened == openedBefore,
              "(listed \(listed), opened \(opened))")
    } else {
        check("a row's Hide button hides it in one click, without opening it", false, "(button not found)")
    }
    forcedHover = nil
    rowPanel.orderOut(nil)
    rowHideDefaults.removePersistentDomain(forName: rowHideSuite)
    // New Tag…: the box takes the keyboard without making Limbo the active app,
    // and Return adds what was typed; Esc adds nothing.
    let prompt = TagPrompt()
    var typedTag: String?
    let activeBefore = NSApp.isActive
    let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
    prompt.show(for: "Rename the billing exports") { typedTag = $0 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let editor = prompt.window?.firstResponder as? NSTextView
    check("the new-tag box takes the keyboard", prompt.window?.isKeyWindow == true && editor != nil)
    // While the box has the keyboard AppKit counts Limbo as active, but the
    // app in front stays the one you were in, and gets the keyboard back after.
    let frontAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
    check("without bringing Limbo to the front", frontAfter == frontBefore && frontAfter != getpid(),
          "(in front \(frontBefore ?? 0) -> \(frontAfter ?? 0), me \(getpid()))")
    editor?.insertText("Waiting on design", replacementRange: NSRange(location: NSNotFound, length: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    editor?.insertNewline(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check("Return adds the typed tag, closes the box and lets go of the keyboard",
          typedTag == "Waiting on design" && !prompt.isShowing && NSApp.isActive == activeBefore,
          "(got \(typedTag ?? "nothing"), active \(NSApp.isActive))")
    typedTag = nil
    prompt.show(for: "Rename the billing exports") { typedTag = $0 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    (prompt.window?.firstResponder as? NSTextView)?.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    if let window = prompt.window,
       let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                     isARepeat: false, keyCode: 53) {
        window.sendEvent(escape)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check("Esc closes it without adding", typedTag == nil && !prompt.isShowing)
    prompt.close()
    // A single click on the close button still works.
    click(at: NSPoint(x: host.frame.width - 20, y: host.frame.height - 18))
    check("the close button takes a single click", unpinned)
    print(failed == 0 ? "all passed" : "\(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

if arguments.contains("--gesture-check") {
    runGestureCheck()
}
if arguments.contains("--resize-check") {
    runResizeCheck()
}
if arguments.contains("--self-test") {
    runSelfTest()
}
if let seconds = argument(after: "--glow-cycle").flatMap(Int.init) {
    runGlowCycle(seconds: seconds)
}
if let path = argument(after: "--snapshot") {
    writeSnapshot(to: path, dark: arguments.contains("--dark"), sample: arguments.contains("--sample"),
                  expand: arguments.contains("--expand"), limit: argument(after: "--rows").flatMap(Int.init))
    exit(0)
}
if arguments.contains("--codex-bench") {
    runCodexBench()
    exit(0)
}
if arguments.contains("--cursor-bench") {
    runAppBench(AppThreadsWatcher.cursor(), name: "Cursor")
    exit(0)
}
if arguments.contains("--orca-bench") {
    runAppBench(AppThreadsWatcher.orca(adopted: AdoptedIds()), name: "Orca")
    exit(0)
}
if arguments.contains("--antigravity-bench") {
    runAppBench(AppThreadsWatcher.antigravity(), name: "Antigravity")
    exit(0)
}
if arguments.contains("--dump") {
    runDump()
    exit(0)
}
if let id = argument(after: "--open") {
    // Opens one row the way a click does: pid:<pid> for a terminal session, local_<id> for a desktop one.
    guard let row = SessionEngine.scanOnce().first(where: { $0.id == id }), row.openURL != nil else {
        print("no openable row \(id)")
        exit(1)
    }
    print("\(row.openLabel): \(row.id)")
    openRow(row)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    RunLoop.main.run()
}
if let cycles = argument(after: "--bench-panel").flatMap(Int.init) {
    runPanelBench(cycles: cycles, reuse: !arguments.contains("--fresh"), real: arguments.contains("--real"),
                  hold: argument(after: "--hold").flatMap(Double.init) ?? 0)
}

guard isOnlyInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
