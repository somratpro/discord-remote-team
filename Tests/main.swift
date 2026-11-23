import Foundation

func check(_ value: @autoclosure () -> Bool, _ name: String) {
    guard value() else { fatalError(name) }
    print("PASS " + name)
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
