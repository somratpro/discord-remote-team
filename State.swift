import AppKit
import SwiftUI

@MainActor final class State: ObservableObject {
    private let prefs = UserDefaults.standard
    @Published var people = [Person]()
    @Published var mode = "Setup"
    @Published var detail = "Connect the check-in channel in Settings."
    @Published var lastSync: Date?
    @Published var pinned = false
    @Published var faces = UserDefaults.standard.object(forKey: "showFaces") as? Bool ?? true

    var channelLink: String { prefs.string(forKey: "channel") ?? defaultChannel }
    var updatesLink: String { prefs.string(forKey: "updatesChannel") ?? "" }
    @Published var updatesWarning: String?
    @Published var lastUpdatesSync: Date?
    @Published var directory = TeamDirectory()
    @Published var evidence = RoleEvidence()
    var guild: String? { sample ? "preview" : Channel(channelLink)?.guild }
    var updatesChannel: Channel? { Channel(updatesLink) ?? Channel(channelLink) }
    private var discovery = RoleDiscovery()
    private var roleTask: Task<Void, Never>?

    func saveDirectory(_ value: TeamDirectory, guild: String) throws {
        guard guild == self.guild else { throw Problem("The selected Discord server changed.") }
        if !sample {
            try value.save(guild, prefs: prefs)
        }
        directory = value
    }

    func profile(_ person: Person) -> ResolvedProfile {
        directory.resolve(person.id, evidence: evidence)
    }

    private func discover(_ api: Discord, people: [Person], generation: Int) {
        guard roleTask == nil else { return }
        let discovery = self.discovery
        roleTask = Task {
            let result = await discovery.load(api, ids: people.map(\.id))
            guard self.generation == generation, !Task.isCancelled else { return }
            evidence = result
            roleTask = nil
        }
    }

