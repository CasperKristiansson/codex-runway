import Foundation

struct AnalyticsUpdate {
    var messages: [AnalyticsMessageDay]?
    var usage: [AnalyticsUsageDay]?
    var plugins: [AnalyticsToolDay]?
    var skills: [AnalyticsToolDay]?
    var reviews: [AnalyticsRawDay]?
    var plan: AnalyticsPlanHistory?
    var creditEvents: [AnalyticsJSON]?
    var chats: [AnalyticsChat]?
    var dataFreshnessTimestamp: String?
    var errors: [String] = []

    var succeeded: Bool {
        messages != nil || usage != nil || plugins != nil || skills != nil || reviews != nil || plan != nil || creditEvents != nil || chats != nil
    }
}

enum AnalyticsClientError: LocalizedError {
    case noChatGPTSession
    case accountChanged
    case server(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noChatGPTSession: "Codex Analytics needs the signed-in ChatGPT account."
        case .accountChanged: "The signed-in account changed while Analytics was refreshing."
        case .server(let status): "Codex Analytics returned HTTP \(status)."
        case .invalidResponse: "Codex Analytics returned an unexpected response."
        }
    }
}

/// Reads the same first-party Analytics routes as the installed Codex app.
/// Credentials are read for each sync and never written to the local archive.
@MainActor
final class AnalyticsClient {
    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let accountId: String
        }
        let tokens: Tokens?
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private let authFile: URL

    init(authFile: URL? = nil, session: URLSession? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.authFile = authFile ?? home.appendingPathComponent("auth.json")
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func fetch(accountID: String, initial: Bool, threads: [AnalyticsThreadSummary] = [], now: Date = .now) async throws -> AnalyticsUpdate {
        let auth = try credentials()
        guard auth.accountId == accountID else { throw AnalyticsClientError.accountChanged }
        let calendar = ProfileCalendar.calendar
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: initial ? -364 : -29, to: today)!
        let startDate = ProfileCalendar.key(start)
        let endDate = ProfileCalendar.key(today)
        let middleDate = ProfileCalendar.key(calendar.date(byAdding: .day, value: -181, to: today)!)
        let firstEnd = ProfileCalendar.key(calendar.date(byAdding: .day, value: -182, to: today)!)
        let windows = initial ? [(startDate, firstEnd), (middleDate, endDate)] : [(startDate, endDate)]
        let common = ["group_by": "day", "workspace_user": "true"]
        var update = AnalyticsUpdate()

        do {
            let response: AnalyticsEnvelope<AnalyticsMessageDay> = try await getRows(
                "analytics/daily-workspace-usage-counts", windows: windows, options: common, auth: auth)
            update.messages = response.data
        } catch { update.errors.append("Messages: \(error.localizedDescription)") }
        do {
            let response: AnalyticsEnvelope<AnalyticsUsageDay> = try await getRows(
                "usage/daily-token-usage-breakdown", windows: windows, options: ["group_by": "day"], auth: auth)
            update.usage = response.data
        } catch { update.errors.append("Usage history: \(error.localizedDescription)") }
        do {
            let response: AnalyticsEnvelope<AnalyticsToolDay> = try await getRows(
                "analytics/daily-plugin-usage-metrics", windows: windows,
                options: common.merging(["top_plugin_limit": "100"]) { _, new in new }, auth: auth)
            update.plugins = response.data
            update.dataFreshnessTimestamp = response.dataFreshnessTs
        } catch { update.errors.append("Plugins: \(error.localizedDescription)") }
        do {
            let response: AnalyticsEnvelope<AnalyticsToolDay> = try await getRows(
                "analytics/daily-skill-usage-metrics", windows: windows,
                options: common.merging(["top_skill_limit": "100"]) { _, new in new }, auth: auth)
            update.skills = response.data
            update.dataFreshnessTimestamp = response.dataFreshnessTs ?? update.dataFreshnessTimestamp
        } catch { update.errors.append("Skills: \(error.localizedDescription)") }
        do {
            let response: AnalyticsEnvelope<AnalyticsJSON> = try await getRows(
                "analytics/daily-code-review-metrics", windows: windows, options: common, auth: auth)
            update.reviews = response.data.compactMap { row in
                guard let object = row.object, let date = object["date"]?.string else { return nil }
                return AnalyticsRawDay(date: date, payload: row)
            }
        } catch { update.errors.append("Code reviews: \(error.localizedDescription)") }
        do {
            update.plan = try await get("usage/plan_limit_history", query: ["days": "30"], auth: auth)
        } catch { update.errors.append("Plan history: \(error.localizedDescription)") }
        do {
            let response: AnalyticsEnvelope<AnalyticsJSON> = try await get("usage/credit-usage-events", auth: auth)
            update.creditEvents = response.data
        } catch { update.errors.append("Credit events: \(error.localizedDescription)") }
        if !threads.isEmpty {
            do { update.chats = try await fetchChats(threads: threads, auth: auth) }
            catch { update.errors.append("Top chats: \(error.localizedDescription)") }
        }

        guard update.succeeded else { throw AnalyticsClientError.invalidResponse }
        guard try credentials().accountId == accountID else { throw AnalyticsClientError.accountChanged }
        return update
    }

    private func credentials() throws -> AuthFile.Tokens {
        guard let file = try? Data(contentsOf: authFile),
              let tokens = try? decoder.decode(AuthFile.self, from: file).tokens,
              !tokens.accessToken.isEmpty, !tokens.accountId.isEmpty
        else { throw AnalyticsClientError.noChatGPTSession }
        return tokens
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], auth: AuthFile.Tokens) async throws -> T {
        var components = URLComponents(string: "https://chatgpt.com/backend-api/wham/\(path)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnalyticsClientError.invalidResponse }
        guard http.statusCode == 200 else { throw AnalyticsClientError.server(http.statusCode) }
        return try decoder.decode(T.self, from: data)
    }

    private func getRows<Row: Decodable>(_ path: String, windows: [(String, String)],
                                          options: [String: String], auth: AuthFile.Tokens) async throws -> AnalyticsEnvelope<Row> {
        var all: [Row] = []
        var freshness: String?
        for (start, end) in windows {
            var query = options
            query["start_date"] = start
            query["end_date"] = end
            let response: AnalyticsEnvelope<Row> = try await get(path, query: query, auth: auth)
            all.append(contentsOf: response.data)
            freshness = response.dataFreshnessTs ?? freshness
        }
        return AnalyticsEnvelope(data: all, dataFreshnessTs: freshness)
    }

    private struct ChatResponse: Decodable { let threads: [AnalyticsChatUsage] }

    private func fetchChats(threads: [AnalyticsThreadSummary], auth: AuthFile.Tokens) async throws -> [AnalyticsChat] {
        let formatter = ISO8601DateFormatter()
        var results: [AnalyticsChat] = []
        let eligible = threads.filter { $0.parentThreadId == nil && $0.bestTimestamp != nil }
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var descendants: [String: [String]] = [:]
        for thread in threads where thread.parentThreadId != nil {
            var current = thread
            var visited: Set<String> = [thread.id]
            while let parentID = current.parentThreadId, let parent = byID[parentID], visited.insert(parentID).inserted {
                current = parent
            }
            if current.parentThreadId == nil {
                descendants[current.id, default: []].append(thread.id)
            }
        }
        for offset in stride(from: 0, to: eligible.count, by: 40) {
            let batch = Array(eligible[offset..<min(offset + 40, eligible.count)])
            let input: [[String: Any]] = batch.map { thread in
                ["thread_id": thread.id,
                 "created_at": formatter.string(from: Date(timeIntervalSince1970: thread.bestTimestamp!)),
                 "descendant_thread_ids": descendants[thread.id] ?? []]
            }
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage/thread_usage/query_v2")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["threads": input])
            request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
            request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AnalyticsClientError.invalidResponse }
            guard http.statusCode == 200 else { throw AnalyticsClientError.server(http.statusCode) }
            let rows = try decoder.decode(ChatResponse.self, from: data).threads
            let metadata = Dictionary(batch.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for row in rows where row.dataStatus != "unavailable" {
                guard let thread = metadata[row.threadId] else { continue }
                results.append(AnalyticsChat(threadID: row.threadId,
                    title: thread.name?.isEmpty == false ? thread.name! : String((thread.preview ?? "Untitled task").prefix(90)),
                    createdAt: Date(timeIntervalSince1970: thread.bestTimestamp!),
                    updatedAt: thread.updatedAt.map { Date(timeIntervalSince1970: $0) },
                    weeklyLimitPercent: row.weeklyLimitPercent,
                    fiveHourLimitPercent: row.fiveHourLimitPercent,
                    balanceUsageCredits: row.balanceUsageCredits,
                    dataStatus: row.dataStatus, groups: row.groups))
            }
        }
        return results
    }

    private static var desktopUserAgent: String {
        let info = NSDictionary(contentsOfFile: "/Applications/ChatGPT.app/Contents/Info.plist")
        let version = info?["CFBundleShortVersionString"] as? String ?? "26"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        return "Codex Desktop/\(version) (Mac OS; \(architecture))"
    }
}
