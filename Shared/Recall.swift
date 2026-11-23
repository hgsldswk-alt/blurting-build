import Foundation

struct PaperAttempt: Codable, Sendable {
    var photoIDs: [UUID] = []
    var manualMarks: [UUID: Bool] = [:]
}

struct RecallDraft: Codable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable { case writing, comparing }

    var id = UUID()
    let noteID: UUID
    let version: UUID
    let points: [Point]
    let deadline: Date
    var answer = ""
    var phase = Phase.writing
    var missed = Set<UUID>()
    var priorMissed = Set<UUID>()
    var confirmedBlank = false
    var paper: PaperAttempt?

    init(note: Note, now: Date, previousMisses: Set<UUID>) {
        noteID = note.id
        version = note.version
        points = note.points
        deadline = now.addingTimeInterval(Double(note.minutes) * 60)
        priorMissed = previousMisses
    }

    var isBlank: Bool { Outline.clean(answer).isEmpty }
    var needsBlankConfirmation: Bool { paper == nil && isBlank }
    var canFinish: Bool { phase == .comparing && (!needsBlankConfirmation || confirmedBlank) }

    mutating func comparePaper(photoIDs: [UUID], recognized: String) {
        guard var paper else { return }
        if !recognized.isEmpty {
            answer = [Outline.clean(answer), recognized].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        paper.photoIDs.append(contentsOf: photoIDs)
        missed = PaperMatch.misses(in: answer, points: points)
        for (id, marked) in paper.manualMarks {
            if marked { missed.insert(id) } else { missed.remove(id) }
        }
        self.paper = paper
        phase = .comparing
    }

    func secondsRemaining(at date: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    mutating func markBlank() {
        guard phase == .comparing, needsBlankConfirmation else { return }
        confirmedBlank = true
        missed = Set(points.map(\.id))
    }

    mutating func toggle(_ id: UUID) {
        guard phase == .comparing, !needsBlankConfirmation, points.contains(where: { $0.id == id }) else { return }
        if !missed.insert(id).inserted { missed.remove(id) }
        paper?.manualMarks[id] = missed.contains(id)
    }
}

struct RecallSession: Codable, Identifiable, Sendable {
    let id: UUID
    let noteID: UUID
    let version: UUID
    let points: [Point]
    let answer: String
    let missed: Set<UUID>
    let completed: Date
    let queuedCount: Int
    let milestones: [Milestone]
    var paperPhotoIDs: [UUID]? = nil
    var nextChapterReview: Date? = nil

    var recalled: Int { points.count - missed.count }
    var coverage: Int { Self.coverage(recalled: recalled, total: points.count) }

    static func coverage(recalled: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(recalled) * 100 / Double(total)).rounded())
    }
}

struct ReviewItem: Codable, Identifiable, Sendable {
    let noteID: UUID
    let pointID: UUID
    let due: Date
    var stage: Int? = nil
    var wasMissed: Bool? = nil
    var id: String { "\(noteID.uuidString)/\(pointID.uuidString)" }
    var schedule: ReviewSchedule { ReviewSchedule(stage: stage ?? 0, due: due) }
}

enum Milestone: String, Codable, CaseIterable, Identifiable, Sendable {
    case streak, fifty
    var id: Self { self }
    var number: Int { self == .streak ? 7 : 50 }
    var label: String { L.t(self == .streak ? "milestone.streak" : "milestone.fifty") }
}

enum LocalDay {
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let values = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return [values.era, values.year, values.month, values.day].map { String($0 ?? 0) }.joined(separator: "-")
    }

    static func tomorrow(from date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    }
}

struct ReviewPrompt: Codable, Sendable {
    var days = Set<String>()
    var eligibleVersion: String?
    var requestedVersions = Set<String>()

    mutating func recordDay(_ date: Date, calendar: Calendar = .current) {
        days.insert(LocalDay.key(for: date, calendar: calendar))
    }

    mutating func completed(on date: Date, version: String, calendar: Calendar = .current) {
        recordDay(date, calendar: calendar)
        if days.count >= 3 { eligibleVersion = version }
    }

