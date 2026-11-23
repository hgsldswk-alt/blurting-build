import Charts
import SwiftUI
import UIKit

@MainActor
struct RecallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var writing: Bool
    @State private var announced = false
    @State private var recognizing = false
    let draft: RecallDraft
    let reveal: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextButton(title: L.t("recall.exit"), id: "recall.exit", symbol: "chevron.left") {
                    writing = false
                    model.flush()
                    dismiss()
                }.disabled(recognizing)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let date = model.testing && model.arguments.contains("-demo") ? model.now : model.effectiveDate(timeline.date)
                    timer(draft.secondsRemaining(at: date))
                }
                Spacer()
                if writing {
                    TextButton(title: L.t("action.done"), id: "recall.keyboardDone") { writing = false }
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }
            TextButton(title: L.t(draft.paper == nil ? "paper.mode" : "paper.typeInstead"),
                       id: "recall.paper", symbol: draft.paper == nil ? "pencil.line" : "keyboard") {
                writing = false
                model.setPaperMode(draft.paper == nil, for: draft.noteID)
            }.disabled(recognizing)
            if draft.paper == nil {
                typedPaper
                PaperButton(title: L.t("recall.reveal"), id: "recall.reveal", primary: true) {
                    writing = false
                    reveal()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    PageHeading(title: L.t("paper.mode"), subtitle: L.t("paper.instructions"))
                    Spacer(minLength: 0)
                }.padding(15).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).paperCard()
                if recognizing {
                    ProgressView(L.t("paper.recognizing"))
                } else {
                    PaperPhotoControls(remaining: 3, primary: true, receive: scan)
                    TextButton(title: L.t("paper.manual"), id: "paper.manual") {
                        if model.comparePaper(draft, photos: [], recognized: "") { reveal() }
                    }
                }
            }
        }
        .padding(.horizontal, 21).padding(.bottom, 12)
        .paperPage()
        .task {
            guard draft.paper == nil, !model.testing || !model.arguments.contains("-demo") else { return }
            writing = true
        }
    }

    private var typedPaper: some View {
        ZStack(alignment: .topLeading) {
            if draft.answer.isEmpty {
                Text(L.t("recall.placeholder")).foregroundStyle(Paper.muted)
                    .padding(.horizontal, 13).padding(.top, 15)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
            TextEditor(text: Binding(
                get: { model.library.drafts[draft.noteID]?.answer ?? draft.answer },
                set: { model.setAnswer($0, noteID: draft.noteID) }
            ))
            .focused($writing)
            .autocorrectionDisabled()
            .padding(8).scrollContentBackground(.hidden)
            .accessibilityLabel(L.t("recall.answer"))
            .accessibilityIdentifier("recall.answer")
        }
        .frame(maxHeight: .infinity).paperCard()
    }

    private func scan(_ photos: [Data]) {
        recognizing = true
        Task {
            let content = draft.points.map(\.text).joined(separator: "\n")
            let answer = await PaperOCR.recognize(photos, language: PaperLanguage.infer(from: content))
            if model.comparePaper(draft, photos: photos, recognized: answer) {
                reveal()
            }
            recognizing = false
        }
    }

    private func timer(_ seconds: Int) -> some View {
        VStack(spacing: 2) {
            Text(L.t("recall.time", seconds / 60, seconds % 60))
                .font(.system(.title, design: .monospaced).weight(.semibold)).monospacedDigit()
                .accessibilityIdentifier("recall.timer")
            Text(L.t(seconds == 0 ? "recall.elapsed" : "recall.remaining"))
                .font(.caption2).foregroundStyle(seconds == 0 ? Paper.mark : Paper.muted)
                .multilineTextAlignment(.center)
        }
        .onChange(of: seconds, initial: true) { _, remaining in
            if remaining == 0 && !announced {
                announced = true
                if !model.testing { UIAccessibility.post(notification: .announcement, argument: L.t("recall.elapsed")) }
            }
        }
    }
}

