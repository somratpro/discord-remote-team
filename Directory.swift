import Foundation

struct GuildRole: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let managed: Bool

    var canSuggestTitle: Bool {
        let accessLabels: Set<String> = [
            "admin", "administrator", "mod", "moderator", "member", "staff", "owner",
            "bot", "red", "green", "blue", "yellow", "orange", "purple", "pink", "black", "white"
        ]
        return !managed && !name.hasPrefix("@") && !accessLabels.contains(name.lowercased())
    }
}

struct GuildMember: Decodable {
    let roles: [String]
}

extension Discord {
    func guildRoles() async throws -> [GuildRole] {
        try await get("/guilds/\(channel.guild)/roles", as: [GuildRole].self)
    }

    func guildMember(_ id: String) async throws -> GuildMember {
        guard isID(id) else { throw Problem("Invalid Discord user ID.") }
        return try await get("/guilds/\(channel.guild)/members/\(id)", as: GuildMember.self)
    }
}

struct TeamProfile: Codable, Equatable {
    var title = ""
    var skills: [String] = []
    var owns: [String] = []
    var backsUp: [String] = []
    var preferredRole: String?
}

struct Capacity: Codable, Equatable {
    var focused: Bool
    var expires: Date
}

struct TeamDirectory: Codable, Equatable {
    static let defaultTitles = "Admin Officer, SEO Analyst, Developer, Dev Team Lead, Marketer, Designer, Project Manager, Software Engineer, Copywriter"
    var recognizedTitles = defaultTitles
    var approved: [String: String] = [:]
    var people: [String: TeamProfile] = [:]

    static func load(_ guild: String, prefs: UserDefaults = .standard) -> Self {
        guard let data = prefs.data(forKey: "directory." + guild),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(_ guild: String, prefs: UserDefaults = .standard) throws {
        prefs.set(try JSONEncoder().encode(self), forKey: "directory." + guild)
    }

    static func capacity(_ guild: String, prefs: UserDefaults = .standard) -> [String: Capacity] {
        guard let data = prefs.data(forKey: "capacity." + guild) else { return [:] }
        return (try? JSONDecoder().decode([String: Capacity].self, from: data)) ?? [:]
    }

    static func saveCapacity(_ value: [String: Capacity], guild: String, prefs: UserDefaults = .standard) throws {
        prefs.set(try JSONEncoder().encode(value), forKey: "capacity." + guild)
    }

    func resolve(_ id: String, evidence: RoleEvidence) -> ResolvedProfile {
        let profile = people[id] ?? TeamProfile()
        let candidates = Set((evidence.members[id] ?? []).compactMap { roleID -> String? in
            guard let role = evidence.roles[roleID], approved[roleID] == role.name else { return nil }
            return role.name
        }).sorted()
        if !profile.title.isEmpty { return ResolvedProfile(profile: profile, role: profile.title, source: "operator", candidates: []) }
        let preferred = profile.preferredRole.flatMap { candidates.contains($0) ? $0 : nil }
        let role = preferred ?? (candidates.count == 1 ? candidates.first : nil)
        return ResolvedProfile(profile: profile, role: role,
                               source: role == nil ? "unknown" : "discord_role", candidates: candidates)
    }
}

struct ResolvedProfile {
    let profile: TeamProfile
    let role: String?
    let source: String
    let candidates: [String]
}

struct RoleEvidence: Equatable {
    var roles: [String: GuildRole] = [:]
    var members: [String: [String]] = [:]
    var incomplete = false
}

struct DirectoryTransfer: Codable {
    let guild: String
    let approved: [String: String]
    let people: [String: TeamProfile]

    init(guild: String, directory: TeamDirectory) {
        self.guild = guild
        approved = directory.approved
        people = directory.people
    }

    func changes(for guild: String, current: TeamDirectory) throws -> (additions: Int, conflicts: Int) {
        guard self.guild == guild else { throw Problem("This directory belongs to a different Discord server.") }
        guard approved.keys.allSatisfy(isID), people.keys.allSatisfy(isID) else {
            throw Problem("The directory contains an invalid Discord ID.")
        }
        let additions = approved.keys.filter { current.approved[$0] == nil }.count
            + people.keys.filter { current.people[$0] == nil }.count
        let roleConflicts = approved.filter { id, title in current.approved[id].map { $0 != title } ?? false }.count
        let personConflicts = people.filter { id, profile in current.people[id].map { $0 != profile } ?? false }.count
        return (additions, roleConflicts + personConflicts)
    }

    func applying(to current: TeamDirectory, replaceConflicts: Bool) -> TeamDirectory {
        var result = current
        result.approved.merge(approved) { replaceConflicts ? $1 : $0 }
        result.people.merge(people) { replaceConflicts ? $1 : $0 }
        return result
    }
}

// One credential and guild per cache. Each request is awaited before starting another.
@MainActor final class RoleDiscovery {
    private var scope: String?
    private var credential: String?
    private var evidence = RoleEvidence()
    private var rolesUntil = Date.distantPast
    private var membersUntil: [String: Date] = [:]
    private var retryAt = Date.distantPast
    private let lifetime: TimeInterval = 300

    func load(_ api: Discord, ids: [String], clock: () -> Date = Date.init) async -> RoleEvidence {
        let now = clock()
        if scope != api.channel.guild || credential != api.token {
            scope = api.channel.guild
            credential = api.token
            evidence = RoleEvidence()
            rolesUntil = .distantPast
            membersUntil = [:]
            retryAt = .distantPast
        }
        evidence.incomplete = false
        if now >= rolesUntil {
            evidence.roles = [:]
            if clock() >= retryAt {
                do {
                    let roles = try await api.guildRoles()
                    evidence.roles = Dictionary(roles.filter {
                        $0.id != api.channel.guild && $0.canSuggestTitle
                    }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    rolesUntil = clock().addingTimeInterval(lifetime)
                } catch {
                    pause(error, now: clock())
                }
            }
        }
        guard now < rolesUntil, !evidence.roles.isEmpty else {
            evidence.incomplete = now >= rolesUntil
            return evidence
        }
        for id in Set(ids).sorted() where now >= (membersUntil[id] ?? .distantPast) {
            evidence.members[id] = nil
            guard clock() >= retryAt, !Task.isCancelled else { continue }
            do {
                evidence.members[id] = try await api.guildMember(id).roles
                membersUntil[id] = clock().addingTimeInterval(lifetime)
            } catch {
                if error is RateLimit { pause(error, now: clock()) }
                membersUntil[id] = clock().addingTimeInterval(60)
            }
        }
        evidence.incomplete = ids.contains { evidence.members[$0] == nil }
        return evidence
    }

    private func pause(_ error: Error, now: Date) {
        let delay = (error as? RateLimit)?.seconds ?? 60
        retryAt = now.addingTimeInterval(delay)
    }
}

@MainActor final class DiscordBackoff {
    private let clock: () -> Date
    private var retryAt = Date.distantPast

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    func fetch<T>(_ operation: () async throws -> T) async throws -> T {
        let remaining = retryAt.timeIntervalSince(clock())
        if remaining > 0 { throw RateLimit(seconds: remaining) }
        do {
            return try await operation()
        } catch let limit as RateLimit {
            retryAt = clock().addingTimeInterval(limit.seconds)
            throw limit
        }
    }
}
