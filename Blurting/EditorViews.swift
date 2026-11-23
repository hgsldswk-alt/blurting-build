import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

struct OutlineDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw OutlineIssue.invalid }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct NoteEditor: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focus: Field?
    private enum Field: Hashable { case title, subject, source }
    @State private var title: String
    @State private var subject: String
    @State private var source: String
    @State private var points: [Point]
    @State private var mode: Outline.Mode = .lines
    @State private var issue: OutlineIssue?
    @State private var parseIssue: OutlineIssue?
    @State private var selectedPoint: Point?
    @State private var discarding = false
    @State private var scan = false
    @State private var camera = false
    @State private var fallbackPending = false
    @State private var captured: Data?
    @State private var scanning = false
    @State private var scanError: String?
    @Environment(\.dismiss) private var dismiss
    let note: Note?
    let prefill: NewNoteLink?
    let save: (Note) -> Void

    init(note: Note?, prefill: NewNoteLink? = nil, save: @escaping (Note) -> Void) {
        self.note = note
        self.prefill = prefill
        self.save = save
        _title = State(initialValue: note?.title ?? prefill?.title ?? "")
        _subject = State(initialValue: note?.subject ?? prefill?.subject ?? "")
        _source = State(initialValue: note?.source ?? "")
        _points = State(initialValue: note?.points ?? [])
    }

    var body: some View {
        PaperScroll {
            HStack {
                TextButton(title: L.t("nav.back"), id: "nav.back", symbol: "chevron.left") {
                    if changed { discarding = true } else { dismiss() }
                }
                Spacer()
                if focus != nil {
                    TextButton(title: L.t("action.done"), id: "editor.keyboardDone") { focus = nil }
                }
            }
            PageHeading(title: L.t(note == nil ? "editor.title" : "note.edit"), subtitle: L.t("editor.subtitle"))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) { titleField; subjectField }
                VStack(spacing: 8) { titleField; subjectField }
            }
            if note == nil {
                PaperButton(title: L.t("scan.import"), id: "editor.scan", symbol: "camera.viewfinder") { openScanner() }
                    .disabled(scanning)
                if scanning { ProgressView(L.t("paper.recognizing")) }
                if let scanError {
                    Text(scanError).font(.footnote).foregroundStyle(Paper.mark).accessibilityIdentifier("editor.scanError")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("editor.source")).font(.caption.weight(.semibold)).foregroundStyle(Paper.muted)
                ZStack(alignment: .topLeading) {
                    if source.isEmpty {
                        Text(L.t("editor.placeholder")).foregroundStyle(Paper.muted)
                            .padding(.horizontal, 6).padding(.top, 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    TextEditor(text: $source)
                        .scrollContentBackground(.hidden)
                        .frame(height: 130)
                        .autocorrectionDisabled()
                        .accessibilityLabel(L.t("editor.source"))
                        .accessibilityIdentifier("editor.source")
                        .focused($focus, equals: .source)
                }
                .padding(8).paperCard(10)
            }

            Picker(L.t("editor.split"), selection: $mode) {
                Text(L.t("editor.lines")).tag(Outline.Mode.lines)
                Text(L.t("editor.paragraphs")).tag(Outline.Mode.paragraphs)
            }.pickerStyle(.segmented).accessibilityIdentifier("editor.split")
            if let issue { Text(issue.message).font(.footnote).foregroundStyle(Paper.mark).accessibilityIdentifier("editor.error") }

            HStack {
                Text(L.t("note.points", points.count)).font(.headline)
                Spacer()
                TextButton(title: L.t("editor.add"), id: "editor.add", symbol: "plus") { selectedPoint = Point(text: "") }
            }
            if !points.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if index > 0 { Divider() }
                        PaperRow(title: point.text, id: "editor.point.\(index)") {
                            focus = nil
                            selectedPoint = point
                        }
                    }
                }.paperCard()
                Text(L.t("editor.editHint")).font(.footnote).foregroundStyle(Paper.muted)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaperButton(title: L.t(note == nil ? "editor.saveStart" : "action.save"),
                        id: "editor.save", primary: true) { commit() }
                .disabled(scanning || points.isEmpty || issue == .tooLong)
                .opacity(points.isEmpty || issue == .tooLong ? 0.55 : 1)
                .frame(maxWidth: 600).padding(.horizontal, 21).padding(.vertical, 6)
                .frame(maxWidth: .infinity).background(Paper.background)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: source) { _, _ in parse() }
        .onChange(of: mode) { _, _ in parse() }
        .onChange(of: title) { _, _ in refreshValidation() }
        .onChange(of: subject) { _, _ in refreshValidation() }
        .task {
            if note == nil, model.testing, model.arguments.contains("-demo") {
                let example = Example.note(at: model.now)
                title = example.title
                subject = example.subject
                source = model.environment["BLURTING_NOTE_TEXT"] ?? example.source
                parse()
            }
        }
        .sheet(item: $selectedPoint) { point in
            PointEditor(point: point, canMerge: canMerge(point), save: { update(point, text: $0) },
                        merge: { merge(point, text: $0) }, delete: {
                points.removeAll { $0.id == point.id }
                selectedPoint = nil
                refreshValidation()
            }, editing: points.contains { $0.id == point.id })
        }
        .alert(L.t("editor.discard"), isPresented: $discarding) {
            Button(L.t("action.discard"), role: .destructive) { dismiss() }
            Button(L.t("action.cancel"), role: .cancel) {}
        }
        .fullScreenCover(isPresented: $scan, onDismiss: {
            if fallbackPending {
                fallbackPending = false
                camera = true
            }
        }) {
            BookScanView(language: scanLanguage, useText: {
                appendScan($0)
                scan = false
            }, useCamera: {
                guard scan else { return }
                fallbackPending = true
                scan = false
            })
        }
        .fullScreenCover(isPresented: $camera, onDismiss: recognizePhoto) {
            PhotoCamera { data in
                captured = data
                camera = false
            }.ignoresSafeArea()
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.t("editor.noteTitle")).font(.caption.weight(.semibold)).foregroundStyle(Paper.muted)
            TextField(L.t("editor.noteTitleHint"), text: $title)
                .focused($focus, equals: .title).submitLabel(.next).onSubmit { focus = showsSubject ? .subject : .source }
                .accessibilityIdentifier("editor.title").paperField().frame(minWidth: 130)
        }
    }

    @ViewBuilder private var subjectField: some View {
        if showsSubject {
            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("editor.subject")).font(.caption.weight(.semibold)).foregroundStyle(Paper.muted)
                TextField(L.t("editor.subjectHint"), text: $subject)
                    .focused($focus, equals: .subject).submitLabel(.next).onSubmit { focus = .source }
                    .accessibilityIdentifier("editor.subject").paperField().frame(minWidth: 110)
            }
        }
    }

    private var changed: Bool {
        title != (note?.title ?? prefill?.title ?? "") || subject != (note?.subject ?? prefill?.subject ?? "") ||
        source != (note?.source ?? "") || points != (note?.points ?? [])
    }

    private var showsSubject: Bool { model.hasPro || prefill?.subject.isEmpty == false }

    private var scanLanguage: PaperLanguage { PaperLanguage.infer(from: [source, title].joined(separator: "\n")) }

    private func openScanner() {
        focus = nil
        scanError = nil
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            scanError = L.t("scan.cameraUnavailable")
            return
        }
        scanning = true
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            scanning = false
            guard allowed else { scanError = L.t("scan.cameraDenied"); return }
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable &&
                DataScannerViewController.supportedTextRecognitionLanguages.contains(scanLanguage.rawValue) {
                scan = true
            } else {
                camera = true
            }
        }
    }

    private func recognizePhoto() {
        guard let captured else { return }
        self.captured = nil
        scanning = true
        let language = scanLanguage
        Task {
            let text = await PaperOCR.recognize([captured], language: language)
            appendScan(text)
            scanning = false
        }
    }

    private func appendScan(_ text: String) {
        guard !Outline.clean(text).isEmpty else { scanError = L.t("scan.noText"); return }
        scanError = nil
        mode = .lines
        source = [source, text].filter { !Outline.clean($0).isEmpty }.joined(separator: "\n")
        parse()
    }

    private func parse() {
        parseIssue = nil
        if Outline.clean(source).isEmpty {
            points = []
            refreshValidation()
            return
        }
        do {
            let split = try Outline.split(source, mode: mode)
            var candidates = Dictionary(grouping: points, by: \.text)
            points = split.map { text in
                guard let point = candidates[text]?.first else { return Point(text: text) }
                candidates[text]?.removeFirst()
                return point
            }
            refreshValidation()
        } catch OutlineIssue.empty {
            points = []
            parseIssue = .empty
            refreshValidation()
        } catch {
            parseIssue = .tooLong
            refreshValidation()
        }
    }

    private func refreshValidation() {
        if parseIssue == .tooLong || source.utf8.count > Outline.maxSourceBytes || title.utf8.count > Outline.maxTitleBytes ||
            subject.utf8.count > Outline.maxTitleBytes {
            issue = .tooLong
            return
        }
        if !points.isEmpty {
            do { try Outline.validate(points.map(\.text)) }
            catch { issue = .tooLong; return }
        }
        issue = points.isEmpty ? parseIssue : nil
    }

    private func canMerge(_ point: Point) -> Bool {
        guard let index = points.firstIndex(where: { $0.id == point.id }) else { return false }
        return index + 1 < points.count
    }

    private func update(_ point: Point, text: String) {
        if let index = points.firstIndex(where: { $0.id == point.id }) {
            if points[index].text != text { points[index] = Point(text: text) }
        } else {
            points.append(Point(text: text))
        }
        selectedPoint = nil
        refreshValidation()
    }

    private func merge(_ point: Point, text: String) {
        guard let index = points.firstIndex(where: { $0.id == point.id }), index + 1 < points.count else { return }
        points[index] = Point(text: text + " " + points[index + 1].text)
        points.remove(at: index + 1)
        selectedPoint = nil
        refreshValidation()
    }

    private func commit() {
        refreshValidation()
        guard !points.isEmpty, issue == nil else { return }
        let name = Outline.clean(title)
        let firstLine = points[0].text.split(whereSeparator: \.isNewline).first ?? ""
        let resolvedTitle = name.isEmpty ? String(firstLine.prefix(48)) : name
        let group = showsSubject ? Outline.clean(subject) : note?.subject ?? ""
        var updated = note ?? Note(title: resolvedTitle, points: points, lastUsed: Date())
        updated.revise(title: resolvedTitle, subject: group, source: source, points: points)
        focus = nil
        save(updated)
    }
}