@MainActor
struct CompareView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var recognizing = false
    @State private var addPhotos = false
    let note: Note
    let draft: RecallDraft
    let finish: () -> Void

    private var firstPrior: UUID? { draft.points.first { draft.priorMissed.contains($0.id) }?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PageBack()
                Text(note.title).font(.footnote).foregroundStyle(Paper.muted).lineLimit(1).layoutPriority(1)
            }
            PageHeading(title: L.t("compare.title"), subtitle: L.t(draft.paper == nil ? "compare.subtitle" : "paper.compareHint"))
            if draft.needsBlankConfirmation && !draft.confirmedBlank {
                PaperButton(title: L.t("compare.blank"), id: "compare.blank") { model.confirmBlank(note.id) }
            }
            if draft.paper != nil && draft.isBlank {
                Text(L.t("paper.noText")).font(.footnote).foregroundStyle(Paper.mark)
                    .accessibilityIdentifier("paper.noText")
            }
            if typeSize.isAccessibilitySize {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            answerColumn(stacked: true)
                            originalColumn(stacked: true, proxy: proxy)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    answerColumn(stacked: false)
                    ScrollViewReader { proxy in
                        originalColumn(stacked: false, proxy: proxy)
                    }
                }
            }
            HStack {
                Text(L.t("compare.misses", draft.missed.count)).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Paper.mark).accessibilityIdentifier("compare.missCount")
                Spacer()
                if draft.canFinish {
                    Text(L.t("score.count", draft.points.count - draft.missed.count, draft.points.count))
                        .font(.footnote).foregroundStyle(Paper.muted)
                }
            }
            PaperButton(title: L.t("compare.finish"), id: "compare.finish", primary: true, action: finish)
                .disabled(!draft.canFinish || recognizing).opacity(draft.canFinish ? 1 : 0.55)
        }
        .padding(.horizontal, 21).padding(.bottom, 12)
        .paperPage()
    }

    private func answerColumn(stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            columnTitle(L.t(draft.paper == nil ? "compare.answer" : "paper.recognized"))
            if stacked {
                paperAnswer
            } else {
                ScrollView { paperAnswer }
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).paperCard()
    }

    private var paperAnswer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draft.isBlank || draft.paper == nil {
                Text(draft.isBlank ? L.t("compare.emptyAnswer") : draft.answer)
                    .font(.subheadline).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("compare.answer")
            }
            if let paper = draft.paper, paper.photoIDs.count < 3 {
                if recognizing {
                    ProgressView().accessibilityLabel(L.t("paper.recognizing"))
                } else if addPhotos {
                    PaperPhotoControls(remaining: 3 - paper.photoIDs.count, receive: append)
                } else {
                    TextButton(title: L.t("paper.addPhotos"), id: "compare.addPhotos", symbol: "plus") {
                        addPhotos = true
                    }
                }
            }
        }
    }

    private func append(_ photos: [Data]) {
        addPhotos = false
        recognizing = true
        Task {
            let content = draft.points.map(\.text).joined(separator: "\n")
            let answer = await PaperOCR.recognize(photos, language: PaperLanguage.infer(from: content))
            model.comparePaper(draft, photos: photos, recognized: answer)
            recognizing = false
        }
    }

    private func originalColumn(stacked: Bool, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            columnTitle(L.t("compare.original", draft.points.count))
            if let firstPrior {
                TextButton(title: L.t("compare.prior"), id: "compare.prior", symbol: "arrow.down.to.line") {
                    withAnimation { proxy.scrollTo(firstPrior, anchor: .top) }
                }
            }
            if stacked {
                pointRows
            } else {
                ScrollView { pointRows }
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8).paperCard()
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pointRows: some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(Array(draft.points.enumerated()), id: \.element.id) { index, point in
                let marked = draft.missed.contains(point.id)
                Button {
                    model.toggle(point.id, in: note.id)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: marked ? "checkmark.square.fill" : (draft.paper == nil ? "squareshape" : "checkmark.circle"))
                            .foregroundStyle(marked ? Paper.mark : Paper.muted)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(point.text)
                            if marked {
                                Text(L.t("compare.missed")).font(.caption2.weight(.semibold)).foregroundStyle(Paper.mark)
                            } else if draft.paper != nil {
                                Text(L.t("paper.recalled")).font(.caption2).foregroundStyle(Paper.muted)
                            } else if draft.priorMissed.contains(point.id) {
                                Text(L.t("compare.wasMissed")).font(.caption2).foregroundStyle(Paper.muted)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .multilineTextAlignment(.leading).font(.footnote)
                    .padding(6).frame(minHeight: 44)
                    .background(marked ? Paper.missed : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(draft.needsBlankConfirmation)
                .accessibilityLabel(point.text)
                .accessibilityValue(marked ? L.t("compare.missed") : L.t(draft.paper == nil ? "compare.unmarked" : "paper.recalled"))
                .accessibilityIdentifier("compare.point.\(index)")
                .id(point.id)
            }
        }
    }
}

