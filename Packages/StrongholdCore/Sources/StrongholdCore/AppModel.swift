import Foundation
import GitEngine
import Observation

/// App-wide state: which git we use and the repository open in the window.
@MainActor
@Observable
public final class AppModel {
    public enum GitState: Equatable {
        case checking
        case ready(GitVersion)
        case unavailable(String)
    }

    public private(set) var gitState: GitState = .checking
    public private(set) var git: GitRunner?
    public private(set) var repository: RepositoryModel?
    public let library: RepositoryLibrary
    /// The last error from opening a repository, for an alert.
    public var openError: String?
    /// A folder the user tried to open that isn't a repository yet; the UI offers to initialise it.
    public var offerToInitialize: URL?
    public private(set) var cloneState: CloneState = .idle

    public enum CloneState: Equatable, Sendable {
        case idle
        case running(remote: String)
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    private let locate: @Sendable () -> GitRunner?
    private let feedback: Feedback
    private var cloneTask: Task<Bool, Never>?

    /// - Parameters:
    ///   - library: the repositories the user has added; defaults to the one in Application Support.
    ///   - locate: finds the git to use; injectable so tests can supply an isolated runner.
    public init(library: RepositoryLibrary = RepositoryLibrary(storageURL: RepositoryLibrary.standardStorageURL),
                feedback: Feedback = Feedback(),
                locate: @escaping @Sendable () -> GitRunner? = { GitRunner.system() }) {
        self.library = library
        self.locate = locate
        self.feedback = feedback
    }

    /// Finds git and checks its version. Call once at launch.
    public func start() async {
        gitState = .checking
        guard let runner = locate() else {
            git = nil
            gitState = .unavailable(GitError.gitNotFound.localizedDescription)
            return
        }
        do {
            let version = try await runner.version()
            guard version >= GitVersion.minimumSupported else {
                throw GitError.unsupportedVersion(version)
            }
            git = runner
            gitState = .ready(version)
        } catch {
            git = nil
            gitState = .unavailable(error.localizedDescription)
        }
    }

    /// Opens the repository containing `url` and loads it. Returns false and sets `openError` on failure.
    @discardableResult
    public func open(_ url: URL) async -> Bool {
        guard let git else {
            fail(GitError.gitNotFound)
            return false
        }
        do {
            let repository = try await Repository.open(at: url, git: git)
            return await show(repository)
        } catch GitError.notARepository(let folder) {
            offerToInitialize = folder
            return false
        } catch {
            fail(error)
            return false
        }
    }

    /// Runs `git init` in `url` and opens the new repository.
    @discardableResult
    public func initializeRepository(at url: URL) async -> Bool {
        offerToInitialize = nil
        guard let git else {
            fail(GitError.gitNotFound)
            return false
        }
        do {
            return await show(try await Repository.initialize(at: url, git: git))
        } catch {
            fail(error)
            return false
        }
    }

    /// Clones `remote` into `destination` and opens it. Returns false if it failed or was cancelled;
    /// failures are in `cloneState`.
    @discardableResult
    public func clone(remote: String, to destination: URL) async -> Bool {
        guard let git else {
            cloneState = .failed(GitError.gitNotFound.localizedDescription)
            return false
        }
        guard !cloneState.isRunning else { return false }
        cloneState = .running(remote: remote)
        let task = Task { () -> Bool in
            do {
                let repository = try await Repository.clone(from: remote, to: destination, git: git)
                cloneState = .idle
                return await show(repository)
            } catch is CancellationError {
                cloneState = .idle
            } catch {
                cloneState = .failed(error.localizedDescription)
                feedback.error()
            }
            return false
        }
        cloneTask = task
        let opened = await task.value
        cloneTask = nil
        return opened
    }

    /// Stops a clone in progress. Its half-made folder is removed.
    public func cancelClone() {
        cloneTask?.cancel()
    }

    public func dismissCloneError() {
        if case .failed = cloneState { cloneState = .idle }
    }

    /// Opens a repository from the library. If its folder has gone, says so instead of failing obscurely.
    @discardableResult
    public func open(_ entry: LibraryEntry) async -> Bool {
        guard library.isAvailable(entry) else {
            openError = "\(entry.name) is no longer at \(entry.path). Remove it from the library or put the folder back."
            feedback.error()
            return false
        }
        return await open(entry.url)
    }

    public func close() {
        repository?.stopWatching()
        repository = nil
    }

    private func show(_ repository: Repository) async -> Bool {
        self.repository?.stopWatching()
        let model = RepositoryModel(repository: repository)
        self.repository = model
        openError = nil
        library.markOpened(repository.rootURL)
        await model.refresh()
        model.startWatching()
        return true
    }

    private func fail(_ error: Error) {
        openError = error.localizedDescription
        feedback.error()
    }
}
