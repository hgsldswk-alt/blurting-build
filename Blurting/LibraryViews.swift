import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let navigate: (Route) -> Void
    let start: (Note) -> Void
    @Binding var durationOpen: Bool
    private var current: Note? { model.library.homeNote(pro: model.hasPro) }

    var body: some View {
        let due = model.dueNotes
        PaperScroll {
            HStack {
                Brand()
                Spacer()
                if !model.freePeriod {
                    TextButton(title: L.t("pay.pro"), id: "home.pro") { navigate(.paywall) }
                }
            }
            if let next = due.first {
                PaperRow(title: L.t("home.reviewToday", due.count), id: "home.reviewToday",
                         subtitle: next.title, icon: "calendar.badge.clock", accessory: "play") { start(next) }
                    .paperCard()
            } else {
                Label(L.t("home.reviewToday", 0), systemImage: "calendar")
                    .font(.footnote).foregroundStyle(Paper.muted)
                    .accessibilityIdentifier("home.reviewToday.empty")
            }
            if let current { recallSheet(current) } else { welcome }
            if !model.freePeriod && !model.entitlement.purchasedPro { disclosure }
            VStack(spacing: 0) {
                PaperRow(title: L.t("home.new"), id: "home.new", icon: "doc.badge.plus") { newNote() }
                Divider()
                PaperRow(title: L.t("nav.notes"), id: "home.notes", icon: "books.vertical") { navigate(.notes) }
                Divider()
                PaperRow(title: L.t("nav.review"), id: "home.review", icon: "arrow.clockwise") { navigate(.review) }
                Divider()
                PaperRow(title: L.t("reminder.settings"), id: "home.settings", icon: "bell") { navigate(.settings) }
            }
            .paperCard()
            HStack {
                TextButton(title: L.t("import.title"), id: "home.import") {
                    navigate(model.hasPro ? .importCode : .paywall)
                }
                Spacer()
                TextButton(title: L.t("milestone.title"), id: "home.milestones") { navigate(.milestones) }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(L.t("home.title")).font(.system(.largeTitle, design: .serif)).accessibilityAddTraits(.isHeader)
            Text(L.t("home.welcome")).font(.subheadline).foregroundStyle(Paper.muted)
            PaperButton(title: L.t("home.example"), id: "home.example", symbol: "arrow.right", primary: true) {
                let note = Example.note(at: model.now)
                model.add(note)
                start(note)
            }
        }.padding(17).paperCard()
    }

    private func recallSheet(_ note: Note) -> some View {
        let latest = model.library.history(for: note.id).first
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.t("home.continueLabel")).font(.footnote.weight(.semibold)).foregroundStyle(Paper.muted)
                Spacer()
                Button {
                    durationOpen = true
                } label: {
                    Label(L.t("home.minutes", note.minutes), systemImage: "timer")
                        .font(.footnote.weight(.semibold)).padding(.horizontal, 8)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(Paper.background, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.duration")
                .confirmationDialog(L.t("home.durationTitle"), isPresented: $durationOpen, titleVisibility: .visible) {
                    ForEach([3, 5, 10, 20], id: \.self) { minutes in
                        Button(L.t("home.minutes", minutes)) { model.setDuration(minutes, for: note) }
                    }
                }
            }
            Text(L.t("home.title")).font(.system(.largeTitle, design: .serif)).accessibilityAddTraits(.isHeader)
            Text(note.subject.isEmpty ? note.title : L.t("note.subjectChapter", note.subject, note.title))
                .font(.subheadline).foregroundStyle(Paper.muted).accessibilityIdentifier("home.chapter")
            PaperButton(title: model.library.drafts[note.id] == nil ? L.t("recall.start") : L.t("recall.resume"),
                        id: "home.start", symbol: "arrow.right", primary: true) { start(note) }
            if let latest {
                Divider().padding(.top, 3)
                HStack {
                    Text(L.t("home.lastCoverage")).font(.footnote).foregroundStyle(Paper.muted)
                    Spacer()
                    Text(L.t("score.percent", latest.coverage)).font(.system(.title, design: .serif))
                }
            }
        }
        .padding(17).paperCard()
        .background {
            RoundedRectangle(cornerRadius: 16).fill(Paper.background)
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Paper.line) }
                .padding(.horizontal, 6).offset(y: 5)
        }
        .padding(.bottom, 4)
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.hasPro ? L.t("pay.days", model.remainingDays) : L.t("pay.expired"))
                .font(.footnote.weight(.semibold))
            Text(L.t("pay.basic")).font(.footnote).foregroundStyle(Paper.muted)
            Text(model.proPrice.map { L.t("pay.onePrice", $0) } ?? L.t("pay.oneTime"))
                .font(.footnote).foregroundStyle(Paper.muted)
        }.padding(.horizontal, 2)
    }

    private func newNote() { navigate(model.canCreate ? .editor(nil) : .paywall) }
}