@MainActor
struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    let session: RecallSession
    let navigate: (Route) -> Void
    let home: () -> Void
    private let readingTimer = URL(string: "https://apps.apple.com/us/app/book-reading-timer/id6837217650")!

    var body: some View {
        PaperScroll {
            TextButton(title: L.t("nav.home"), id: "result.home", symbol: "chevron.left", action: home)
            PageHeading(title: L.t("result.title"), subtitle: model.library.notes.first { $0.id == session.noteID }?.title)
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("score.selfRated")).font(.footnote).foregroundStyle(Paper.muted)
                Text(L.t("score.percent", session.coverage)).font(.system(.largeTitle, design: .serif))
                    .accessibilityIdentifier("result.coverage")
                Text(L.t("score.count", session.recalled, session.points.count)).font(.subheadline)
                if session.queuedCount > 0 {
                    Divider()
                    HStack {
                        Text(L.t("result.queued", session.queuedCount)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(L.t("result.tomorrow")).font(.caption).foregroundStyle(Paper.muted)
                    }
                }
                if let due = session.nextChapterReview {
                    Text(L.t("result.nextReview", due.formatted(date: .abbreviated, time: .omitted)))
                        .font(.footnote).foregroundStyle(Paper.muted)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).paperCard()
            if !session.milestones.isEmpty {
                Text(L.t("milestone.title")).font(.headline)
                ForEach(session.milestones) { item in
                    PaperRow(title: item.label, id: "result.milestone.\(item.rawValue)",
                             subtitle: L.t("milestone.card"), icon: "rosette") { navigate(.share(.milestone(item))) }
                        .paperCard()
                }
            }
            PaperButton(title: L.t("share.preview"), id: "result.share", primary: true) {
                navigate(.share(.score(session.coverage)))
            }
            Link(L.t("result.readNext"), destination: readingTimer)
                .font(.footnote.weight(.semibold)).frame(minHeight: 44)
                .accessibilityIdentifier("result.readNext")
        }
    }
}

