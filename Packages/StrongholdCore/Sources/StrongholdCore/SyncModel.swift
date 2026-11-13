import Foundation
import GitEngine
import Observation

/// Fetch, pull and push for one repository: one operation at a time, live progress, cancellation, and
/// failures worded for people.
@MainActor
@Observable
public final class SyncModel {
    public enum Kind: Sendable, Equatable {
        case fetch
        case pull
        case push
        case deleteRemoteBranch

        public var title: String {
            switch self {
            case .fetch: "Fetching"
            case .pull: "Pulling"
            case .push: "Pushing"
            case .deleteRemoteBranch: "Deleting remote branch"
            }
        }

        var failureTitle: String {
            switch self {
            case .fetch: "Fetch failed"
            case .pull: "Pull failed"
            case .push: "Push failed"
            case .deleteRemoteBranch: "Couldn\u{2019}t delete the remote branch"
            }
        }
    }

    /// The operation that is running now.
    public struct Activity: Equatable, Sendable {
        public var kind: Kind
        public var progress: TransferProgress?

        /// "Pushing…" or "Pushing · Writing objects 45%".
        public var text: String {
            guard let progress else { return "\(kind.title)\u{2026}" }
            return "\(kind.title) \u{00B7} \(progress.summary)"
        }
    }

    /// A follow-up the person can choose after a failure.
    public enum Retry: Sendable, Equatable {
        case pullWithAutostash
    }

    public struct Failure: Equatable, Sendable, Identifiable {
        public let id = UUID()
        public var kind: Kind
        public var reason: RemoteFailure
        public var message: String
        public var retry: Retry?

        public var title: String { kind.failureTitle }
    }

    public private(set) var activity: Activity?
    /// The last failure, shown in an alert. Clear it with `dismissFailure()`.
    public private(set) var failure: Failure?
    /// A short result for the last success, such as "Already up to date."
    public private(set) var notice: String?

    public var isBusy: Bool { activity != nil }

    private let repository: Repository
    private var task: Task<Void, Never>?
    private var operationID = 0

    /// Called after every operation, whether or not it succeeded, so lists and counts reload.
    var didFinish: @MainActor () async -> Void = {}

    public init(repository: Repository) {
        self.repository = repository
    }

    public func dismissFailure() { failure = nil }
    public func dismissNotice() { notice = nil }

    // MARK: Operations

    /// Fetches every remote, pruning branches deleted there.
    public func fetch(_ options: FetchOptions = FetchOptions()) async {
        await run(.fetch) { repository, progress in
            try await repository.fetch(options, onProgress: progress)
            return nil
        }
    }

    /// Pulls into the current branch. With no `strategy` the repository's git config decides.
    public func pull(strategy: PullStrategy? = nil, autostash: Bool = false) async {
        await run(.pull) { repository, progress in
            let chosen: PullStrategy
            if let strategy { chosen = strategy } else { chosen = try await repository.defaultPullStrategy() }
            let result = try await repository.pull(PullOptions(strategy: chosen, autostash: autostash), onProgress: progress)
            return result.alreadyUpToDate ? "Already up to date." : "Pulled the latest changes."
        }
    }

    /// Pushes the current branch, publishing it first if it has no upstream.
    public func push(_ options: PushOptions = PushOptions()) async {
        await run(.push) { repository, progress in
            let result = try await repository.push(options, onProgress: progress)
            if result.alreadyUpToDate { return "Everything is already pushed." }
            return result.setUpstream ? "Published \(result.branch) to \(result.remote)." : "Pushed to \(result.remote)."
        }
    }

    public func deleteRemoteBranch(remote: String, branch: String) async {
        await run(.deleteRemoteBranch) { repository, progress in
            try await repository.deleteRemoteBranch(remote: remote, branch: branch, onProgress: progress)
            return "Deleted \(remote)/\(branch)."
        }
    }

    /// Runs the follow-up a failure offered.
    public func retry(_ retry: Retry) async {
        failure = nil
        switch retry {
        case .pullWithAutostash: await pull(autostash: true)
        }
    }

    /// Stops the running operation. Git is terminated and the person sees no error.
    public func cancel() { task?.cancel() }

    // MARK: Running

    private func run(_ kind: Kind,
                     _ body: @escaping @Sendable (Repository, @escaping @Sendable (TransferProgress) -> Void) async throws -> String?) async {
        guard activity == nil else { return }
        operationID += 1
        let id = operationID
        activity = Activity(kind: kind)
        failure = nil
        notice = nil
        let repository = repository
        let task = Task { [weak self] in
            do {
                let message = try await body(repository) { progress in
                    Task { @MainActor in self?.report(progress, for: id) }
                }
                self?.notice = message
            } catch is CancellationError {
                self?.notice = "\(kind.title.replacingOccurrences(of: "ing", with: "")) cancelled."
            } catch {
                self?.failure = Self.failure(for: error, kind: kind)
            }
        }
        self.task = task
        await task.value
        self.task = nil
        activity = nil
        await didFinish()
    }

    private func report(_ progress: TransferProgress, for id: Int) {
        guard id == operationID, activity != nil else { return }
        activity?.progress = progress
    }

    static func failure(for error: Error, kind: Kind) -> Failure {
        if case GitError.remoteFailed(let reason, _) = error {
            return Failure(kind: kind, reason: reason, message: error.localizedDescription,
                           retry: reason == .localChangesInTheWay && kind == .pull ? .pullWithAutostash : nil)
        }
        return Failure(kind: kind, reason: .other, message: error.localizedDescription, retry: nil)
    }
}
