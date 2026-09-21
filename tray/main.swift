import AppKit
import Foundation

struct Session: Decodable {
    let tool: String
    let label: String
    let state: String
    let ts: String?
}

struct Board: Decodable {
    let updated: String?
    let sessions: [Session]
}

private enum LimboUI {
    static let menuWidth: CGFloat = 360
    static let cardRadius: CGFloat = 10
    static let tileSize: CGFloat = 34
    static let tileRadius: CGFloat = 8
    static let iconInTile: CGFloat = 20
    static let pad: CGFloat = 10
    static let rowH: CGFloat = 20
    static let noteH: CGFloat = 13
    static let headerH: CGFloat = 38
    static let gap: CGFloat = 4
    static let quitH: CGFloat = 28
    static let spinTag = 9101
    static let spinFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    static func brand(for tool: String) -> NSColor {
        switch tool {
        case "claude": return NSColor(calibratedRed: 0.92, green: 0.48, blue: 0.22, alpha: 1)
        case "codex":  return NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.48, alpha: 1)
        case "cursor": return NSColor(calibratedRed: 0.45, green: 0.55, blue: 1.0, alpha: 1)
        case "grok":   return NSColor(calibratedWhite: 0.85, alpha: 1)
        default:       return NSColor.controlAccentColor
        }
    }

    static func displayName(_ tool: String) -> String {
        switch tool {
        case "claude": return "Claude"
        case "codex":  return "Codex"
        case "cursor": return "Cursor"
        case "grok":   return "Grok"
        default:       return tool.capitalized
        }
    }

    static func key(tool: String, label: String) -> String { "\(tool)|\(label)" }

    static func symbol(_ name: String, pointSize: CGFloat = 11) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: name) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        return img.withSymbolConfiguration(cfg)
    }
}

// MARK: - Persistent notes / hide

final class Annotations {
    static let shared = Annotations()

    private(set) var notes: [String: String] = [:]
    private(set) var hidden: Set<String> = []

    private let url: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/session-watcher/annotations.json")
    }()

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let n = obj["notes"] as? [String: String] { notes = n }
        if let h = obj["hidden"] as? [String] { hidden = Set(h) }
    }

    func save() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["notes": notes, "hidden": Array(hidden).sorted()]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func note(for key: String) -> String { notes[key] ?? "" }

    func setNote(_ text: String, for key: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { notes.removeValue(forKey: key) } else { notes[key] = t }
        save()
    }

    func isHidden(_ key: String) -> Bool { hidden.contains(key) }

    func hide(_ key: String) {
        hidden.insert(key)
        save()
    }

    func unhideIfRunning(tool: String, label: String, state: String) {
        let k = LimboUI.key(tool: tool, label: label)
        if (state == "running" || state == "busy") && hidden.contains(k) {
            hidden.remove(k)
            save()
        }
    }
}

// MARK: - Pill

final class StatusPill: NSView {
    init(text: String, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let w = (text as NSString).size(withAttributes: [.font: font]).width + 14
        super.init(frame: NSRect(x: 0, y: 0, width: max(48, w), height: 18))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = color.withAlphaComponent(0.35).cgColor
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.frame = bounds.insetBy(dx: 2, dy: 1)
        addSubview(label)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Icon button

final class IconButton: NSButton {
    init(symbol: String, tip: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 18))
        bezelStyle = .inline
        isBordered = false
        title = ""
        image = LimboUI.symbol(symbol, pointSize: 11)
        imagePosition = .imageOnly
        contentTintColor = NSColor.white.withAlphaComponent(0.55)
        toolTip = tip
        self.target = target
        self.action = action
        focusRingType = .none
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = NSColor.white.withAlphaComponent(0.85)
    }
    override func mouseExited(with event: NSEvent) {
        contentTintColor = NSColor.white.withAlphaComponent(0.55)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
}

// MARK: - Session row

final class SessionRowView: NSView {
    let tool: String
    let label: String
    let key: String
    private let onOpen: (String) -> Void
    private let onEditNote: (String) -> Void
    private let onHide: (String) -> Void
    private var actionButtons: [IconButton] = []

