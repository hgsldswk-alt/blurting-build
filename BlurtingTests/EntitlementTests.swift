import Foundation
import XCTest

final class EntitlementTests: XCTestCase {
    func testPaidLaunchUsesFirstOpenOrPaidStartAndExactThirtyDayCutoff() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(Launch.freePeriod)
        let firstRun = Entitlement(firstOpen: first)
        XCTAssertTrue(firstRun.hasPro(at: first, free: false))
        XCTAssertTrue(firstRun.hasPro(at: firstRun.trialEnd.addingTimeInterval(-1), free: false))
        XCTAssertFalse(firstRun.hasPro(at: firstRun.trialEnd, free: false))
        XCTAssertFalse(firstRun.hasPro(at: first.addingTimeInterval(-1), free: false))
        let paidStart = first.addingTimeInterval(86_400)
        let switched = Entitlement(firstOpen: first, proStartedAt: paidStart)
        XCTAssertEqual(switched.trialStart, paidStart)
        XCTAssertEqual(switched.trialEnd.timeIntervalSince(paidStart), 30 * 86_400)
        XCTAssertTrue(switched.hasPro(at: switched.trialEnd, free: true))
    }

    func testVerifiedReceiptRestoresEarlierStartWithoutExtendingCurrentTrial() throws {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        var local = Entitlement(firstOpen: first)
        local.applyVerified(pro: nil, trialDate: first.addingTimeInterval(86_400))
        XCTAssertEqual(local.trialStart, first)
        let earlier = first.addingTimeInterval(-10 * 86_400)
        local.applyVerified(pro: nil, trialDate: earlier)
        XCTAssertEqual(local.trialStart, earlier)
        XCTAssertFalse(local.hasPro(at: local.trialEnd, free: false))
        local.applyVerified(pro: true, trialDate: nil)
        let restored = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(local))
        XCTAssertTrue(restored.hasPro(at: local.trialEnd, free: false))
        local.applyVerified(pro: false, trialDate: nil)
        XCTAssertFalse(local.hasPro(at: local.trialEnd, free: false))
    }
}
