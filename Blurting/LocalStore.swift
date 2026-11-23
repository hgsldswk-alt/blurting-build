import Foundation
import Security
import SwiftData

@Model
private final class LocalValue {
    @Attribute(.unique) var key: String
    var bytes: Data

    init(key: String, bytes: Data) {
        self.key = key
        self.bytes = bytes
    }
}

@ModelActor
actor LocalStore {
    private var committedRevision = 0
    private var committedPhotos = Set<UUID>()
    private static let service = "com.hgsldswk.blurting.entitlement"

    nonisolated static func open(testing: Bool, persistent: Bool, reset: Bool) async throws -> LocalStore {
        try await Task.detached(priority: .userInitiated) {
            let configuration: ModelConfiguration
            if testing && !persistent {
                configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            } else {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: true)
                var directory = support.appendingPathComponent(testing ? "BlurtingUITests" : "Blurting", isDirectory: true)
                if testing && reset && FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var resources = URLResourceValues()
                resources.isExcludedFromBackup = true
                try directory.setResourceValues(resources)
                configuration = ModelConfiguration(url: directory.appendingPathComponent("library.store"),
                                                   cloudKitDatabase: .none)
            }
            let container = try ModelContainer(for: LocalValue.self, configurations: configuration)
            return LocalStore(modelContainer: container)
        }.value
    }

    func load(testing: Bool, now: Date) throws -> (Library, Entitlement) {
        modelContext.autosaveEnabled = false
        let library = try read(Library.self, key: "library") ?? Library()
        committedPhotos = library.photoIDs
        let local = try read(Entitlement.self, key: "entitlement")
        var entitlement = local ?? Entitlement(firstOpen: now)
        if !testing, let secure = Self.readKeychain() {
            entitlement.firstOpen = min(entitlement.firstOpen, secure.firstOpen)
            if let start = secure.proStartedAt {
                entitlement.proStartedAt = min(entitlement.proStartedAt ?? start, start)
            }
            entitlement.applyVerified(pro: local == nil ? secure.purchasedPro : nil,
                                      trialDate: secure.trialClaimedAt)
        }
        if !Launch.isFree, entitlement.proStartedAt == nil { entitlement.proStartedAt = now }
        try saveEntitlement(entitlement, testing: testing)
        return (library, entitlement)
    }

    func save(_ library: Library, photos: [UUID: Data], revision: Int) throws {
        guard revision > committedRevision else { return }
        let referenced = library.photoIDs
        do {
            for id in referenced.subtracting(committedPhotos) {
                guard let data = photos[id] else { throw CocoaError(.fileNoSuchFile) }
                put(data, key: Self.photoKey(id), existing: nil)
            }
            for id in committedPhotos.subtracting(referenced) {
                if let value = try entry(Self.photoKey(id)) { modelContext.delete(value) }
            }
            let bytes = try JSONEncoder().encode(library)
            put(bytes, key: "library", existing: try entry("library"))
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        committedPhotos = referenced
        committedRevision = revision
    }

    func photo(_ id: UUID) throws -> Data? { try entry(Self.photoKey(id))?.bytes }

    private static func photoKey(_ id: UUID) -> String { "paper-photo/\(id.uuidString)" }

    func saveEntitlement(_ value: Entitlement, testing: Bool) throws {
        let encoded = try JSONEncoder().encode(value)
        try store(encoded, key: "entitlement")
        if !testing { Self.writeKeychain(encoded) }
    }

    private func entry(_ key: String) throws -> LocalValue? {
        var request = FetchDescriptor<LocalValue>(predicate: #Predicate { $0.key == key })
        request.fetchLimit = 1
        return try modelContext.fetch(request).first
    }

    private func read<Value: Decodable>(_ type: Value.Type, key: String) throws -> Value? {
        guard let row = try entry(key) else { return nil }
        return try JSONDecoder().decode(type, from: row.bytes)
    }

    private func put(_ bytes: Data, key: String, existing: LocalValue?) {
        if let existing { existing.bytes = bytes }
        else { modelContext.insert(LocalValue(key: key, bytes: bytes)) }
    }

    private func store(_ bytes: Data, key: String) throws {
        do {
            put(bytes, key: key, existing: try entry(key))
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "v1"]
    }

    private static func readKeychain() -> Entitlement? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data else { return nil }
        return try? JSONDecoder().decode(Entitlement.self, from: bytes)
    }

    private static func writeKeychain(_ data: Data) {
        let status = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var value = keychainQuery
            value[kSecValueData as String] = data
            value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(value as CFDictionary, nil)
        }
    }
}
