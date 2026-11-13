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
// Never opened: the *.key files beside the live records, transcripts, and every
// other file in those folders (waiting-input/, backlog/, deleted_*, ...).
//
// Cost model: no polling. One FSEvents stream wakes the app when a session file
// changes, and only the changed files are re-read, on a low-priority queue. The
// panel's views exist only while it is open.

import AppKit
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
func plainLine(_ s: String?, max: Int) -> String? {
    guard let s else { return nil }
    let unmarked = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    var t = unmarked.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        .joined(separator: " ")
    t = String(t.drop(while: { $0 == "#" || $0 == "*" || $0 == ">" || $0 == " " }))
    guard !t.isEmpty else { return nil }
    if t.count > max { t = String(t.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" }
    if let first = t.first, first.isLowercase { t = first.uppercased() + t.dropFirst() }
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

    enum CodingKeys: String, CodingKey {
        case sessionId, title, cwd, lastActivityAt, lastTurnEdgeAt, isArchived, lastAssistantUuid
        case summary = "postTurnSummary", summaryFor = "postTurnSummaryFor", wrapUp = "turnWrapUp"
        case lastTurnReport, parent = "spawnedFrom"
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
        statusDetail: plainLine(s?.detail, max: 240),
        needsAction: plainLine(s?.needs, max: 600),
        summaryFor: raw.summaryFor,
        wrapUp: plainLine(raw.wrapUp?.text, max: 240),
        lastReport: plainLine(raw.lastTurnReport, max: 200),
        parentId: raw.parent?.sessionId)
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
              let pidValue = o["pid"] as? Int, pidValue > 0, pidValue <= Int(Int32.max)
        else { continue }
        if (o["spare"] as? Bool) == true { continue }
        if let kind = o["kind"] as? String, kind != "interactive" { continue }
        let pid = Int32(pidValue)
        let startedMs = (o["startedAt"] as? Double) ?? 0
        let key = "\(pid)@\(Int64(startedMs))"
        present.insert(key)
        if exited.contains(key) { continue }
        if kill(pid, 0) != 0 && errno == ESRCH { continue }
        let cwd = o["cwd"] as? String ?? ""
        var title = plainLine(o["name"] as? String, max: 160) ?? ""
        if title.isEmpty { title = (cwd as NSString).lastPathComponent }
        if title.isEmpty { title = "Session \(pid)" }
        let statusMs = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? startedMs
        let host = (o["hostSessionId"] as? String).flatMap { isSessionId($0) ? $0 : nil }
        records[pid] = LiveRecord(
            pid: pid, key: key, name: title,
            status: (o["status"] as? String) ?? "idle",
            waitingFor: plainLine(o["waitingFor"] as? String, max: 300),
            started: Date(timeIntervalSince1970: startedMs / 1000),
            statusSince: Date(timeIntervalSince1970: statusMs / 1000),
            hostId: host, cwd: cwd)
    }
    return (records, present)
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
}

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
///  4. turn ended but the app has not written its summary yet -> Just finished
///  5. fresh summary: blocked, need_input or failed    -> Your turn
///     review_ready                                    -> Ready for review
///     anything else, or no usable summary             -> Done
///  6. terminal session (no desktop id), idle          -> Terminal
func classify(desk: [DeskRecord], live: [Int32: LiveRecord], now: Date) -> [Row] {
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
                            since: l.statusSince, link: link))
            continue
        }
        if let l, l.isWaiting {
            rows.append(Row(id: d.sessionId, group: .yourTurn, title: d.title,
                            ask: l.waitingFor ?? "Waiting for your input", context: context,
                            since: l.statusSince, link: link))
            continue
        }
        if d.isArchived { continue }
        let anchor = d.lastTurnEdge ?? d.lastActivity ?? d.fileTime
        if l == nil && now.timeIntervalSince(anchor) > dataWindow { continue }

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
                            since: lagging ? (l?.statusSince ?? anchor) : anchor, link: link))
            continue
        }
        guard fresh else {
            rows.append(Row(id: d.sessionId, group: .done, title: d.title, detail: d.wrapUp ?? d.lastReport,
                            context: context, since: anchor, link: link))
            continue
        }
        switch d.category {
        case "blocked", "need_input", "failed":
            let ask = d.needsAction ?? d.statusDetail ?? "Waiting for your answer"
            rows.append(Row(id: d.sessionId, group: .yourTurn, title: d.title, ask: ask,
                            detail: d.statusDetail == ask ? nil : d.statusDetail,
                            context: context, since: anchor, link: link))
        case "review_ready":
            rows.append(Row(id: d.sessionId, group: .review, title: d.title,
                            detail: d.statusDetail ?? d.wrapUp, context: context, since: anchor, link: link))
        default:
            rows.append(Row(id: d.sessionId, group: .done, title: d.title,
                            detail: d.statusDetail ?? d.wrapUp ?? d.lastReport,
                            context: context, since: anchor, link: link))
        }
    }

    // A live desktop process whose record is missing or not yet written.
    for (host, l) in liveByHost where bySession[host] == nil {
        let group: Group = l.isBusy ? .running : (l.isWaiting ? .yourTurn : .done)
        rows.append(Row(id: host, group: group, title: l.name,
                        ask: l.isWaiting ? (l.waitingFor ?? "Waiting for your input") : nil,
                        context: folderLabel(l.cwd), since: l.statusSince, link: host))
    }
    // Sessions started in a terminal: no summary, so idle ones never count as your turn.
    for l in terminalLive {
        let group: Group = l.isBusy ? .running : (l.isWaiting ? .yourTurn : .terminal)
        rows.append(Row(id: "pid:\(l.pid)", group: group, title: l.name,
                        ask: l.isWaiting ? (l.waitingFor ?? "Waiting for your input") : nil,
                        context: folderLabel(l.cwd), since: l.statusSince, terminal: true))
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
    private var eventBatches = 0
    private var fileParses = 0

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
            return classify(desk: engine.desk.values.compactMap(\.record), live: engine.live, now: Date())
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
            "footprintMB": (footprintMB().now * 10).rounded() / 10, "cpuSeconds": (cpu * 1000).rounded() / 1000,
        ]
        let url = Paths.home.appendingPathComponent("Library/Caches/\(LoginItem.label).stats.json")
        if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func publishIfChanged() {
        let rows = classify(desk: desk.values.compactMap(\.record), live: live, now: Date())
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
    /// Drives the "3 min ago" labels. Ticks only while the panel is open.
    @Published var now = Date()
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

/// One template image, so the system tints it for light and dark menu bars:
/// a play symbol with the number of sessions running, then a speech bubble
/// with the number waiting for you. A check mark when neither.
func statusImage(needYou: Int, running: Int) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    var parts: [(symbol: String, text: String?)] = []
    if running > 0 { parts.append(("play.fill", "\(running)")) }
    if needYou > 0 { parts.append(("bubble.left.fill", "\(needYou)")) }
    if parts.isEmpty { parts.append(("checkmark.circle", nil)) }

    let items: [(NSImage?, NSAttributedString?)] = parts.map { part in
        (NSImage(systemSymbolName: part.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config),
         part.text.map { NSAttributedString(string: $0, attributes: attrs) })
    }
    let height: CGFloat = 18, inner: CGFloat = 3, outer: CGFloat = 9
    var width: CGFloat = 0
    for (i, item) in items.enumerated() {
        if i > 0 { width += outer }
        if let image = item.0 { width += image.size.width }
        if let text = item.1 { width += inner + ceil(text.size().width) }
    }
    let result = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
        var x: CGFloat = 0
        for (i, item) in items.enumerated() {
            if i > 0 { x += outer }
            if let image = item.0 {
                image.draw(in: NSRect(x: x, y: (height - image.size.height) / 2,
                                      width: image.size.width, height: image.size.height))
                x += image.size.width
            }
            if let text = item.1 {
                x += inner
                let size = text.size()
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += ceil(size.width)
            }
        }
        return true
    }
    result.isTemplate = true
    return result
}

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