struct PointEditor: View {
    @State private var text: String
    @FocusState private var focused: Bool
    let canMerge: Bool
    let save: (String) -> Void
    let merge: (String) -> Void
    let delete: () -> Void
    let editing: Bool

    init(point: Point, canMerge: Bool, save: @escaping (String) -> Void, merge: @escaping (String) -> Void,
         delete: @escaping () -> Void, editing: Bool) {
        _text = State(initialValue: point.text)
        self.canMerge = canMerge
        self.save = save
        self.merge = merge
        self.delete = delete
        self.editing = editing
    }

    var body: some View {
        PaperScroll {
            PageBack()
            PageHeading(title: L.t(editing ? "point.edit" : "editor.add"))
            TextEditor(text: $text)
                .scrollContentBackground(.hidden).frame(height: 116).padding(8).paperCard()
                .accessibilityLabel(L.t("point.edit"))
                .accessibilityIdentifier("point.text")
                .focused($focused)
            let clean = Outline.clean(text)
            let valid = !clean.isEmpty && clean.utf8.count <= Outline.maxPointBytes
            PaperButton(title: L.t("action.save"), id: "point.save", primary: true) { save(clean) }.disabled(!valid)
            if canMerge {
                PaperButton(title: L.t("point.merge"), id: "point.merge") { merge(clean) }.disabled(!valid)
            }
            if editing {
                TextButton(title: L.t("action.delete"), id: "point.delete", symbol: "trash", action: delete)
            }
        }
        .task { focused = true }
    }
}

