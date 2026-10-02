import Foundation

/// Explicit presentation DTOs only. Never encode auth, recovery records or raw
/// Analytics payloads. Dates are Unix seconds, missing values are JSON null.
@MainActor
enum HubSnapshot {
    static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    static func date(_ value: Date?) -> Any { optional(value?.timeIntervalSince1970) }
    static func safe(_ text: String) -> String {
        // Errors from upstream clients can contain arbitrary server text. These
        // are never transported; this also bounds user-visible labels.
        String(text.prefix(300))
    }
    static func point(_ value: CapacityPoint) -> [String: Any] {
        ["date": value.date.timeIntervalSince1970, "units": value.units, "segment": value.segment]
    }
    static func reset(_ value: CapacityReset) -> [String: Any] {
        ["date": value.date.timeIntervalSince1970, "account": safe(value.accountName),
         "before": value.hasEstimate ? value.before as Any : NSNull(),
         "after": value.hasEstimate ? value.after as Any : NSNull(),
         "kind": value.projected ? "scheduled" : value.assumed ? "assumed" : "observed"]
    }
    static func overview(store: RunwayStore, now: Date) -> [String: Any] {
        let report = CapacityForecast.report(accounts: store.accounts, now: now)
        let range = store.displayPreferences.range
        let start = now.addingTimeInterval(-(range.lookback ?? 2 * CapacityForecast.day))
        let end = range == .overview ? max(now.addingTimeInterval(2 * CapacityForecast.day), (report.resets.filter(\.projected).map(\.date).max() ?? now).addingTimeInterval(0.25 * CapacityForecast.day)) : now
        let preceding = report.history.last { $0.date < start }
        let history = (preceding.map { [$0] } ?? []) + report.history.filter { $0.date >= start && $0.date <= end }
        let tableEnd = CapacityForecast.alignedIntervalEnd(now: now, duration: range.tableInterval)
        let intervals = CapacityForecast.intervals(points: report.history, resets: report.resets,
            start: tableEnd.addingTimeInterval(-(range.lookback ?? 2 * CapacityForecast.day)), end: tableEnd, duration: range.tableInterval)
        return ["total": report.total, "remaining": report.hasBalance ? report.remaining as Any : NSNull(),
            "ratePerDay": optional(report.ratePerHour.map { $0 * 24 }), "averageHistoryHours": optional(report.averageHistoryHours),
            "usesTimeOfDay": report.usesTimeOfDay, "issue": optional(report.issue), "notes": report.notes,
            "stale": report.hasStaleReadings, "assumedResets": report.hasAssumedResets,
            "start": start.timeIntervalSince1970, "end": end.timeIntervalSince1970,
            "history": history.suffix(2500).map(point), "historyTruncated": history.count > 2500,
            "prediction": range == .overview ? (report.projection?.points ?? []).prefix(2500).map(point) : [],
            "resets": report.resets.filter { $0.date >= start && (range == .overview || !$0.projected) }.prefix(512).map(reset),
            "exhaustedAt": date(report.projection?.exhaustedAt), "shortfallUnits": optional(report.projection?.shortfallUnits),
            "shortfallAt": date(report.projection?.shortfallAt),
            "intervals": intervals.reversed().prefix(7).map { row in
                ["start": row.start.timeIntervalSince1970, "end": row.end.timeIntervalSince1970,
                 "used": row.consumedUnits, "balance": row.endUnits, "resets": row.resets.map(reset)] as [String: Any]
            }]
    }
    static func base(store: RunwayStore, now: Date, cachedOverview: [String: Any]? = nil) -> [String: Any] {
        ["version": 1, "available": true, "generatedAt": now.timeIntervalSince1970,
         "currentAccountID": optional(store.activeAccountID?.uuidString),
         "accountCount": store.accounts.count, "accountsTruncated": store.accounts.count > 128,
         "accounts": store.accounts.prefix(128).map { account -> [String: Any] in
            let snapshot = account.latestSnapshot
            return ["id": account.id.uuidString, "name": safe(account.name), "email": safe(account.displayEmail),
                    "plan": safe(account.planName), "enabled": account.isEnabled,
                    "current": account.id == store.activeAccountID,
                    "capacityUnits": optional(account.capacityUnits),
                    "remainingPercent": optional(snapshot?.remainingPercent(at: now)),
                    "observedUsedPercent": optional(snapshot?.usedPercent), "assumedReset": snapshot?.assumesReset(at: now) ?? false,
                    "resetAt": date(snapshot?.nextReset(at: now)), "fetchedAt": date(snapshot?.capturedAt),
                    "stale": snapshot.map { now.timeIntervalSince($0.capturedAt) > 30 * 60 } ?? true,
                    "bankedResets": optional(snapshot?.bankedResetCount),
                    "secondaryUsedPercent": optional(snapshot?.secondaryUsedPercent), "secondaryResetAt": date(snapshot?.secondaryResetAt),
                    "savedLoginID": optional(store.savedLogin(for: account)?.id),
                    "canRefresh": account.id == store.activeAccountID ? !store.loginActionsDisabled && !store.loginRecoveryPending : store.canRefreshUsage(for: account),
                    "refreshReason": store.savedLogin(for: account) == nil && account.id != store.activeAccountID ? "Save this account’s login in Settings first." : "Refreshes are serialized with native account operations.",
                    "refreshing": store.refreshingSavedAccountID == account.id || (account.id == store.activeAccountID && store.isRefreshing),
                    "refreshError": store.savedUsageErrors[account.id] == nil ? NSNull() : "Usage refresh failed. Last successful reading retained; see native Runway for details."]
         },
         "preferences": ["range": store.displayPreferences.range.rawValue, "mode": store.displayPreferences.mode.rawValue, "percent": store.displayPreferences.showsPercent],
         "savedLogins": store.savedLogins.prefix(128).map { ["id": $0.id, "email": safe($0.email), "savedAt": $0.savedAt.timeIntervalSince1970] as [String: Any] },
         "status": ["busy": store.loginActionsDisabled, "refreshing": store.isRefreshing,
                    "profileRefreshing": store.isRefreshingProfile, "analyticsRefreshing": store.isRefreshingAnalytics,
                    "loginBusy": store.isManagingLogin, "recoveryPending": store.loginRecoveryPending, "canCancel": store.loginCanCancel,
                    "loginMessage": store.loginStatusIsError ? "Account operation needs attention. Open native Runway for details." : optional(store.loginStatusMessage),
                    "loginError": store.loginStatusIsError,
                    "usageError": store.refreshError == nil ? NSNull() : "Usage refresh failed; saved data retained.",
                    "profileError": store.profileRefreshError == nil ? NSNull() : "History refresh failed; saved data retained.",
                    "analyticsError": store.analyticsRefreshError == nil ? NSNull() : "Analytics sync incomplete; saved data retained."],
         "overview": cachedOverview ?? overview(store: store, now: now)]
    }
    static func history(accounts: [CodexAccount], now: Date) throws -> [String: Any] {
        let profiles = accounts.compactMap(\.profile)
        let profile = accounts.count == 1 ? profiles.first : AccountProfile.combined(profiles, now: now)
        let summary = profile?.summary
        return ["available": profile != nil, "savedCount": profiles.count, "accountCount": accounts.count,
                "fetchedAt": date(profile?.fetchedAt), "hasDailyData": profile?.hasDailyData ?? false,
                "stats": ["Lifetime tokens": ProfileFormat.tokens(summary?.lifetimeTokens), "Peak tokens": ProfileFormat.tokens(summary?.peakDailyTokens),
                          "Longest chat": ProfileFormat.duration(summary?.longestRunningTurnSec), "Current streak": ProfileFormat.days(summary?.currentStreakDays), "Longest streak": ProfileFormat.days(summary?.longestStreakDays)],
                "days": (profile?.dailyUsageBuckets ?? []).suffix(366).map { ["date": $0.startDate, "tokens": $0.tokens] as [String: Any] }]
    }
    static func analytics(accounts: [CodexAccount], store: RunwayStore, days: Int, now: Date) -> [String: Any] {
        let since = ProfileCalendar.key(now.addingTimeInterval(-Double(days - 1) * 86_400))
        let today = ProfileCalendar.key(now)
        let saved = accounts.compactMap { account in store.analyticsByAccount[account.id].map { (account, $0) } }
        // Curated typed fields only; omit raw credit events, reviews and chat groups.
        let response: [String: Any] = ["savedCount": saved.count, "accountCount": accounts.count, "since": since, "until": today,
                "accounts": saved.map { account, archive -> [String: Any] in
                    func within(_ date: String) -> Bool { date >= since && date <= today }
                    return ["id": account.id.uuidString, "name": safe(account.name), "capacityUnits": optional(account.capacityUnits),
                            "fetchedAt": date(archive.messagesFetchedAt ?? archive.usageFetchedAt),
                            "freshness": optional(archive.dataFreshnessTimestamp),
                            "messages": archive.messages.filter { within($0.date) }.prefix(366).map { row in
                                ["date": row.date, "total": optional(row.totals?.turns),
                                 "models": (row.models ?? []).map { ["name": safe($0.model), "value": optional($0.turns)] },
                                 "surfaces": row.clients.map { ["name": safe($0.clientId), "value": optional($0.turns)] }] as [String: Any]
                            },
                            "usage": archive.usage.filter { within($0.date) }.prefix(366).map { row in
                                ["date": row.date, "models": row.models.map { ["name": safe($0.model), "value": $0.credits] as [String: Any] },
                                 "surfaces": row.productSurfaceUsageValues.keys.sorted().map { ["name": safe($0), "value": row.productSurfaceUsageValues[$0]!] as [String: Any] },
                                 "features": row.attribution.map { ["name": safe($0.threadSource), "value": $0.value] as [String: Any] }] as [String: Any]
                            },
                            "plugins": archive.plugins.filter { within($0.date) }.prefix(366).map { ["date": $0.date, "items": $0.overviews.map { ["name": safe($0.displayName), "value": $0.invocationCounts] as [String: Any] }] as [String: Any] },
                            "skills": archive.skills.filter { within($0.date) }.prefix(366).map { ["date": $0.date, "items": $0.overviews.map { ["name": safe($0.displayName), "value": $0.invocationCounts] as [String: Any] }] as [String: Any] },
                            "chats": archive.chats.filter { ProfileCalendar.key($0.updatedAt ?? $0.createdAt) >= since }
                                .sorted { ($0.weeklyLimitPercent ?? -1) > ($1.weeklyLimitPercent ?? -1) }.prefix(100).map {
                                    ["id": $0.threadID, "title": safe($0.title), "weeklyPercent": optional($0.weeklyLimitPercent),
                                     "fiveHourPercent": optional($0.fiveHourLimitPercent), "credits": optional($0.balanceUsageCredits), "status": safe($0.dataStatus)] as [String: Any]
                                },
                            "periods": archive.planPeriods.filter { String($0.endsAt.prefix(10)) >= since }.suffix(100).map { row in
                                ["id": row.id, "start": row.startsAt, "end": row.endsAt, "windowMinutes": row.windowMinutes,
                                 "plan": safe(row.planType), "complete": row.accountingComplete, "usedPercent": optional(row.usedBasisPoints.map { $0 / 100 }),
                                 "breakdowns": (row.breakdowns ?? []).prefix(16).map { ["dimension": $0.dimension, "rows": $0.rows.prefix(32).map { ["name": safe($0.key), "value": $0.basisPoints / 100] as [String: Any] }] as [String: Any] }] as [String: Any]
                            }]
                }]
        return compactAnalytics(response)
    }

