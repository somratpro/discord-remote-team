import AppKit
import Foundation

@MainActor enum RemoteMCP {
    static let version = "2025-06-18"
    static let instructions = """
    Ask whether the operator wants to delegate a substantial task. If they agree, call list_team once with {}. Clarify the deliverable if it is unclear. Start with checked-in people, then match the required skills and role. Quote the relevant skill in your reason. Prefer a qualified checked-in project owner, then a qualified checked-in backup, and explain a substitution. Offer equally qualified people together. If no checked-in person has the required skill or a suitable backup is missing, explain the gap and let the operator decide. Attendance alone does not confirm capacity. Respect a recorded focus period and confirm capacity with the teammate. Identify the chosen recipient by Discord user ID when names collide. Draft the goal, deliverable, completion criteria and any supplied deadline. Get explicit approval for the exact recipient and message before sending through an independently authorized interface. A Discord link opens navigation only. Keep the profile fallback available. Report delivery only after confirmed sending.
    """
    static let tools: [[String: Any]] = [[
        "name": "list_team",
        "description": "Use once for who is active, on break, or out, or to find an available teammate for delegation. No arguments. Returns a summary, status counts, and the full attendance roster with roles, skills, ownership, capacity and Discord navigation links. Available teammates are checked in.",
        "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        "annotations": ["readOnlyHint": true, "openWorldHint": true]
    ]]

    static func run() async {
        await run(list: { try await live.listTeam() })
    }

    static func run(list: () async throws -> [String: Any]) async {
        while let line = readLine() {
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                emit(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]])
                continue
            }
            guard let id = request["id"] else { continue }
            let params = request["params"] as? [String: Any] ?? [:]
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch method {
            case "initialize":
                response["result"] = ["protocolVersion": version, "capabilities": ["tools": [:]],
                                      "serverInfo": ["name": "remote-team", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"], "instructions": instructions] as [String: Any]
            case "ping":
                response["result"] = [:] as [String: Any]
            case "tools/list":
                response["result"] = ["tools": tools]
            case "tools/call":
                if !validArguments(params["arguments"]) {
                    response["error"] = ["code": -32602, "message": "list_team accepts an empty argument object or omitted arguments."]
                } else if params["name"] as? String == "list_team" {
                    do {
                        let roster = try await list()
                        let data = try JSONSerialization.data(withJSONObject: roster, options: [.sortedKeys, .withoutEscapingSlashes])
                        var result = content(String(decoding: data, as: UTF8.self), error: false)
                        result["structuredContent"] = roster
                        response["result"] = result
                    } catch let limit as RateLimit {
                        response["result"] = content("Discord rate-limited the request. Retry after \(Int(limit.seconds.rounded(.up))) seconds.", error: true)
                    } catch {
                        response["result"] = content(error.localizedDescription, error: true)
                    }
                } else {
                    response["error"] = ["code": -32602, "message": "Unknown tool"]
                }
            default:
                response["error"] = ["code": -32601, "message": "Method not found"]
            }
            emit(response)
        }
    }

    static func validArguments(_ value: Any?) -> Bool {
        guard let value else { return true }
        return (value as? [String: Any])?.isEmpty == true
    }

    static func content(_ value: String, error: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": value]], "isError": error]
    }

    static func emit(_ value: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return }
        FileHandle.standardOutput.write(bytes + Data([10]))
    }

    private static let live: MCPRoster = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        return MCPRoster(session: URLSession(configuration: config), credential: Keychain.read)
    }()

    static func render(posts: [Post], fetchedAt: Date, now: Date, zone: TimeZone,
                       directory: TeamDirectory, capacity: [String: Capacity],
                       evidence: RoleEvidence, prefs: UserDefaults) -> [String: Any] {
        let people = roster(posts: posts, members: [], rules: Rules(now: now, zone: zone)).map { person -> [String: Any] in
            let profile = directory.resolve(person.id, evidence: evidence)
            var result: [String: Any] = [
                "name": person.user.name, "discord_user_id": person.id, "status": person.status.title,
                "role": profile.role as Any? ?? NSNull(), "role_source": profile.source,
                "skills": profile.profile.skills, "owns": profile.profile.owns, "backs_up": profile.profile.backsUp
            ]
            if !profile.candidates.isEmpty && profile.role == nil { result["role_candidates"] = profile.candidates }
            if let value = capacity[person.id], value.expires > now {
                result["capacity"] = ["status": value.focused ? "focused" : "taking_tasks",
                                      "expires_at": plainDate.string(from: value.expires), "source": "operator"]
            } else { result["capacity"] = NSNull() }
            if let first = person.firstIn { result["first_in"] = plainDate.string(from: first) }
            if let last = person.last { result["status_since"] = plainDate.string(from: last) }
            if person.autoCheckedOut { result["checkout"] = "automatic" }
            if let saved = dmURL(prefs.string(forKey: "dm." + person.id) ?? "") {
                result["discord_dm_url"] = saved.absoluteString
            } else {
                result["discord_dm_candidate_url"] = candidateDM(person.id)?.absoluteString
            }
            result["discord_profile_url"] = profileURL(person.id, desktop: false)?.absoluteString
            result["discord_desktop_profile_url"] = profileURL(person.id, desktop: true)?.absoluteString
            return result
        }
        let available = people.filter { $0["status"] as? String == Status.inside.title }
        let onBreak = people.filter { $0["status"] as? String == Status.onBreak.title }
        let counts = Dictionary(grouping: people, by: { $0["status"] as? String ?? "" }).mapValues { $0.count }
        let summary = "\(available.count) checked in, \(onBreak.count) on break, \(counts[Status.outside.title, default: 0]) checked out."
        return [
            "summary": summary, "as_of": plainDate.string(from: now),
            "discord_fetched_at": plainDate.string(from: fetchedAt),
            "time_zone": zone.identifier, "status_counts": counts,
            "available": available.compactMap { $0["name"] as? String },
            "on_break": onBreak.compactMap { $0["name"] as? String }, "teammates": people
        ]
    }


}