    var zoneID: String { prefs.string(forKey: "zone") ?? defaultZone }
    var browser: String { prefs.string(forKey: "browser") ?? "" }
    var zone: TimeZone { TimeZone(identifier: zoneID) ?? .current }
    var token = ""
    var inside: [Person] { people.filter { $0.status == .inside } }
    var visiblePeople: [Person] { people.filter { $0.status == .inside || $0.status == .onBreak } }
    var sample: Bool { mode == "Preview" }
    var hasConnection: Bool { !token.isEmpty }
    private var runner: Task<Void, Never>?
    private var previous = [Post]()
    private var workPosts = [Post]()
    private var workFullAt = Date.distantPast
    private var workDay: Date?
    private var updatesRetryAt = Date.distantPast
    private var fullAt = Date.distantPast
    private var fullDay: Date?
    private var rosterDay: Date?
    private var nextAllowed = Date.distantPast
    private var syncing = false
    private var generation = 0
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
    func start() {
        do { token = try Keychain.read() }
        catch { detail = error.localizedDescription }
        if hasConnection { reset(); refresh(full: true) }
    }
    func save(channel: String, updates: String, zone: String, newToken: String, browser: String, faces: Bool) throws {
        guard Channel(channel) != nil else { throw Problem("Paste a Discord server channel link.") }
        let updates = updates.trimmingCharacters(in: .whitespacesAndNewlines)
        guard updates.isEmpty || Channel(updates) != nil else { throw Problem("Paste a Discord channel link for work updates, or leave it blank.") }
        guard TimeZone(identifier: zone) != nil else { throw Problem("Enter a time zone such as Asia/Dhaka.") }
        let t = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || hasConnection else { throw Problem("Enter the bot token to connect, or use Preview to try the interface.") }
        if !t.isEmpty { try Keychain.save(t); token = t }
        prefs.set(channel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "channel")
        prefs.set(updates, forKey: "updatesChannel"); prefs.set(zone, forKey: "zone")
        prefs.set(browser, forKey: "browser"); prefs.set(faces, forKey: "showFaces")
        self.faces = faces
        reset()
        mode = "Syncing"; detail = "Reading Discord channel history…"
        refresh(full: true)
    }
    func reset() {
        runner?.cancel(); generation += 1; syncing = false
        previous = []; workPosts = []; people = []; fullAt = .distantPast
        updatesWarning = nil; updatesRetryAt = .distantPast
        lastSync = nil; fullDay = nil; rosterDay = nil; lastUpdatesSync = nil
        workFullAt = .distantPast; workDay = nil
        roleTask?.cancel(); roleTask = nil; discovery = RoleDiscovery()
        evidence = RoleEvidence()
        directory = Channel(channelLink).map { TeamDirectory.load($0.guild, prefs: prefs) } ?? TeamDirectory()
    }
    func preview() {
        reset()
        mode = "Preview"; detail = "Sample teammates · disconnected from Discord"
        directory = TeamDirectory()
        directory.people["sample-0"] = TeamProfile(title: "Developer")
        directory.people["sample-3"] = TeamProfile(title: "Marketer")
        let developer = GuildRole(id: "sample-developer", name: "Developer", managed: false)
        let analyst = GuildRole(id: "sample-analyst", name: "SEO", managed: false)
        directory.approved[developer.id] = developer.name
        evidence = RoleEvidence(roles: [developer.id: developer, analyst.id: analyst],
                                members: ["sample-1": [developer.id], "sample-2": [analyst.id]],
                                bios: ["sample-2": "SEO Specialist & Content Strategist"])
        let names = ["Maya Ahmed", "Arif Khan", "Nadia Islam", "Leo Chen"]
        let states: [Status] = [.inside,.onBreak,.outside,.unknown]
        people = names.enumerated().map { i, n in
            let t = Date().addingTimeInterval(Double(-3600 * (i + 1)))
            var person = Person(user: User(id: "sample-\(i)", username: n), status: states[i],
                          firstIn: i < 3 ? t : nil, last: i < 3 ? (i == 2 ? Date() : t) : nil)
            if i == 0, let url = URL(string: "https://discord.com") {
                person.workUpdate = WorkUpdate(text: "Finished the dashboard review. I’m working through the feedback now.", date: t, url: url)
            }
            return person
        }
    }
    func resume() {
        reset()
        mode = hasConnection ? "Syncing" : "Setup"
        detail = hasConnection ? "Reading Discord channel history…" : "Connect the check-in channel in Settings."
        refresh(full: true)
    }
    func refresh(full: Bool = false) {
        guard !sample, hasConnection else { return }
        let now = Date()
        let localRules = Rules(now: now, zone: zone)
        let needsUpdate = rosterDay != localRules.today || people.contains { person in
            (person.checkoutDeadline.map { $0 <= now } ?? false) ||
            (person.lastCheckIn.map { $0 <= localRules.since } ?? false)
        }
        if lastSync != nil, needsUpdate, let channel = updatesChannel {
            presentRoster(channel: channel, rules: localRules)
        }
        guard !syncing, Date() >= nextAllowed,
              let ch = Channel(channelLink) else { return }
        let api = Discord(token: token, channel: ch, session: session)
        let updateChannel = Channel(updatesLink) ?? ch
        let fetchSeparateUpdates = updateChannel != ch && now >= updatesRetryAt
        let requestID = generation
        syncing = true
        if full || lastSync == nil || mode == "Offline" { mode = "Syncing" }
        runner = Task {
            defer { if generation == requestID { syncing = false } }
            do {
                let rules = Rules(now: Date(), zone: zone)
                async let separate = fetchSeparateUpdates
                    ? loadWorkUpdates(channel: updateChannel, since: rules.today, full: full)
                    : nil
                let first = try await api.page()
                let oldest = first.last.flatMap { UInt64($0.id) } ?? 0
                let gap = !first.isEmpty && !previous.isEmpty && oldest > (UInt64(previous[0].id) ?? 0)
                let rebuild = full || fullDay != rules.today || Date().timeIntervalSince(fullAt) > 300 || gap
                var posts = previous
                if rebuild {
                    posts = try await api.history(first: first, since: rules.since)
                } else if first.count < 100 { posts = first }
                else { posts = first + previous.filter { (UInt64($0.id) ?? 0) < oldest } }
                try Task.checkCancellation()
                guard generation == requestID else { return }
                if first.isEmpty {
                    throw Problem("No readable messages. Check the channel, its history, and the bot’s Read Message History permission.")
                }
                if posts.allSatisfy({ $0.content.isEmpty }) {
                    throw Problem("No readable message text. Check Message Content Intent in the Discord Developer Portal.")
                }
                if rebuild { fullAt = Date(); fullDay = rules.today }
                previous = posts
                if updateChannel == ch {
                    workPosts = posts
                    lastUpdatesSync = Date()
                }
                let attendanceRules = Rules(now: Date(), zone: zone)
                presentRoster(channel: updateChannel, rules: attendanceRules)
                lastSync = Date(); mode = "Live"
                detail = people.isEmpty ? "No check-ins in the last seven days." : "Updates every 20 seconds"
                discover(api, people: roster(posts: posts, members: [], rules: attendanceRules), generation: requestID)
                if let updates = await separate {
                    try Task.checkCancellation()
                    guard generation == requestID else { return }
                    switch updates {
                    case .success(let (snapshot, readAt)):
                        workPosts = snapshot.posts
                        if snapshot.rebuilt { workFullAt = readAt; workDay = rules.today }
                        lastUpdatesSync = readAt
                        updatesWarning = nil
                    case .failure(let error):
                        let delay = (error as? RateLimit)?.seconds ?? 20
                        updatesRetryAt = Date().addingTimeInterval(delay)
                        updatesWarning = "Work updates may be stale. " + (error is RateLimit
                            ? "Discord requested a pause."
                            : "Check the updates channel and the bot’s permissions.")
                    }
                    presentRoster(channel: updateChannel, rules: Rules(now: Date(), zone: zone))
                }
            } catch {
                guard generation == requestID, !Task.isCancelled else { return }
                mode = "Offline"
                if let limit = error as? RateLimit {
                    nextAllowed = Date().addingTimeInterval(limit.seconds)
                    detail = "Discord requested a pause. Sync will retry automatically."
                } else { detail = error.localizedDescription }
            }
        }
    }
    private func presentRoster(channel: Channel, rules: Rules) {
        people = rosterWithUpdates(posts: previous, updates: workPosts, channel: channel, rules: rules)
        rosterDay = rules.today
    }

