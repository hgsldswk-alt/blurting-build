import SwiftUI
import UIKit

@MainActor
struct ShareView: View {
    @EnvironmentObject private var model: AppModel
    @State private var qr: CGImage?
    @State private var shareItem: SharedImage?
    @State private var temporaryImage: URL?
    @State private var requested = false
    @State private var message: String?
    let content: ShareContent

    var body: some View {
        PaperScroll {
            PageBack()
            PageHeading(title: L.t("share.title"), subtitle: L.t("share.subtitle"))
            GeometryReader { geometry in
                let scale = min(1, geometry.size.width / ShareArtwork.size.width)
                ShareCard(content: content, qr: qr)
                    .scaleEffect(scale, anchor: .top)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
            .aspectRatio(3.0 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Paper.line).allowsHitTesting(false) }
            .accessibilityIdentifier("share.artwork")
            Text(L.t("share.privacy")).font(.footnote).foregroundStyle(Paper.muted)
            if let message { Text(message).font(.footnote).foregroundStyle(Paper.mark) }
            if requested {
                Text(L.t("share.ready")).font(.footnote).accessibilityIdentifier("share.requested")
            }
            PaperButton(title: L.t("share.image"), id: "share.export", symbol: "square.and.arrow.up", primary: true) {
                share()
            }.disabled(qr == nil)
        }
        .task {
            let link = DownloadLink.current
            qr = await Task.detached(priority: .userInitiated) { ShareArtwork.qr(for: link) }.value
            if qr == nil { message = L.t("error.image") }
        }
        .sheet(item: $shareItem, onDismiss: removeTemporaryImage) { item in
            ActivitySheet(url: item.url)
        }
    }

    private func share() {
        guard let qr, let png = ShareArtwork.png(content: content, qr: qr) else {
            message = L.t("error.image")
            return
        }
        if model.testing { requested = true; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blurting-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            temporaryImage = url
            shareItem = SharedImage(url: url)
        } catch {
            self.message = L.t("error.image")
        }
    }

    private func removeTemporaryImage() {
        if let temporaryImage { try? FileManager.default.removeItem(at: temporaryImage) }
        temporaryImage = nil
    }
}

private struct SharedImage: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
struct MilestonesView: View {
    @EnvironmentObject private var model: AppModel
    let navigate: (Route) -> Void

    var body: some View {
        PaperScroll {
            PageBack(title: L.t("nav.home"))
            PageHeading(title: L.t("milestone.title"))
            let awarded = model.library.lifetime.awards
            if awarded.isEmpty {
                Text(L.t("milestone.empty")).font(.subheadline).foregroundStyle(Paper.muted)
            }
            ForEach(Milestone.allCases.filter { awarded.contains($0) }) { item in
                PaperRow(title: item.label, id: "milestones.\(item.rawValue)",
                         subtitle: L.t("milestone.card"), icon: "rosette") { navigate(.share(.milestone(item))) }
                    .paperCard()
            }
        }
    }
}