    func shouldRequest(version: String, idle: Bool) -> Bool {
        idle && eligibleVersion == version && !requestedVersions.contains(version)
    }
}

struct LifetimePractice: Codable, Sendable {
    var days = Set<String>()
    var count = 0
    var awards = Set<Milestone>()

    mutating func completed(on date: Date, calendar: Calendar) -> [Milestone] {
        count += 1
        days.insert(LocalDay.key(for: date, calendar: calendar))
        var earned: [Milestone] = []
        if !awards.contains(.streak) {
            let streak = (1...6).allSatisfy { offset in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return false }
                return days.contains(LocalDay.key(for: day, calendar: calendar))
            }
            if streak { earned.append(.streak) }
        }
        if count >= 50, !awards.contains(.fifty) { earned.append(.fifty) }
        awards.formUnion(earned)
        return earned
    }
}

struct Library: Codable, Sendable {
    var notes: [Note] = []
    var drafts: [UUID: RecallDraft] = [:]
    var sessions: [RecallSession] = []
    var queue: [String: ReviewItem] = [:]
    var lastNoteID: UUID?
    var freeSelection: [UUID]?
    var reviewPrompt = ReviewPrompt()
    var lifetime = LifetimePractice()
    var chapterSchedule: [UUID: ReviewSchedule]?
    var reminderPreferences: ReviewPreferences?

    var photoIDs: Set<UUID> {
        Set(drafts.values.flatMap { $0.paper?.photoIDs ?? [] } + sessions.flatMap { $0.paperPhotoIDs ?? [] })
    }

    var recentNotes: [Note] { notes.sorted { $0.lastUsed > $1.lastUsed } }
    var customNotes: [Note] { recentNotes.filter { !$0.isExample } }

    var freeIDs: [UUID] {
        let allIDs = customNotes.map(\.id)
        let preference = freeSelection ?? [lastNoteID].compactMap { $0 }
        let kept = preference.filter { allIDs.contains($0) }
        return Array((kept + allIDs.filter { !kept.contains($0) }).prefix(2))
    }

    mutating func replaceFreeNote(_ victim: UUID, with id: UUID) {
        guard freeIDs.contains(victim), !freeIDs.contains(id), customNotes.contains(where: { $0.id == id }) else { return }
        freeSelection = freeIDs.map { $0 == victim ? id : $0 }
    }

    func canStart(_ note: Note, pro: Bool) -> Bool {
        drafts[note.id] != nil || pro || note.isExample || freeIDs.contains(note.id)
    }

    func homeNote(pro: Bool) -> Note? {
        if let last = notes.first(where: { $0.id == lastNoteID }), canStart(last, pro: pro) { return last }
        return recentNotes.first { canStart($0, pro: pro) }
    }

