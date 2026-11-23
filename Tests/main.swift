import Foundation

func check(_ value: @autoclosure () -> Bool, _ name: String) {
    guard value() else { fatalError(name) }
    if !CommandLine.arguments.contains("--mcp-test") { print("PASS " + name) }
}
let now = plainDate.date(from: "2026-11-22T02:30:00Z")!
let rules = Rules(now: now, zone: TimeZone(identifier: "Asia/Dhaka")!)
let maya = User(id: "100000000000000001", username: "Maya")
let arif = User(id: "100000000000000002", username: "Arif")
let silent = User(id: "100000000000000003", username: "Silent")
let bot = User(id: "100000000000000004", username: "Robot", bot: true)
func post(_ id: Int, _ who: User, _ word: String, _ time: String) -> Post {
    Post(id: String(id), author: who, content: word, timestamp: time)
}
let input = [
    post(1, arif, "in", "2026-11-21T17:59:59Z"),
    post(2, maya, " IN\n", "2026-11-21T18:00:00Z"),
    post(3, maya, "out", "2026-11-22T01:00:00Z"),
    post(4, maya, "in", "2026-11-22T02:00:00.123456+00:00"),
    post(5, maya, "out of office", "2026-11-22T02:01:00Z"),
    post(6, bot, "in", "2026-11-22T02:02:00Z")
]
let result = roster(posts: input.reversed(), members: [silent], rules: rules)
check(result.count == 3, "Roster merges unique people and excludes bots")
check(result[0].id == maya.id && result[0].status == .inside, "Latest exact status wins after re-entry")
check(result[0].firstIn == rules.today, "First check-in survives later sessions at Dhaka midnight")
check(result[0].last == postDate(input[3]), "Non-command text ignored and fractional timestamp accepted")
check(result[1].status == .earlier && result[2].status == .unknown, "Previous-day and unreported states stay distinct")
let deleted = roster(posts: Array(input.prefix(3)), members: [], rules: rules)
check(deleted.first { $0.id == maya.id }?.status == .outside, "A removed check-in restores the prior out")
var edited = Array(input.prefix(3))
edited[2] = post(3, maya, "in", input[2].timestamp)
check(roster(posts: edited, members: [], rules: rules)[0].status == .inside, "Edited message rebuilds status")
let example = "https://discord.com/channels/100000000000000010/100000000000000011"
let channel = Channel(example)!
check(dmURL("https://discord.com/channels/@me/100000000000000006/100000000000000007")?.absoluteString == "https://discord.com/channels/@me/100000000000000006", "DM message links normalize to the conversation")
check(dmURL(example) == nil && dmURL("https://discord.com.fake/channels/@me/100000000000000006") == nil, "Rejects server and unrelated links")

