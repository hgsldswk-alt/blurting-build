import Foundation

struct ReviewSchedule: Codable, Sendable {
    static let intervals = [1, 3, 7, 14, 30]
    let stage: Int
    let due: Date

    static func next(after prior: Self?, recalled: Bool, at now: Date, calendar: Calendar) -> Self {
        let stage = recalled ? min((prior?.stage ?? -1) + 1, intervals.count - 1) : 0
        let start = calendar.startOfDay(for: now)
        let due = calendar.date(byAdding: .day, value: intervals[stage], to: start) ?? start
        return Self(stage: stage, due: due)
    }
}

struct ReviewPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var hour = 19
    var minute = 0

    func fireDates(for dueDates: [Date], now: Date, calendar: Calendar = .current) -> [Date] {
        guard enabled else { return [] }
        let today = calendar.startOfDay(for: now)
        let days = Set(dueDates.map { max(today, calendar.startOfDay(for: $0)) })
        return days.compactMap {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: $0,
                          matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        }.filter { $0 > now }.sorted()
    }
}
