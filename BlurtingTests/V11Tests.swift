import Foundation
import XCTest

final class V11Tests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testChinesePaperMatching() {
        let cases: [(String, String, Bool)] = [
            ("光合作用", "光 合，作 用。", true),
            ("植物吸收水分", "植物吸收水份", true),
            ("細胞核含有染色體", "細胞核有染色體", true),
            ("碳沿食物網傳遞", "碳沿食", false),
            ("ＡＴＰ供能", "atp 供能", true)
        ]
        assertMatches(cases)
    }

    func testEnglishPaperMatching() {
        let cases: [(String, String, Bool)] = [
            ("Plants absorb carbon", "PLANTS, absorb ＣＡＲＢＯＮ!", true),
            ("Plants absorb carbon dioxide", "Plants absorp carbon dioxide", true),
            ("Glucose stores chemical energy", "glucose energy", true),
            ("The ocean stores carbon", "carbon", false),
            ("carbon carbon carbon dioxide", "carbon", false)
        ]
        assertMatches(cases)
    }

    func testLanguageFollowsNoteWithPreferredFallbackForSharedCharacters() {
        XCTAssertEqual(PaperLanguage.infer(from: "繁體講義與學習資料", preferred: "en"), .traditional)
        XCTAssertEqual(PaperLanguage.infer(from: "简体讲义与学习资料", preferred: "zh-Hant"), .simplified)
        XCTAssertEqual(PaperLanguage.infer(from: "Study notes", preferred: "zh-Hant"), .english)
        XCTAssertEqual(PaperLanguage.infer(from: "水", preferred: "zh-Hant"), .traditional)
    }

    func testPaperFallbackAndManualOverridePersistWhenAddingAnotherPhoto() throws {
        let note = Note(title: "Paper", points: [Point(text: "Carbon cycle"), Point(text: "Oceans absorb carbon")])
        var draft = RecallDraft(note: note, now: .now, previousMisses: [])
        draft.paper = PaperAttempt()
        let first = UUID()
        draft.comparePaper(photoIDs: [first], recognized: "")
        XCTAssertTrue(draft.canFinish)
        XCTAssertEqual(draft.missed, Set(note.points.map(\.id)))
        draft.toggle(note.points[0].id)
        let second = UUID()
        draft.comparePaper(photoIDs: [second], recognized: "Different text")
        let saved = try JSONDecoder().decode(RecallDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(saved.paper?.photoIDs, [first, second])
        XCTAssertEqual(saved.missed, [note.points[1].id])
    }

    func testChapterScheduleAdvancesCapsAndResets() throws {
        let note = Note(title: "Chapter", points: [Point(text: "An idea")])
        var library = Library(notes: [note])
        var now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        for days in [1, 3, 7, 14, 30, 30] {
            let session = try finish(note, in: &library, at: now)
            let due = try XCTUnwrap(calendar.date(byAdding: .day, value: days, to: now))
            XCTAssertEqual(session.nextChapterReview, due)
            XCTAssertEqual(library.nextReview(for: note.id), due)
            now = due
        }
        let missed = try finish(note, in: &library, at: now, missed: true)
        XCTAssertEqual(missed.nextChapterReview, calendar.date(byAdding: .day, value: 1, to: now))
        let item = try XCTUnwrap(library.queue.values.first)
        XCTAssertEqual(item.stage, 0)
        XCTAssertEqual(item.due, missed.nextChapterReview)
        _ = try finish(note, in: &library, at: item.due)
        let recalled = try XCTUnwrap(library.queue.values.first)
        XCTAssertEqual(recalled.stage, 1)
        XCTAssertEqual(recalled.due, calendar.date(byAdding: .day, value: 3, to: item.due))
        _ = try finish(note, in: &library, at: recalled.due, missed: true)
        XCTAssertEqual(library.queue.values.first?.stage, 0)
    }

    func testLegacyReviewDataDecodesAndBackfillsWholeChapterOnce() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Note(title: "Legacy", points: [Point(text: "An idea")])
        var library = Library(notes: [note])
        _ = try finish(note, in: &library, at: date, missed: true)
        let data = try JSONEncoder().encode(library)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "chapterSchedule")
        var queue = try XCTUnwrap(legacy["queue"] as? [String: [String: Any]])
        for key in Array(queue.keys) {
            queue[key]?.removeValue(forKey: "stage")
            queue[key]?.removeValue(forKey: "wasMissed")
        }
        legacy["queue"] = queue
        var sessions = try XCTUnwrap(legacy["sessions"] as? [[String: Any]])
        sessions[0].removeValue(forKey: "nextChapterReview")
        legacy["sessions"] = sessions
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        var migrated = try JSONDecoder().decode(Library.self, from: legacyData)
        XCTAssertEqual(migrated.queue.values.first?.schedule.stage, 0)
        migrated.migrateReviewSchedule(calendar: calendar)
        XCTAssertEqual(migrated.chapterSchedule?[note.id]?.due, LocalDay.tomorrow(from: date, calendar: calendar))
        XCTAssertNil(migrated.history(for: note.id).first?.paperPhotoIDs)
        let saved = migrated.chapterSchedule?[note.id]?.due
        migrated.migrateReviewSchedule(calendar: calendar)
        XCTAssertEqual(migrated.chapterSchedule?[note.id]?.due, saved)
    }

    func testReminderSchedulesOnlyDueDaysAndUpdatesAfterDisabling() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 15)))
        let tomorrow = LocalDay.tomorrow(from: now, calendar: calendar)
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: tomorrow))
        let overdue = now.addingTimeInterval(-86_400)
        var prefs = ReviewPreferences()
        let dates = prefs.fireDates(for: [overdue, now, tomorrow, tomorrow, later], now: now, calendar: calendar)
        XCTAssertEqual(dates.map { calendar.component(.day, from: $0) }, [24, 25, 28])
        XCTAssertTrue(dates.allSatisfy { calendar.component(.hour, from: $0) == 19 })
        XCTAssertTrue(prefs.fireDates(for: [overdue], now: now.addingTimeInterval(5 * 3600), calendar: calendar).isEmpty)
        prefs.enabled = false
        XCTAssertTrue(prefs.fireDates(for: [now, tomorrow], now: now, calendar: calendar).isEmpty)
    }

    func testNewNoteLinkDecodesTitleAndSubjectAndRejectsInvalidRoutes() throws {
        let valid = try XCTUnwrap(URL(string: "blurting://new?title=%E7%AC%AC%201%20%E7%AB%A0%20%26%20CO2&subject=Biology"))
        XCTAssertEqual(NewNoteLink(url: valid)?.title, "第 1 章 & CO2")
        XCTAssertEqual(NewNoteLink(url: valid)?.subject, "Biology")
        let plus = try XCTUnwrap(URL(string: "BLURTING://NEW/?title=C%2B%2B"))
        XCTAssertEqual(NewNoteLink(url: plus)?.title, "C++")
        let withoutTitle = try XCTUnwrap(URL(string: "blurting://new?subject=History"))
        XCTAssertEqual(NewNoteLink(url: withoutTitle)?.title, "")
        for bad in ["https://new?title=Chapter", "blurting://edit", "blurting://new/wrong", "blurting://new?title=a&title=b",
                    "blurting://new?title=" + String(repeating: "a", count: 481)] {
            XCTAssertNil(NewNoteLink(url: try XCTUnwrap(URL(string: bad))))
        }
    }

    private func assertMatches(_ cases: [(String, String, Bool)]) {
        for (expected, actual, matched) in cases {
            let point = Point(text: expected)
            XCTAssertEqual(PaperMatch.misses(in: actual, points: [point]).isEmpty, matched, "\(expected) / \(actual)")
        }
    }

    private func finish(_ note: Note, in library: inout Library, at date: Date, missed: Bool = false) throws -> RecallSession {
        var draft = try XCTUnwrap(library.start(noteID: note.id, at: date))
        draft.answer = "Recall"
        draft.phase = .comparing
        if missed { draft.toggle(note.points[0].id) }
        library.drafts[note.id] = draft
        return try XCTUnwrap(library.finish(noteID: note.id, draftID: draft.id, at: date, pro: true, calendar: calendar))
    }
}