    /// Aggregate chart presentation in Swift before crossing IPC, so payloads
    /// remain bounded even with many accounts. No archives are changed. Keep
    /// per-source metadata and attach account labels to task/period rows.
    private static func compactAnalytics(_ response: [String: Any]) -> [String: Any] {
        guard let sources = response["accounts"] as? [[String: Any]], !sources.isEmpty else { return response }
        var result = response
        let weightTotal = sources.reduce(0.0) { $0 + (($1["capacityUnits"] as? Double) ?? 1) }
        var charts: [String: [String: [String: [String: Double]]]] = [:]
        var chats: [[String: Any]] = [], periods: [[String: Any]] = []
        for source in sources {
            let weight = sources.count > 1 ? ((source["capacityUnits"] as? Double) ?? 1) / max(1, weightTotal) : 1
            for type in ["usage", "messages", "plugins", "skills"] {
                let groups = type == "usage" ? ["features", "models", "surfaces"] : type == "messages" ? ["models", "surfaces"] : ["items"]
                for row in source[type] as? [[String: Any]] ?? [] {
                    guard let day = row["date"] as? String else { continue }
                    for group in groups {
                        let items = row[group] as? [[String: Any]] ?? []
                        var represented = 0.0
                        for item in items {
                            guard let name = item["name"] as? String, let value = (item["value"] as? NSNumber)?.doubleValue, value.isFinite else { continue }
                            represented += value
                            charts[type, default: [:]][day, default: [:]][group, default: [:]][name, default: 0] += value * (type == "usage" ? weight : 1)
                        }
                        if type == "messages", let total = (row["total"] as? NSNumber)?.doubleValue, total > represented {
                            charts[type, default: [:]][day, default: [:]][group, default: [:]]["Other", default: 0] += total - represented
                        }
                    }
                }
            }
            for row in source["chats"] as? [[String: Any]] ?? [] { chats.append(row.merging(["account": source["name"] ?? "Account"]) { _, value in value }) }
            for row in source["periods"] as? [[String: Any]] ?? [] { periods.append(row.merging(["account": source["name"] ?? "Account"]) { _, value in value }) }
        }
        var combined: [String: Any] = ["id": "combined", "name": "Saved accounts", "capacityUnits": 1]
        for type in ["usage", "messages", "plugins", "skills"] {
            let days = charts[type] ?? [:]
            var totals: [String: [String: Double]] = [:]
            for groups in days.values { for (group, values) in groups { for (name, value) in values { totals[group, default: [:]][name, default: 0] += value } } }
            let retained = totals.mapValues { values in Set(values.sorted { $0.value > $1.value }.prefix(24).map(\.key)) }
            combined[type] = days.keys.sorted().map { day -> [String: Any] in
                var row: [String: Any] = ["date": day]
                for (group, values) in days[day] ?? [:] {
                    let names = retained[group] ?? []
                    var bounded = values.filter { names.contains($0.key) }
                    let other = values.filter { !names.contains($0.key) }.values.reduce(0, +)
                    if other > 0 { bounded["Other", default: 0] += other }
                    row[group] = bounded.keys.sorted().map { ["name": $0, "value": bounded[$0]!] as [String: Any] }
                }
                return row
            }
        }
        combined["chats"] = chats.sorted { ($0["weeklyPercent"] as? Double ?? -1) > ($1["weeklyPercent"] as? Double ?? -1) }.prefix(100).map { $0 }
        combined["periods"] = periods.sorted { ($0["end"] as? String ?? "") > ($1["end"] as? String ?? "") }.prefix(100).map { $0 }
        result["sources"] = sources.map { ["id": $0["id"] ?? "", "name": $0["name"] ?? "", "fetchedAt": $0["fetchedAt"] ?? NSNull(), "freshness": $0["freshness"] ?? NSNull()] }
        result["accounts"] = [combined]
        result["boundedDetails"] = true
        return result
    }
}
