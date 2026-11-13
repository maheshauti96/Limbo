// Limbo Tasks: a menu bar list of live Claude Code sessions.
//
// Reads ~/.claude/sessions/<pid>.json (one small file per live session) and
// nothing else. Never reads the sibling *.key files or any transcript.
// No timers and no polling: an FSEvents stream wakes the app when a session
// file changes, and the menu itself is only built when it is opened.

import AppKit
import CoreServices

struct LiveSession {
    let pid: Int32
    let name: String
    let busy: Bool
    let since: Date          // when the status last changed
    let hostId: String?      // the desktop app's session id, for the deep link
}

enum SessionStore {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    static func load() -> [LiveSession] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [LiveSession] = []
        for n in names where n.hasSuffix(".json") {
            let path = dir.appendingPathComponent(n).path
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int,
                  size > 0, size < 64 * 1024,
                  let data = fm.contents(atPath: path),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = o["pid"] as? Int, pid > 0
            else { continue }
            // Skip files left behind by a process that has exited.
            if kill(pid_t(pid), 0) != 0 && errno == ESRCH { continue }
            let cwd = o["cwd"] as? String ?? ""
            var name = (o["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = (cwd as NSString).lastPathComponent }
            if name.isEmpty { name = "Session \(pid)" }
            let ms = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? (o["startedAt"] as? Double) ?? 0
            out.append(LiveSession(
                pid: Int32(pid),
                name: name,
                busy: (o["status"] as? String) == "busy",
                since: Date(timeIntervalSince1970: ms / 1000),
                hostId: o["hostSessionId"] as? String))
        }
        // Longest-running first for busy; most recently finished first for idle.
        return out.sorted {
            if $0.busy != $1.busy { return $0.busy }
            return $0.busy ? $0.since < $1.since : $0.since > $1.since
        }
    }
}

final class DirWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(path: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<DirWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        // 2 s latency: the first change is delivered at once, later ones are
        // batched, so a burst of writes costs one reload.
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
            FSEventStreamStart(s)
        }
    }
}

func age(_ d: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(d)))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min" }
    if s < 86400 { return "\(s / 3600) h" }
    return "\(s / 86400) d"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var watcher: DirWatcher?
    private var sessions: [LiveSession] = []
    private var lastTitle = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        reload()
        watcher = DirWatcher(path: SessionStore.dir.path) { [weak self] in self?.reload() }
    }

    /// Cheap: reads a handful of sub-kilobyte files and sets the title only if it changed.
    private func reload() {
        sessions = SessionStore.load()
        let running = sessions.filter { $0.busy }.count
        let idle = sessions.count - running
        let title = "▶ \(running)  ● \(idle)"
        if title != lastTitle {
            lastTitle = title
            statusItem.button?.title = title
            statusItem.button?.toolTip = "\(running) running, \(idle) idle Claude sessions"
        }
    }

    // The menu is built only when the user opens it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        reload()
        menu.removeAllItems()
        let running = sessions.filter { $0.busy }
        let idle = sessions.filter { !$0.busy }
        addSection("Running now", running, verb: "running for", to: menu)
        if !running.isEmpty && !idle.isEmpty { menu.addItem(.separator()) }
        addSection("Idle, your turn", idle, verb: "idle for", to: menu)
        if sessions.isEmpty {
            let none = NSMenuItem(title: "No live Claude sessions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Limbo Tasks", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addSection(_ header: String, _ rows: [LiveSession], verb: String, to menu: NSMenu) {
        guard !rows.isEmpty else { return }
        let h = NSMenuItem(title: "\(header) (\(rows.count))", action: nil, keyEquivalent: "")
        h.isEnabled = false
        menu.addItem(h)
        for s in rows {
            let item = NSMenuItem(title: s.name, action: nil, keyEquivalent: "")
            let text = NSMutableAttributedString(
                string: s.name,
                attributes: [.font: NSFont.menuFont(ofSize: 0)])
            let detail = s.since.timeIntervalSince1970 > 0 ? "\(verb) \(age(s.since))" : verb
            text.append(NSAttributedString(
                string: "\n\(detail)" + (s.hostId == nil ? " · terminal session" : ""),
                attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
            if let id = s.hostId {
                item.representedObject = id
                item.target = self
                item.action = #selector(openSession(_:))
            }
            menu.addItem(item)
        }
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let url = URL(string: "claude://claude.ai/epitaxy/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
