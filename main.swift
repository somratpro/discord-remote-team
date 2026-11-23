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
    var faces = [NSStatusItem]()
    var shown = [Person]()
    var panel: NSPanel!
    var setup: NSWindow?
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
        panel.title = "Remote Team"; panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: RosterView(state: state, photos: photos, settings: { [weak self] in self?.settings() },
            hide: { [weak self] in self?.panel.orderOut(nil) },
            pin: { [weak self] in self?.togglePin() }, openDM: { [weak self] p in self?.dm(p) }, openProfile: { [weak self] p in self?.openProfile(p) }))
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
        let count = state.inside.count
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
        shown = state.faces ? Array(state.visiblePeople.prefix(3)) : []
        while faces.count > shown.count { NSStatusBar.system.removeStatusItem(faces.removeLast()) }
        while faces.count < shown.count {
            let item = NSStatusBar.system.statusItem(withLength: 25)
            item.button?.target = self; item.button?.action = #selector(faceClick(_:))
            faces.append(item)
        }
        for (i,p) in shown.enumerated() {
            let button = faces[i].button
            photos.fetch(p.user)
            button?.tag = i
            button?.image = avatar(p.user, status: p.status)
            button?.toolTip = p.user.name + " · " + state.subtitle(p) + (state.mode == "Live" ? "" : " · " + state.mode)
            button?.setAccessibilityLabel("Open DM with " + p.user.name)
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
    @objc func faceClick(_ sender: NSStatusBarButton) {
        if shown.indices.contains(sender.tag) { dm(shown[sender.tag]) }
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
