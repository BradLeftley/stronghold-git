import Foundation
import Observation

/// One repository in the library.
public struct LibraryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The repository's working-tree folder.
    public var path: String
    /// What the library shows; starts as the folder name and can be renamed.
    public var name: String
    public var addedAt: Date
    public var lastOpened: Date?

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public init(id: UUID = UUID(), path: String, name: String, addedAt: Date = Date(), lastOpened: Date? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.addedAt = addedAt
        self.lastOpened = lastOpened
    }
}

/// The repositories the user has added or cloned. It is a small JSON file in Application Support: only
/// folder paths and display names, never credentials.
@MainActor
@Observable
public final class RepositoryLibrary {
    public private(set) var entries: [LibraryEntry] = []
    /// Set when the file could not be written, so the UI can say the library won't survive a restart.
    public private(set) var saveError: String?

    private let storageURL: URL?
    private let now: @Sendable () -> Date

    /// - Parameter storageURL: where the library is kept; nil keeps it in memory only.
    public init(storageURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storageURL = storageURL
        self.now = now
        load()
    }

    /// `~/Library/Application Support/Stronghold/library.json`.
    public static var standardStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stronghold", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    // MARK: Reading

    /// Most recently opened first, then by name. Repositories never opened come after those that were.
    public var sorted: [LibraryEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.lastOpened, rhs.lastOpened) {
            case let (l?, r?) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Entries whose name or path contains `text`, ignoring case and accents. All of them for empty text.
    public func search(_ text: String) -> [LibraryEntry] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedStandardContains(query) || $0.path.localizedStandardContains(query)
        }
    }

    public func entry(forPath path: String) -> LibraryEntry? {
        let key = Self.canonical(path)
        return entries.first { Self.canonical($0.path) == key }
    }

    /// Whether the entry's folder is still there.
    public func isAvailable(_ entry: LibraryEntry) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Changing

    /// Adds the repository at `url`, or returns the existing entry for the same folder.
    @discardableResult
    public func add(_ url: URL) -> LibraryEntry {
        let path = Self.canonical(url.path)
        if let existing = entry(forPath: path) { return existing }
        let entry = LibraryEntry(path: path, name: url.lastPathComponent, addedAt: now())
        entries.append(entry)
        save()
        return entry
    }

    /// Records that the repository was just opened, adding it if needed.
    public func markOpened(_ url: URL) {
        let entry = add(url)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].lastOpened = now()
        save()
    }

    public func rename(_ id: LibraryEntry.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].name = trimmed
        save()
    }

    /// Takes the repository out of the library. Its folder is not touched.
    public func remove(_ id: LibraryEntry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    // MARK: Storage

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func load() {
        guard let storageURL, let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode(Stored.self, from: data).repositories
        } catch {
            // Keep the unreadable file for the user instead of overwriting it with an empty library.
            let backup = storageURL.deletingLastPathComponent().appendingPathComponent("library.corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: storageURL, to: backup)
            entries = []
        }
    }

    private func save() {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(Stored(repositories: entries)).write(to: storageURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private struct Stored: Codable {
        var version = 1
        var repositories: [LibraryEntry]
    }
}
