import SwiftUI
import VisionKit

@MainActor
struct BookScanView: View {
    @State private var text = ""
    let language: PaperLanguage
    let useText: (String) -> Void
    let useCamera: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageBack()
            PageHeading(title: L.t("scan.import"), subtitle: L.t("scan.aim"))
            LiveBookScanner(language: language, update: { text = $0 }, fallback: useCamera)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                TextButton(title: L.t("paper.capture"), id: "scan.camera", symbol: "camera", action: useCamera)
                Spacer()
                PaperButton(title: L.t("scan.useText"), id: "scan.useText", primary: true) { useText(text) }
                    .disabled(text.isEmpty).opacity(text.isEmpty ? 0.5 : 1)
            }
        }.padding(.horizontal, 21).padding(.vertical, 10).paperPage()
    }
}

@MainActor
private struct LiveBookScanner: UIViewControllerRepresentable {
    let language: PaperLanguage
    let update: (String) -> Void
    let fallback: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(update: update, fallback: fallback) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.text(languages: language.recognitionLanguages)],
                                                qualityLevel: .accurate, recognizesMultipleItems: true,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        Task { @MainActor [weak scanner] in
            guard let scanner else { return }
            do { try scanner.startScanning() } catch { fallback() }
        }
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let update: (String) -> Void
        let fallback: () -> Void

        init(update: @escaping (String) -> Void, fallback: @escaping () -> Void) {
            self.update = update
            self.fallback = fallback
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            read(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            read(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            read(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            fallback()
        }

        private func read(_ items: [RecognizedItem]) {
            let texts = items.compactMap { item -> RecognizedItem.Text? in
                if case .text(let text) = item { return text }
                return nil
            }
            update(texts.map(\.transcript).joined(separator: "\n"))
        }
    }
}