    private func loadWorkUpdates(channel: Channel, since: Date, full: Bool) async -> Result<(MessageWindow, Date), Error> {
        let api = Discord(token: token, channel: channel, session: session)
        let initial = workPosts
        let rebuild = full || workDay != since || Date().timeIntervalSince(workFullAt) >= 300
        do {
            let window = try await api.window(previous: initial, since: since, rebuild: rebuild)
            return .success((window, Date()))
        } catch {
            return .failure(error)
        }
    }

    func updateReadTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.timeZone = zone; f.timeStyle = .short
        return f.string(from: date)
    }
    func subtitle(_ p: Person) -> String {
        switch p.status {
        case .inside:
            let duration = p.firstIn.map { " (" + elapsedString(from: $0) + ")" } ?? ""
            return (p.firstIn != p.last ? "In since " + time(p.last) + " · first in " + time(p.firstIn) : "In since " + time(p.last)) + duration
        case .onBreak: return "On break since " + time(p.last)
        case .outside: return (p.autoCheckedOut ? "Auto out " : "Out ") + time(p.last) + (p.firstIn.map { " · first in " + time($0) } ?? "")
        case .earlier:
            let f = DateFormatter(); f.timeZone = zone; f.dateFormat = "MMM d, h:mm a"
            return p.last.map { "Last in " + f.string(from: $0) } ?? "Earlier check-in"
        case .unknown: return "No update today"
        }
    }
    func elapsedString(from start: Date, to end: Date = Date()) -> String {
        let diff = max(0, Int(end.timeIntervalSince(start)))
        let hours = diff / 3600
        let mins = (diff % 3600) / 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
    func copyStandupSummary() {
        let now = Date()
        var text = "# Team Standup · " + time(now) + "\n\n"
        let onBreak = people.filter { $0.status == .onBreak }
        let outside = people.filter { $0.status == .outside }
        text += "### Overview: \(inside.count) Checked In · \(onBreak.count) On Break · \(outside.count) Checked Out\n\n"
        let activeMembers = people.filter { $0.status != .unknown && $0.status != .earlier }
        if !activeMembers.isEmpty {
            for p in activeMembers {
                let prof = profile(p)
                let roleStr = prof.role.map { " (\($0))" } ?? ""
                text += "- **\(p.user.name)**\(roleStr) — \(subtitle(p))\n"
                if let update = p.workUpdate {
                    text += "  - *Latest update (\(time(update.date))):* \(update.text)\n"
                }
            }
        } else {
            text += "_No check-ins recorded today._\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func saveDM(_ raw: String, for id: String) throws {
        let key = "dm." + id
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prefs.removeObject(forKey: key)
        } else if let url = dmURL(raw) {
            prefs.set(url.absoluteString, forKey: key)
        } else {
            throw Problem("Enter a Discord DM conversation or message link.")
        }
    }

    func dm(_ id: String) -> String { prefs.string(forKey: "dm." + id) ?? "" }
    func openBrowser(_ url: URL) {
        if !browser.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
                if let error { DispatchQueue.main.async { NSApp.presentError(error) } }
            }
        } else { NSWorkspace.shared.open(url) }
    }
}

let palette: [Color] = [.teal, .indigo, .purple, .blue, .orange, .pink]
func avatarColor(_ id: String) -> Color { palette[id.utf8.reduce(0) { ($0 + Int($1)) % palette.count }] }
func statusColor(_ status: Status) -> Color? {
    switch status {
    case .inside: return .green
    case .onBreak: return .yellow
    default: return nil
    }
}
func initials(_ u: User) -> String {
    u.name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
}

@MainActor final class Photos: ObservableObject {
    @Published var images = [String: NSImage]()
    private var inflight = Set<String>()
    static func key(_ user: User) -> String { user.id + "/" + (user.avatar ?? "") }
    func fetch(_ user: User) {
        guard let hash = user.avatar, isID(user.id), hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || $0 == 95 }),
              let url = URL(string: "https://cdn.discordapp.com/avatars/\(user.id)/\(hash).png?size=64") else { return }
        let key = Self.key(user)
        guard images[key] == nil, inflight.insert(key).inserted else { return }
        Task {
            defer { inflight.remove(key) }
            if let (bytes, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
               let photo = NSImage(data: bytes) { images[key] = photo }
        }
    }
}
