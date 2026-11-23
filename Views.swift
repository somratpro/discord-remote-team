import SwiftUI
import AppKit
import ServiceManagement

struct Face: View {
    let user: User
    let status: Status
    @ObservedObject var photos: Photos
    var body: some View {
        ZStack {
            Circle().fill(avatarColor(user.id).opacity(0.18))
            if let photo = photos.images[Photos.key(user)] {
                Image(nsImage: photo).resizable().scaledToFill()
            } else {
                Text(initials(user)).font(.system(size: 13, weight: .semibold)).foregroundStyle(avatarColor(user.id))
            }
        }.frame(width: 34, height: 34).clipShape(Circle()).overlay {
            if let color = statusColor(status) { Circle().strokeBorder(color, lineWidth: 2) }
        }.onAppear { photos.fetch(user) }
    }
}

struct RosterView: View {
    @ObservedObject var state: State
    @ObservedObject var photos: Photos
    let settings: () -> Void
    let hide: () -> Void
    let pin: () -> Void
    let openDM: (Person) -> Void
    let openProfile: (Person) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Remote Team").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: hide) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }.buttonStyle(.borderless)
                    .help("Hide roster").accessibilityLabel("Hide roster")
            }.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if state.sample || state.mode != "Live" {
                HStack(alignment: .top) {
                    Image(systemName: state.sample ? "eye" : "info.circle")
                    Text(state.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(.secondary).padding(12)
            }
            if let warning = state.updatesWarning {
                Text(warning).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Status.allCases, id: \.rawValue) { status in
                        let group = state.people.filter { $0.status == status }
                        if !group.isEmpty {
                            HStack {
                                Circle().fill(statusColor(status) ?? Color.secondary.opacity(0.55)).frame(width: 7, height: 7)
                                Text(status.title).font(.headline)
                                Spacer()
                                Text(String(group.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }.padding(.top, 10).padding(.bottom, 3)
                            ForEach(group) { p in
                                Button { openDM(p) } label: {
                                    HStack(spacing: 10) {
                                        Face(user: p.user, status: p.status, photos: photos)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(p.user.name).fontWeight(.medium)
                                            Text(state.subtitle(p)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "bubble.left").foregroundStyle(.secondary)
                                    }.padding(.vertical, 4).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .help("Open DM with " + p.user.name)
                                .contextMenu { Button("Open Discord profile") { openProfile(p) }.disabled(state.sample) }
                                if let update = p.workUpdate {
                                    Button { state.openBrowser(update.url) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Label("Work update · " + state.time(update.date), systemImage: "arrow.up.right.square")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text(update.text).font(.callout).lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain).disabled(state.sample)
                                        .help("Open work update in Discord")
                                        .padding(.leading, 44).padding(.bottom, 6)
                                }
                            }
                        }
                    }
                    if state.people.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.2").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text(state.mode == "Syncing" ? "Reading check-ins…" : "No teammates to show").font(.headline)
                            if !state.hasConnection { Button("Connect Discord…", action: settings) }
                        }.frame(maxWidth: .infinity).padding(.top, 32)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Text(state.lastSync.map { state.mode + " · " + state.time($0) } ?? state.mode)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if state.sample { Button("Exit preview") { state.resume(); if !state.hasConnection { settings() } } }
                else { Button { state.refresh(full: true) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh from Discord") }
                Button(action: pin) {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                }
                .help(state.pinned ? "Unpin roster" : "Keep roster on top")
                .accessibilityLabel(state.pinned ? "Unpin roster" : "Pin roster")
                Button(action: settings) { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
                Menu { Button("Copy AI setup prompt") { copyMCPPrompt() }; Button("Quit Remote Team") { NSApp.terminate(nil) } }
                    label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
        }.frame(width: 322, height: 454)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsView: View {
    @ObservedObject var state: State
    let close: () -> Void
    let preview: () -> Void
    @SwiftUI.State private var channel: String
    @SwiftUI.State private var updates: String
    @SwiftUI.State private var zone: String
    @SwiftUI.State private var browser: String
    @SwiftUI.State private var faces: Bool
    @SwiftUI.State private var token = ""
    @SwiftUI.State private var error = ""
    @SwiftUI.State private var advanced = false
    @SwiftUI.State private var login = SMAppService.mainApp.status == .enabled
    init(state: State, close: @escaping () -> Void, preview: @escaping () -> Void) {
        self.state = state; self.close = close; self.preview = preview
        _channel = StateWrapper(initialValue: state.channelLink)
        _updates = StateWrapper(initialValue: state.updatesLink)
        _zone = StateWrapper(initialValue: state.zoneID)
        _faces = StateWrapper(initialValue: state.faces)
        _browser = StateWrapper(initialValue: state.browser)
    }
    private typealias StateWrapper<T> = SwiftUI.State<T>
    private let browsers = [
        ("com.google.Chrome", "Google Chrome"), ("com.brave.Browser","Brave"),
        ("com.microsoft.edgemac","Microsoft Edge"), ("company.thebrowser.Browser","Arc"),
        ("com.vivaldi.Vivaldi","Vivaldi"), ("org.chromium.Chromium","Chromium")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "person.2.fill").font(.title2).foregroundStyle(.teal)
                    .frame(width: 44,height: 44).background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading,spacing: 3) {
                    Text("Remote Team").font(.system(size: 22, weight: .semibold))
                    Text("Your Discord check-in channel, in the menu bar.").foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Discord connection").font(.headline)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Check-in channel").font(.callout)
                        TextField("Discord channel URL", text: $channel)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Bot token").font(.callout)
                        SecureField(state.hasConnection ? "Saved in Keychain · leave blank to keep" : "Enter bot token", text: $token)
                        Text("Saved only in this Mac’s Keychain. Attendance comes directly from Discord.").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("How to connect a Discord bot") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("1. Create an application in the Discord Developer Portal. On its Bot page, enable Message Content Intent and save.")
                            Text("2. Under Installation, enable Guild Install with the bot scope. Give it View Channel and Read Message History. Open the install link and choose your team server.")
                            Text("3. Check that the bot can read the attendance channel, including its history. On the Bot page, copy its token and paste it above.")
                            Link("Open Discord Developer Portal ↗", destination: URL(string: "https://discord.com/developers/applications")!)
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    Divider()
                    Toggle("Show up to three employee photos in the menu bar", isOn: $faces)
                    Toggle("Open at login", isOn: $login).onChange(of: login) { value in
                        do {
                            if value && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                            else if !value && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
                            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                        } catch { self.error = error.localizedDescription }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Work updates channel (optional)").font(.callout)
                        TextField("Discord channel URL", text: $updates)
                            .accessibilityLabel("Work updates channel")
                        Text("Leave blank to show updates from the check-in channel. The bot needs access to any separate channel.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Time zone and browser", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Team time zone", text: $zone)
                            Picker("Open DMs in", selection: $browser) {
                                Text("Default browser").tag("")
                                ForEach(browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }, id: \.0) {
                                    Text($0.1).tag($0.0)
                                }
                            }
                        }.padding(.vertical, 8)
                    }
                    if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.textFieldStyle(.roundedBorder).padding(20)
            }
            Divider()
            HStack {
                Button("Try preview", action: preview)
                Button("Copy AI setup prompt") { copyMCPPrompt() }
                Spacer()
                Button("Save & connect") {
                    do {
                        try state.save(channel: channel, updates: updates, zone: zone.trimmingCharacters(in: .whitespacesAndNewlines),
                                       newToken: token, browser: browser, faces: faces)
                        token = ""; close()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 505, height: 510)
    }
}
