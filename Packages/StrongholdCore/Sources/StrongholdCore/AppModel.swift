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
    /// The last error from opening a repository, for an alert.
    public var openError: String?

    private let locate: @Sendable () -> GitRunner?
    private let feedback: Feedback

    /// - Parameters:
    ///   - locate: finds the git to use; injectable so tests can supply an isolated runner.
    public init(feedback: Feedback = Feedback(), locate: @escaping @Sendable () -> GitRunner? = { GitRunner.system() }) {
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
            let model = RepositoryModel(repository: repository)
            self.repository = model
            openError = nil
            await model.refresh()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    public func close() {
        repository = nil
    }

    private func fail(_ error: Error) {
        openError = error.localizedDescription
        feedback.error()
    }
}