@MainActor
struct ImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var preview: OutlineTransfer?
    @State private var message: String?
    @State private var picker = false
    @State private var loading = false
    @State private var opened = false
    let isFile: Bool
    let upgrade: () -> Void

    var body: some View {
        PaperScroll {
            PageBack(title: L.t(isFile ? "nav.notes" : "nav.home"))
            PageHeading(title: L.t(isFile ? "file.import" : "import.title"),
                        subtitle: L.t(isFile ? "file.hint" : "import.subtitle"))
            if isFile {
                PaperButton(title: L.t("file.choose"), id: "import.chooseFile") { picker = true }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("import.code")).font(.caption.weight(.semibold)).foregroundStyle(Paper.muted)
                    TextEditor(text: $code)
                        .scrollContentBackground(.hidden).frame(height: 84).paperField()
                        .font(.system(.footnote, design: .monospaced)).autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel(L.t("import.code"))
                        .accessibilityIdentifier("import.code")
                    if model.testing {
                        PaperButton(title: L.t("import.paste"), id: "import.paste") {
                            if let text = model.environment["BLURTING_IMPORT_CODE"] { code = text }
                        }
                    } else {
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first { code = value }
                        }
                        .labelStyle(.titleOnly)
                        .accessibilityLabel(L.t("import.paste"))
                        .accessibilityIdentifier("import.paste")
                    }
                }.padding(12).paperCard()
            }
            if loading { ProgressView() }
            if let message {
                Text(message).font(.footnote).foregroundStyle(Paper.mark).accessibilityIdentifier("import.error")
            }
            if let preview {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("import.preview")).font(.caption).foregroundStyle(Paper.muted)
                    Text(preview.title).font(.title2.weight(.semibold)).accessibilityIdentifier("import.previewTitle")
                    Text(L.t("note.points", preview.points.count)).font(.footnote).foregroundStyle(Paper.muted)
                    Divider()
                    Text(L.t("import.local")).font(.footnote).foregroundStyle(Paper.muted)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).paperCard()
                PaperButton(title: L.t("import.save"), id: "import.save", primary: true) { commit(preview) }
            }
        }
        .onChange(of: code) { _, value in validate(value) }
        .task {
            guard isFile, !opened else { return }
            opened = true
            if model.testing, let text = model.environment["BLURTING_IMPORT_FILE"] {
                setPreview { try OutlineTransfer.readFile(Data(text.utf8), title: L.t("file.sampleName"), isJSON: true) }
            } else {
                picker = true
            }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.json, .plainText]) { result in
            switch result {
            case .success(let url): readFile(url)
            case .failure: message = L.t("error.file")
            }
        }
    }

    private func validate(_ value: String) {
        if Outline.clean(value).isEmpty {
            preview = nil
            message = nil
        } else {
            setPreview { try OutlineTransfer.readCode(value) }
        }
    }

    private func setPreview(_ load: () throws -> OutlineTransfer) {
        preview = nil
        message = nil
        do { preview = try load() }
        catch let issue as OutlineIssue { message = issue.message }
        catch { message = L.t("error.file") }
    }

    private func readFile(_ url: URL) {
        loading = true
        preview = nil
        message = nil
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                Result {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: Outline.maxFileBytes + 1) ?? Data()
                    return try OutlineTransfer.readFile(data, title: url.deletingPathExtension().lastPathComponent,
                                                        isJSON: url.pathExtension.lowercased() == "json")
                }
            }.value
            loading = false
            setPreview { try loaded.get() }
        }
    }

    private func commit(_ payload: OutlineTransfer) {
        guard model.hasPro else { upgrade(); return }
        do {
            try model.importNote(payload)
            dismiss()
        } catch let issue as OutlineIssue {
            message = issue.message
        } catch {
            message = L.t("error.file")
        }
    }
}
