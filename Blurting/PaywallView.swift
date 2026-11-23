import SwiftUI

@MainActor
struct PaywallView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PaperScroll {
            PageBack()
            PageHeading(title: L.t("pay.title"), subtitle: L.t("pay.subtitle"))

            VStack(alignment: .leading, spacing: 10) {
                Text(L.t("pay.included")).font(.headline)
                feature("pay.feature.notes", icon: "books.vertical")
                feature("pay.feature.trend", icon: "chart.xyaxis.line")
                feature("pay.feature.transfer", icon: "square.and.arrow.up")
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).paperCard()

            VStack(alignment: .leading, spacing: 7) {
                Text(model.entitlement.purchasedPro ? L.t("pay.unlocked") :
                     model.hasPro ? L.t("pay.days", model.remainingDays) : L.t("pay.expired"))
                    .font(.headline).accessibilityIdentifier("paywall.status")
                Text(L.t("pay.trialTerms")).font(.footnote).foregroundStyle(Paper.muted)
                Text(L.t("pay.basic")).font(.footnote).foregroundStyle(Paper.muted)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).paperCard()

            if !model.entitlement.purchasedPro {
                PaperButton(title: priceTitle, id: "paywall.buy", primary: true) {
                    Task { await model.purchase(model.proID) }
                }.disabled(model.storeBusy)
                if model.hasPro && model.entitlement.trialClaimedAt == nil {
                    PaperButton(title: L.t("pay.claim"), id: "paywall.trial") {
                        Task { await model.purchase(model.trialID) }
                    }.disabled(model.storeBusy)
                }
            }
            TextButton(title: L.t("pay.restore"), id: "paywall.restore") {
                Task { await model.restore() }
            }.disabled(model.storeBusy)
            if model.storeBusy { ProgressView() }
            if let message = model.purchaseMessage {
                Text(message).font(.footnote).foregroundStyle(Paper.mark).accessibilityIdentifier("paywall.message")
            }
        }
        .task {
            model.purchaseMessage = nil
            await model.loadProducts()
        }
    }

    private var priceTitle: String {
        if let price = model.proPrice { return L.t("pay.buyPrice", price) }
        return L.t("pay.buy")
    }

    private func feature(_ key: String, icon: String) -> some View {
        Label(L.t(key), systemImage: icon).font(.subheadline)
    }
}