    /// Fixed right chrome: [trash?][pencil] — icons don't drift with title length.
    private static let actionSlot: CGFloat = 22
    private static let actionGap: CGFloat = 2
    private static let rightPad: CGFloat = 4

    init(
        tool: String,
        label: String,
        state: String,
        note: String,
        glyph: String,
        accent: NSColor,
        width: CGFloat,
        onOpen: @escaping (String) -> Void,
        onEditNote: @escaping (String) -> Void,
        onHide: @escaping (String) -> Void
    ) {
        self.tool = tool
        self.label = label
        self.key = LimboUI.key(tool: tool, label: label)
        self.onOpen = onOpen
        self.onEditNote = onEditNote
        self.onHide = onHide

        let active = state == "running" || state == "busy"
        let hasNote = !note.isEmpty
        let h = LimboUI.rowH + (hasNote ? LimboUI.noteH + 2 : 0)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: h))

        let x0: CGFloat = 4
        let titleY = hasNote ? LimboUI.noteH + 3 : 2

        let mark = NSTextField(labelWithString: active ? glyph : "○")
        mark.tag = LimboUI.spinTag
        mark.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        mark.textColor = active ? accent : NSColor.white.withAlphaComponent(0.35)
        mark.alignment = .center
        mark.frame = NSRect(x: x0, y: titleY, width: 16, height: 16)
        mark.identifier = NSUserInterfaceItemIdentifier(active ? "spin" : "idle")
        addSubview(mark)

        // Fixed action column from the right: pencil always, trash when idle.
        var slots: [String] = ["pencil"]
        if !active { slots.insert("trash", at: 0) }
        let chromeW = CGFloat(slots.count) * Self.actionSlot + CGFloat(max(0, slots.count - 1)) * Self.actionGap + Self.rightPad
        var x = width - chromeW

        for sym in slots {
            let tip = sym == "pencil" ? "Edit note" : "Hide until running"
            let sel: Selector = sym == "pencil" ? #selector(noteTapped) : #selector(hideTapped)
            let btn = IconButton(symbol: sym == "pencil" ? "pencil" : "trash", tip: tip, target: self, action: sel)
            btn.frame = NSRect(x: x, y: titleY - 1, width: Self.actionSlot, height: 18)
            btn.alphaValue = 0.0 // reveal on row hover
            addSubview(btn)
            actionButtons.append(btn)
            x += Self.actionSlot + Self.actionGap
        }

        let titleX = x0 + 18
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = NSColor.white.withAlphaComponent(0.92)
        title.lineBreakMode = .byTruncatingMiddle
        title.frame = NSRect(x: titleX, y: titleY, width: max(40, width - chromeW - titleX - 6), height: 16)
        addSubview(title)

