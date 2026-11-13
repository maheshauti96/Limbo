// Limbo Tasks: a menu bar panel of live Claude Code sessions.
//
// Reads ~/.claude/sessions/<pid>.json (one small file per live session) and
// nothing else. Never reads the sibling *.key files or any transcript.
//
// Cost model: no polling. An FSEvents stream wakes the app when a session file
// changes. The panel's views exist only while it is open; closing it releases
// them, and the only timer (a 30 s tick for "3 min ago" labels) stops with it.

import AppKit
import CoreServices
import SwiftUI

// MARK: - Data

struct LiveSession: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let busy: Bool
    let since: Date          // when the status last changed
    let hostId: String?      // the desktop app's session id, for the deep link
    let folder: String
    var id: Int32 { pid }
}

func folderLabel(_ cwd: String) -> String {
    if cwd.contains("/scratch-workspaces/") { return "Scratch" }
    let last = (cwd as NSString).lastPathComponent
    return last.isEmpty ? "No folder" : last
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
                hostId: o["hostSessionId"] as? String,
                folder: folderLabel(cwd)))
        }
        // Longest-running first for busy; most recently finished first for idle.
        return out.sorted {
            if $0.busy != $1.busy { return $0.busy }
            return $0.busy ? $0.since < $1.since : $0.since > $1.since
        }
    }
}

final class SessionModel: ObservableObject {
    @Published private(set) var sessions: [LiveSession]
    var onChange: (() -> Void)?

    init(sessions: [LiveSession] = []) { self.sessions = sessions }

    /// Cheap: a handful of sub-kilobyte files. Publishes only when something changed.
    func reload() {
        let next = SessionStore.load()
        if next != sessions {
            sessions = next
            onChange?()
        }
    }

    var running: [LiveSession] { sessions.filter { $0.busy } }
    var idle: [LiveSession] { sessions.filter { !$0.busy } }
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
/// play + count for running sessions, pause + count for sessions waiting on you.
func statusImage(running: Int, idle: Int) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    var parts: [(String, String?)] = []
    if running > 0 { parts.append(("play.fill", "\(running)")) }
    if idle > 0 { parts.append(("pause.fill", "\(idle)")) }
    if parts.isEmpty { parts.append(("moon.zzz.fill", nil)) }

    var items: [(NSImage?, NSAttributedString?)] = []
    for (symbol, text) in parts {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        items.append((image, text.map { NSAttributedString(string: $0, attributes: attrs) }))
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
func duration(since d: Date, now: Date) -> String? {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return nil }
    if s < 3600 { return "\(s / 60) min" }
    if s < 86400 { return "\(s / 3600) hr" }
    let days = s / 86400
    return days == 1 ? "1 day" : "\(days) days"
}

/// Green for running. Orange for a session that finished in the last half hour,
/// which most likely needs you. A quiet ring for one that has been idle longer.
struct StatusDot: View {
    let session: LiveSession
    let now: Date

