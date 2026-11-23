import Foundation

private final class LocalizationAnchor: NSObject {}

enum L {
    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        let value = NSLocalizedString(key, bundle: Bundle(for: LocalizationAnchor.self), comment: "")
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: .current, arguments: arguments)
    }
}
