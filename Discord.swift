import Foundation
import Security

let defaultChannel = ""
let defaultZone = "Asia/Dhaka"

struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func isID(_ s: String) -> Bool {
    (15...20).contains(s.count) && s.utf8.allSatisfy { (48...57).contains($0) } && UInt64(s) != nil
}

func linkParts(_ raw: String) -> [String]? {
    guard let u = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          u.scheme == "https", u.host?.lowercased() == "discord.com", u.user == nil,
          u.password == nil, u.port == nil else { return nil }
    return u.path.split(separator: "/").map(String.init)
}

struct Channel: Equatable {
    let guild: String
    let id: String
    init?(_ raw: String) {
        guard let p = linkParts(raw), p.count == 3, p[0] == "channels", isID(p[1]), isID(p[2]) else { return nil }
        guild = p[1]; id = p[2]
    }
    var url: URL { URL(string: "https://discord.com/channels/" + guild + "/" + id)! }
    func messageURL(_ messageID: String) -> URL? {
        guard isID(messageID) else { return nil }
        return URL(string: "https://discord.com/channels/" + guild + "/" + id + "/" + messageID)
    }
}

func dmURL(_ raw: String) -> URL? {
    guard let p = linkParts(raw), (p.count == 3 || p.count == 4), p[0] == "channels",
          p[1] == "@me", isID(p[2]), p.count == 3 || isID(p[3]) else { return nil }
    return URL(string: "https://discord.com/channels/@me/" + p[2])
}

func candidateDM(_ userID: String) -> URL? {
    guard isID(userID) else { return nil }
    return URL(string: "https://discord.com/channels/@me/" + userID)
}

func profileURL(_ userID: String, desktop: Bool) -> URL? {
    guard isID(userID) else { return nil }
    return URL(string: (desktop ? "discord://-/users/" : "https://discord.com/users/") + userID)
}

struct User: Codable, Equatable {
    let id: String
    let username: String
    var global_name: String? = nil
    var avatar: String? = nil
    var bot: Bool? = nil
    var name: String { global_name ?? username }
}
struct Post: Codable, Equatable {
    let id: String
    let author: User
    let content: String
    let timestamp: String
    var mentions: [User] = []
    var webhook_id: String? = nil
    var type: Int = 0
}

enum Status: Int, CaseIterable {
    case inside, onBreak, outside, earlier, unknown
    var title: String { ["Checked in", "On break", "Checked out", "Last in before today", "No update today"][rawValue] }
}
let rosterRetention: TimeInterval = 7 * 24 * 60 * 60
let shiftLimit: TimeInterval = 9 * 60 * 60

struct Person: Identifiable {
    var user: User
    var id: String { user.id }
    var status = Status.unknown
    var lastCheckIn: Date?
    var firstIn: Date?
    var last: Date?
    var autoCheckedOut = false
    var workUpdate: WorkUpdate?

    var checkoutDeadline: Date? {
        guard status == .inside || status == .onBreak else { return nil }
        return firstIn?.addingTimeInterval(shiftLimit)
    }
}
struct Rules {
    let now: Date
    let today: Date
    let since: Date
    init(now: Date, zone: TimeZone) {
        self.now = now
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        today = c.startOfDay(for: now)
        since = now.addingTimeInterval(-rosterRetention)
    }
}
let fractionalDate: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let plainDate = ISO8601DateFormatter()
func postDate(_ post: Post) -> Date? {
    fractionalDate.date(from: post.timestamp) ?? plainDate.date(from: post.timestamp)
}
enum AttendanceCommand: String {
    case `in`, out, `break`, back

