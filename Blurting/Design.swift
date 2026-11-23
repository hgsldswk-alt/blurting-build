import SwiftUI

enum Paper {
    static let background = Color(red: 251/255, green: 248/255, blue: 242/255)
    static let ink = Color(red: 39/255, green: 37/255, blue: 32/255)
    static let muted = Color(red: 98/255, green: 92/255, blue: 83/255)
    static let line = Color(red: 231/255, green: 223/255, blue: 211/255)
    static let accent = Color(red: 232/255, green: 137/255, blue: 43/255)
    static let onAccent = Color(red: 42/255, green: 26/255, blue: 8/255)
    static let missed = Color(red: 255/255, green: 240/255, blue: 223/255)
    static let mark = Color(red: 141/255, green: 71/255, blue: 17/255)
}

extension View {
    func paperCard(_ radius: CGFloat = 16) -> some View {
        background(.white, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Paper.line).allowsHitTesting(false) }
    }

    func paperPage() -> some View {
        foregroundStyle(Paper.ink).background(Paper.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
    }

    func paperField(_ radius: CGFloat = 10) -> some View {
        padding(10).frame(minHeight: 44).paperCard(radius)
    }
}

struct PaperButton: View {
    let title: String
    let id: String
    var symbol: String? = nil
    var primary = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).multilineTextAlignment(.center)
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: primary ? 52 : 44)
            .foregroundStyle(primary ? Paper.onAccent : Paper.ink)
            .background(primary ? Paper.accent : .white, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(primary ? Paper.accent : Paper.line)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct TextButton: View {
    let title: String
    let id: String
    var symbol: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Paper.muted)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct PaperRow: View {
    let title: String
    let id: String
    var subtitle: String? = nil
    var icon: String? = nil
    var accessory = "chevron.right"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(Paper.muted).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Paper.muted) }
                }
                Spacer(minLength: 4)
                if !accessory.isEmpty {
                    Image(systemName: accessory).font(.caption.weight(.semibold))
                        .foregroundStyle(Paper.muted).accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct PageHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(.largeTitle, design: .serif)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Paper.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PageBack: View {
    @Environment(\.dismiss) private var dismiss
    var title = L.t("nav.back")

    var body: some View {
        HStack {
            TextButton(title: title, id: "nav.back", symbol: "chevron.left") { dismiss() }
            Spacer()
        }
    }
}

struct PaperScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) { content }
                .frame(maxWidth: 600)
                .padding(.horizontal, 21).padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
        .keyboardDismissMode()
        .paperPage()
    }
}

private extension ScrollView {
    func keyboardDismissMode() -> some View { scrollDismissesKeyboard(.interactively) }
}

struct Brand: View {
    var body: some View {
        Label(L.t("app.name"), systemImage: "document")
            .font(.subheadline.weight(.bold))
            .accessibilityAddTraits(.isHeader)
    }
}