final class MockDiscord: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, bytes) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [MockDiscord.self]
let api = Discord(token: "test-only", channel: channel, session: URLSession(configuration: config))
let first = (10...109).reversed().map { post($0, maya, "in", "2026-11-22T00:01:00Z") }
MockDiscord.handler = { request in
    check(request.url!.query == "limit=100&before=10", "History paginates using the oldest message ID")
    check(request.value(forHTTPHeaderField: "Authorization") == "Bot test-only", "Uses bot authentication")
    return (200, try! JSONEncoder().encode([post(9, arif, "out", "2026-11-20T00:01:00Z")]))
}
let complete = try await api.history(first: first, since: rules.since)
check(complete.count == 101 && complete.last?.id == "9", "History larger than one page reconstructed")
MockDiscord.handler = { _ in (429, Data("{\"retry_after\":12.5}".utf8)) }
do { _ = try await api.page(); fatalError("Expected rate limit") }
catch let limit as RateLimit { check(limit.seconds == 12.5, "Discord retry interval honored") }
MockDiscord.handler = { _ in (403, Data()) }
do { _ = try await api.page(); fatalError("Expected permissions error") }
catch let p as Problem { check(p.message.contains("Read Message History"), "Actionable missing permission error") }
let events = [
    post(10, maya, "in", "2026-11-22T01:00:00Z"),
    post(11, maya, " BREAK ", "2026-11-22T02:00:00Z"),
    post(12, maya, "back", "2026-11-22T03:00:00Z"),
    post(13, maya, "out", "2026-11-22T04:00:00Z"),
    post(14, maya, "back", "2026-11-22T05:00:00Z")
]
for (index, expected) in [Status.inside, .onBreak, .inside, .outside, .outside].enumerated() {
    let team = roster(posts: Array(events.prefix(index + 1)), members: [], rules: rules)
    check(team.first?.status == expected, "Break transition " + String(index + 1))
    check(team.first?.firstIn == postDate(events[0]), "Break preserves first check-in")
}
check(roster(posts: [events[1], events[2]], members: [], rules: rules).isEmpty, "Break and back cannot create a shift")
check(candidateDM(maya.id)?.absoluteString == "https://discord.com/channels/@me/" + maya.id, "Builds the requested Discord route")
check(candidateDM("100000000000000001/path") == nil, "Rejects invalid identifiers")
let deadline = postDate(events[0])!.addingTimeInterval(9 * 60 * 60)
func rosterAt(_ now: Date, _ posts: [Post]) -> Person {
    roster(posts: posts, members: [], rules: Rules(now: now, zone: TimeZone(identifier: "Asia/Dhaka")!))[0]
}
check(rosterAt(deadline.addingTimeInterval(-1), Array(events.prefix(2))).status == .onBreak, "Still on break just before nine hours")
for count in [1, 2, 3] {
    let person = rosterAt(deadline, Array(events.prefix(count)))
    check(person.status == .outside && person.autoCheckedOut && person.last == deadline, "Auto out at nine hours after first in with \(count) events")
}
let manualOut = rosterAt(deadline, Array(events.prefix(4)))
check(manualOut.status == .outside && !manualOut.autoCheckedOut && manualOut.last == postDate(events[3]), "Preserves manual checkout timestamp")
let reentry = post(15, maya, "in", "2026-11-22T10:30:00Z")
check(rosterAt(deadline.addingTimeInterval(3600), Array(events.prefix(4)) + [reentry]).last == deadline, "Another in does not restart the first-in cutoff")

let updateChannel = Channel("https://discord.com/channels/100000000000000010/100000000000000012")!
let workMessages = [
    post(100000000000000021, maya, "Testing checkout", "2026-11-22T01:01:00Z"),
    post(100000000000000024, maya, " OUT ", "2026-11-22T02:01:00Z"),
    post(100000000000000023, maya, "Checkout tests passed", "2026-11-22T02:00:00Z"),
    post(100000000000000025, silent, "Draft ready", "2026-11-22T02:02:00Z"),
    post(100000000000000026, bot, "Automated reminder", "2026-11-22T02:03:00Z"),
    post(100000000000000020, arif, "Old update", "2026-11-21T17:00:00Z")
]
let separateRoster = rosterWithUpdates(posts: [events[0]], updates: workMessages, channel: updateChannel, rules: rules)
check(separateRoster.count == 2 && separateRoster[0].status == .inside, "Updates add authors without changing attendance")
check(separateRoster[0].workUpdate?.text == "Checkout tests passed", "Selects latest human update and skips attendance commands")
check(separateRoster[0].workUpdate?.url.absoluteString.hasSuffix("/100000000000000012/100000000000000023") == true, "Links to the original update channel and message")
check(separateRoster[1].id == silent.id && separateRoster[1].status == .unknown, "Update-only author has no attendance update")
let combined = [events[0], workMessages[0]]
check(rosterWithUpdates(posts: combined, updates: combined, channel: channel, rules: rules)[0].workUpdate?.text == "Testing checkout", "Same-channel messages attach to attendance")

