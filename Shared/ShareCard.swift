import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum ShareContent: Hashable, Sendable {
    case score(Int)
    case milestone(Milestone)
}

enum DownloadLink {
    static func url(appStoreID: String) -> URL {
        guard !appStoreID.isEmpty, appStoreID.utf8.allSatisfy({ (48...57).contains($0) }),
              let url = URL(string: "https://apps.apple.com/app/id\(appStoreID)") else {
            return URL(string: "https://apps.apple.com/")!
        }
        return url
    }

    static var current: URL {
        url(appStoreID: Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? "")
    }
}

enum ShareArtwork {
    static let size = CGSize(width: 360, height: 480)
    static let scale: CGFloat = 3

    static func qr(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        let frame = image.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: frame)
        return CIContext().createCGImage(image.composited(over: white), from: frame)
    }

    @MainActor
    static func png(content: ShareContent, qr: CGImage) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(content: content, qr: qr))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage?.pngData()
    }
}

struct ShareCard: View {
    let content: ShareContent
    let qr: CGImage?

    private let ink = Color(red: 39/255, green: 37/255, blue: 32/255)
    private let muted = Color(red: 98/255, green: 92/255, blue: 83/255)
    private let paper = Color(red: 251/255, green: 248/255, blue: 242/255)
    private let mark = Color(red: 141/255, green: 71/255, blue: 17/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L.t("app.name"), systemImage: "document").font(.system(size: 19, weight: .bold))
            Spacer()
            switch content {
            case .score(let value):
                Text(L.t("share.recalled")).font(.system(size: 30, design: .serif))
                number(L.t("score.percent", value))
                Text(L.t("share.coverage")).font(.system(size: 16)).foregroundStyle(muted)
            case .milestone(let item):
                Text(L.t("milestone.title")).font(.system(size: 22, design: .serif))
                number(String(item.number))
                Text(item.label).font(.system(size: 20)).foregroundStyle(muted)
            }
            Spacer()
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("share.hashtag")).font(.system(size: 17, weight: .semibold)).foregroundStyle(mark)
                    Text(L.t("share.try")).font(.system(size: 13)).foregroundStyle(muted)
                }
                Spacer()
                if let qr {
                    Image(qr, scale: 1, orientation: .up, label: Text(L.t("share.qr"))).resizable().interpolation(.none)
                        .frame(width: 94, height: 94)
                } else {
                    ProgressView().frame(width: 94, height: 94)
                }
            }
        }
        .padding(26)
        .frame(width: ShareArtwork.size.width, height: ShareArtwork.size.height, alignment: .leading)
        .foregroundStyle(ink)
        .background(paper)
        .environment(\.colorScheme, .light)
    }

    private func number(_ number: String) -> some View {
        Text(number).font(.system(size: 88, design: .serif)).foregroundStyle(mark)
            .lineLimit(1).minimumScaleFactor(0.7)
    }
}
