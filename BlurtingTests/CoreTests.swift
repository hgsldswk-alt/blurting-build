import Foundation
import XCTest

final class CoreTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testSplitPreservesOrderAndDuplicatesAcrossMixedPrefixes() throws {
        let text = "\r\n一、第一\r\n• 第二\r\n\r\n（３）第三\r① 第四\n2. 第二"
        XCTAssertEqual(try Outline.split(text, mode: .lines), ["第一", "第二", "第三", "第四", "第二"])
        XCTAssertEqual(try Outline.split("line one\nwrap\n\n- next\ncontinued\n- last", mode: .paragraphs),
                       ["line one\nwrap", "next\ncontinued", "last"])
        XCTAssertEqual(try Outline.split("-4\n2.718\n2. example\n•例句", mode: .lines),
                       ["-4", "2.718", "example", "例句"])
        XCTAssertThrowsError(try Outline.split("\n  \n- ", mode: .lines))
        XCTAssertThrowsError(try Outline.split(String(repeating: "a", count: Outline.maxSourceBytes + 1), mode: .lines))
        XCTAssertThrowsError(try Outline.split(Array(repeating: "x", count: Outline.maxPoints + 1).joined(separator: "\n"), mode: .lines))
    }

    func testOutlineCodeAndFileValidation() throws {
        let source = try OutlineTransfer(title: "Sample", points: ["第一", "第一", "line\nwrap"])
        XCTAssertEqual(try OutlineTransfer.readCode(source.code()), source)
        XCTAssertEqual(try OutlineTransfer.readFile(source.file(), title: "", isJSON: true), source)
        XCTAssertEqual(try OutlineTransfer.readFile(Data("\u{FEFF}- first\n- second".utf8), title: "Text", isJSON: false).points,
                       ["first", "second"])
        for invalid in ["BP1.!", "BP1.", "invalid", "BP1.A"] {
            XCTAssertThrowsError(try OutlineTransfer.readCode(invalid))
        }
        XCTAssertThrowsError(try OutlineTransfer.readCode("BP2.abcd")) {
            XCTAssertEqual($0 as? OutlineIssue, .unsupported)
        }
        XCTAssertThrowsError(try OutlineTransfer.readFile(Data(#"{"version":2,"title":"X","points":["A"]}"#.utf8),
                                                         title: "", isJSON: true)) {
            XCTAssertEqual($0 as? OutlineIssue, .unsupported)
        }
        XCTAssertThrowsError(try OutlineTransfer.readFile(Data([0xFF]), title: "Bad", isJSON: false))
        let long = try OutlineTransfer(title: "Long", points: Array(repeating: String(repeating: "x", count: 4_000), count: 3))
        XCTAssertThrowsError(try long.code()) { XCTAssertEqual($0 as? OutlineIssue, .tooLong) }
        XCTAssertEqual(try OutlineTransfer.readFile(long.file(), title: "", isJSON: true), long)
        XCTAssertTrue(source.matches(Note(title: source.title, points: source.points.map { Point(text: $0) })))
    }

    func testCoverageAndHistoricalOutlineVersions() throws {
        for (recalled, expected) in [(0, 0), (17, 85), (20, 100)] {
            XCTAssertEqual(RecallSession.coverage(recalled: recalled, total: 20), expected)
        }
        XCTAssertEqual(RecallSession.coverage(recalled: 2, total: 3), 67)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var note = makeNote(count: 20)
        let old = note.version
        var library = Library(notes: [note])
        let first = try finish(note: note, library: &library, when: date, pro: true, misses: [0, 1, 2])
        var revised = note.points
        revised[0] = Point(text: "replacement")
        note.revise(title: note.title, subject: "", source: "", points: revised)
        library.update(note)
        _ = try finish(note: note, library: &library, when: date.addingTimeInterval(300), pro: true, misses: [])
        XCTAssertEqual(library.history(for: note.id, version: old).first?.coverage, 85)
        XCTAssertEqual(library.history(for: note.id, version: note.version).first?.coverage, 100)
        XCTAssertEqual(library.history(for: note.id).count, 2)
        XCTAssertEqual(first.points[0].text, "Point 0")
    }

    func testCrossMidnightDraftAndBlankAnswerGuards() throws {
        let late = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23, minute: 59)))
        let note = makeNote(count: 20)
        var library = Library(notes: [note])
        var draft = try XCTUnwrap(library.start(noteID: note.id, at: late))
        let id = draft.id
        XCTAssertEqual(draft.secondsRemaining(at: late.addingTimeInterval(61)), 239)
        XCTAssertEqual(draft.secondsRemaining(at: late.addingTimeInterval(301)), 0)
        draft.phase = .comparing
        draft.answer = " \n"
        draft.toggle(note.points[0].id)
        XCTAssertTrue(draft.missed.isEmpty)
        library.drafts[note.id] = draft
        XCTAssertNil(library.finish(noteID: note.id, draftID: id, at: late, pro: true, calendar: utc))
        draft.markBlank()
        library.drafts[note.id] = draft

        let restored = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(restored.drafts[note.id]?.id, id)
        XCTAssertEqual(restored.drafts[note.id]?.deadline, draft.deadline)
        XCTAssertEqual(restored.drafts[note.id]?.missed.count, 20)
        let completed = library.finish(noteID: note.id, draftID: id, at: late, pro: true, calendar: utc)
        XCTAssertEqual(completed?.coverage, 0)
        XCTAssertEqual(library.finish(noteID: note.id, draftID: id, at: late, pro: true)?.id, id)
        XCTAssertEqual(library.sessions.count, 1)
        XCTAssertEqual(library.queue.count, 20)
    }

    func testReviewQueueDeduplicatesResetsMissesAndKeepsRecoveredPoints() throws {
        let date = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 22)))
        let tomorrow = LocalDay.tomorrow(from: date, calendar: utc)
        let note = makeNote(count: 3)
        var library = Library(notes: [note])
        _ = try finish(note: note, library: &library, when: date, pro: true, misses: [0, 1])
        XCTAssertEqual(library.due(for: note.id, at: tomorrow).count, 2)
        XCTAssertTrue(library.due(for: note.id, at: date).isEmpty)
        let draft = try XCTUnwrap(library.start(noteID: note.id, at: tomorrow))
        XCTAssertEqual(draft.priorMissed, Set(note.points.prefix(2).map(\.id)))
        _ = try finish(note: note, library: &library, when: tomorrow, pro: true, misses: [0])
        XCTAssertEqual(library.queue.count, 2)
        XCTAssertTrue(library.due(for: note.id, at: tomorrow).isEmpty)
        XCTAssertEqual(library.due(for: note.id, at: LocalDay.tomorrow(from: tomorrow, calendar: utc)).count, 1)
        let recovered = library.queue.values.first { $0.pointID == note.points[1].id }
        XCTAssertEqual(recovered?.stage, 1)
        XCTAssertEqual(recovered?.wasMissed, false)
        XCTAssertEqual(recovered?.due, utc.date(byAdding: .day, value: 3, to: tomorrow))
        _ = try finish(note: note, library: &library, when: tomorrow, pro: true, misses: [])
        XCTAssertTrue(library.queue.values.allSatisfy { $0.wasMissed == false })
    }

    func testFreeSlotsPreserveOtherNotesAndOpenDrafts() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeNote(count: 2, date: date)
        let middle = makeNote(count: 2, date: date.addingTimeInterval(1))
        let last = makeNote(count: 2, date: date.addingTimeInterval(2))
        var library = Library(notes: [first, middle, last], lastNoteID: last.id)
        XCTAssertEqual(library.freeIDs, [last.id, middle.id])
        XCTAssertFalse(library.canStart(first, pro: false))
        library.replaceFreeNote(middle.id, with: first.id)
        XCTAssertTrue(library.canStart(first, pro: false))
        XCTAssertTrue(library.canStart(middle, pro: true))
        _ = library.start(noteID: middle.id, at: date)
        XCTAssertTrue(library.canStart(middle, pro: false))
        let session = try finish(note: middle, library: &library, when: date, pro: false, misses: [0])
        XCTAssertEqual(session.coverage, 50)
        XCTAssertTrue(library.queue.isEmpty)
        XCTAssertEqual(library.notes.count, 3)
        XCTAssertFalse(library.canStart(middle, pro: false))
    }

    func testRatingWaitsForThirdUseDayCompletionAndIdleOncePerVersion() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var state = ReviewPrompt()
        state.completed(on: date, version: "1", calendar: utc)
        state.completed(on: date.addingTimeInterval(600), version: "1", calendar: utc)
        state.recordDay(date.addingTimeInterval(86_400), calendar: utc)
        state.recordDay(date.addingTimeInterval(2 * 86_400), calendar: utc)
        XCTAssertFalse(state.shouldRequest(version: "1", idle: true))
        state.completed(on: date.addingTimeInterval(2 * 86_400), version: "1", calendar: utc)
        XCTAssertFalse(state.shouldRequest(version: "1", idle: false))
        XCTAssertTrue(state.shouldRequest(version: "1", idle: true))
        state.requestedVersions.insert("1")
        XCTAssertFalse(state.shouldRequest(version: "1", idle: true))
        XCTAssertFalse(state.shouldRequest(version: "2", idle: true))
        state.completed(on: date.addingTimeInterval(3 * 86_400), version: "2", calendar: utc)
        XCTAssertTrue(state.shouldRequest(version: "2", idle: true))
    }

    func testMilestonesAwardOnceAndIgnoreIncompleteDrafts() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let note = makeNote(count: 1)
        var library = Library(notes: [note])
        for day in 0..<7 {
            let date = start.addingTimeInterval(Double(day * 86_400))
            let outcome = try finish(note: note, library: &library, when: date, pro: true, misses: [])
            XCTAssertEqual(outcome.milestones, day == 6 ? [.streak] : [])
        }
        for repetition in 8...51 {
            let next = start.addingTimeInterval(Double(6 * 86_400 + repetition))
            let outcome = try finish(note: note, library: &library, when: next, pro: true, misses: [])
            XCTAssertEqual(outcome.milestones, repetition == 50 ? [.fifty] : [])
        }
        library.remove(note.id)
        XCTAssertTrue(library.sessions.isEmpty)
        XCTAssertEqual(library.lifetime.count, 51)
        XCTAssertEqual(library.lifetime.awards, [.streak, .fifty])
    }

    private func makeNote(count: Int, date: Date = Date()) -> Note {
        Note(title: "Chapter", points: (0..<count).map { Point(text: "Point \($0)") }, lastUsed: date)
    }

    private func finish(note: Note, library: inout Library, when: Date, pro: Bool, misses: [Int]) throws -> RecallSession {
        var draft = try XCTUnwrap(library.start(noteID: note.id, at: when))
        draft.phase = .comparing
        draft.answer = "Some text"
        for index in misses { draft.toggle(note.points[index].id) }
        library.drafts[note.id] = draft
        return try XCTUnwrap(library.finish(noteID: note.id, draftID: draft.id, at: when, pro: pro, calendar: utc))
    }
}
