import Foundation

struct Entitlement: Codable, Equatable, Sendable {
    var firstOpen = Date()
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(trialClaimedAt ?? localStart, localStart)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }

    mutating func applyVerified(pro: Bool?, trialDate: Date?) {
        if let pro { purchasedPro = pro }
        if let trialDate { trialClaimedAt = min(trialClaimedAt ?? trialDate, trialDate) }
    }
}
