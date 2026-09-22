import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
var raw = try JSONSerialization.jsonObject(with: Data(contentsOf:url)) as! [[String:Any]]
for index in raw.indices {
    raw[index]["id"] = UUID().uuidString
    raw[index]["name"] = "Account \(index + 1)"
    raw[index]["email"] = ""
    var snapshots = raw[index]["snapshots"] as! [[String:Any]]
    for i in snapshots.indices { snapshots[i]["id"] = UUID().uuidString }
    raw[index]["snapshots"] = snapshots
}
let accounts = try JSONDecoder().decode([CodexAccount].self,from:JSONSerialization.data(withJSONObject:raw))
let now = accounts.flatMap(\.snapshots).map(\.capturedAt).max()!
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
let report = CapacityForecast.report(accounts: accounts, now:now, calendar: calendar)
let horizons = [6, 12, 24, 48]
let units = Dictionary(uniqueKeysWithValues: horizons.map { hours in
    (String(hours), report.demand!.units(from: now, to: now.addingTimeInterval(Double(hours) * 3_600)))
})
let output: [String: Any] = ["ratePerHour": report.ratePerHour!, "usesTimeOfDay": report.usesTimeOfDay,
    "demandUnitsByHorizon": units, "remaining": report.remaining]
let outputData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(data: outputData, encoding: .utf8)!)