func ago(_ d: Date, _ now: Date) -> String {
    elapsed(since: d, now: now).map { "\($0) ago" } ?? "just now"
}

struct Indicator: View {
    let group: Group

    var body: some View {
        ZStack {
            switch group {
            case .yourTurn:
                Circle().fill(Color.orange).frame(width: 8, height: 8)
            case .running:
                Circle().fill(Color.green.opacity(0.22)).frame(width: 16, height: 16)
                Circle().fill(Color.green).frame(width: 8, height: 8)
            case .justFinished:
                Circle().strokeBorder(Color.orange, lineWidth: 1.5).frame(width: 8, height: 8)
            case .review:
                Circle().fill(Color.blue).frame(width: 8, height: 8)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
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
    @State private var hovering = false

    private var canOpen: Bool { row.link != nil }

    private var secondLine: String? {
        switch row.group {
        case .yourTurn: return row.ask
        case .review, .done: return row.detail
        case .running, .justFinished, .terminal: return nil
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
                Indicator(group: row.group).padding(.top, 1)
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
                            .foregroundStyle(row.group == .yourTurn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(row.group == .done ? 1 : 2)
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
        HStack(alignment: .firstTextBaseline) {
            Text("Claude sessions").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(summary(b)).font(.system(size: 11)).foregroundStyle(.secondary)
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
    private var popover: NSPopover?

    private var clock: Timer?

    init(model: SessionModel, reuse: Bool = true, animates: Bool = true, willOpen: @escaping () -> Void) {
        self.model = model
        self.reuse = reuse
        self.animates = animates
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
        let host = NSHostingController(rootView: PanelView(model: model) { [weak self] row in self?.open(row) })
        host.sizingOptions = [.preferredContentSize]
        let p = NSPopover()
        p.behavior = .transient
        p.animates = animates
        p.delegate = self
        p.contentViewController = host
        return p
    }

    func popoverWillShow(_ notification: Notification) {
        model.now = Date()
        clock?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.model.now = Date() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func popoverDidClose(_ notification: Notification) {
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
        NSWorkspace.shared.open(url)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let model = SessionModel()
    private let engine = SessionEngine()
    private var panel: PanelController!
    private var expiry: DispatchSourceTimer?
    private var shownCounts: (Int, Int)?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        panel = PanelController(model: model) { [weak self] in self?.engine.refresh() }
        updateStatusItem()
        engine.onRows = { [weak self] rows in
            self?.model.rows = rows
            self?.updateStatusItem()
        }
        engine.enableStatsSignal()
        engine.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
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
            statusItem.button?.image = statusImage(needYou: counts.0, running: counts.1)
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
            since: minutesAgo(6), link: "local_s1"),
        Row(id: "local_s2", group: .yourTurn, title: "Go-live readiness",
            ask: "Answer plan section 12: first customer tenant date; OK to re-upload the dashboard if prod restarts; Slack channels for prod and dev alerts; OK to create short-lived DNS and load balancers; alert thresholds; who runs the cluster steps. Also: start the dev gate tests, and OK to create embed users on dev?",
            detail: "Cutover plan drafted; 6 decisions needed", context: "web-platform",
            since: minutesAgo(26 * 60), link: "local_s2"),
        Row(id: "local_s3", group: .yourTurn, title: "btw: give me the queries for this",
            ask: "Run the step 3 check and tell me whether it returns recent rows.",
            context: "Go-live readiness", since: minutesAgo(4 * 1440), link: "local_s3"),
        Row(id: "local_s4", group: .running, title: "Audit traffic before the old site is shut down",
            context: "Documents", since: minutesAgo(12), link: "local_s4"),
        Row(id: "pid:5", group: .running, title: "data-pipeline", context: "data-pipeline",
            since: minutesAgo(0.5), terminal: true),
        Row(id: "local_s6", group: .justFinished, title: "Fix the flaky checkout test", context: "web-app",
            since: minutesAgo(0.2), link: "local_s6"),
        Row(id: "local_s7", group: .review, title: "Move dashboards to the new BI tool",
            detail: "Two schema PRs open; will validate after they merge", context: "analytics",
            since: minutesAgo(19 * 60), link: "local_s7"),
        Row(id: "local_s8", group: .done, title: "Chrome tabs cleanup",
            detail: "Closed 5 tabs for merged PRs; one PR still open", context: "Scratch",
            since: minutesAgo(215), link: "local_s8"),
        Row(id: "local_s9", group: .done, title: "Draft the release notes for 4.2",
            detail: "Notes drafted; screenshots still needed", context: "web-app",
            since: minutesAgo(1500), link: "local_s9"),
        Row(id: "pid:10", group: .terminal, title: "documents-72", context: "Documents",
            since: minutesAgo(18 * 60), terminal: true),
    ])
}

/// Renders the panel and the menu bar item to PNG files.
func writeSnapshot(to path: String, dark: Bool, sample: Bool, expand: Bool, limit: Int?) {
    _ = NSApplication.shared
    let model = SessionModel()
    let rows = sample ? sampleRows(now: Date()) : SessionEngine.scanOnce()
    model.rows = limit.map { Array(rows.prefix($0)) } ?? rows
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: PanelView(model: model, open: { _ in }, expandAll: expand)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))

    // The menu bar item, drawn the way a template image appears on each bar.
    let board = Board(rows: model.rows, now: Date())
    let bar = statusImage(needYou: board.yourTurn.count, running: board.running.count)
    let tinted = NSImage(size: bar.size, flipped: false) { rect in
        bar.draw(in: rect)
        (dark ? NSColor.white : NSColor.black).setFill()
        rect.fill(using: .sourceIn)
        return true
    }
    let strip = NSImage(size: NSSize(width: bar.size.width + 24, height: 24), flipped: false) { rect in
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        rect.fill()
        tinted.draw(in: NSRect(x: 12, y: 3, width: bar.size.width, height: bar.size.height))
        return true
    }
    if let tiff = strip.tiffRepresentation, let stripRep = NSBitmapImageRep(data: tiff) {
        try? stripRep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path + ".bar.png"))
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
            print("\(name)\t\(String(format: "%.1f", now.timeIntervalSince(r.since) / 3600))h\t\(r.title)")
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