@MainActor final class MCPRoster {
    private struct Snapshot {
        let channel: Channel
        let token: String
        let teamDay: Date
        let fetchedAt: Date
        let posts: [Post]
    }

    private let discovery = RoleDiscovery()
    private let backoff: DiscordBackoff
    private var snapshot: Snapshot?
    private let reuseInterval: TimeInterval = 5
    private let prefs: UserDefaults
    private let session: URLSession
    private let credential: () throws -> String
    private let clock: () -> Date

    init(prefs: UserDefaults = .standard, session: URLSession, credential: @escaping () throws -> String,
         clock: @escaping () -> Date = Date.init) {
        self.prefs = prefs
        self.session = session
        self.credential = credential
        self.clock = clock
        backoff = DiscordBackoff(clock: clock)
    }

    func listTeam() async throws -> [String: Any] {
        guard let channel = Channel(prefs.string(forKey: "channel") ?? defaultChannel) else {
            throw Problem("Set your Discord channel in Remote Team Settings.")
        }
        let zone = TimeZone(identifier: prefs.string(forKey: "zone") ?? defaultZone) ?? .current
        let rules = Rules(now: clock(), zone: zone)
        let token = try credential()
        guard !token.isEmpty else { throw Problem("Connect Discord in Remote Team Settings first.") }
        let api = Discord(token: token, channel: channel, session: session)
        let current: Snapshot
        if let cached = snapshot, cached.channel == channel, cached.token == token,
           cached.teamDay == rules.today, clock().timeIntervalSince(cached.fetchedAt) < reuseInterval {
            current = cached
        } else {
            let history = try await backoff.fetch {
                let first = try await api.page()
                guard !first.isEmpty else { throw Problem("The channel has no readable history. Check Discord permissions or post a check-in.") }
                let posts = try await api.history(first: first, since: rules.since)
                guard posts.contains(where: { !$0.content.isEmpty }) else {
                    throw Problem("No readable text. Check Message Content Intent.")
                }
                return posts
            }
            let fetchedAt = clock()
            current = Snapshot(channel: channel, token: token, teamDay: rules.today,
                               fetchedAt: fetchedAt, posts: history)
            snapshot = current
        }

        let ids = roster(posts: current.posts, members: [], rules: rules).map(\.id)
        let evidence = await discovery.load(api, ids: ids, clock: clock)
        let now = clock()
        let directory = TeamDirectory.load(channel.guild, prefs: prefs)
        let capacity = TeamDirectory.capacity(channel.guild, prefs: prefs)
        return RemoteMCP.render(posts: current.posts, fetchedAt: current.fetchedAt, now: now, zone: zone,
                      directory: directory, capacity: capacity, evidence: evidence, prefs: prefs)
    }

}

@MainActor func copyMCPPrompt() {
    guard let executable = Bundle.main.executableURL?.path,
          let data = try? JSONSerialization.data(withJSONObject: [
            "mcpServers": ["remote-team": ["command": executable, "args": ["--mcp"]]]
          ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
    let prompt = """
    Configure Remote Team as a local stdio MCP server on this Mac. Adapt this config to your client’s syntax and verify that list_team appears. Remote Team uses its local Keychain connection, so there is no credential to paste here.

    \(String(decoding: data, as: UTF8.self))

    Save this as an ongoing instruction if your client supports it:

    \(RemoteMCP.instructions)
    """
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
    let alert = NSAlert()
    alert.messageText = "AI setup prompt copied"
    alert.informativeText = "Paste it into an AI client that supports local MCP servers on this Mac."
    alert.runModal()
}