    mutating func start(noteID: UUID, at date: Date) -> RecallDraft? {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return nil }
        notes[index].lastUsed = date
        lastNoteID = noteID
        if let draft = drafts[noteID] { return draft }
        let previous = Set(queue.values.filter { $0.noteID == noteID && $0.wasMissed != false }.map(\.pointID))
        let draft = RecallDraft(note: notes[index], now: date, previousMisses: previous)
        drafts[noteID] = draft
        return draft
    }

    mutating func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        if notes[index].version != note.version { chapterSchedule?.removeValue(forKey: note.id) }
        notes[index] = note
        let active = Set(note.points.map(\.id))
        queue = queue.filter { $0.value.noteID != note.id || active.contains($0.value.pointID) }
    }

    mutating func remove(_ id: UUID) {
        notes.removeAll { $0.id == id }
        drafts.removeValue(forKey: id)
        sessions.removeAll { $0.noteID == id }
        queue = queue.filter { $0.value.noteID != id }
        chapterSchedule?.removeValue(forKey: id)
        freeSelection?.removeAll { $0 == id }
        if lastNoteID == id { lastNoteID = nil }
    }

    func due(for id: UUID, at date: Date) -> [ReviewItem] {
        queue.values.filter { $0.noteID == id && $0.due <= date }
    }

    func reviewDates(for id: UUID) -> [Date] {
        queue.values.filter { $0.noteID == id }.map(\.due) + [chapterSchedule?[id]?.due].compactMap { $0 }
    }

    var reviewDatesByNote: [UUID: [Date]] {
        var dates = (chapterSchedule ?? [:]).mapValues { [$0.due] }
        for item in queue.values { dates[item.noteID, default: []].append(item.due) }
        return dates
    }

    func nextReview(for id: UUID) -> Date? {
        reviewDates(for: id).min()
    }

    mutating func migrateReviewSchedule(calendar: Calendar = .current) {
        guard chapterSchedule == nil else { return }
        let latest = Dictionary(grouping: sessions, by: \.noteID)
        chapterSchedule = [:]
        for note in notes {
            guard let session = latest[note.id]?.filter({ $0.version == note.version })
                .max(by: { $0.completed < $1.completed }) else { continue }
            chapterSchedule?[note.id] = ReviewSchedule.next(after: nil, recalled: session.missed.isEmpty,
                                                             at: session.completed, calendar: calendar)
        }
    }

    func history(for id: UUID, version: UUID? = nil) -> [RecallSession] {
        sessions.filter { $0.noteID == id && (version == nil || $0.version == version) }
            .sorted { $0.completed > $1.completed }
    }

    mutating func finish(noteID: UUID, draftID: UUID, at now: Date, pro: Bool,
                         appVersion: String = "1.0", calendar: Calendar = .current) -> RecallSession? {
        if let completed = sessions.first(where: { $0.id == draftID }) { return completed }
        guard let draft = drafts[noteID], draft.id == draftID, draft.canFinish,
              let note = notes.first(where: { $0.id == noteID }) else { return nil }

        let active = Set(note.points.map(\.id))
        var queuedCount = 0
        let canSchedule = pro || note.isExample || freeIDs.contains(noteID)
        for point in draft.points where active.contains(point.id) {
            let key = "\(noteID.uuidString)/\(point.id.uuidString)"
            let prior = queue[key]
            let recalled = !draft.missed.contains(point.id)
            guard prior != nil || (!recalled && canSchedule) else { continue }
            let schedule = ReviewSchedule.next(after: prior?.schedule, recalled: recalled, at: now, calendar: calendar)
            queue[key] = ReviewItem(noteID: noteID, pointID: point.id, due: schedule.due, stage: schedule.stage,
                                    wasMissed: !recalled)
            if !recalled { queuedCount += 1 }
        }
        if canSchedule, draft.version == note.version {
            let next = ReviewSchedule.next(after: chapterSchedule?[noteID], recalled: draft.missed.isEmpty,
                                           at: now, calendar: calendar)
            if chapterSchedule == nil { chapterSchedule = [:] }
            chapterSchedule?[noteID] = next
        }

        let earned = lifetime.completed(on: now, calendar: calendar)
        let completed = RecallSession(id: draft.id, noteID: noteID, version: draft.version, points: draft.points,
                                      answer: draft.answer, missed: draft.missed, completed: now,
                                      queuedCount: queuedCount, milestones: earned,
                                      paperPhotoIDs: draft.paper?.photoIDs, nextChapterReview: chapterSchedule?[noteID]?.due)
        sessions.append(completed)
        drafts.removeValue(forKey: noteID)
        reviewPrompt.completed(on: now, version: appVersion, calendar: calendar)
        return completed
    }

}

enum Example {
    static func note(at date: Date = Date()) -> Note {
        let points = (1...20).map { Point(text: L.t("example.point.\($0)")) }
        return Note(title: L.t("example.title"), subject: L.t("example.subject"),
                    source: points.map(\.text).joined(separator: "\n"), points: points,
                    lastUsed: date, isExample: true)
    }

    static func noteForScreenshots(at date: Date = Date()) -> Note {
        var note = note(at: date)
        note.isExample = false
        return note
    }
}
