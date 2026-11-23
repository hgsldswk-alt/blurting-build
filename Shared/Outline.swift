import Foundation

struct Point: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text: String
}

struct Note: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var subject = ""
    var source = ""
    var points: [Point]
    var version = UUID()
    var minutes = 5
    var lastUsed = Date()
    var isExample = false

    mutating func revise(title: String, subject: String, source: String, points: [Point]) {
        if self.points != points { version = UUID() }
        self.title = title
        self.subject = subject
        self.source = source
        self.points = points
    }
}

enum OutlineIssue: Error, Equatable {
    case empty, tooLong, invalid, unsupported, duplicate

    var message: String {
        switch self {
        case .empty: L.t("error.empty")
        case .tooLong: L.t("error.long")
        case .invalid: L.t("error.code")
        case .unsupported: L.t("error.version")
        case .duplicate: L.t("error.duplicate")
        }
    }
}

enum Outline {
    enum Mode: String, CaseIterable { case lines, paragraphs }

    static let maxSourceBytes = 64_000
    static let maxPointBytes = 8_000
    static let maxPoints = 250
    static let maxTitleBytes = 480
    static let maxCodeBytes = 12_000
    static let maxFileBytes = 1_048_576

    private static let prefix = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:[-–—*+](?=\s|$)\s*)|(?:[•●▪◦‣・‧·]\s*)|(?:(?:[0-9０-９]+|[一二三四五六七八九十百]+)(?:[.．:：](?![0-9０-９])|[、)）])\s*)|(?:[(（](?:[0-9０-９]+|[一二三四五六七八九十百]+)[)）]\s*)|(?:[①-⑳]\s*))"#
    )

    static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripPrefix(_ value: String) -> String {
        clean(prefix.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: ""))
    }

    static func split(_ source: String, mode: Mode) throws -> [String] {
        guard source.utf8.count <= maxSourceBytes else { throw OutlineIssue.tooLong }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var points: [String] = []
        var paragraph: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = clean(line)
            if mode == .lines {
                let point = stripPrefix(trimmed)
                if !point.isEmpty { points.append(point) }
            } else if trimmed.isEmpty {
                if !paragraph.isEmpty { points.append(paragraph.joined(separator: "\n")) }
                paragraph.removeAll(keepingCapacity: true)
            } else {
                let point = stripPrefix(trimmed)
                if point != trimmed, !paragraph.isEmpty {
                    points.append(paragraph.joined(separator: "\n"))
                    paragraph.removeAll(keepingCapacity: true)
                }
                if !point.isEmpty { paragraph.append(point) }
            }
        }
        if !paragraph.isEmpty { points.append(paragraph.joined(separator: "\n")) }
        try validate(points)
        return points
    }

    static func validate(_ points: [String]) throws {
        guard !points.isEmpty, points.allSatisfy({ !clean($0).isEmpty }) else { throw OutlineIssue.empty }
        guard points.count <= maxPoints,
              points.allSatisfy({ $0.utf8.count <= maxPointBytes }),
              points.reduce(0, { $0 + $1.utf8.count }) <= maxSourceBytes else { throw OutlineIssue.tooLong }
    }
}

struct OutlineTransfer: Codable, Equatable {
    let version: Int
    let title: String
    let points: [String]

    init(title: String, points: [String]) throws {
        let title = Outline.clean(title)
        guard !title.isEmpty else { throw OutlineIssue.empty }
        guard title.utf8.count <= Outline.maxTitleBytes else { throw OutlineIssue.tooLong }
        try Outline.validate(points)
        self.version = 1
        self.title = title
        self.points = points.map(Outline.clean)
    }

    func code() throws -> String {
        let payload = try JSONEncoder().encode(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let value = "BP1." + payload
        guard value.utf8.count <= Outline.maxCodeBytes else { throw OutlineIssue.tooLong }
        return value
    }

    static func readCode(_ code: String) throws -> Self {
        let value = Outline.clean(code)
        guard value.utf8.count <= Outline.maxCodeBytes else { throw OutlineIssue.tooLong }
        guard let separator = value.firstIndex(of: "."),
              value[..<separator].hasPrefix("BP") else { throw OutlineIssue.invalid }
        guard value[..<separator] == "BP1" else { throw OutlineIssue.unsupported }
        let payload = value[value.index(after: separator)...]
        guard !payload.isEmpty, payload.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw OutlineIssue.invalid }
        var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw OutlineIssue.invalid }
        return try decode(data)
    }

    func file() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func readFile(_ data: Data, title: String, isJSON: Bool) throws -> Self {
        guard data.count <= Outline.maxFileBytes else { throw OutlineIssue.tooLong }
        if isJSON { return try decode(data) }
        guard var text = String(data: data, encoding: .utf8) else { throw OutlineIssue.invalid }
        if text.unicodeScalars.first?.value == 0xFEFF { text.removeFirst() }
        if Outline.clean(text).hasPrefix("BP") && Outline.clean(text).contains("."),
           !Outline.clean(text).contains(where: \.isWhitespace) {
            return try readCode(text)
        }
        return try Self(title: title, points: Outline.split(text, mode: .lines))
    }

    private static func decode(_ data: Data) throws -> Self {
        guard let payload = try? JSONDecoder().decode(Self.self, from: data) else { throw OutlineIssue.invalid }
        guard payload.version == 1 else { throw OutlineIssue.unsupported }
        return try Self(title: payload.title, points: payload.points)
    }

    func matches(_ note: Note) -> Bool {
        title == Outline.clean(note.title) && points == note.points.map { Outline.clean($0.text) }
    }
}
