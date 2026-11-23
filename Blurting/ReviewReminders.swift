import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class ReviewReminders {
    private let center = UNUserNotificationCenter.current()
    private let prefix = "blurting.review."
    private var task: Task<Void, Never>?
    private var lastDates: [Date]?
    private var lastEnabled: Bool?

    func refresh(dates: [Date], enabled: Bool, requestPermission: Bool, force: Bool = false) {
        guard force || requestPermission || lastDates != dates || lastEnabled != enabled else { return }
        lastDates = dates
        lastEnabled = enabled
        let previous = task
        task = Task {
            await previous?.value
            var status = await center.notificationSettings().authorizationStatus
            if enabled && requestPermission && status == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            let authorized = enabled && [.authorized, .provisional, .ephemeral].contains(status)
            let desired = authorized ? Array(dates.filter { $0 > Date() }.prefix(60)) : []
            let requests = Dictionary(uniqueKeysWithValues: desired.map {
                (prefix + String(Int($0.timeIntervalSince1970)), $0)
            })
            let pending = Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) })
            let stale = pending.subtracting(requests.keys)
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
            for (id, date) in requests where !pending.contains(id) && date > Date() {
                let content = UNMutableNotificationContent()
                content.title = L.t("reminder.notificationTitle")
                content.body = L.t("reminder.notificationBody")
                content.sound = .default
                var components = Calendar.current.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
                components.calendar = Calendar.current
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }
}

@MainActor
struct ReviewSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var denied = false

    var body: some View {
        PaperScroll {
            PageBack(title: L.t("nav.home"))
            PageHeading(title: L.t("reminder.settings"), subtitle: L.t("reminder.description"))
            VStack(spacing: 12) {
                Toggle(L.t("reminder.toggle"), isOn: Binding(
                    get: { model.reviewPreferences.enabled },
                    set: { enabled in
                        var preferences = model.reviewPreferences
                        preferences.enabled = enabled
                        model.setReviewPreferences(preferences, ask: enabled)
                    }
                ))
                .accessibilityIdentifier("settings.reminders")
                DatePicker(L.t("reminder.time"), selection: Binding(
                    get: { clockTime },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        var preferences = model.reviewPreferences
                        preferences.hour = parts.hour ?? 19
                        preferences.minute = parts.minute ?? 0
                        model.setReviewPreferences(preferences, ask: preferences.enabled)
                    }
                ), displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("settings.time")
                .disabled(!model.reviewPreferences.enabled)
            }.padding(14).paperCard()
            if denied && model.reviewPreferences.enabled {
                Text(L.t("reminder.denied")).font(.footnote).foregroundStyle(Paper.muted)
                PaperButton(title: L.t("reminder.systemSettings"), id: "settings.system") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !model.testing else { return }
            denied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
        }
    }

    private var clockTime: Date {
        Calendar.current.date(bySettingHour: model.reviewPreferences.hour, minute: model.reviewPreferences.minute,
                              second: 0, of: model.now) ?? model.now
    }
}
