import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

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
    let reviewDirectory: () -> Void
    let handoff: (Person) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Remote Team").font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: hide) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
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
                                            let profile = state.profile(p)
                                            if let title = profile.role {
                                                Text(title).font(.caption).lineLimit(1).help(title)
                                            } else if !profile.candidates.isEmpty {
                                                Text("Multiple job titles · review directory").font(.caption).lineLimit(1)
                                            }
                                            Text(state.subtitle(p)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "bubble.left").foregroundStyle(.secondary)
                                    }.padding(.vertical, 4).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .help("Open DM with " + p.user.name)
                                .contextMenu {
                                    Button("Open Discord profile") { openProfile(p) }.disabled(state.sample)
                                    Button("Prepare handoff…") { handoff(p) }
                                }
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
                Menu {
                    Button("Copy today's standup summary") { state.copyStandupSummary() }
                    Button("Review team directory…", action: reviewDirectory).disabled(state.guild == nil)
                    Button("Copy AI setup prompt") { copyMCPPrompt() }
                    Button("Quit Remote Team") { NSApp.terminate(nil) }
                }
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
                        Text("Work updates channel link (optional)").font(.callout)
                        TextField("Discord work updates channel URL", text: $updates)
                            .accessibilityLabel("Work updates channel")
                        Text("Leave blank to use the check-in channel for updates.")
                            .font(.caption).foregroundStyle(.secondary)
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

struct DirectoryView: View {
    @ObservedObject var state: State
    let guild: String
    let openProfile: (Person) -> Void
    let close: () -> Void
    @SwiftUI.State private var draft: TeamDirectory
    @SwiftUI.State private var imported: DirectoryTransfer?
    @SwiftUI.State private var error = ""
    @SwiftUI.State private var selection: String?

    private let shortDesignations = ["Developer", "Designer", "SEO", "Marketer", "Manager", "Lead", "Writer", "Admin"]