    init?(_ text: String) {
        self.init(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct WorkUpdate {
    let text: String
    let date: Date
    let url: URL
}

func rosterWithUpdates(posts: [Post], updates: [Post], channel: Channel, rules: Rules) -> [Person] {
    var latest = [String: (post: Post, date: Date, id: UInt64)]()
    for post in updates {
        guard post.author.bot != true, post.webhook_id == nil, [0, 19].contains(post.type),
              AttendanceCommand(post.content) == nil, let date = postDate(post), date >= rules.today,
              !post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let id = UInt64(post.id), id > (latest[post.author.id]?.id ?? 0) else { continue }
        latest[post.author.id] = (post, date, id)
    }
    return roster(posts: posts, members: latest.values.map { $0.post.author }, rules: rules).map { person in
        guard let update = latest[person.id], let url = channel.messageURL(update.post.id) else { return person }
        var person = person
        person.workUpdate = WorkUpdate(text: update.post.content, date: update.date, url: url)
        return person
    }
}

func roster(posts: [Post], members: [User], rules: Rules) -> [Person] {
    var people = [String: Person]()
    for user in members where user.bot != true { people[user.id] = Person(user: user) }
    for post in posts.sorted(by: { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }) {
        guard post.author.bot != true, post.webhook_id == nil, [0,19].contains(post.type),
              let date = postDate(post), date > rules.since else { continue }
        guard let command = AttendanceCommand(post.content) else { continue }
        var person = people[post.author.id] ?? Person(user: post.author)
        person.user = post.author
        let today = date >= rules.today
        switch command {
        case .in:
            person.lastCheckIn = date
            person.status = today ? .inside : .earlier
            if today && person.firstIn == nil { person.firstIn = date }
        case .out:
            guard person.lastCheckIn != nil else { continue }
            person.status = today ? .outside : .unknown
        case .break:
            guard today && person.status == .inside else { continue }
            person.status = .onBreak
        case .back:
            guard today && person.status == .onBreak else { continue }
            person.status = .inside
        }
        person.last = date
        people[person.id] = person
    }
    return people.values.map { person in
        guard let deadline = person.checkoutDeadline, deadline <= rules.now else { return person }
        var expired = person
        expired.status = .outside
        expired.last = deadline
        expired.autoCheckedOut = true
        return expired
    }.sorted {
        if $0.status != $1.status { return $0.status.rawValue < $1.status.rawValue }
        let order = $0.user.name.localizedCaseInsensitiveCompare($1.user.name)
        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
}

enum Keychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "TeamCheckin.Discord",
         kSecAttrAccount as String: "bot"]
    }
    static func read() throws -> String {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8)
        else { throw Problem("Keychain could not read the bot token (\(status)).") }
        return value
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let q = query
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Problem("Keychain could not save the bot token (\(status)).") }
    }
}

struct RateLimit: Error { let seconds: TimeInterval }
struct Discord {
    private struct Limit: Decodable { let retry_after: Double }
    let token: String
    let channel: Channel
    var session: URLSession = .shared
    func get<T: Decodable>(_ suffix: String, as: T.Type) async throws -> T {
        let url = URL(string: "https://discord.com/api/v10" + suffix)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bot " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        switch status {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 401: throw Problem("Discord rejected the bot token. Replace it in Settings.")
        case 403: throw Problem("Access denied. Grant the bot View Channel and Read Message History in the check-in channel.")
        case 404: throw Problem("Channel or roster message unavailable. Check the links and the bot’s channel access.")
        case 429:
            let seconds = (try? JSONDecoder().decode(Limit.self, from: data).retry_after) ?? 60
            throw RateLimit(seconds: max(1, seconds))
        default: throw Problem("Discord returned HTTP \(status ?? 0). Retrying automatically.")
        }
    }
    func page(before id: String? = nil) async throws -> [Post] {
        try await get("/channels/\(channel.id)/messages?limit=100" + (id.map { "&before=" + $0 } ?? ""), as: [Post].self)
    }
    func history(first: [Post], since: Date) async throws -> [Post] {
        var result = first
        var page = first
        while page.count == 100, let oldest = page.last, let date = postDate(oldest), date >= since {
            try Task.checkCancellation()
            let next = try await self.page(before: oldest.id)
            guard next.last?.id != oldest.id else { throw Problem("Discord history did not advance. Retrying.") }
            result.append(contentsOf: next)
            page = next
        }
        return result
    }
}

struct MessageWindow {
    let posts: [Post]
    let rebuilt: Bool
}

extension Discord {
    func window(previous: [Post], since: Date, rebuild: Bool) async throws -> MessageWindow {
        let first = try await page()
        let oldest = first.last.flatMap { UInt64($0.id) } ?? 0
        let newestCached = previous.first.flatMap { UInt64($0.id) }
        let gap = first.count == 100 && (newestCached.map { oldest > $0 } ?? true)
        let reconcile = rebuild || gap
        let posts: [Post]
        if reconcile {
            posts = try await history(first: first, since: since)
        } else if first.count < 100 {
            posts = first
        } else {
            posts = first + previous.filter { (UInt64($0.id) ?? 0) < oldest }
        }
        return MessageWindow(posts: posts.filter { postDate($0).map { $0 >= since } ?? false }, rebuilt: reconcile)
    }
}
