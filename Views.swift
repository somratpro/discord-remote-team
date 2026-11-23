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
            if !state.sample, let channel = state.updatesChannel, state.hasConnection {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        state.openBrowser(channel.url)
                    } label: {
                        Label("Open work updates channel", systemImage: "arrow.up.right.square")
                    }.buttonStyle(.borderless)
                    if let readAt = state.lastUpdatesSync {
                        Text("Last read " + state.updateReadTime(readAt))
                    }
                    if let warning = state.updatesWarning {
                        Text(warning)
                    } else if state.lastUpdatesSync != nil && !state.people.contains(where: { $0.workUpdate != nil }) {
                        Text("No readable updates today")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
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
    @SwiftUI.State private var capacity: [String: Capacity]
    @SwiftUI.State private var imported: DirectoryTransfer?
    @SwiftUI.State private var error = ""
    @SwiftUI.State private var selection: String?
    @SwiftUI.State private var rawLists: [String: String] = [:]

    init(state: State, guild: String, openProfile: @escaping (Person) -> Void, close: @escaping () -> Void) {
        self.state = state
        self.guild = guild
        self.openProfile = openProfile
        self.close = close
        _draft = SwiftUI.State(initialValue: state.directory)
        _capacity = SwiftUI.State(initialValue: state.capacity.filter { $0.value.expires > Date() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review job titles").font(.headline)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Recognized job titles").font(.callout)
                        TextField("Separate titles with commas", text: $draft.recognizedTitles)
                            .accessibilityLabel("Recognized job titles, separated by commas")
                        Text("Approve exact job role labels once for everyone who has them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if state.evidence.incomplete { Text("Some Discord role assignments could not be verified.").font(.caption) }
                    let labels = reviewableRoles.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    ForEach(labels, id: \.self) { label in
                        let ids = reviewableRoles[label, default: []].map(\.id)
                        Toggle(label, isOn: Binding(
                            get: { ids.allSatisfy { draft.approved[$0] == label } },
                            set: { approved in
                                for id in ids { draft.approved[id] = approved ? label : nil }
                            }
                        ))
                    }
                    if labels.isEmpty { Text("No recognized job roles to review.").foregroundStyle(.secondary) }
                    Divider()
                    Text("Teammates").font(.headline)
                    ForEach(state.people) { person in
                        let resolved = draft.resolve(person.id, evidence: state.evidence)
                        DisclosureGroup(isExpanded: Binding(get: { selection == person.id },
                                                             set: { selection = $0 ? person.id : nil })) {
                            fields(person, resolved: resolved).padding(.vertical, 8)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(person.user.name)
                                Text(resolved.role ?? (resolved.candidates.isEmpty ? "Title unknown" : "Multiple approved titles"))
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
                    capacity = capacity.filter { $0.value.expires > Date() }
                    draft.people = draft.people.filter { $0.value != TeamProfile() }
                    do { try state.saveDirectory(draft, capacity: capacity, guild: guild); close() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(state.guild != guild || imported != nil)
            }
        }.textFieldStyle(.roundedBorder).padding(18).frame(width: 545, height: 560)
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

    private func text(_ id: String, key: String, field: WritableKeyPath<TeamProfile, [String]>) -> Binding<String> {
        let entry = id + "/" + key
        return Binding(get: { rawLists[entry] ?? draft.people[id, default: TeamProfile()][keyPath: field].joined(separator: ", ") },
                       set: { value in
                           rawLists[entry] = value
                           draft.people[id, default: TeamProfile()][keyPath: field] = items(value)
                       })
    }

    private func fields(_ person: Person, resolved: ResolvedProfile) -> some View {
        let id = person.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(id).font(.caption.monospaced())
                Spacer()
                Button("Open Discord profile") { openProfile(person) }.disabled(state.sample)
            }
            TextField("Explicit job title from profile or team records", text: Binding(
                get: { draft.people[id, default: TeamProfile()].title },
                set: { draft.people[id, default: TeamProfile()].title = $0 }
            )).onSubmit { trimTitle(id) }
            if !draft.people[id, default: TeamProfile()].title.isEmpty {
                Button("Clear title override") { draft.people[id, default: TeamProfile()].title = "" }
            }
            if resolved.candidates.count > 1 {
                Menu("Choose an approved role") {
                    if draft.people[id]?.preferredRole != nil {
                        Button("Clear choice") { draft.people[id]?.preferredRole = nil }
                    }
                    ForEach(resolved.candidates, id: \.self) { title in
                        Button(title) { draft.people[id, default: TeamProfile()].preferredRole = title }
                    }
                }
            }
            TextField("Skills, separated by commas", text: text(id, key: "skills", field: \.skills))
            TextField("Projects owned, separated by commas", text: text(id, key: "owns", field: \.owns))
            TextField("Projects backed up, separated by commas", text: text(id, key: "backsUp", field: \.backsUp))
            Picker("Capacity set by operator", selection: Binding(
                get: { capacity[id].map { $0.focused ? "focused" : "taking" } ?? "" },
                set: { option in
                    capacity[id] = option.isEmpty ? nil : Capacity(focused: option == "focused", expires: nextTeamDay)
                }
            )) {
                Text("Unknown").tag("")
                Text("Taking tasks").tag("taking")
                Text("Focused until…").tag("focused")
            }
            if let entry = capacity[id] {
                DatePicker("Expires", selection: Binding(get: { entry.expires }, set: { expiry in
                    capacity[id] = Capacity(focused: entry.focused, expires: expiry)
                }))
                Button("Expire at next team day") {
                    capacity[id] = Capacity(focused: entry.focused, expires: nextTeamDay)
                }
            }
        }
    }

    private var nextTeamDay: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = state.zone
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
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
                    Text("\(name) · \(draft.people[id] == nil ? "New profile" : "Conflicting profile")")
                    if let current = draft.people[id] { Text("Current · " + describe(current)).font(.caption) }
                    Text("Incoming · " + describe(incoming)).font(.caption)
                }
            }
            HStack {
                Button("Cancel import") { imported = nil }
                Button("Keep existing conflicts") {
                    draft = value.applying(to: draft, replaceConflicts: false); rawLists = [:]; imported = nil
                }
                Button("Use incoming conflicts") {
                    draft = value.applying(to: draft, replaceConflicts: true); rawLists = [:]; imported = nil
                }
            }
        }
    }

    private func describe(_ profile: TeamProfile) -> String {
        [profile.title, profile.skills.joined(separator: ", "),
         "Owns " + profile.owns.joined(separator: ", "), "Backs up " + profile.backsUp.joined(separator: ", ")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
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
