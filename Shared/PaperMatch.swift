import Foundation

enum PaperLanguage: String, Sendable {
    case english = "en-US"
    case simplified = "zh-Hans"
    case traditional = "zh-Hant"

    var recognitionLanguages: [String] { self == .english ? [rawValue] : [rawValue, Self.english.rawValue] }

    static func infer(from text: String, preferred: String = Bundle.main.preferredLocalizations.first ?? "en") -> Self {
        guard PaperMatch.containsHan(text) else {
            if text.rangeOfCharacter(from: .letters) != nil { return .english }
            if preferred.hasPrefix("zh-Hant") { return .traditional }
            return preferred.hasPrefix("zh") ? .simplified : .english
        }
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)
        let traditional = text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false)
        let traditionalCount = differences(text, simplified)
        let simplifiedCount = differences(text, traditional)
        if traditionalCount != simplifiedCount { return traditionalCount > simplifiedCount ? .traditional : .simplified }
        return preferred.hasPrefix("zh-Hant") ? .traditional : .simplified
    }

    private static func differences(_ source: String, _ transformed: String?) -> Int {
        guard let transformed else { return 0 }
        return zip(source, transformed).filter { $0.0 != $0.1 }.count + abs(source.count - transformed.count)
    }
}

enum PaperMatch {
    private static let han = try! NSRegularExpression(pattern: #"\p{Han}"#)
    private static let words = try! NSRegularExpression(pattern: #"(?:(?!\p{Han})[\p{L}\p{M}\p{Nd}])+"#)

    static func containsHan(_ text: String) -> Bool {
        han.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    struct Tokens {
        let words: [String: Int]
        let pairs: [String: Int]
        let characters: [String: Int]

        init(_ source: String) {
            let normalized = source.precomposedStringWithCompatibilityMapping.lowercased()
                .replacingOccurrences(of: "['’]", with: "", options: .regularExpression)
            let range = NSRange(normalized.startIndex..., in: normalized)
            let wordTokens = PaperMatch.words.matches(in: normalized, range: range).compactMap {
                Range($0.range, in: normalized).map { String(normalized[$0]) }
            }
            let hanTokens = PaperMatch.han.matches(in: normalized, range: range).compactMap {
                Range($0.range, in: normalized).map { String(normalized[$0]) }
            }
            words = Self.count(wordTokens)
            pairs = Self.count(zip(hanTokens, hanTokens.dropFirst()).map { $0.0 + $0.1 })
            characters = Self.count(hanTokens)
        }

        private static func count(_ values: [String]) -> [String: Int] {
            values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }

        func coverage(in answer: Self) -> Double {
            let singleHan = pairs.isEmpty
            let chinese = singleHan ? characters : pairs
            let answerChinese = singleHan ? answer.characters : answer.pairs
            let matched = Self.overlap(words, answer.words) + Self.overlap(chinese, answerChinese)
            let total = words.values.reduce(0, +) + chinese.values.reduce(0, +)
            return total == 0 ? 0 : Double(matched) / Double(total)
        }

        private static func overlap(_ expected: [String: Int], _ actual: [String: Int]) -> Int {
            expected.reduce(0) { $0 + min($1.value, actual[$1.key, default: 0]) }
        }
    }

    static func misses(in text: String, points: [Point]) -> Set<UUID> {
        let answer = Tokens(text)
        return Set(points.filter { Tokens($0.text).coverage(in: answer) < 0.5 }.map(\.id))
    }
}
