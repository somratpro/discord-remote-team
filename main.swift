import AppKit
import SwiftUI
import Combine

final class RosterPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}

@MainActor final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = State()
    let photos = Photos()
    var countItem: NSStatusItem!
    var avatarItem: NSStatusItem?
    private var avatarPeople = [Person]()
    private let avatarSize: CGFloat = 20
    private let avatarGap: CGFloat = 2
    private var avatarStride: CGFloat { avatarSize + avatarGap }
    var panel: NSPanel!
    var setup: NSWindow?
    var directoryWindow: NSWindow?
    var handoffWindow: NSWindow?
    var timer: Timer?
    var subscriptions = Set<AnyCancellable>()
    var renderPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        countItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        countItem.autosaveName = "TeamCheckinCount"
        countItem.button?.target = self
        countItem.button?.action = #selector(toggleRoster)
        panel = RosterPanel(contentRect: NSRect(x: 0, y: 0, width: 322, height: 454),
                        styleMask: [.borderless, .utilityWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: RosterView(state: state, photos: photos, settings: { [weak self] in self?.settings() },
            hide: { [weak self] in self?.panel.orderOut(nil) },
            pin: { [weak self] in self?.togglePin() }, openDM: { [weak self] p in self?.dm(p) }, openProfile: { [weak self] p in self?.openProfile(p) },
            reviewDirectory: { [weak self] in self?.reviewDirectory() },
            handoff: { [weak self] p in self?.handoff(p) },
            editDM: { [weak self] p in self?.editDM(p) }))
        state.objectWillChange.merge(with: photos.objectWillChange).sink { [weak self] _ in self?.queueRender() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 20, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        state.start(); render()
        if !state.hasConnection { settings() }
        else if UserDefaults.standard.bool(forKey: "pinned") { togglePin(); showRoster() }
    }
    @objc func poll() { state.refresh() }
    @objc func wake() { state.refresh(full: true) }
    func queueRender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in self?.renderPending = false; self?.render() }
    }
    func render() {
        let inShift = state.visiblePeople
        let count = inShift.count
        switch state.mode {
        case "Live": countItem.button?.title = " \(count) in"
        case "Offline": countItem.button?.title = state.lastSync == nil ? " Offline" : " \(count) in · stale"
        case "Preview": countItem.button?.title = " \(count) in · preview"
        case "Syncing": countItem.button?.title = " Syncing"
        default: countItem.button?.title = " Set up"
        }
        countItem.button?.image = NSImage(systemSymbolName: state.mode == "Offline" ? "exclamationmark.triangle" : "person.2.fill", accessibilityDescription: "Remote Team")
        countItem.button?.imagePosition = .imageLeading
        countItem.button?.toolTip = "Remote Team · " + state.detail
        renderAvatars(state.faces ? Array(inShift.prefix(3)) : [])
    }

    private func renderAvatars(_ people: [Person]) {
        avatarPeople = people
        guard !people.isEmpty else {
            if let avatarItem { NSStatusBar.system.removeStatusItem(avatarItem) }
            avatarItem = nil
            return
        }
        let width = CGFloat(people.count) * avatarStride + avatarGap
        if avatarItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: width)
            item.button?.target = self
            item.button?.action = #selector(avatarClick(_:))
            item.button?.imagePosition = .imageOnly
            item.button?.setAccessibilityLabel("Open teammate Discord conversations")
            avatarItem = item
        }
        let pictures = people.map { avatar($0.user, status: $0.status) }
        let spacing = avatarStride
        let size = avatarSize
        avatarItem?.length = width
        avatarItem?.button?.image = NSImage(size: NSSize(width: width, height: size), flipped: false) { _ in
            for (index, picture) in pictures.enumerated() {
                picture.draw(in: NSRect(x: spacing * CGFloat(index) + spacing - size,
                                       y: 0, width: size, height: size))
            }
            return true
        }
        avatarItem?.button?.toolTip = people.map { $0.user.name + " · " + state.subtitle($0) }.joined(separator: "\n")
        for person in people { photos.fetch(person.user) }
    }

    @objc private func avatarClick(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, let window = sender.window {
            let location = sender.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let stripWidth = CGFloat(avatarPeople.count) * avatarStride + avatarGap
            let stripX = sender.bounds.midX - stripWidth / 2
            let index = Int(floor((location.x - stripX - avatarGap / 2) / avatarStride))
            if avatarPeople.indices.contains(index) { dm(avatarPeople[index]) }
            return
        }

        let menu = NSMenu()
        for person in avatarPeople {
            let item = menu.addItem(withTitle: person.user.name, action: #selector(avatarMenuClick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = person.id
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    @objc private func avatarMenuClick(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let person = avatarPeople.first(where: { $0.id == id }) {
            dm(person)
        }
    }

    func avatar(_ user: User, status: Status) -> NSImage {
        let photo = photos.images[Photos.key(user)]
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            if let photo { photo.draw(in: rect) }
            else {
                NSColor(avatarColor(user.id)).setFill(); rect.fill()
                let s = NSAttributedString(string: initials(user), attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white])
                let size = s.size()
                s.draw(at: NSPoint(x: (20-size.width)/2, y: (20-size.height)/2))
            }
            if let color = statusColor(status) {
                NSColor(color).setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.2, dy: 1.2))
                ring.lineWidth = 2.2
                ring.stroke()
            }
            return true
        }
    }
    func togglePin() {
        state.pinned.toggle()
        panel.level = state.pinned ? .floating : .normal
        UserDefaults.standard.set(state.pinned, forKey: "pinned")
    }
    @objc func toggleRoster() {
        if panel.isVisible { panel.orderOut(nil) } else { showRoster() }
    }
    func showRoster() {
        if !state.pinned || !panel.isVisible {
            let frame = countItem.button?.window?.frame
            let screen = countItem.button?.window?.screen ?? NSScreen.main
            if let v = screen?.visibleFrame {
                let left = min(max(v.minX + 4, (frame?.maxX ?? v.maxX) - panel.frame.width), v.maxX - panel.frame.width - 4)
                panel.setFrameTopLeftPoint(NSPoint(x: left, y: v.maxY - 3))
            }
        }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel && !state.pinned { panel.orderOut(nil) }
    }
    func settings() {
        if let window = setup, window.isVisible { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 505, height: 510),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Remote Team Settings"
        window.contentView = NSHostingView(rootView: SettingsView(state: state, close: { [weak self] in
            self?.setup?.close(); self?.showRoster()
        }, preview: { [weak self] in self?.setup?.close(); self?.state.preview(); self?.showRoster() }))
        setup = window
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func editorWindow<Content: View>(_ title: String, view: Content) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func reviewDirectory() {
        guard let guild = state.guild else { return }
        if let window = directoryWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        directoryWindow = editorWindow("Team Directory", view: DirectoryView(state: state, guild: guild,
            openProfile: { [weak self] in self?.openProfile($0) }, close: { [weak self] in
                self?.directoryWindow?.close()
                self?.showRoster()
            }))
    }

    func handoff(_ person: Person) {
        handoffWindow?.close()
        let guild = state.guild
        handoffWindow = editorWindow("Prepare Handoff", view: HandoffView(person: person, sample: state.sample,
            openDM: { [weak self] in
                guard let self, self.state.guild == guild else { return }
                self.dm(person)
            },
            openProfile: { [weak self] in self?.openProfile(person) }))
    }

    func editDM(_ person: Person) {
        guard !state.sample else { return }
        let alert = NSAlert()
        alert.messageText = "Discord DM link for " + person.user.name
        alert.informativeText = "Paste the link copied from the Discord conversation. Leave it blank to reset."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = state.dm(person.id)
        field.placeholderString = "https://discord.com/channels/@me/…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                try state.saveDM(field.stringValue, for: person.id)
                return
            } catch {
                alert.informativeText = error.localizedDescription
            }
        }
    }

    func dm(_ person: Person) {
        guard !state.sample else { return }
        if let url = dmURL(state.dm(person.id)) ?? candidateDM(person.id) {
            state.openBrowser(url)
        }
    }
    func openProfile(_ person: Person) {
        let desktop = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.hnc.Discord") != nil
        guard let url = profileURL(person.id, desktop: desktop) else { return }
        if desktop { NSWorkspace.shared.open(url) } else { state.openBrowser(url) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !state.hasConnection && !state.sample { settings() } else { showRoster() }
        return true
    }
}

if CommandLine.arguments.contains("--mcp") {
    await RemoteMCP.run()
    exit(0)
}

do {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    // Accessory apps need an Edit menu for standard paste/copy shortcuts in the setup fields.
    let menu = NSMenu()
    let edit = NSMenu(title: "Edit")
    for (name, selector, key) in [("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {
        edit.addItem(withTitle: name, action: Selector(selector), keyEquivalent: key)
    }
    let item = NSMenuItem(); item.submenu = edit; menu.addItem(item); app.mainMenu = menu
    withExtendedLifetime(delegate) { app.run() }
}