@MainActor
struct NotesView: View {
    @EnvironmentObject private var model: AppModel
    let navigate: (Route) -> Void
    let start: (Note) -> Void

    private var subjects: [String] {
        Array(Set(model.library.recentNotes.map(\.subject))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        PaperScroll {
            PageBack(title: L.t("nav.home"))
            PageHeading(title: L.t("nav.notes"))
            HStack(spacing: 8) {
                PaperButton(title: L.t("home.new"), id: "notes.new") { navigate(model.canCreate ? .editor(nil) : .paywall) }
                PaperButton(title: L.t("file.import"), id: "notes.importFile") { navigate(model.hasPro ? .importFile : .paywall) }
            }
            if model.library.notes.isEmpty {
                Text(L.t("note.empty")).font(.subheadline).foregroundStyle(Paper.muted)
            } else {
                if model.hasPro {
                    Text(L.t("note.subjects")).font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(subjects.enumerated()), id: \.element) { index, subject in
                            if index > 0 { Divider() }
                            PaperRow(title: subject.isEmpty ? L.t("note.ungrouped") : subject,
                                     id: "notes.subject.\(index)", icon: "folder") { navigate(.subject(subject)) }
                        }
                    }.paperCard()
                }
                Text(L.t("note.chapters")).font(.headline)
                ForEach(Array(model.library.recentNotes.enumerated()), id: \.element.id) { index, note in
                    row(note, index: index)
                }
            }
        }
    }

    private func row(_ note: Note, index: Int) -> some View {
        let available = model.library.canStart(note, pro: model.hasPro)
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                PaperRow(title: note.title, id: "notes.detail.\(index)",
                         subtitle: note.subject.isEmpty ? nil : note.subject, accessory: "") { navigate(.note(note.id)) }
                if available {
                    TextButton(title: L.t(model.library.drafts[note.id] == nil ? "action.start" : "action.resume"),
                               id: "notes.start.\(index)") { start(note) }
                    .padding(.trailing, 8)
                } else {
                    Menu {
                        ForEach(model.library.freeIDs, id: \.self) { id in
                            if let victim = model.library.notes.first(where: { $0.id == id }) {
                                Button(L.t("note.replaceName", victim.title)) { model.replaceFreeNote(id, with: note.id) }
                            }
                        }
                    } label: {
                        Text(L.t("note.useFree")).font(.caption.weight(.semibold)).foregroundStyle(Paper.mark)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("notes.useFree.\(index)")
                    .padding(.trailing, 8)
                }
            }
        }.paperCard()
    }
}

