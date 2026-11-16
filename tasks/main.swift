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
//       keep-on-top window shows. What a running session is doing now, and how a
//       finished one's latest turn ended (its question, buttons and reply).
// Never opened: the *.key files beside the live records, and every other file
// in those folders (waiting-input/, backlog/, deleted_*, ...).
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
            })
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
/// monitors) are still running: their output files, …/<session>/tasks/<id>.output,
/// held open by the session's own child shells. Its process can be idle the
/// whole time, between turns. A few system calls per idle session; no process
/// is started and nothing is read.
func runningBackgroundTasks(parent: Int32, session: String) -> Int {
    var children = [pid_t](repeating: 0, count: 64)
    let count = Int(proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.stride)))
    guard count > 0 else { return 0 }
    let marker = "/\(session)/tasks/"
    var files = Set<String>()
    for child in children.prefix(min(count, children.count)) {
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
    return files.count
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
              background: [Int32: Int] = [:]) -> [Row] {
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
        rows.append(Row(id: "pid:\(l.pid)", group: group, title: l.name,
                        ask: l.isWaiting ? (l.waitingFor ?? "Waiting for your input") : nil,
                        context: folderLabel(l.cwd), since: l.statusSince, terminal: true,
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

    init(rows: [Row], now: Date) {
        for r in rows {
            let age = now.timeIntervalSince(r.since)
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
            && review.isEmpty && done.isEmpty && terminal.isEmpty
    }
}

// MARK: - Engine

/// Owns all file access, on one low-priority serial queue.
final class SessionEngine {
    let queue = DispatchQueue(label: "com.maheshauti.limbo-tasks.data", qos: .utility)
    /// Called on the main queue, only when the rows changed.
    var onRows: (([Row]) -> Void)?

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
    private var cardReads = 0
    /// A record is written about 2 s after its transcript ends, which triggers a
    /// look; this also looks every 30 s in case a transcript ends later.
    private var cardCheck: DispatchSourceTimer?

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
            return classify(desk: engine.desk.values.compactMap(\.record), live: engine.live, now: Date(),
                            activities: activities, cards: engine.currentCards(), background: engine.backgroundWork())
        }
    }

    private func reloadLive() {
        let result = readLiveRecords(exited: exited)
        live = result.records
        exited.formIntersection(result.present)
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

    private func publishIfChanged() {
        let rows = classify(desk: desk.values.compactMap(\.record), live: live, now: Date(), activities: activities,
                            cards: currentCards(), background: backgroundWork())
        guard rows != lastRows else { return }
        lastRows = rows
        DispatchQueue.main.async { [weak self] in self?.onRows?(rows) }
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
            return now.timeIntervalSince(row.since) <= freshFor && (opened.map { $0 < row.since } ?? true)
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
    var color: NSColor = .systemBlue {
        didSet { if color != oldValue { applyColors() } }
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        wantsLayer = true
        // Set up as is, or the arc animates in from a full ring.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let ring = CGPath(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 11, height: 11), transform: nil)
        for shape in [track, arc] {
            shape.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            shape.path = ring
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0.3
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

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
    func makeNSView(context: Context) -> SpinnerView { SpinnerView(frame: .zero) }
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

/// One mark per state, told apart by shape as well as colour: a turning ring
/// (running), an hourglass (running but quiet), an exclamation (needs you),
/// an eye (ready for review), a check (finished), a ring (idle terminal).
struct Indicator: View {
    let group: Group
    var quiet = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.highContrast) private var forcedContrast

    var body: some View {
        let p = Palette(scheme, contrast: forcedContrast || systemContrast == .increased)
        ZStack {
            switch group {
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
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
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
        parts.append(canOpen ? "Click to open in Claude" : "Started in a terminal, so it can't be opened from here")
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        Button { if canOpen { open(row) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Indicator(group: row.group, quiet: quiet != nil).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(.system(size: 13, weight: row.group == .done ? .regular : .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        trailing
                    }
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
        .pointerStyle(canOpen ? .link : nil)
        .onHover { hovering = $0 }
        .opacity(dimmed ? 0.72 : 1)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(stateWord)")
        .accessibilityValue(secondLine ?? meta)
        .accessibilityHint(canOpen ? "Opens the session in Claude" : "")
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
        .pointerStyle(.link)
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
        .pointerStyle(.link)
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
        guard let id = row.link, isSessionId(id),
              let url = URL(string: "claude://claude.ai/epitaxy/\(id)") else { return }
        popover?.performClose(nil)
        model.markOpened(row)
        NSWorkspace.shared.open(url)
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
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.highContrast) private var contrast

    private var response: String? { toggleResponse == nil ? nil : row.card?.response }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line
                // Beside the row's own button, not inside it, so a click here never opens the session.
                .overlay(alignment: .topTrailing) {
                    if let toggleResponse, response != nil {
                        ResponseToggle(shown: responseShown, action: toggleResponse)
                            .testFrame("response:\(row.id)")
                            .padding(.top, 2)
                            .padding(.trailing, 4)
                    }
                }
            if responseShown, let response {
                ResponseDrawer(text: response, open: { open(row) })
                    .padding(.leading, 32)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
            }
        }
    }

    private var line: some View {
        let quiet = row.quiet(now: now)
        let p = Palette(scheme, contrast: contrast)
        // A question from the session's next-step box, when it is not shown as a card.
        let question = row.group == .running ? nil : row.card?.ask
        return Button { if row.link != nil { open(row) } } label: {
            HStack(alignment: .top, spacing: 8) {
                Indicator(group: row.group, quiet: quiet != nil)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title).font(.system(size: 12, weight: contrast ? .bold : .medium))
                            .lineLimit(1).truncationMode(.tail)
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
                        }
                        if response != nil { Color.clear.frame(width: 18, height: 1) }   // room for the response button
                    }
                    if let quiet {
                        Text([quietPhrase(quiet, compact: true), row.activity].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(p.quiet).lineLimit(1).truncationMode(.tail)
                    } else if let line = question ?? (row.group == .yourTurn ? row.ask
                        : (row.group == .review ? row.detail : (row.group == .running ? row.activity : nil))) {
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
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering && row.link != nil ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .pointerStyle(row.link != nil ? .link : nil)
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
        .pointerStyle(.link)
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
            Button(action: open) {
                HStack(spacing: 3) {
                    Text("Open in Claude")
                    Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p.review)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel("Open the session in Claude")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(contrast ? 0.1 : 0.06)))
    }

    /// Bold, italics, code and web links; the reply's line breaks are kept.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
    /// The button being pressed right now, and why the last click only opened the session.
    var answering: String? = nil
    var note: String? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.highContrast) private var contrast

    var body: some View {
        let p = Palette(scheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { open(row) } label: {
                    HStack(spacing: 6) {
                        Indicator(group: row.group)
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
                .pointerStyle(.link)
                .help("Open in Claude")
                if card.response != nil {
                    ResponseToggle(shown: responseShown, action: toggleResponse).testFrame("response:\(row.id)")
                }
            }
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(contrast ? 0.1 : 0.06)))
        .overlay {
            if contrast {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.5))
            }
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
        .pointerStyle(.link)
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
    /// Waiting or review sessions older than the header's time choice.
    let hidden: Int

    init(board: Board, now: Date, within limit: TimeInterval, finishedWithin: TimeInterval) {
        let allWaiting = board.yourTurn + board.older
        running = board.running
        waiting = allWaiting.filter { now.timeIntervalSince($0.since) <= limit }
        review = board.review.filter { now.timeIntervalSince($0.since) <= limit }
        finished = board.justFinished + board.done.filter { now.timeIntervalSince($0.since) <= finishedWithin }
        hidden = (allWaiting + board.review).filter { now.timeIntervalSince($0.since) > limit }.count
    }

    var all: [Row] { running + waiting + review + finished }

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
    /// Answering from a card: presses its button in Claude (when the switch is on).
    var answer: ((Row, String) -> Void)? = nil
    @ObservedObject var answers = AnswerStatus()
    @State private var filter: RowFilter?
    /// The row or card whose latest reply is showing; one at a time.
    @State private var openResponse: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("keepOnTopWaitingHours") private var waitingHours = WaitingWindow.day.rawValue
    @AppStorage(GlowStyle.key) private var glowStyle = GlowStyle.aurora.rawValue
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
    private var solid: Bool { forceSolid ?? reduceTransparency }
    private var palette: Palette { Palette(scheme, contrast: contrast) }
    private var showGotIt: Bool { !status.previewing && (status.mode == .done || status.mode == .needsYou) }

    var body: some View {
        let list = FloatingRows(board: Board(rows: model.rows, now: model.now), now: model.now,
                                within: window.hours * 3600, finishedWithin: Self.doneShownFor)
        SwiftUI.Group {
            if layout.mini { pill(list) } else { full(list) }
        }
        .environment(\.highContrast, contrast)
        .onAppear {
            if let initialFilter { filter = initialFilter }
            if let initialResponse { openResponse = initialResponse }
        }
        .onChange(of: waitingHours) { refit() }
        .onChange(of: layout.width) { refit() }
        .onChange(of: layout.height) { refit() }
        .onChange(of: layout.mini) { refit() }
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
        let carded = Array(rows.filter { $0.group != .running && $0.card?.ask != nil }
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
                        .pointerStyle(.link)
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
        .background { surface(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(contrast ? 0.7 : 0.1)))
    }

    /// The cards ("Waiting on you"), then the other sessions.
    private func content(_ carded: [Row], _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !carded.isEmpty {
                sectionTitle("Waiting on you")
                ForEach(carded) { row in
                    if let card = row.card {
                        AnswerCard(row: row, card: card, now: model.now, open: open,
                                   responseShown: openResponse == row.id,
                                   toggleResponse: { toggleResponse(row.id) },
                                   answer: answerFromCards && answer != nil ? { label in answer?(row, label) } : nil,
                                   answering: answers.answering?.row == row.id ? answers.answering?.label : nil,
                                   note: answers.notes[row.id])
                    }
                }
                if !rows.isEmpty { sectionTitle("Sessions") }
            }
            // With cards, the band sits behind the rows only: the cards have their own fill.
            if !rows.isEmpty { rowStack(rows).background { if !carded.isEmpty { scrim } } }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.time)
            .padding(.leading, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func toggleResponse(_ id: String) {
        openResponse = openResponse == id ? nil : id
    }

    private func rowStack(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                CompactRow(row: row, now: model.now, open: open, responseShown: openResponse == row.id,
                           toggleResponse: row.group == .running ? nil : { toggleResponse(row.id) })
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    /// A soft band behind the text while a running glow moves under it. Outside
    /// the scroll view, so its blurred edge is never cut off.
    @ViewBuilder private var scrim: some View {
        if status.mode == .running && !contrast {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(scheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.4))
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .blur(radius: 18)
        }
    }

    /// The window's background: the blurred material, or a solid one with
    /// Reduce Transparency on.
    @ViewBuilder private func surface<S: Shape>(_ shape: S) -> some View {
        if solid {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    private func header(_ list: FloatingRows, filter active: RowFilter?) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: claudeMark)
                .renderingMode(.template)
                .resizable()
                .frame(width: 15, height: 15)
                .foregroundStyle(.secondary)
            // Full chips when they fit, then compact ones (mark and number),
            // then a check for Got it, then only the chosen filter's chip: the
            // header never grows past the window.
            ViewThatFits(in: .horizontal) {
                headerCounts(list, filter: active, fit: .full)
                headerCounts(list, filter: active, fit: .compact)
                headerCounts(list, filter: active, fit: .compactIcon)
                headerCounts(list, filter: active, fit: .minimal)
            }
            .layoutPriority(1)
            // The empty middle: double-click it for the pill, or drag the window.
            // (On the empty part only, so double-clicking a chip stays a chip click.)
            Color.clear
                .frame(minWidth: 4, maxWidth: .infinity, minHeight: 18, maxHeight: 18)   // never taller
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { setMini(true) }
                .gesture(WindowDragGesture())
                .help("Double-click to shrink to a pill")
            glowMenu
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
            .accessibilityLabel("Stop keeping on top")
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())   // drag the window by its header
        .contextMenu {
            Button("Shrink to Pill") { setMini(true) }
            Divider()
            Button("Fit to Content") { layout.height = nil; layout.save() }
                .disabled(layout.height == nil)
            Button("Default Size") { layout.width = FloatingLayout.defaultWidth; layout.height = nil; layout.save() }
                .disabled(layout.height == nil && layout.width == FloatingLayout.defaultWidth)
            Divider()
            Toggle("Answer from Cards (uses Accessibility)", isOn: $answerFromCards)
        }
    }

    /// How much of the header's middle fits, widest first.
    enum HeaderFit { case full, compact, compactIcon, minimal }

    /// The counts as chips that filter the list, "All finished" or "All
    /// caught up" when there are none, and Got it while it glows amber or green.
    private func headerCounts(_ list: FloatingRows, filter active: RowFilter?, fit: HeaderFit) -> some View {
        let all = RowFilter.allCases.filter { list.count($0) > 0 }
        let kinds = fit == .minimal ? all.filter { $0 == active } : all
        let compact = fit != .full
        let iconGotIt = fit == .compactIcon || (fit == .minimal && !kinds.isEmpty)
        let title = all.isEmpty || ((fit == .full || fit == .compact) && status.mode == .done)
        return HStack(spacing: 5) {
            if title {
                Text(status.mode == .done ? "All finished" : "All caught up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.mode == .done ? Color.primary : palette.time)
                    .lineLimit(1)
            }
            ForEach(kinds, id: \.self) { kind in
                countChip(kind, list.count(kind), selected: active == kind, compact: compact)
            }
            if showGotIt {
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
                .pointerStyle(.link)
                .help(status.mode == .done ? "Got it: stop the green, you've seen that everything finished"
                                           : "Got it: stop the amber glow without opening the session")
                .accessibilityLabel("Got it")
            }
        }
        .fixedSize()
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
            HStack(spacing: 4) {
                if compact {
                    chipMark(kind)
                    Text("\(n)")
                } else {
                    Text(chipTitle(kind, n))
                }
                if selected { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(selected ? tint : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(selected ? tint.opacity(0.2) : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.7) : Color.primary.opacity(contrast ? 0.6 : 0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
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
                Image(nsImage: claudeMark)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.secondary)
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
        .onTapGesture(count: 2) { setMini(false) }
        .gesture(WindowDragGesture())
        .help("Double-click to expand")
        .contextMenu { Button("Expand") { setMini(false) } }
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

    private func setMini(_ on: Bool) {
        layout.mini = on
        layout.save()
    }

    /// Picks how the window glows while a session runs, and in what colour.
    private var glowMenu: some View {
        let style = GlowStyle(rawValue: glowStyle) ?? .aurora
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
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Glow while a session runs: \(style.title)")
        .accessibilityLabel("Glow while a session runs: \(style.title)")
    }
}

// MARK: - Running glow

/// How the keep-on-top window shows that a session is running: colour that
/// comes in from its edges, with no border line. Picked from the sparkle menu
/// in the window's header.
enum GlowStyle: String, CaseIterable, Identifiable {
    case aurora, ember, corners, tide, rise, heartbeat, random, none
    static let key = "runningGlow"
    /// The effects themselves, the ones Random picks from.
    static let effects: [GlowStyle] = [.aurora, .ember, .corners, .tide, .rise, .heartbeat]
    var id: String { rawValue }
    var title: String {
        switch self {
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
        UserDefaults.standard.string(forKey: key).flatMap(GlowStyle.init(rawValue:)) ?? .aurora
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
        let edge = imageLayer(insetGlowImage(color: green, blur: 26, spread: 3, scale: scale))
        edge.frame = b
        let wash = CAGradientLayer()
        wash.colors = washColors(green)
        wash.locations = [0, 0.3, 0.5, 0.7, 1]
        layoutWash(wash, in: b)
        wash.opacity = calm ? 0 : 0.5
        holder.addSublayer(edge)
        holder.addSublayer(wash)
        flashClip.addSublayer(holder)
        let fade = keyframes("opacity", values: [0, 1, 1, 0], times: [0, 0.12, 0.5, 1], duration: 2.2)
        fade.repeatCount = 1
        CATransaction.setCompletionBlock { [weak holder] in holder?.removeFromSuperlayer() }
        holder.add(fade, forKey: "flash")
        if !calm {
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

        case .random, .none:
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

/// The keep-on-top window's size as you left it: any width, and a height
/// only after you drag its top or bottom edge (until then it fits the rows).
final class FloatingLayout: ObservableObject {
    static let defaultWidth: CGFloat = 300
    static let minSize = NSSize(width: 220, height: 64)
    private static let widthKey = "keepOnTopWidth", heightKey = "keepOnTopHeight", miniKey = "keepOnTopMini"
    @Published var width: CGFloat
    @Published var height: CGFloat?
    /// Shrunk to a pill with just the counts.
    @Published var mini: Bool

    init(width: CGFloat = FloatingLayout.defaultWidth, height: CGFloat? = nil, mini: Bool = false) {
        self.width = width
        self.height = height
        self.mini = mini
    }

    static func saved() -> FloatingLayout {
        let d = UserDefaults.standard
        let w = d.double(forKey: widthKey), h = d.double(forKey: heightKey)
        return FloatingLayout(width: w >= minSize.width ? w : defaultWidth, height: h >= minSize.height ? h : nil,
                              mini: d.bool(forKey: miniKey))
    }

    func save() {
        UserDefaults.standard.set(Double(width), forKey: Self.widthKey)
        UserDefaults.standard.set(Double(height ?? 0), forKey: Self.heightKey)
        UserDefaults.standard.set(mini, forKey: Self.miniKey)
    }
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
    var onResize: (NSRect, ResizeEdges) -> Void = { _, _ in }
    var onResizeEnd: () -> Void = {}
    /// The pointer in screen points; a check can stand in for the real mouse.
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var drag: (edges: ResizeEdges, frame: NSRect, mouse: NSPoint)?
    private var showingResizeCursor = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        ResizeEdges(at: convert(point, from: superview), in: bounds.size).isEmpty ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                              .inVisibleRect], owner: self))
    }

    private func edges(_ event: NSEvent) -> ResizeEdges {
        ResizeEdges(at: convert(event.locationInWindow, from: nil), in: bounds.size)
    }

    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    /// The pointer is at `point` (this view's coordinates), or has left (nil):
    /// the resize cursor on an edge, the arrow again off it.
    func hover(at point: NSPoint?) {
        guard drag == nil else { return }
        let edges = point.map { ResizeEdges(at: $0, in: bounds.size) } ?? []
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
            self?.fitToContent()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
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
        let running = board.running.count
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

    /// Resizes to the content, keeping the top edge where it is.
    func fitToContent() {
        guard model.pinned else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let host = self.host else { return }
            self.updateGlow()
            guard !self.resizing else { return }
            // The pill: rounder glow, and no resizing.
            self.glow.cornerRadius = self.layout.mini ? 16 : 12
            self.edges?.isHidden = self.layout.mini
            let size = host.fittingSize
            guard panel.frame.size != size else { return }
            let screen = panel.screen?.frame ?? NSScreen.main?.frame ?? panel.frame
            panel.setFrame(anchoredFrame(panel.frame, size: size, screen: screen), display: true)
        }
    }

    /// Side edges change only the width, so the height keeps fitting the rows;
    /// the top or bottom edge sets the height too, and the list scrolls in it.
    private func userResized(to frame: NSRect, edges: ResizeEdges) {
        resizing = true
        if !edges.isDisjoint(with: [.top, .bottom]) { layout.height = frame.height }
        layout.width = frame.width
        panel?.setFrame(frame, display: true)
    }

    private func resizeEnded() {
        resizing = false
        layout.save()
        fitToContent()
    }

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
                                    guard let id = row.link, isSessionId(id),
                                          let url = URL(string: "claude://claude.ai/epitaxy/\(id)") else { return }
                                    self?.model.markOpened(row)
                                    NSWorkspace.shared.open(url)
                                },
                                unpin: { [weak self] in self?.hide() },
                                refit: { [weak self] in self?.fitToContent() },
                                glowChanged: { [weak self] in self?.glowChanged($0) },
                                acknowledge: { [weak self] in self?.acknowledgeGlow() },
                                glow: glow,
                                layout: layout,
                                status: status,
                                answer: { [weak self] row, label in self?.answer(row, label) },
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
        edges.isHidden = layout.mini
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
        queue.async {
            var log: [String] = ["\(Date()) answer “\(button)”"]
            let outcome = self.press(session: session, url: url, ask: ask, button: button, transcript: transcript,
                                     previous: previous, log: &log)
            log.append("outcome: \(outcome)")
            Self.writeLog(log)
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
                       previous: NSRunningApplication?, log: inout [String]) -> Outcome {
        let open = { DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) } }
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundleId).first else {
            open()
            return .opened("Claude was not running")
        }
        let app = AXUIElementCreateApplication(claude.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        // Claude's window content (Chromium) builds its accessibility tree only
        // when asked, and costs Claude some work while it does: only for now.
        let before = attribute(app, "AXManualAccessibility") as? Bool
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        defer {
            if before != true { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse) }
        }
        var onScreen = scan(app)
        for _ in 0..<8 where onScreen.count < 50 {      // the tree takes a moment to build
            Thread.sleep(forTimeInterval: 0.5)
            onScreen = scan(app)
        }
        let claudeInFront = previous?.bundleIdentifier == Self.claudeBundleId
        let shownBefore = onScreen.count >= 50 ? currentSession(app) : nil
        let visible = claudeInFront || Self.windowVisible(pid: claude.processIdentifier)
        log.append("before: \(onScreen.count) texts and buttons; Claude in front: \(claudeInFront); visible: \(visible); showing it already: \(shownBefore == session)")

        // Quietly: shown already and visible, Claude stays where it is.
        if shownBefore == session && visible {
            let outcome = pressShown(session: session, ask: ask, button: button, transcript: transcript, app: app,
                                     attempts: claudeInFront ? 2 : 1, log: &log)
            if outcome == .answered || claudeInFront || outcome != .opened(Self.notTaken) {
                if outcome != .answered { open() }
                return outcome
            }
            log.append("the background press did not land: bringing Claude forward")
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
        for _ in 0..<40 {                                // up to 6 s, including a Space switch
            Thread.sleep(forTimeInterval: 0.15)
            if claude.isActive && currentSession(app) == session { ready = true; break }
        }
        log.append("Claude in front on the session: \(ready)")
        guard ready else {
            open()
            return .opened("Claude did not switch to the session")
        }
        Thread.sleep(forTimeInterval: 1)                 // the page is still loading: a press now can be lost
        let outcome = pressShown(session: session, ask: ask, button: button, transcript: transcript, app: app,
                                 attempts: 2, log: &log)
        guard outcome == .answered else {
            open()                                       // in front, on the session, for you to answer
            return outcome
        }
        if claudeInFront {
            // You were reading another session in Claude: back to it.
            if let shownBefore, shownBefore != session, isSessionId(shownBefore),
               let back = URL(string: "claude://claude.ai/epitaxy/\(shownBefore)") {
                DispatchQueue.main.sync { _ = NSWorkspace.shared.open(back) }
                log.append("switched Claude back to the session it showed")
            }
        } else {
            giveBack(previous)
            log.append("brought back the app you were in")
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
                            attempts: Int, log: inout [String]) -> Outcome {
        var last: AXUIElement?
        var agreeing = 0
        var questionSeen = false
        for look in 1...14 {                           // up to 7 s
            Thread.sleep(forTimeInterval: 0.5)
            guard currentSession(app) == session else { last = nil; agreeing = 0; continue }
            let nodes = scan(app)
            let asked = questions(ask, in: nodes)
            if !asked.isEmpty { questionSeen = true }
            // Claude keeps the questions of answered boxes in the conversation,
            // without their buttons: the live box is the copy that has the button.
            guard let target = liveButton(ask, button, in: nodes) else {
                if let q = asked.last, look == 14 {
                    log.append("look \(look): \(asked.count) copies of the question; buttons after the last: "
                               + buttons(after: q, in: nodes).map { "“\($0.label.prefix(30))”" }.joined(separator: ", "))
                }
                last = nil
                agreeing = 0
                continue
            }
            // Press only what three looks in a row (1 s) agree on: right after a
            // switch the page is still being drawn, and a press on it can be lost.
            if let previousLook = last, CFEqual(previousLook, target.element) { agreeing += 1 } else { agreeing = 1 }
            last = target.element
            guard agreeing >= 3 else { continue }
            log.append("look \(look): settled")
            let mark = transcript.flatMap { fileStamp($0)?.size }
            for attempt in 1...attempts {
                guard currentSession(app) == session else { return .opened("Claude moved to another session") }
                var element: AXUIElement? = target.element
                if attempt > 1 { element = liveButton(ask, button, in: scan(app))?.element }
                guard let element else {
                    log.append("attempt \(attempt): the button is gone")
                    return .answered
                }
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                log.append("attempt \(attempt): press \(result == .success ? "ok" : "error \(result.rawValue)")")
                guard result == .success else { return .opened(Self.notTaken) }
                switch confirm(ask: ask, button: button, app: app, transcript: transcript, mark: mark,
                               ticks: attempt == 1 ? 6 : 12, log: &log) {
                case .yes: return .answered
                case .unknown: return .opened("the box did not change after the press")
                case .no: continue            // the transcript shows nothing arrived: try once more
                }
            }
            return .opened(Self.notTaken)
        }
        log.append(questionSeen ? "the button never showed next to the question" : "the question did not show")
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
    private func giveBack(_ previous: NSRunningApplication?) {
        guard let previous, previous.bundleIdentifier != Self.claudeBundleId, let app = previous.bundleURL else { return }
        DispatchQueue.main.sync {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
    }

    private enum Confirmation { case yes, no, unknown }

    /// Whether the answer landed, within `ticks` half-seconds: the box's buttons went away, or
    /// the transcript gained a message from you with the label. `.no` only when
    /// the transcript says nothing arrived, so a second press can't answer twice.
    private func confirm(ask: String, button: String, app: AXUIElement, transcript: String?, mark: Int64?,
                         ticks: Int, log: inout [String]) -> Confirmation {
        for tick in 1...ticks {
            Thread.sleep(forTimeInterval: 0.5)
            if let transcript, let mark, Self.sent(in: transcript, after: mark).contains(where: { Self.sameText($0, button) }) {
                log.append("confirmed by the transcript after \(Double(tick) / 2) s")
                return .yes
            }
            if liveButton(ask, button, in: scan(app)) == nil {
                log.append("confirmed by the box after \(Double(tick) / 2) s")
                return .yes
            }
        }
        log.append("no change in \(Double(ticks) / 2) s")
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
        model.onVisibilityChange = { [weak self] in
            guard let self else { return }
            self.engine.setActivityWanted(self.model.panelOpen || self.model.pinned)
        }
        panel = PanelController(model: model, pin: { [weak self] in self?.floating.toggle() }) { [weak self] in
            self?.engine.refresh()
        }
        updateStatusItem()
        engine.onRows = { [weak self] rows in
            self?.model.rows = rows
            self?.updateStatusItem()
            self?.floating.fitToContent()
        }
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
        engine.refresh()
        updateStatusItem()
    }

    private func updateStatusItem() {
        let now = Date()
        let board = Board(rows: model.rows, now: now)
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
        Row(id: "local_s4", group: .running, title: "Audit traffic before the old site is shut down",
            context: "Documents", since: minutesAgo(12), link: "local_s4",
            activity: "Scanning the app logs for scope errors"),
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
            card: TurnCard(reply: "Both schema PRs are open. Once they merge, I'll point the dashboards at the new tables and compare a week of numbers.")),
        Row(id: "local_s8", group: .done, title: "Chrome tabs cleanup",
            detail: "Closed 5 tabs for merged PRs; one PR still open", context: "Scratch",
            since: minutesAgo(215), link: "local_s8",
            card: TurnCard(reply: "Closed five tabs for merged PRs. One PR is still open, so its tab stays.")),
        Row(id: "local_s9", group: .done, title: "Draft the release notes for 4.2",
            detail: "Notes drafted; screenshots still needed", context: "web-app",
            since: minutesAgo(1500), link: "local_s9"),
        Row(id: "pid:10", group: .terminal, title: "documents-72", context: "Documents",
            since: minutesAgo(18 * 60), terminal: true),
    ])
}

/// --size 380x260, or 380xauto: the keep-on-top window's size in a snapshot.
func snapshotLayout() -> FloatingLayout {
    let parts = (argument(after: "--size") ?? "").split(separator: "x").map(String.init)
    let width = parts.first.flatMap(Double.init).map { CGFloat($0) } ?? FloatingLayout.defaultWidth
    let height = parts.count > 1 ? Double(parts[1]).map { CGFloat($0) } : nil
    return FloatingLayout(width: width, height: height, mini: arguments.contains("--mini"))
}

/// Renders the panel and the menu bar item to PNG files.
func writeSnapshot(to path: String, dark: Bool, sample: Bool, expand: Bool, limit: Int?) {
    _ = NSApplication.shared
    // --live: the real turning rings and shimmering status lines, frozen mid-animation.
    staticIndicators = !arguments.contains("--live")
    let model = SessionModel()
    let rows = sample ? sampleRows(now: Date()) : SessionEngine.scanOnce()
    model.rows = limit.map { Array(rows.prefix($0)) } ?? rows
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
                                               initialResponse: argument(after: "--response"))
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
func runDump() {
    let now = Date()
    let board = Board(rows: SessionEngine.scanOnce(), now: now)
    let groups: [(String, [Row])] = [
        ("your-turn", board.yourTurn), ("your-turn-older", board.older), ("running", board.running),
        ("just-finished", board.justFinished), ("review", board.review), ("done", board.done),
        ("terminal", board.terminal),
    ]
    for (name, rows) in groups {
        for r in rows {
            print("\(name)\t\(String(format: "%.1f", now.timeIntervalSince(r.since) / 3600))h\t\(r.title)"
                  + (r.activity.map { "\t[\($0)]" } ?? ""))
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
    model.rows = real ? SessionEngine.scanOnce() : sampleRows(now: Date())
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
    // Background work: a child shell holding …/<session>/tasks/<id>.output counts.
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
    model.rows = sampleRows(now: Date())
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
    model.rows = sampleRows(now: Date())
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
    click(at: NSPoint(x: 175, y: host.frame.height - 18), times: 2)   // between the chips and the menus
    refit()
    check("double-clicking the header shrinks to the pill", layout.mini, "(\(NSStringFromSize(host.frame.size)))")
    check("the glow comes along to the pill", glow.window != nil && Int(glow.bounds.height) == 32, glowState())
    click(at: NSPoint(x: host.frame.width / 2, y: host.frame.height / 2), times: 2)
    refit()
    check("double-clicking the pill expands it", !layout.mini)
    check("the glow comes back to the window", glow.window != nil && glow.bounds.height == host.frame.height
              && glow.bounds.height > 100, glowState())
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
if arguments.contains("--dump") {
    runDump()
    exit(0)
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