let suite = "RemoteTeamTests." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
prefs.set(example, forKey: "channel")
let developer = GuildRole(id: "100000000000000030", name: "Developer", managed: false)
let analyst = GuildRole(id: "100000000000000031", name: "SEO Analyst", managed: false)
let admin = GuildRole(id: "100000000000000032", name: "Admin", managed: false)
let integration = GuildRole(id: "100000000000000033", name: "Dev Team Lead", managed: true)
let everyone = GuildRole(id: channel.guild, name: "@everyone", managed: false)
let duplicate = User(id: arif.id, username: maya.name)
let nadia = User(id: "100000000000000034", username: "Nadia")
let leo = User(id: "100000000000000035", username: "Leo")
let syntheticPosts = [
    post(26, leo, "in", "2026-11-22T02:00:00Z"),
    post(25, nadia, "break", "2026-11-22T02:10:00Z"),
    post(24, nadia, "in", "2026-11-22T02:00:00Z"),
    post(23, duplicate, "in", "2026-11-22T02:00:00Z"),
    post(22, silent, "in", "2026-11-22T02:00:00Z"),
    post(21, maya, "in", "2026-11-22T01:00:00Z")
]
var directory = TeamDirectory()
directory.approved = [developer.id: developer.name]
directory.people = [
    maya.id: TeamProfile(title: ""),
    duplicate.id: TeamProfile(title: ""),
    nadia.id: TeamProfile(title: ""),
    leo.id: TeamProfile(title: "Marketer")
]
try directory.save(channel.guild, prefs: prefs)

var clock = now
var requestPaths = [String]()
var removedRole = false
var inaccessible = false
var onlyPermissions = false
var limitAttendance = false
MockDiscord.handler = { request in
    let path = request.url!.path
    requestPaths.append(path)
    if path.hasSuffix("/messages") {
        if limitAttendance { return (429, Data("{\"retry_after\":12.5}".utf8)) }
        return (200, try! JSONEncoder().encode(syntheticPosts))
    }
    if path.hasSuffix("/roles") {
        if inaccessible { return (403, Data()) }
        let roles = onlyPermissions ? [admin, integration, everyone] :
            (removedRole ? [analyst, admin, integration, everyone] : [developer, analyst, admin, integration, everyone])
        return (200, try! JSONEncoder().encode(roles))
    }
    let id = String(path.split(separator: "/").last!)
    let roles = id == silent.id ? [] : [developer.id, admin.id] + (id == maya.id ? [analyst.id] : [])
    return (200, try! JSONSerialization.data(withJSONObject: ["roles": roles]))
}
let service = MCPRoster(prefs: prefs, session: api.session, credential: { "test-only" }, clock: { clock })
if CommandLine.arguments.contains("--mcp-test") {
    await RemoteMCP.run(list: { try await service.listTeam() })
    exit(0)
}

func rows(_ result: [String: Any]) -> [String: [String: Any]] {
    let teammates = result["teammates"] as! [[String: Any]]
    return Dictionary(uniqueKeysWithValues: teammates.map { ($0["discord_user_id"] as! String, $0) })
}

var response = try await service.listTeam()
var peopleByID = rows(response)
check(peopleByID[maya.id]?["role"] as? String == "Developer"
      && peopleByID[duplicate.id]?["role"] as? String == "Developer", "One approved role resolves for duplicate-name teammates")
check(peopleByID[silent.id]?["role"] is NSNull,
      "Missing profile returns null title")
check(peopleByID[nadia.id]?["status"] as? String == Status.onBreak.title, "On-break specialist stays distinct")
check(requestPaths.filter { $0.hasSuffix("/roles") }.count == 1 &&
      requestPaths.filter { $0.contains("/members/") }.count == 5, "Discovery reads one catalogue and unique targeted members")
let unchangedPaths = requestPaths
directory.approved[analyst.id] = analyst.name
try directory.save(channel.guild, prefs: prefs)
clock = now.addingTimeInterval(2)
response = try await service.listTeam()
peopleByID = rows(response)
check(requestPaths == unchangedPaths && peopleByID[maya.id]?["role"] is NSNull &&
      (peopleByID[maya.id]?["role_candidates"] as? [String]) == ["Developer", "SEO Analyst"], "Cached MCP sees approval edits and reports ambiguity")
