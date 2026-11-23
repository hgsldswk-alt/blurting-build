import Foundation
import StoreKit
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var library = Library()
    @Published private(set) var entitlement = Entitlement()
    @Published private(set) var now = Date()
    @Published private(set) var ready = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var storeBusy = false
    @Published var storageError: String?
    @Published var purchaseMessage: String?

    let testing: Bool
    let arguments: [String]
    let environment: [String: String]
    private var store: LocalStore?
    private var saveTask: Task<Void, Never>?
    private var transactionTask: Task<Void, Never>?
    private var revision = 0
    private var paidRevision = 0
    private var restoring = false
    private var refreshing = false
    private var backgroundSave = UIBackgroundTaskIdentifier.invalid
    private var pendingPhotos: [UUID: Data] = [:]
    private lazy var reminders = ReviewReminders()
    private var askForReminderPermission = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.arguments = arguments
        self.environment = environment
        #if DEBUG
        testing = arguments.contains("-ui-testing")
        #else
        testing = false
        #endif
    }

    var freePeriod: Bool { Launch.isFree(arguments: testing ? arguments : []) }
    var hasPro: Bool { entitlement.hasPro(at: now, free: freePeriod) }
    var canCreate: Bool { hasPro || library.customNotes.count < 2 }
    var proID: String { Bundle.main.object(forInfoDictionaryKey: "BlurtingProProductID") as? String ?? "com.hgsldswk.blurting.pro" }
    var trialID: String { Bundle.main.object(forInfoDictionaryKey: "BlurtingTrialProductID") as? String ?? "com.hgsldswk.blurting.trial" }

    var proPrice: String? { products.first { $0.id == proID }?.displayPrice }
    var remainingDays: Int { max(0, Int(ceil(entitlement.trialEnd.timeIntervalSince(now) / 86_400))) }
    var reviewPreferences: ReviewPreferences { library.reminderPreferences ?? ReviewPreferences() }
    var reviewNotes: [(note: Note, date: Date)] {
        let dates = library.reviewDatesByNote
        return library.recentNotes.filter { library.canStart($0, pro: hasPro) }.compactMap { note -> (note: Note, date: Date)? in
            guard let date = dates[note.id]?.min() else { return nil }
            return (note, date)
        }.sorted { $0.date < $1.date || ($0.date == $1.date && $0.note.id.uuidString < $1.note.id.uuidString) }
    }
    var dueNotes: [Note] { reviewNotes.filter { $0.date <= now }.map(\.note) }
    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
    }

    func clock() {
        now = effectiveDate(Date())
        if ready, !hasPro, library.freeSelection == nil {
            library.freeSelection = library.freeIDs
            save()
        }
    }

    func effectiveDate(_ date: Date) -> Date {
        let offset = testing ? Double(environment["BLURTING_DAY_OFFSET"] ?? "") ?? 0 : 0
        return date.addingTimeInterval(offset * 86_400)
    }

    func open() async {
        guard !ready else { return }
        storageError = nil
        clock()
        let persistent = testing && arguments.contains("-persist")
        let reset = testing && arguments.contains("-reset")
        do {
            let repository = try await LocalStore.open(testing: testing, persistent: persistent, reset: reset)
            let (saved, access) = try await repository.load(testing: testing, now: now)
            store = repository
            library = saved
            entitlement = access
            if testing && arguments.contains("-expired") {
                entitlement.proStartedAt = now.addingTimeInterval(-31 * 86_400)
                entitlement.purchasedPro = false
            }
            if testing && arguments.contains("-demo") { seedDemo() }
            library.migrateReviewSchedule()
            ready = true
            recordUse()
            save()
            if !testing && !freePeriod {
                listenForPurchases()
                Task(priority: .utility) { await loadProducts(showFailure: false) }
            }
        } catch {
            self.storageError = L.t("error.open")
        }
    }

    func recordUse() {
        clock()
        guard ready else { return }
        let key = LocalDay.key(for: now)
        guard !library.reviewPrompt.days.contains(key) else { return }
        library.reviewPrompt.recordDay(now)
        save()
    }

    func add(_ note: Note) {
        library.notes.append(note)
        if !hasPro { library.freeSelection = library.freeIDs }
        save()
    }

    func update(_ note: Note) {
        library.update(note)
        save()
    }

    func delete(_ id: UUID) {
        library.remove(id)
        save()
    }

    func setDuration(_ minutes: Int, for note: Note) {
        var updated = note
        updated.minutes = minutes
        update(updated)
    }

    func start(_ note: Note) -> RecallDraft? {
        clock()
        guard library.canStart(note, pro: hasPro) else { return nil }
        let draft = library.start(noteID: note.id, at: now)
        save()
        return draft
    }

    func setAnswer(_ answer: String, noteID: UUID) {
        guard var draft = library.drafts[noteID], draft.phase == .writing, draft.answer != answer else { return }
        draft.answer = answer
        library.drafts[noteID] = draft
        save(debounce: true)
    }

    func reveal(_ id: UUID) {
        guard library.drafts[id]?.phase == .writing else { return }
        library.drafts[id]?.phase = .comparing
        save()
    }

    func setPaperMode(_ enabled: Bool, for id: UUID) {
        guard var draft = library.drafts[id], draft.phase == .writing else { return }
        draft.paper = enabled ? PaperAttempt() : nil
        library.drafts[id] = draft
        save()
    }

    @discardableResult
    func comparePaper(_ draft: RecallDraft, photos: [Data], recognized: String) -> Bool {
        guard var current = library.drafts[draft.noteID], current.id == draft.id, let paper = current.paper,
              photos.count + paper.photoIDs.count <= 3 else { return false }
        if current.phase == .writing { current.answer = "" }
        let ids = photos.map { data in
            let id = UUID()
            pendingPhotos[id] = data
            return id
        }
        current.comparePaper(photoIDs: ids, recognized: recognized)
        library.drafts[draft.noteID] = current
        save()
        return true
    }

    func photo(_ id: UUID) async -> Data? {
        if let pending = pendingPhotos[id] { return pending }
        return try? await store?.photo(id)
    }

    func confirmBlank(_ id: UUID) {
        library.drafts[id]?.markBlank()
        save()
    }

    func toggle(_ point: UUID, in note: UUID) {
        library.drafts[note]?.toggle(point)
        save()
    }

    func finish(_ draft: RecallDraft) -> RecallSession? {
        clock()
        let result = library.finish(noteID: draft.noteID, draftID: draft.id, at: now, pro: hasPro,
                                    appVersion: version)
        if result != nil {
            askForReminderPermission = askForReminderPermission || reviewPreferences.enabled
            save()
        }
        return result
    }

    func setReviewPreferences(_ preferences: ReviewPreferences, ask: Bool) {
        library.reminderPreferences = preferences
        askForReminderPermission = ask
        save()
    }

    func refreshReminders(ask: Bool = false, force: Bool = false) {
        guard ready, !testing else { return }
        let dates = library.reviewDatesByNote
        let eligible = library.notes.filter { library.canStart($0, pro: hasPro) }
        let due = eligible.flatMap { dates[$0.id] ?? [] }
        reminders.refresh(dates: reviewPreferences.fireDates(for: due, now: now),
                          enabled: reviewPreferences.enabled, requestPermission: ask, force: force)
    }

    func importNote(_ payload: OutlineTransfer) throws {
        guard !library.customNotes.contains(where: payload.matches) else { throw OutlineIssue.duplicate }
        add(Note(title: payload.title, source: payload.points.joined(separator: "\n"), points: payload.points.map { Point(text: $0) }))
    }

    func replaceFreeNote(_ victim: UUID, with id: UUID) {
        library.replaceFreeNote(victim, with: id)
        save()
    }

    func markReviewRequested(_ version: String) {
        library.reviewPrompt.requestedVersions.insert(version)
        save()
    }

    func flush(leavingForeground: Bool = false) {
        guard ready else { return }
        if leavingForeground, !testing, backgroundSave == .invalid {
            backgroundSave = UIApplication.shared.beginBackgroundTask(withName: "Save recall draft") { [weak self] in
                Task { @MainActor in self?.endBackgroundSave() }
            }
        }
        save()
    }

    private func endBackgroundSave() {
        guard backgroundSave != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundSave)
        backgroundSave = .invalid
    }

    private func save(debounce: Bool = false) {
        guard let store else { return }
        revision += 1
        let writeRevision = revision
        let snapshot = library
        let referenced = snapshot.photoIDs
        let photos = pendingPhotos.filter { referenced.contains($0.key) }
        pendingPhotos = photos
        saveTask?.cancel()
        saveTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(170)) }
            guard !Task.isCancelled else { return }
            do {
                try await store.save(snapshot, photos: photos, revision: writeRevision)
                if revision == writeRevision {
                    pendingPhotos.removeAll()
                    storageError = nil
                    refreshReminders(ask: askForReminderPermission)
                    askForReminderPermission = false
                }
            } catch {
                if revision == writeRevision { self.storageError = L.t("error.save") }
            }
            if revision == writeRevision { endBackgroundSave() }
        }
    }

    func loadProducts(showFailure: Bool = true) async {
        guard !testing, !freePeriod, products.count < 2, !storeBusy else { return }
        storeBusy = true
        defer { storeBusy = false }
        do {
            products = try await Product.products(for: [proID, trialID])
            if showFailure && products.isEmpty { purchaseMessage = L.t("error.products") }
        } catch {
            if showFailure { self.purchaseMessage = L.t("error.products") }
        }
    }

    func purchase(_ id: String) async {
        guard !storeBusy else { return }
        purchaseMessage = nil
        if testing {
            applyVerified(pro: id == proID ? true : nil, trial: id == trialID ? now : nil)
            purchaseMessage = L.t(id == proID ? "pay.unlocked" : "pay.trialClaimed")
            return
        }
        if products.first(where: { $0.id == id }) == nil { await loadProducts() }
        guard let product = products.first(where: { $0.id == id }) else {
            purchaseMessage = L.t("error.products")
            return
        }
        storeBusy = true
        defer { storeBusy = false }

        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                accept(transaction)
                await transaction.finish()
                purchaseMessage = L.t(id == proID ? "pay.unlocked" : "pay.trialClaimed")
            case .success(.unverified):
                purchaseMessage = L.t("error.verification")
            case .pending:
                purchaseMessage = L.t("pay.pending")
            case .userCancelled:
                purchaseMessage = L.t("pay.cancelled")
            @unknown default:
                purchaseMessage = L.t("error.purchase")
            }
        } catch {
            self.purchaseMessage = L.t("error.purchase")
        }
    }

    func restore() async {
        guard !storeBusy, !restoring else { return }
        purchaseMessage = nil
        if testing {
            if environment["BLURTING_RESTORE_PRO"] == "1" { applyVerified(pro: true, trial: nil) }
            purchaseMessage = L.t(entitlement.purchasedPro ? "pay.restored" : "pay.nothing")
            return
        }
        restoring = true
        storeBusy = true
        defer { restoring = false; storeBusy = false }
        do {
            try await AppStore.sync()
            while refreshing && !Task.isCancelled { try await Task.sleep(for: .milliseconds(60)) }
            await refreshPurchases(force: true)
            purchaseMessage = L.t(entitlement.purchasedPro || entitlement.trialClaimedAt != nil ? "pay.restored" : "pay.nothing")
        } catch {
            self.purchaseMessage = L.t("error.restore")
        }
    }

    private func listenForPurchases() {
        transactionTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                if case .verified(let transaction) = result,
                   [self.proID, self.trialID].contains(transaction.productID) {
                    self.accept(transaction)
                    await transaction.finish()
                }
            }
        }
        Task { await refreshPurchases() }
    }

    private func refreshPurchases(force: Bool = false) async {
        if refreshing || (restoring && !force) { return }
        refreshing = true
        defer { refreshing = false }
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result { accept(transaction) }
        }
        if let result = await StoreKit.Transaction.latest(for: proID),
           case .verified(let transaction) = result, transaction.revocationDate != nil {
            accept(transaction)
        }
    }

    private func accept(_ transaction: StoreKit.Transaction) {
        if transaction.productID == proID {
            applyVerified(pro: transaction.revocationDate == nil, trial: nil)
        } else if transaction.productID == trialID, transaction.revocationDate == nil {
            applyVerified(pro: nil, trial: transaction.originalPurchaseDate)
        }
    }

    private func applyVerified(pro: Bool?, trial: Date?) {
        var updated = entitlement
        updated.applyVerified(pro: pro, trialDate: trial)
        guard updated != entitlement else { return }
        entitlement = updated
        refreshReminders()
        paidRevision += 1
        let writeRevision = paidRevision
        if let store {
            Task {
                guard writeRevision == paidRevision else { return }
                do {
                    try await store.saveEntitlement(updated, testing: testing)
                } catch {
                    self.purchaseMessage = L.t("error.save")
                }
            }
        }
    }

    private func seedDemo() {
        let note = Example.noteForScreenshots(at: now)
        library = Library(notes: [note], lastNoteID: note.id)
        let calendar = Calendar.current
        let lastDay = Launch.value("-screen", in: arguments) == "review-due" ? 1 : 0
        for (days, misses) in [(9, 9), (6, 7), (3, 6), (lastDay, 3)] {
            let date = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            guard var draft = library.start(noteID: note.id, at: date) else { continue }
            draft.answer = L.t("example.answer")
            draft.phase = .comparing
            let indexes = misses == 3 ? [3, 6, 14] : Array(0..<misses)
            draft.missed = Set(indexes.map { note.points[$0].id })
            library.drafts[note.id] = draft
            _ = library.finish(noteID: note.id, draftID: draft.id, at: date, pro: true)
        }
    }
}