    init(state: State, guild: String, openProfile: @escaping (Person) -> Void, close: @escaping () -> Void) {
        self.state = state
        self.guild = guild
        self.openProfile = openProfile
        self.close = close
        _draft = SwiftUI.State(initialValue: state.directory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recognized designations").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Separate designations with commas", text: $draft.recognizedTitles)
                            .accessibilityLabel("Recognized designations, separated by commas")
                        Text("Approved designations for matching roles or bios.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    let labels = reviewableRoles.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    if !labels.isEmpty {
                        Text("Approve server roles").font(.subheadline).padding(.top, 4)
                        ForEach(labels, id: \.self) { label in
                            let ids = reviewableRoles[label, default: []].map(\.id)
                            Toggle(label, isOn: Binding(
                                get: { ids.allSatisfy { draft.approved[$0] == label } },
                                set: { approved in
                                    for id in ids { draft.approved[id] = approved ? label : nil }
                                }
                            ))
                        }
                    }
                    Divider()
                    Text("Teammates").font(.headline)
                    ForEach(state.people) { person in
                        let resolved = draft.resolve(person.id, evidence: state.evidence)
                        DisclosureGroup(isExpanded: Binding(get: { selection == person.id },
                                                             set: { selection = $0 ? person.id : nil })) {
                            fields(person, resolved: resolved).padding(.vertical, 8)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.user.name).fontWeight(.medium)
                                Text(resolved.role ?? (resolved.candidates.isEmpty ? "No designation set" : "Multiple approved titles"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let imported {
                        Divider()
                        transferPreview(imported)
                    }
                }.padding(2)
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Import…", action: importDirectory).disabled(state.sample)
                Button("Export saved directory…", action: exportDirectory).disabled(state.sample)
                Spacer()
                Button("Cancel", action: close)
                Button("Save") {
                    for id in Array(draft.people.keys) { trimTitle(id) }
                    draft.people = draft.people.filter { $0.value != TeamProfile() }
                    do { try state.saveDirectory(draft, guild: guild); close() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(state.guild != guild || imported != nil)
            }
        }.textFieldStyle(.roundedBorder).padding(18).frame(width: 520, height: 490)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var reviewableRoles: [String: [GuildRole]] {
        let recognized = Set(items(draft.recognizedTitles).map { $0.lowercased() })
        return Dictionary(grouping: state.evidence.roles.values.filter {
            draft.approved[$0.id] != nil || recognized.contains($0.name.lowercased())
        }, by: \.name)
    }

    private func items(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func fields(_ person: Person, resolved: ResolvedProfile) -> some View {
        let id = person.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Open Discord profile") { openProfile(person) }.disabled(state.sample)
                Button("Paste from About Me") {
                    guard let text = NSPasteboard.general.string(forType: .string),
                          let title = detectDesignation(from: text, recognized: items(draft.recognizedTitles)) else {
                        error = "Copy the job-title line from About Me, or enter the designation directly."
                        return
                    }
                    draft.people[id, default: TeamProfile()].title = title
                    error = ""
                }
            }
            if let bio = resolved.bio, !bio.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bio from Discord:").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(bio).font(.caption).padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Designation").font(.callout.weight(.medium))
                TextField("e.g. Developer, Designer, SEO", text: Binding(
                    get: { draft.people[id, default: TeamProfile()].title },
                    set: { draft.people[id, default: TeamProfile()].title = $0 }
                )).onSubmit { trimTitle(id) }

                HStack(spacing: 5) {
                    Text("Quick set:").font(.caption).foregroundStyle(.secondary)
                    ForEach(shortDesignations, id: \.self) { desig in
                        Button(desig) {
                            draft.people[id, default: TeamProfile()].title = desig
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
            }
            if !draft.people[id, default: TeamProfile()].title.isEmpty {
                Button("Clear designation") { draft.people[id, default: TeamProfile()].title = "" }
                    .font(.caption)
            }
            if resolved.candidates.count > 1 {
                Menu("Choose an approved role (\(resolved.candidates.joined(separator: ", ")))") {
                    if draft.people[id]?.preferredRole != nil {
                        Button("Clear choice") { draft.people[id]?.preferredRole = nil }
                    }
                    ForEach(resolved.candidates, id: \.self) { title in
                        Button(title) { draft.people[id, default: TeamProfile()].preferredRole = title }
                    }
                }
            }
        }
    }

    private func trimTitle(_ id: String) {
        guard let title = draft.people[id]?.title else { return }
        draft.people[id]?.title = title.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    private func importDirectory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let value = try JSONDecoder().decode(DirectoryTransfer.self, from: Data(contentsOf: url))
            _ = try value.changes(for: guild, current: draft)
            imported = value
            error = ""
        } catch { self.error = error.localizedDescription }
    }

    private func exportDirectory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Remote-Team-Directory.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(DirectoryTransfer(guild: guild, directory: state.directory)).write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    private func transferPreview(_ value: DirectoryTransfer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Directory import preview").font(.headline)
            if let changes = try? value.changes(for: guild, current: draft) {
                Text("\(changes.additions) additions · \(changes.conflicts) conflicts")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(value.approved.keys.sorted(), id: \.self) { id in
                if let incoming = value.approved[id], incoming != draft.approved[id] {
                    Text("Role \(id) · \(draft.approved[id].map { "Conflict: \($0) → " } ?? "New: ")\(incoming)")
                }
            }
            ForEach(value.people.keys.sorted(), id: \.self) { id in
                if let incoming = value.people[id], incoming != draft.people[id] {
                    let name = state.people.first { $0.id == id }.map { $0.user.name + " · " + id } ?? id
                    Text("\(name) · \(draft.people[id] == nil ? "New designation" : "Conflicting designation")")
                    if let current = draft.people[id], !current.title.isEmpty { Text("Current · " + current.title).font(.caption) }
                    if !incoming.title.isEmpty { Text("Incoming · " + incoming.title).font(.caption) }
                }
            }
            HStack {
                Button("Cancel import") { imported = nil }
                Button("Keep existing conflicts") {
                    draft = value.applying(to: draft, replaceConflicts: false); imported = nil
                }
                Button("Use incoming conflicts") {
                    draft = value.applying(to: draft, replaceConflicts: true); imported = nil
                }
            }
        }
    }
}

struct HandoffView: View {
    let person: Person
    let sample: Bool
    let openDM: () -> Void
    let openProfile: () -> Void
    @SwiftUI.State private var draft = ""
    @SwiftUI.State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(person.user.name).font(.headline)
            Text(person.id).font(.caption.monospaced()).textSelection(.enabled)
            Text("Paste or write the exact message to copy. Include the deliverable, completion criteria, and any agreed deadline.")
            TextEditor(text: Binding(get: { draft }, set: { draft = $0; copied = false })).font(.body).frame(height: 150).border(.quaternary)
            HStack {
                Button("Open Discord profile", action: openProfile).disabled(sample)
                Spacer()
                if copied { Text("Copied").foregroundStyle(.secondary) }
                Button("Approve, copy & open DM") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(draft, forType: .string)
                    if copied { openDM() }
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 495)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