@MainActor
struct TrendView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: RecallSession?
    @State private var selectedNote: Note?
    let note: Note
    let start: (Note) -> Void
    let upgrade: () -> Void

    private var chapter: Note { selectedNote.flatMap { selected in model.library.notes.first { $0.id == selected.id } } ?? note }
    private var all: [RecallSession] { model.library.history(for: chapter.id) }
    private var current: [RecallSession] { all.filter { $0.version == chapter.version } }

    var body: some View {
        PaperScroll {
            PageBack()
            PageHeading(title: chapter.subject.isEmpty ? L.t("trend.history") : chapter.subject, subtitle: L.t("trend.subtitle"))
            if model.hasPro { chapterMenu }
            if model.hasPro, let latest = current.first {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L.t("score.selfRated")).font(.headline)
                    Text(L.t("score.percent", latest.coverage)).font(.system(.largeTitle, design: .serif))
                    Text(L.t("score.count", latest.recalled, latest.points.count)).font(.footnote).foregroundStyle(Paper.muted)
                    chart
                }.padding(14).paperCard()
            } else if model.hasPro {
                Text(L.t("trend.empty")).font(.footnote).foregroundStyle(Paper.muted)
            } else {
                PaperRow(title: L.t("trend.pro"), id: "trend.pro", icon: "chart.xyaxis.line", action: upgrade).paperCard()
            }

            if !all.isEmpty {
                Text(L.t("trend.history")).font(.headline)
                historyRows
            } else if !model.hasPro {
                Text(L.t("trend.empty")).font(.footnote).foregroundStyle(Paper.muted)
            }
            if model.library.canStart(chapter, pro: model.hasPro) {
                PaperButton(title: L.t(model.library.drafts[chapter.id] == nil ? "recall.start" : "recall.resume"),
                            id: "trend.start", primary: true) { start(chapter) }
            }
        }
        .sheet(item: $selected) { session in
            PaperScroll {
                PageBack()
                PageHeading(title: chapter.title, subtitle: session.completed.formatted(date: .abbreviated, time: .shortened))
                Text(L.t("score.count", session.recalled, session.points.count)).font(.headline)
                Text(L.t("compare.answer")).font(.headline)
                Text(Outline.clean(session.answer).isEmpty ? L.t("compare.emptyAnswer") : session.answer)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).paperCard()
                if let photos = session.paperPhotoIDs, !photos.isEmpty {
                    Text(L.t("paper.history")).font(.headline)
                    ForEach(Array(photos.enumerated()), id: \.element) { index, id in
                        PaperPhotoPreview(id: id, index: index + 1)
                    }
                }
                ForEach(session.points) { point in
                    Label(point.text, systemImage: session.missed.contains(point.id) ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(session.missed.contains(point.id) ? Paper.mark : Paper.ink)
                        .padding(8)
                }
            }
        }
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(model.library.recentNotes.filter { $0.subject == chapter.subject }) { candidate in
                Button(candidate.title) { selectedNote = candidate }
            }
        } label: {
            HStack {
                Text(chapter.title).font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.down").accessibilityHidden(true)
            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle()).paperCard()
        }
        .accessibilityIdentifier("trend.chapter")
    }

    private var chart: some View {
        Chart {
            ForEach(Array(current.reversed())) { session in
                LineMark(x: .value(L.t("trend.date"), session.completed),
                         y: .value(L.t("score.selfRated"), session.coverage))
                    .foregroundStyle(Paper.muted)
                PointMark(x: .value(L.t("trend.date"), session.completed),
                          y: .value(L.t("score.selfRated"), session.coverage))
                    .foregroundStyle(session.id == current.first?.id ? Paper.mark : Paper.muted)
                    .accessibilityLabel(Text(session.completed.formatted(date: .abbreviated, time: .shortened)))
                    .accessibilityValue(Text(L.t("score.percent", session.coverage)))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text(L.t("score.percent", percent)) }
                }
            }
        }
        .frame(height: 154)
        .accessibilityIdentifier("trend.chart")
    }

    private var historyRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(all.enumerated()), id: \.element.id) { index, session in
                if index > 0 { Divider() }
                PaperRow(title: session.completed.formatted(date: .abbreviated, time: .omitted),
                         id: "trend.session.\(index)",
                         subtitle: session.version == chapter.version ? nil : L.t("trend.older"),
                         accessory: "") { selected = session }
                .overlay(alignment: .trailing) {
                    Text(L.t("score.summary", session.recalled, session.points.count, session.coverage))
                        .font(.caption.weight(.semibold)).padding(.trailing, 12)
                        .allowsHitTesting(false)
                }
            }
        }.paperCard()
    }
}
