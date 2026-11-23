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
    private var updatesRetryAt = Date.distantPast
    private var fullAt = Date.distantPast
    private var fullDay: Date?
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
        if hasConnection { refresh(full: true) }
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
        lastSync = nil; fullDay = nil
    }
    func preview() {
        reset()
        mode = "Preview"; detail = "Sample teammates · disconnected from Discord"
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
        if people.contains(where: { $0.checkoutDeadline.map { $0 <= now } ?? false }) {
            if let channel = Channel(updatesLink) ?? Channel(channelLink) {
                people = rosterWithUpdates(posts: previous, updates: workPosts, channel: channel, rules: Rules(now: now, zone: zone))
            }
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
                    ? loadWorkUpdates(channel: updateChannel, since: rules.today)
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
                let updates = await separate
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
                } else if let updates {
                    switch updates {
                    case .success(let messages):
                        workPosts = messages
                        updatesWarning = nil
                    case .failure(let error):
                        let delay = (error as? RateLimit)?.seconds ?? 20
                        updatesRetryAt = Date().addingTimeInterval(delay)
                        updatesWarning = "Work updates may be stale. " + (error is RateLimit
                            ? "Discord requested a pause."
                            : "Check the updates channel and the bot’s permissions.")
                    }
                }
                people = rosterWithUpdates(posts: posts, updates: workPosts, channel: updateChannel, rules: rules)
                lastSync = Date(); mode = "Live"
                detail = people.isEmpty ? "No check-ins found in the last eight calendar days." : "Updates every 20 seconds"
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
    private func loadWorkUpdates(channel: Channel, since: Date) async -> Result<[Post], Error> {
        let api = Discord(token: token, channel: channel, session: session)
        do {
            let first = try await api.page()
            return .success(try await api.history(first: first, since: since))
        } catch {
            return .failure(error)
        }
    }

    func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.timeZone = zone; f.timeStyle = .short
        return f.string(from: date)
    }
    func subtitle(_ p: Person) -> String {
        switch p.status {
        case .inside: return p.firstIn != p.last ? "In since " + time(p.last) + " · first in " + time(p.firstIn) : "In since " + time(p.last)
        case .onBreak: return "On break since " + time(p.last)
        case .outside: return (p.autoCheckedOut ? "Auto out " : "Out ") + time(p.last) + (p.firstIn.map { " · first in " + time($0) } ?? "")
        case .earlier:
            let f = DateFormatter(); f.timeZone = zone; f.dateFormat = "MMM d, h:mm a"
            return p.last.map { "Last in " + f.string(from: $0) } ?? "Earlier check-in"
        case .unknown: return "No update today"
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