@MainActor
struct NoteDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var code: String?
    @State private var export: OutlineDocument?
    @State private var showingExport = false
    let note: Note
    let navigate: (Route) -> Void
    let start: (Note) -> Void
    let remove: () -> Void

    var body: some View {
        PaperScroll {
            PageBack(title: L.t("nav.notes"))
            PageHeading(title: note.title, subtitle: note.subject.isEmpty ? nil : note.subject)
            if model.library.canStart(note, pro: model.hasPro) {
                PaperButton(title: L.t(model.library.drafts[note.id] == nil ? "recall.start" : "recall.resume"),
                            id: "detail.start", primary: true) { start(note) }
            }
            VStack(spacing: 0) {
                PaperRow(title: L.t("trend.history"), id: "detail.history") { navigate(.trend(note.id)) }
                if !note.isExample {
                    Divider()
                    PaperRow(title: L.t("note.edit"), id: "detail.edit") { navigate(.editor(note.id)) }
                }
                Divider()
                PaperRow(title: L.t("code.copy"), id: "detail.code",
                         subtitle: L.t("code.privateNote"), accessory: "doc.on.doc") { makeCode() }
                Divider()
                PaperRow(title: L.t("file.export"), id: "detail.file", accessory: "square.and.arrow.up") { exportFile() }
            }.paperCard()
            if let message { Text(message).font(.footnote).foregroundStyle(Paper.mark).accessibilityIdentifier("detail.message") }
            if model.hasPro, let code {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("code.preview")).font(.headline)
                    Text(L.t("code.privateNote")).font(.footnote).foregroundStyle(Paper.muted)
                    Text(code).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    PaperButton(title: L.t("action.copy"), id: "detail.copyCode") {
                        UIPasteboard.general.string = code
                        message = L.t("code.copied")
                        self.code = nil
                    }
                }.padding(12).paperCard()
            }
            if !Outline.clean(note.source).isEmpty {
                Text(L.t("note.savedSource")).font(.headline)
                Text(note.source).textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading).paperCard()
            }
            Text(L.t("note.points", note.points.count)).font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(note.points.enumerated()), id: \.element.id) { index, point in
                    if index > 0 { Divider() }
                    Text(point.text).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.paperCard()
            TextButton(title: L.t("action.delete"), id: "detail.delete", symbol: "trash") { confirmDelete = true }
        }
        .alert(L.t("note.deleteTitle"), isPresented: $confirmDelete) {
            Button(L.t("action.delete"), role: .destructive, action: remove)
            Button(L.t("action.cancel"), role: .cancel) {}
        } message: { Text(L.t("note.deleteBody")) }
        .fileExporter(isPresented: $showingExport, document: export, contentType: .json,
                      defaultFilename: safeFilename) { result in
            if case .failure = result { message = L.t("error.export") }
        }
    }

    private var safeFilename: String {
        String(note.title.replacingOccurrences(of: "/", with: "-").prefix(60))
    }

    private func transfer() throws -> OutlineTransfer {
        try OutlineTransfer(title: note.title, points: note.points.map(\.text))
    }

    private func makeCode() {
        guard model.hasPro else { navigate(.paywall); return }
        message = nil
        do { code = try transfer().code() }
        catch OutlineIssue.tooLong { message = L.t("code.useFile") }
        catch { message = L.t("error.export") }
    }

    private func exportFile() {
        guard model.hasPro else { navigate(.paywall); return }
        do {
            export = OutlineDocument(data: try transfer().file())
            if model.testing {
                message = L.t("file.ready")
            } else {
                showingExport = true
            }
        } catch {
            message = L.t("error.export")
        }
    }
}

@MainActor
struct SubjectView: View {
    @EnvironmentObject private var model: AppModel
    let subject: String
    let navigate: (Route) -> Void
    var body: some View {
        PaperScroll {
            PageBack(title: L.t("nav.notes"))
            PageHeading(title: subject.isEmpty ? L.t("note.ungrouped") : subject, subtitle: L.t("trend.subtitle"))
            ForEach(Array(model.library.recentNotes.filter { $0.subject == subject }.enumerated()), id: \.element.id) { index, note in
                let latest = model.library.history(for: note.id, version: note.version).first
                PaperRow(title: note.title, id: "subject.trend.\(index)",
                         subtitle: latest.map { L.t("score.percent", $0.coverage) } ?? L.t("trend.empty")) {
                    navigate(.trend(note.id))
                }.paperCard()
            }
        }
    }
}

@MainActor
struct ReviewQueueView: View {
    @EnvironmentObject private var model: AppModel
    let start: (Note) -> Void
    let upgrade: () -> Void

    private var upcoming: [(note: Note, date: Date)] { model.reviewNotes.filter { $0.date > model.now } }

    var body: some View {
        PaperScroll {
            PageBack(title: L.t("nav.home"))
            PageHeading(title: L.t("nav.review"), subtitle: L.t("review.subtitle"))
            if model.dueNotes.isEmpty { Text(L.t("review.empty")).font(.subheadline).foregroundStyle(Paper.muted) }
            ForEach(Array(model.dueNotes.enumerated()), id: \.element.id) { index, note in
                let points = model.library.due(for: note.id, at: model.now).count
                PaperRow(title: note.title, id: "review.start.\(index)",
                         subtitle: points > 0 ? L.t("home.due", points) : nil,
                         accessory: "play") { start(note) }.paperCard()
            }
            if !upcoming.isEmpty {
                Text(L.t("review.upcoming")).font(.headline)
                ForEach(upcoming.map(\.note)) { note in
                    if let date = model.library.nextReview(for: note.id) {
                        HStack {
                            Text(note.title)
                            Spacer()
                            Text(date, format: .dateTime.month().day()).foregroundStyle(Paper.muted)
                        }.padding(12).paperCard()
                    }
                }
            }
            if !model.hasPro && model.library.notes.contains(where: {
                !model.library.canStart($0, pro: false) && model.library.nextReview(for: $0.id) != nil
            }) {
                Text(L.t("review.locked")).font(.subheadline)
                PaperButton(title: L.t("pay.pro"), id: "review.pro", primary: true, action: upgrade)
            }
        }
    }
}