    var body: some View {
        ZStack {
            if session.busy {
                Circle().fill(Color.green.opacity(0.22)).frame(width: 16, height: 16)
                Circle().fill(Color.green).frame(width: 8, height: 8)
            } else if now.timeIntervalSince(session.since) < 1800 {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5).frame(width: 8, height: 8)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct SessionRow: View {
    let session: LiveSession
    let now: Date
    let open: (LiveSession) -> Void
    @State private var hovering = false

    private var canOpen: Bool { session.hostId != nil }
    private var detail: String {
        let time = duration(since: session.since, now: now)
        if session.busy {
            return "\(session.folder) · " + (time.map { "working for \($0)" } ?? "just started")
        }
        return "\(session.folder) · " + (time.map { "finished \($0) ago" } ?? "finished just now")
    }

    var body: some View {
        Button(action: { open(session) }) {
            HStack(spacing: 10) {
                StatusDot(session: session, now: now)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if canOpen {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                } else {
                    Text("Terminal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering && canOpen ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(canOpen)
        .onHover { hovering = $0 }
        .help(canOpen ? "Open in Claude" : "Started in a terminal, so it can't be opened from here")
        .accessibilityLabel("\(session.name), \(session.busy ? "running" : "waiting for you"), \(detail)")
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

struct PanelView: View {
    @ObservedObject var model: SessionModel
    let open: (LiveSession) -> Void
    @State private var loginOn = LoginItem.isEnabled

    private var summary: String {
        let r = model.running.count, i = model.idle.count
        if r == 0 && i == 0 { return "Nothing live" }
        var parts: [String] = []
        if r > 0 { parts.append("\(r) running") }
        if i > 0 { parts.append("\(i) waiting") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // Re-renders every 30 s so "3 min ago" stays right, only while open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if model.sessions.isEmpty {
                    emptyState
                } else if model.sessions.count > 9 {
                    ScrollView { list(now: context.date) }.frame(height: 460)
                } else {
                    list(now: context.date)
                }
            }

            Divider().padding(.top, 8)
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
        .frame(width: 360)
    }

    private func list(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.running.isEmpty {
                SectionHeader(title: "Running", count: model.running.count)
                ForEach(model.running) { SessionRow(session: $0, now: now, open: open) }
            }
            if !model.idle.isEmpty {
                SectionHeader(title: "Your turn", count: model.idle.count)
                ForEach(model.idle) { SessionRow(session: $0, now: now, open: open) }
            }
        }
        .padding(.horizontal, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No live Claude sessions").font(.system(size: 13, weight: .medium))
            Text("Sessions appear here while they are open.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var watcher: DirWatcher?
    private var popover: NSPopover?
    private let model = SessionModel()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        model.onChange = { [weak self] in self?.updateStatusItem() }
        model.reload()
        updateStatusItem()
        watcher = DirWatcher(path: SessionStore.dir.path) { [weak self] in self?.model.reload() }
    }

    private func updateStatusItem() {
        let running = model.running.count, idle = model.idle.count
        statusItem.button?.image = statusImage(running: running, idle: idle)
        statusItem.button?.toolTip = "\(running) running, \(idle) waiting for you"
        statusItem.button?.setAccessibilityLabel("Claude sessions: \(running) running, \(idle) waiting for you")
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let open = popover, open.isShown {
            open.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        model.reload()
        // Built on demand and dropped on close, so no views exist while it is shut.
        let host = NSHostingController(rootView: PanelView(model: model) { [weak self] session in
            self?.open(session)
        })
        host.sizingOptions = [.preferredContentSize]
        let panel = NSPopover()
        panel.behavior = .transient
        panel.delegate = self
        panel.contentViewController = host
        popover = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }

    private func open(_ session: LiveSession) {
        guard let id = session.hostId,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let url = URL(string: "claude://claude.ai/epitaxy/\(id)") else { return }
        popover?.performClose(nil)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Entry point

/// Renders the panel and the menu bar item to PNG files, for checking the design
/// without the screen. `--sample` uses made-up sessions that cover every state.
func writeSnapshot(to path: String, dark: Bool, sample: Bool) {
    _ = NSApplication.shared
    let now = Date()
    let model: SessionModel
    if sample {
        model = SessionModel(sessions: [
            LiveSession(pid: 1, name: "Migrate billing exports to the new schema", busy: true,
                        since: now.addingTimeInterval(-25 * 60), hostId: "local_a", folder: "billing-service"),
            LiveSession(pid: 2, name: "Audit traffic before the old site is shut down", busy: true,
                        since: now.addingTimeInterval(-40), hostId: "local_b", folder: "Documents"),
            LiveSession(pid: 3, name: "Fix flaky checkout test", busy: false,
                        since: now.addingTimeInterval(-4 * 60), hostId: "local_c", folder: "web-app"),
            LiveSession(pid: 4, name: "Draft the release notes for 4.2 and collect screenshots from QA", busy: false,
                        since: now.addingTimeInterval(-3 * 3600), hostId: "local_d", folder: "Scratch"),
            LiveSession(pid: 5, name: "data-pipeline", busy: false,
                        since: now.addingTimeInterval(-26 * 3600), hostId: nil, folder: "data-pipeline"),
        ])
    } else {
        model = SessionModel()
        model.reload()
    }
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: PanelView(model: model, open: { _ in })
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
    let bar = statusImage(running: model.running.count, idle: model.idle.count)
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

let arguments = CommandLine.arguments

// Scriptable switches for the login item, so `make install-tasks` can set it.
for (flag, on) in [("--login-item-on", true), ("--login-item-off", false)]
where arguments.contains(flag) {
    do {
        try LoginItem.setEnabled(on)
        print(on ? "Start at login is on: \(LoginItem.plistURL.path)" : "Start at login is off")
        exit(0)
    } catch {
        FileHandle.standardError.write("Could not change the login item: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    writeSnapshot(to: arguments[i + 1], dark: arguments.contains("--dark"), sample: arguments.contains("--sample"))
    exit(0)
}

guard isOnlyInstance() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
