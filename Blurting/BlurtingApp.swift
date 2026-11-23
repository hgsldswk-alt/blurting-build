import StoreKit
import SwiftUI
import UIKit

@main
struct BlurtingApp: App {
    var body: some Scene {
        WindowGroup { BlurtingRoot().preferredColorScheme(.light).tint(Paper.mark) }
    }
}

enum Route: Hashable {
    case editor(UUID?)
    case prefilledEditor(NewNoteLink)
    case notes, note(UUID), subject(String), trend(UUID)
    case review, recall(UUID), compare(UUID), result(UUID)
    case importCode, importFile, paywall, milestones
    case settings
    case share(ShareContent)
}

@MainActor
struct BlurtingRoot: View {
    @StateObject private var model = AppModel()
    @State private var path: [Route] = []
    @State private var readyForLaunchRoute = false
    @State private var reviewRequested = false
    @State private var durationOpen = false
    @State private var pendingLink: NewNoteLink?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.ready {
                    HomeView(navigate: navigate, start: start, durationOpen: $durationOpen)
                } else if let message = model.storageError {
                    VStack(spacing: 16) {
                        Text(message)
                        PaperButton(title: L.t("action.retry"), id: "store.reopen", primary: true) {
                            Task { await prepare() }
                        }
                    }.padding(24)
                } else {
                    ProgressView(L.t("app.loading"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .paperPage()
            .navigationDestination(for: Route.self, destination: destination)
        }
        .environmentObject(model)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.ready, let message = model.storageError {
                HStack {
                    Text(message).font(.footnote)
                    Spacer()
                    TextButton(title: L.t("action.retry"), id: "store.retry") { model.flush() }
                }.padding(.horizontal, 14).background(Paper.missed)
            }
        }
        .task { await prepare() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled, scenePhase == .active { model.recordUse() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.recordUse()
                model.refreshReminders(force: true)
            }
            if phase != .active { model.flush(leavingForeground: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            model.recordUse()
            model.refreshReminders(force: true)
        }
        .onOpenURL { url in
            if let link = NewNoteLink(url: url) { openLink(link) }
        }
        .task(id: canReview) {
            guard canReview else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, canReview else { return }
            model.markReviewRequested(model.version)
            if model.testing {
                reviewRequested = true
            } else {
                requestReview()
            }
        }
        .overlay(alignment: .bottom) {
            if model.testing, reviewRequested, path.isEmpty {
                Text(L.t("rating.requested")).font(.caption)
                    .padding(5).background(Paper.background)
                    .accessibilityIdentifier("rating.requested")
                    .allowsHitTesting(false)
            }
        }
    }

    private var canReview: Bool {
        model.ready && model.storageError == nil &&
        !(model.testing && model.arguments.contains("-demo")) &&
        model.library.reviewPrompt.shouldRequest(version: model.version,
                                                idle: path.isEmpty && scenePhase == .active && !durationOpen)
    }

    private func prepare() async {
        await model.open()
        guard model.ready, !readyForLaunchRoute else { return }
        readyForLaunchRoute = true
        if let pendingLink {
            self.pendingLink = nil
            openLink(pendingLink)
            return
        }
        guard model.testing else { return }
        if model.arguments.contains("-paywall") {
            navigate(.paywall)
            return
        }
        if model.arguments.contains("-demo"), let note = model.library.homeNote(pro: true) {
            switch Launch.value("-screen", in: model.arguments) {
            case "editor": navigate(.editor(nil))
            case "recall":
                start(note)
                model.setAnswer(L.t("example.screenshotAnswer"), noteID: note.id)
            case "compare":
                start(note)
                model.setAnswer(L.t("example.answer"), noteID: note.id)
                model.reveal(note.id)
                for index in [3, 6, 14] { model.toggle(note.points[index].id, in: note.id) }
                path = [.compare(note.id)]
            case "paper":
                start(note)
                model.setPaperMode(true, for: note.id)
                if let draft = model.library.drafts[note.id] {
                    model.comparePaper(draft, photos: [], recognized: L.t("example.answer"))
                }
                path = [.compare(note.id)]
            case "trend": navigate(.trend(note.id))
            default: break
            }
        }
    }

    private func navigate(_ route: Route) { path.append(route) }

    private func openLink(_ link: NewNoteLink) {
        guard model.ready else { pendingLink = link; return }
        let route = Route.prefilledEditor(link)
        if path.last != route { navigate(route) }
    }

    private func start(_ note: Note) {
        guard let draft = model.start(note) else { navigate(.paywall); return }
        navigate(draft.phase == .writing ? .recall(note.id) : .compare(note.id))
    }

    private func reveal(_ id: UUID) {
        guard path.last == .recall(id) else { return }
        model.reveal(id)
        if !path.isEmpty { path.removeLast() }
        path.append(.compare(id))
    }

    private func finish(_ draft: RecallDraft) {
        guard let result = model.finish(draft) else { return }
        path = [.result(result.id)]
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .editor(let id):
            let note = model.library.notes.first { $0.id == id }
            NoteEditor(note: note) { saved in
                if note != nil {
                    model.update(saved)
                    path.removeLast()
                } else {
                    saveNew(saved)
                }
            }
        case .prefilledEditor(let link):
            NoteEditor(note: nil, prefill: link, save: saveNew)
        case .notes: NotesView(navigate: navigate, start: start)
        case .note(let id):
            if let note = model.library.notes.first(where: { $0.id == id }) {
                NoteDetail(note: note, navigate: navigate, start: start) {
                    path.removeLast()
                    model.delete(id)
                }
            }
        case .subject(let subject): SubjectView(subject: subject, navigate: navigate)
        case .trend(let id):
            if let note = model.library.notes.first(where: { $0.id == id }) {
                TrendView(note: note, start: start, upgrade: { navigate(.paywall) })
            }
        case .review: ReviewQueueView(start: start, upgrade: { navigate(.paywall) })
        case .recall(let id):
            if let draft = model.library.drafts[id] {
                RecallView(draft: draft, reveal: { reveal(id) })
            }
        case .compare(let id):
            if let draft = model.library.drafts[id], let note = model.library.notes.first(where: { $0.id == id }) {
                CompareView(note: note, draft: draft, finish: { finish(draft) })
            }
        case .result(let id):
            if let session = model.library.sessions.first(where: { $0.id == id }) {
                ResultView(session: session, navigate: navigate, home: { path.removeAll() })
            }
        case .importCode: ImportView(isFile: false, upgrade: { navigate(.paywall) })
        case .importFile: ImportView(isFile: true, upgrade: { navigate(.paywall) })
        case .paywall: PaywallView()
        case .milestones: MilestonesView(navigate: navigate)
        case .settings: ReviewSettingsView()
        case .share(let content): ShareView(content: content)
        }
    }

    private func saveNew(_ note: Note) {
        guard model.canCreate else { navigate(.paywall); return }
        model.add(note)
        path.removeLast()
        start(note)
    }
}