        if hasNote {
            let noteField = NSTextField(labelWithString: note)
            noteField.font = .systemFont(ofSize: 10, weight: .regular)
            noteField.textColor = NSColor.white.withAlphaComponent(0.55)
            noteField.lineBreakMode = .byTruncatingTail
            noteField.frame = NSRect(x: titleX, y: 1, width: width - titleX - Self.rightPad, height: 12)
            addSubview(noteField)
        }
    }

    @objc private func noteTapped() { onEditNote(key) }
    @objc private func hideTapped() { onHide(key) }

    override func mouseEntered(with event: NSEvent) {
        for b in actionButtons { b.alphaValue = 1.0 }
    }
    override func mouseExited(with event: NSEvent) {
        for b in actionButtons { b.alphaValue = 0.0 }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(p), hit is NSButton { return }
        onOpen(tool)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Platform card

final class PlatformCardView: NSView {
    private let tool: String
    private let onOpen: (String) -> Void

    init(
        tool: String,
        icon: NSImage?,
        sessions: [Session],
        spinFrame: Int,
        onOpen: @escaping (String) -> Void,
        onEditNote: @escaping (String) -> Void,
        onHide: @escaping (String) -> Void
    ) {
        self.tool = tool
        self.onOpen = onOpen

        let glyph = LimboUI.spinFrames[spinFrame % LimboUI.spinFrames.count]
        let running = sessions.filter { $0.state == "running" || $0.state == "busy" }.count
        let ann = Annotations.shared

        var bodyH: CGFloat = 0
        if sessions.isEmpty {
            bodyH = LimboUI.rowH
        } else {
            for s in sessions {
                let k = LimboUI.key(tool: s.tool, label: s.label)
                let hasNote = !ann.note(for: k).isEmpty
                bodyH += LimboUI.rowH + (hasNote ? LimboUI.noteH + 2 : 0)
            }
        }

        let h = LimboUI.pad + LimboUI.headerH + bodyH + LimboUI.pad
        super.init(frame: NSRect(x: 0, y: 0, width: LimboUI.menuWidth, height: h))

        wantsLayer = true
        layer?.cornerRadius = LimboUI.cardRadius
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.50).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        let brand = LimboUI.brand(for: tool)

        let tile = NSView(frame: NSRect(
            x: LimboUI.pad, y: h - LimboUI.pad - LimboUI.tileSize,
            width: LimboUI.tileSize, height: LimboUI.tileSize
        ))
        tile.wantsLayer = true
        tile.layer?.cornerRadius = LimboUI.tileRadius
        tile.layer?.backgroundColor = brand.withAlphaComponent(tool == "grok" ? 0.30 : 0.38).cgColor
        addSubview(tile)

        let iconView = NSImageView(frame: NSRect(
            x: (LimboUI.tileSize - LimboUI.iconInTile) / 2,
            y: (LimboUI.tileSize - LimboUI.iconInTile) / 2,
            width: LimboUI.iconInTile, height: LimboUI.iconInTile
        ))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = icon
        tile.addSubview(iconView)

        let nameX = LimboUI.pad + LimboUI.tileSize + 10
        let name = NSTextField(labelWithString: LimboUI.displayName(tool))
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .white
        name.frame = NSRect(x: nameX, y: h - LimboUI.pad - 18, width: 150, height: 18)
        addSubview(name)

        let sub = NSTextField(labelWithString: sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
        sub.font = .systemFont(ofSize: 10, weight: .medium)
        sub.textColor = NSColor.white.withAlphaComponent(0.55)
        sub.frame = NSRect(x: nameX, y: h - LimboUI.pad - 34, width: 120, height: 14)
        addSubview(sub)

        let pillText = running > 0 ? "\(running) running" : "idle"
        let pillColor = running > 0 ? brand : NSColor.white.withAlphaComponent(0.40)
        let pill = StatusPill(text: pillText, color: pillColor)
        pill.frame.origin = NSPoint(
            x: LimboUI.menuWidth - LimboUI.pad - pill.bounds.width,
            y: h - LimboUI.pad - 24
        )
        addSubview(pill)

        var y = h - LimboUI.pad - LimboUI.headerH
        let rowWidth = LimboUI.menuWidth - LimboUI.pad * 2
        for s in sessions {
            let display = s.state == "busy" ? "running" : s.state
            let k = LimboUI.key(tool: s.tool, label: s.label)
            let note = ann.note(for: k)
            let rowH = LimboUI.rowH + (note.isEmpty ? 0 : LimboUI.noteH + 2)
            y -= rowH
            let row = SessionRowView(
                tool: s.tool,
                label: s.label,
                state: display,
                note: note,
                glyph: glyph,
                accent: brand,
                width: rowWidth,
                onOpen: onOpen,
                onEditNote: onEditNote,
                onHide: onHide
            )
            row.frame.origin = NSPoint(x: LimboUI.pad, y: y)
            addSubview(row)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(p), hit is NSButton || hit is SessionRowView { return }
        onOpen(tool)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class CardSpacer: NSView {
    init() { super.init(frame: NSRect(x: 0, y: 0, width: LimboUI.menuWidth, height: LimboUI.gap)) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class QuitRowView: NSView {
    private let onQuit: () -> Void
    init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
        super.init(frame: NSRect(x: 0, y: 0, width: LimboUI.menuWidth, height: LimboUI.quitH))
        let label = NSTextField(labelWithString: "Quit limbo")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.frame = NSRect(x: 14, y: 5, width: 160, height: 18)
        addSubview(label)
        let shortcut = NSTextField(labelWithString: "⌘Q")
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        shortcut.frame = NSRect(x: LimboUI.menuWidth - 54, y: 5, width: 40, height: 18)
        addSubview(shortcut)
    }
    override func mouseUp(with event: NSEvent) { onQuit() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var menuIsOpen = false
    private var isEditingNote = false
    private var iconCache: [String: NSImage] = [:]
    private var spinFrame: Int = 0
    private var lastRunning = 0
    private var lastSessionSig = ""

    private let stateURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/session-watcher/state.json")
    }()

    private static let appByTool: [String: String] = [
        "claude": "/Applications/Claude.app",
        "codex": "/Applications/ChatGPT.app",
        "cursor": "/Applications/Cursor.app",
        "grok": "/Applications/Grok Bot.app",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "com.maheshauti.limbo.status"
        if let btn = statusItem.button {
            if let img = NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: "limbo") {
                img.isTemplate = true
                btn.image = img
                btn.imagePosition = .imageLeading
            }
            btn.title = " limbo"
            btn.toolTip = "limbo"
        }

        menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = LimboUI.menuWidth
        menu.delegate = self
        statusItem.menu = menu

        rebuild()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func tick() {
        if isEditingNote { return }
        let board = loadBoard()
        let totalRunning = board?.sessions.filter { isActive($0.state) }.count ?? 0
        if totalRunning > 0 {
            spinFrame = (spinFrame + 1) % LimboUI.spinFrames.count
        }
        lastRunning = totalRunning
        updateMenuBarBadge(running: totalRunning)

        if menuIsOpen {
            // Keep controls clickable: don't tear down the menu; just advance spin glyphs.
            advanceOpenMenuSpinners()
            // Full rebuild only if session set / states changed (or notes file mtime — skip; notes edit forces rebuild)
            let sig = sessionSignature(board)
            if sig != lastSessionSig {
                lastSessionSig = sig
                rebuild(board: board)
            }
        } else {
            lastSessionSig = sessionSignature(board)
            rebuild(board: board)
        }
    }

    private func sessionSignature(_ board: Board?) -> String {
        guard let board else { return "nil" }
        let ann = Annotations.shared
        return board.sessions
            .map { s in
                let k = LimboUI.key(tool: s.tool, label: s.label)
                let n = ann.note(for: k)
                let h = ann.isHidden(k) ? "1" : "0"
                return "\(s.tool)|\(s.label)|\(s.state)|\(h)|\(n.count)"
            }
            .sorted()
            .joined(separator: ";")
    }

    private func advanceOpenMenuSpinners() {
        let glyph = LimboUI.spinFrames[spinFrame % LimboUI.spinFrames.count]
        for item in menu.items {
            guard let root = item.view else { continue }
            updateSpinMarks(in: root, glyph: glyph)
        }
    }

    private func updateSpinMarks(in view: NSView, glyph: String) {
        if let tf = view as? NSTextField, tf.tag == LimboUI.spinTag, tf.identifier?.rawValue == "spin" {
            if tf.stringValue != glyph { tf.stringValue = glyph }
        }
        for sub in view.subviews {
            updateSpinMarks(in: sub, glyph: glyph)
        }
    }

    func rebuild(board incoming: Board? = nil) {
        let board = incoming ?? loadBoard()
        let ann = Annotations.shared

        if let board {
            for s in board.sessions {
                ann.unhideIfRunning(tool: s.tool, label: s.label, state: s.state)
            }
        }

        let totalRunning = board?.sessions.filter { isActive($0.state) }.count ?? 0
        lastRunning = totalRunning
        lastSessionSig = sessionSignature(board)

        menu.removeAllItems()

        if let board, !board.sessions.isEmpty {
            let visible = board.sessions.filter { s in
                let k = LimboUI.key(tool: s.tool, label: s.label)
                if isActive(s.state) { return true }
                return !ann.isHidden(k)
            }
            let grouped = Dictionary(grouping: visible, by: \.tool)
            let tools = grouped.keys.sorted()
            let hiddenCount = board.sessions.count - visible.count

            for (i, tool) in tools.enumerated() {
                let sessions = grouped[tool] ?? []
                let item = NSMenuItem()
                item.isEnabled = true
                item.view = PlatformCardView(
                    tool: tool,
                    icon: appIcon(for: tool, size: LimboUI.iconInTile),
                    sessions: sessions,
                    spinFrame: spinFrame,
                    onOpen: { [weak self] t in self?.openTool(t) },
                    onEditNote: { [weak self] key in self?.editNote(key: key) },
                    onHide: { [weak self] key in self?.hideThread(key: key) }
                )
                menu.addItem(item)
                if i < tools.count - 1 {
                    let spacer = NSMenuItem()
                    spacer.isEnabled = false
                    spacer.view = CardSpacer()
                    menu.addItem(spacer)
                }
            }

            if hiddenCount > 0 {
                let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let s = "\(hiddenCount) hidden · show when running"
                info.attributedTitle = NSAttributedString(string: s, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55)
                ])
                info.isEnabled = false
                menu.addItem(info)
            }
        } else {
            let empty = NSMenuItem(
                title: board == nil
                    ? "no state.json — is session-watcher watch running?"
                    : "no live sessions",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        }

        let quit = NSMenuItem()
        quit.isEnabled = true
        quit.view = QuitRowView { NSApp.terminate(nil) }
        let quitKey = NSMenuItem(title: "Quit limbo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitKey.target = NSApp
        quitKey.isHidden = true
        menu.addItem(quit)
        menu.addItem(quitKey)

        updateMenuBarBadge(running: totalRunning)
    }

    private func editNote(key: String) {
        isEditingNote = true
        let alert = NSAlert()
        alert.messageText = "Thread note"
        alert.informativeText = key.replacingOccurrences(of: "|", with: " · ")
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = Annotations.shared.note(for: key)
        field.placeholderString = "what’s happening / why idle…"
        alert.accessoryView = field
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            Annotations.shared.setNote(field.stringValue, for: key)
        }
        isEditingNote = false
        rebuild()
    }

    private func hideThread(key: String) {
        Annotations.shared.hide(key)
        rebuild()
    }

    private func updateMenuBarBadge(running: Int) {
        guard let btn = statusItem.button else { return }
        for v in btn.subviews where v is NSProgressIndicator {
            v.removeFromSuperview()
        }
        if btn.image == nil {
            if let img = NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: "limbo") {
                img.isTemplate = true
                btn.image = img
                btn.imagePosition = .imageLeading
            }
        }
        if running > 0 {
            let g = LimboUI.spinFrames[spinFrame % LimboUI.spinFrames.count]
            btn.title = " \(g)\(running)"
        } else {
            btn.title = " limbo"
        }
    }

    private func loadBoard() -> Board? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Board.self, from: data)
    }

    private func appIcon(for tool: String, size: CGFloat) -> NSImage? {
        let key = "\(tool)-\(Int(size))"
        if let cached = iconCache[key] { return cached }
        guard let path = Self.appByTool[tool],
              FileManager.default.fileExists(atPath: path) else { return nil }
        let src = NSWorkspace.shared.icon(forFile: path)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        img.isTemplate = false
        iconCache[key] = img
        return img
    }

    private func isActive(_ state: String) -> Bool {
        state == "running" || state == "busy"
    }

    private func openTool(_ tool: String) {
        guard let path = Self.appByTool[tool] else { return }
        let url = URL(fileURLWithPath: path)
        if #available(macOS 11.0, *) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

@main
enum LimboMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