check(peopleByID[maya.id]?["capacity"] == nil, "Capacity removed from MCP output")
directory.people[maya.id]?.preferredRole = developer.name
directory.people[duplicate.id]?.title = "Platform Developer"
try directory.save(channel.guild, prefs: prefs)
peopleByID = rows(try await service.listTeam())
check(peopleByID[maya.id]?["role_source"] as? String == "discord_role" &&
      peopleByID[duplicate.id]?["role"] as? String == "Platform Developer",
      "Role choice and explicit override stay isolated by ID")
directory.people[maya.id]?.title = "macOS Lead"
try directory.save(channel.guild, prefs: prefs)
peopleByID = rows(try await service.listTeam())
check(peopleByID[maya.id]?["role_source"] as? String == "operator" &&
      peopleByID[maya.id]?["role"] as? String == "macOS Lead",
      "Title correction updates a running MCP service")
directory.people[maya.id]?.title = ""
try directory.save(channel.guild, prefs: prefs)
check(TeamDirectory.load(channel.guild, prefs: prefs) == directory &&
      TeamDirectory.load("100000000000000090", prefs: prefs) == TeamDirectory(),
      "Clearing an override persists and guilds stay isolated")
removedRole = true
clock = now.addingTimeInterval(301)
peopleByID = rows(try await service.listTeam())
check(peopleByID[maya.id]?["role"] as? String == "SEO Analyst", "Removed Discord role no longer contributes after refresh")
inaccessible = true
clock = now.addingTimeInterval(602)
peopleByID = rows(try await service.listTeam())
check(peopleByID[maya.id]?["role"] is NSNull && peopleByID[duplicate.id]?["role"] as? String == "Platform Developer",
      "Inaccessible roles return unknown while explicit overrides and attendance survive")
inaccessible = false
onlyPermissions = true
clock = now.addingTimeInterval(1000)
peopleByID = rows(try await service.listTeam())
check(peopleByID[maya.id]?["role"] is NSNull && peopleByID[maya.id]?["status"] as? String == Status.inside.title,
      "Permissions-only roles leave attendance usable")
clock = deadline
peopleByID = rows(try await service.listTeam())
check(peopleByID[maya.id]?["checkout"] as? String == "automatic" && peopleByID[maya.id]?["status_since"] as? String == plainDate.string(from: deadline),
      "Enriched MCP still reports auto out and its timestamp")
limitAttendance = true
clock = clock.addingTimeInterval(10)
do { _ = try await service.listTeam(); fatalError("Expected MCP rate limit") }
catch let limit as RateLimit { check(limit.seconds == 12.5, "MCP records Discord backoff") }
let pausedRequests = requestPaths.count
clock = clock.addingTimeInterval(2)
do { _ = try await service.listTeam(); fatalError("Expected remaining MCP rate limit") }
catch let limit as RateLimit { check(limit.seconds == 10.5 && pausedRequests == requestPaths.count, "MCP backoff blocks network and reports remaining delay") }
limitAttendance = false
clock = clock.addingTimeInterval(11)
_ = try await service.listTeam()
check(requestPaths.count > pausedRequests, "MCP can fetch after backoff expires")
check(RemoteMCP.validArguments(nil) && RemoteMCP.validArguments([String: Any]()) &&
      !RemoteMCP.validArguments(["role": "Developer"]) && !RemoteMCP.validArguments(NSNull()),
      "MCP accepts only omitted or empty arguments")

