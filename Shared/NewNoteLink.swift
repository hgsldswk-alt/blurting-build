import Foundation

struct NewNoteLink: Hashable, Sendable {
    let title: String
    let subject: String

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "blurting",
              components.host?.lowercased() == "new",
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        let items = components.queryItems ?? []
        let titles = items.filter { $0.name == "title" }
        let subjects = items.filter { $0.name == "subject" }
        guard titles.count <= 1, subjects.count <= 1 else { return nil }
        title = Outline.clean(titles.first?.value ?? "")
        subject = Outline.clean(subjects.first?.value ?? "")
        guard title.utf8.count <= Outline.maxTitleBytes, subject.utf8.count <= Outline.maxTitleBytes else { return nil }
    }
}
