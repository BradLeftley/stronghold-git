import Foundation
import GitEngine
import GitTestSupport
import Testing
@testable import StrongholdCore

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    func tick() -> Date { lock.withLock { time += 60; return time } }
}

@MainActor
@Suite("Repository library")
struct LibraryTests {
    private func makeStorage() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stronghold-library-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stronghold-lib-folders-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addsOnceAndNamesAfterTheFolder() throws {
        let library = RepositoryLibrary(storageURL: nil)
        let url = try folder("Project One")
        let first = library.add(url)
        let again = library.add(url.appendingPathComponent("../Project One"))
        #expect(first.id == again.id)
        #expect(library.entries.count == 1)
        #expect(first.name == "Project One")
    }

    @Test func aSymlinkToTheSameFolderIsTheSameEntry() throws {
        let library = RepositoryLibrary(storageURL: nil)
        let url = try folder("real")
        let link = url.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        library.add(url)
        library.add(link)
        #expect(library.entries.count == 1)
    }

    @Test func persistsAcrossInstances() throws {
        let storage = makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        let url = try folder("persisted")
        let library = RepositoryLibrary(storageURL: storage)
        let entry = library.add(url)
        library.rename(entry.id, to: "  Renamed  ")
        library.markOpened(url)

        let reloaded = RepositoryLibrary(storageURL: storage)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries[0].name == "Renamed")
        #expect(reloaded.entries[0].lastOpened != nil)
        #expect(reloaded.entries[0].id == entry.id)
        #expect(reloaded.saveError == nil)
    }

    @Test func storesOnlyPathsAndNames() throws {
        let storage = makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        let library = RepositoryLibrary(storageURL: storage)
        library.add(try folder("p"))
        let text = try String(contentsOf: storage, encoding: .utf8)
        #expect(Set(try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]).keys) == ["version", "repositories"])
        let entry = try #require(((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["repositories"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["id", "path", "name", "addedAt"])
    }

    @Test func aCorruptFileIsKeptAndTheLibraryStartsEmpty() throws {
        let storage = makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storage)
        let library = RepositoryLibrary(storageURL: storage)
        #expect(library.entries.isEmpty)
        let backup = storage.deletingLastPathComponent().appendingPathComponent("library.corrupt.json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "not json")
        library.add(try folder("fresh"))
        #expect(RepositoryLibrary(storageURL: storage).entries.count == 1)
    }

    @Test func unwritableStorageIsReported() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("stronghold-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let library = RepositoryLibrary(storageURL: blocker.appendingPathComponent("sub/library.json"))
        library.add(try folder("x"))
        #expect(library.saveError != nil)
    }

    @Test func sortsRecentFirstThenByName() throws {
        let clock = Clock()
        let library = RepositoryLibrary(storageURL: nil, now: { clock.tick() })
        let alpha = try folder("alpha"), beta = try folder("beta"), gamma = try folder("gamma"), delta = try folder("delta")
        library.add(alpha); library.add(beta); library.add(gamma); library.add(delta)
        library.markOpened(gamma)
        library.markOpened(beta)
        #expect(library.sorted.map(\.name) == ["beta", "gamma", "alpha", "delta"])
        library.markOpened(gamma)
        #expect(library.sorted.map(\.name) == ["gamma", "beta", "alpha", "delta"])
    }

    @Test func searchMatchesNameAndPathIgnoringCaseAndAccents() throws {
        let library = RepositoryLibrary(storageURL: nil)
        library.add(try folder("Café Menu"))
        library.add(try folder("billing"))
        #expect(library.search("").count == 2)
        #expect(library.search("cafe").map(\.name) == ["Café Menu"])
        #expect(library.search("BILL").map(\.name) == ["billing"])
        #expect(library.search("stronghold-lib-folders").count == 2)
        #expect(library.search("nothing").isEmpty)
    }

    @Test func removeKeepsTheFolderOnDisk() throws {
        let library = RepositoryLibrary(storageURL: nil)
        let url = try folder("keepme")
        let entry = library.add(url)
        library.remove(entry.id)
        #expect(library.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func renameIgnoresBlankNamesAndUnknownIDs() throws {
        let library = RepositoryLibrary(storageURL: nil)
        let entry = library.add(try folder("name"))
        library.rename(entry.id, to: "   ")
        library.rename(UUID(), to: "x")
        #expect(library.entries[0].name == "name")
    }

    @Test func notesMissingFolders() throws {
        let library = RepositoryLibrary(storageURL: nil)
        let url = try folder("temporary")
        let entry = library.add(url)
        #expect(library.isAvailable(entry))
        try FileManager.default.removeItem(at: url)
        #expect(!library.isAvailable(entry))
    }

    // MARK: AppModel integration

    private func app(_ tmp: TemporaryRepository, library: RepositoryLibrary) -> AppModel {
        let git = tmp.git
        return AppModel(library: library, feedback: Feedback(environment: ["ILLUMI_SCRIPTED": "1"]), locate: { git })
    }

    @Test func openingARepositoryAddsItToTheLibrary() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("one", files: ["a": "1"])
        let library = RepositoryLibrary(storageURL: nil)
        let model = app(tmp, library: library)
        await model.start()
        // Opened from a subfolder: the entry is the repository root.
        try tmp.write("sub/x.txt", "x")
        #expect(await model.open(tmp.url.appendingPathComponent("sub")))
        #expect(library.entries.count == 1)
        #expect(library.entries[0].path == tmp.url.resolvingSymlinksInPath().path)
        #expect(library.entries[0].lastOpened != nil)
        #expect(model.repository != nil)
    }

    @Test func openingAMissingLibraryEntryExplainsWhy() async throws {
        let tmp = try await TemporaryRepository()
        let library = RepositoryLibrary(storageURL: nil)
        let model = app(tmp, library: library)
        await model.start()
        let gone = LibraryEntry(path: tmp.baseURL.appendingPathComponent("gone").path, name: "Gone")
        #expect(await model.open(gone) == false)
        #expect(model.openError?.contains("Gone is no longer at") == true)
    }

    @Test func initialisesAFolderAndOpensIt() async throws {
        let tmp = try await TemporaryRepository()
        let library = RepositoryLibrary(storageURL: nil)
        let model = app(tmp, library: library)
        await model.start()
        let folder = tmp.baseURL.appendingPathComponent("brand new")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(await model.open(folder) == false)
        #expect(model.offerToInitialize == folder)
        #expect(await model.initializeRepository(at: folder))
        #expect(model.offerToInitialize == nil)
        #expect(model.repository?.name == "brand new")
        #expect(library.entries.count == 1)
    }

    @Test func clonesIntoTheChosenFolderAndOpensIt() async throws {
        let source = try await TemporaryRepository()
        try await source.commit("first", files: ["a.txt": "1"])
        let library = RepositoryLibrary(storageURL: nil)
        let model = app(source, library: library)
        await model.start()
        let destination = source.baseURL.appendingPathComponent("code/cloned")
        #expect(await model.clone(remote: source.path, to: destination))
        #expect(model.cloneState == .idle)
        #expect(model.repository?.commits.map(\.summary) == ["first"])
        #expect(library.entries.map(\.name) == ["cloned"])
    }

    @Test func aFailedCloneReportsTheGitErrorAndCanBeDismissed() async throws {
        let source = try await TemporaryRepository()
        let model = app(source, library: RepositoryLibrary(storageURL: nil))
        await model.start()
        let destination = source.baseURL.appendingPathComponent("code/failed")
        #expect(await model.clone(remote: source.baseURL.appendingPathComponent("nope").path, to: destination) == false)
        guard case .failed(let message) = model.cloneState else { Issue.record("expected failure"); return }
        #expect(message.contains("nope"))
        #expect(model.repository == nil)
        model.dismissCloneError()
        #expect(model.cloneState == .idle)
    }

    @Test func cancellingACloneStopsGitAndLeavesNothing() async throws {
        let source = try await TemporaryRepository()
        // A git that behaves normally except that "clone" hangs.
        let script = source.baseURL.appendingPathComponent("slow-git.sh")
        let realGit = source.git.executableURL.path
        try Data("""
        #!/bin/sh
        case "$*" in *" clone "*) exec sleep 60;; esac
        exec "\(realGit)" "$@"
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = GitRunner(executableURL: script, environment: source.git.environment)
        let model = AppModel(library: RepositoryLibrary(storageURL: nil), feedback: Feedback(environment: ["ILLUMI_SCRIPTED": "1"]),
                             locate: { runner })
        await model.start()
        let destination = source.baseURL.appendingPathComponent("code/cancelled")
        let started = Date()
        Task { try? await Task.sleep(for: .milliseconds(400)); model.cancelClone() }
        #expect(await model.clone(remote: source.path, to: destination) == false)
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(model.cloneState == .idle)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cloningWithoutAnAddressFails() async throws {
        let source = try await TemporaryRepository()
        let model = app(source, library: RepositoryLibrary(storageURL: nil))
        await model.start()
        #expect(model.cloneState.isRunning == false)
        #expect(await model.clone(remote: "  ", to: source.baseURL.appendingPathComponent("x")) == false)
        #expect(model.cloneState != .idle)
    }
}