let export = DirectoryTransfer(guild: channel.guild, directory: directory)
let exported = try JSONEncoder().encode(export)
let received = try JSONDecoder().decode(DirectoryTransfer.self, from: exported)
let changes = try received.changes(for: channel.guild, current: TeamDirectory())
check(changes.additions == 6 && changes.conflicts == 0, "Transfer previews additions")
check(received.applying(to: TeamDirectory(), replaceConflicts: false) == directory, "Guild directory round-trips")
var conflicting = directory
conflicting.people[duplicate.id]?.title = "Different title"
let conflicts = try received.changes(for: channel.guild, current: conflicting)
check(conflicts.conflicts == 1 && received.applying(to: conflicting, replaceConflicts: false) == conflicting &&
      received.applying(to: conflicting, replaceConflicts: true) == directory, "Transfer previews and resolves conflicts explicitly")
do { _ = try received.changes(for: updateChannel.id, current: directory); fatalError("Expected guild mismatch") }
catch is Problem { print("PASS Transfer rejects a guild mismatch") }
check(!String(decoding: exported, as: UTF8.self).contains("capacity"), "Transfer excludes temporary capacity")

let busy = (101...350).reversed().map { post($0, maya, "Update \($0)", "2026-11-22T02:01:00Z") }
var windowRequests = 0
var latest = busy
MockDiscord.handler = { request in
    windowRequests += 1
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
    let threshold = query?.first { $0.name == "before" }?.value.flatMap(Int.init) ?? Int.max
    let items = Array(latest.lazy.filter { Int($0.id)! < threshold }.prefix(100))
    return (200, try! JSONEncoder().encode(items))
}
let fullWindow = try await api.window(previous: [], since: rules.today, rebuild: true)
check(fullWindow.posts.count == 250 && windowRequests == 3, "Busy updates day needs three requests for a full rebuild")
latest.remove(at: 2)
latest[0] = post(350, maya, "Edited latest update", latest[0].timestamp)
let rolling = try await api.window(previous: fullWindow.posts, since: rules.today, rebuild: false)
check(windowRequests == 4 && !rolling.rebuilt && rolling.posts.count == 249 &&
      rolling.posts.first?.content == "Edited latest update", "Updates poll uses one request and reflects latest-page edits and deletes")
latest.removeLast()
let reconcile = try await api.window(previous: rolling.posts, since: rules.today, rebuild: true)
check(reconcile.posts.count == 248 && windowRequests == 7, "Full updates reconciliation catches older deletes")
latest = (500...610).reversed().map { post($0, maya, "New update", "2026-11-22T02:01:00Z") }
let gapped = try await api.window(previous: reconcile.posts, since: rules.today, rebuild: false)
check(gapped.rebuilt && gapped.posts.count == 111 && windowRequests == 9, "Updates recover an overlap gap")
let nextDay = rules.today.addingTimeInterval(86_400)
let overnight = try await api.window(previous: gapped.posts, since: nextDay, rebuild: true)
check(overnight.posts.isEmpty, "Midnight excludes the previous team's day")

let retentionBoundary = now.addingTimeInterval(-rosterRetention)
let justBeforeExpiry = post(901, maya, "in", plainDate.string(from: retentionBoundary.addingTimeInterval(1)))
let expiredCheckIn = post(900, arif, "in", plainDate.string(from: retentionBoundary))
let recentCheckout = post(902, arif, "out", plainDate.string(from: now))
let agingPosts = [recentCheckout, expiredCheckIn, justBeforeExpiry]
check(roster(posts: agingPosts, members: [], rules: rules).map(\.id) == [maya.id],
      "Roster keeps check-ins less than seven days old and checkout does not extend retention")
let oneSecondLater = Rules(now: now.addingTimeInterval(1), zone: TimeZone(identifier: "Asia/Dhaka")!)
check(roster(posts: agingPosts, members: [], rules: oneSecondLater).isEmpty,
      "Roster expires a check-in exactly seven days later without a new message")

check(detectDesignation(from: "Building useful things.\nDev Team Lead at Example Studio",
                        recognized: ["Developer", "Lead"]) == "Dev Team Lead",
      "About Me extraction keeps the full designation and leaves out the employer")
check(detectDesignation(from: "I build audio tools.", recognized: ["Designer"]) == nil,
      "Designation aliases match whole words")
