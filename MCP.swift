import AppKit
import Foundation

@MainActor enum RemoteMCP {
    static let version = "2025-06-18"
    static let instructions = """
    When the user gives you a substantial task with work a human teammate could take on, ask whether they want to delegate part of it. If they agree, call list_team to check self-reported availability. Suggest checked-in teammates, and let the user choose the recipient. Draft the handoff with the goal, deliverable, and deadline if known. Show the draft before sharing it. Use the teammate’s Discord link only for navigation. Verify the recipient in Discord and send only after the user explicitly approves that recipient and exact message, using an authorized Discord interface. If you cannot send from the client, provide the draft and the link.
    """
    static let tools: [[String: Any]] = [[
        "name": "list_team",
        "description": "Use once for who is active, on break, or out, or to find an available teammate for delegation. No arguments. Returns a summary, status counts, and the full roster with Discord navigation links. Available teammates are checked in.",
        "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        "annotations": ["readOnlyHint": true, "openWorldHint": true]
    ]]

    static func run() async {
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
                                      "serverInfo": ["name": "remote-team", "version": "1.1.1"], "instructions": instructions] as [String: Any]
            case "ping":
                response["result"] = [:] as [String: Any]
            case "tools/list":
                response["result"] = ["tools": tools]
            case "tools/call":
                if params["name"] as? String == "list_team" {
                    do {
                        let roster = try await listTeam()
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

    static func content(_ value: String, error: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": value]], "isError": error]
    }

    static func emit(_ value: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return }
        FileHandle.standardOutput.write(bytes + Data([10]))
    }

    private struct Snapshot {
        let channel: Channel
        let since: Date
        let fetchedAt: Date
        let posts: [Post]
    }

    private static var snapshot: Snapshot?
    private static let reuseInterval: TimeInterval = 5
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    static func listTeam() async throws -> [String: Any] {
        let prefs = UserDefaults.standard
        guard let channel = Channel(prefs.string(forKey: "channel") ?? defaultChannel) else {
            throw Problem("Set your Discord channel in Remote Team Settings.")
        }
        let zone = TimeZone(identifier: prefs.string(forKey: "zone") ?? defaultZone) ?? .current
        let rules = Rules(now: Date(), zone: zone)
        let current: Snapshot
        if let cached = snapshot, cached.channel == channel,
           cached.since == rules.since, Date().timeIntervalSince(cached.fetchedAt) < reuseInterval {
            current = cached
        } else {
            let token = try Keychain.read()
            guard !token.isEmpty else { throw Problem("Connect Discord in Remote Team Settings first.") }
            let api = Discord(token: token, channel: channel, session: session)
            let first = try await api.page()
            let fetchedAt = Date()
            guard !first.isEmpty else { throw Problem("The channel has no readable history. Check Discord permissions or post a check-in.") }
            let history = try await api.history(first: first, since: rules.since)
            guard history.contains(where: { !$0.content.isEmpty }) else {
                throw Problem("No readable text. Check Message Content Intent.")
            }
            current = Snapshot(channel: channel, since: rules.since,
                               fetchedAt: fetchedAt, posts: history)
            snapshot = current
        }

        let now = Date()
        let people = roster(posts: current.posts, members: [], rules: Rules(now: now, zone: zone)).map { person -> [String: String] in
            var result = ["name": person.user.name, "discord_user_id": person.id, "status": person.status.title]
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
        let available = people.filter { $0["status"] == Status.inside.title }
        let onBreak = people.filter { $0["status"] == Status.onBreak.title }
        let counts = Dictionary(grouping: people, by: { $0["status"] ?? "" }).mapValues { $0.count }
        let summary = "\(available.count) checked in, \(onBreak.count) on break, \(counts[Status.outside.title, default: 0]) checked out."
        return [
            "summary": summary, "as_of": plainDate.string(from: now),
            "discord_fetched_at": plainDate.string(from: current.fetchedAt),
            "time_zone": zone.identifier, "status_counts": counts,
            "available": available.compactMap { $0["name"] },
            "on_break": onBreak.compactMap { $0["name"] }, "teammates": people
        ]
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
