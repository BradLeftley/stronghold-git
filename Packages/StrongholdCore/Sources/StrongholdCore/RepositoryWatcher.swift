import CoreServices
import Foundation

/// Calls `handler` (after a short quiet period) when files in a working tree, or the parts of `.git` that
/// matter for status, change. Used to keep the changes list current without polling.
public final class RepositoryWatcher: @unchecked Sendable {
    private let root: URL
    private let handler: @Sendable () -> Void
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "stronghold.repository-watcher", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(root: URL, latency: TimeInterval = 0.4, handler: @escaping @Sendable () -> Void) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.received(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        if paths.contains(where: { Self.isRelevant($0, root: root) }) { handler() }
    }

    /// Whether a change at `path` can alter what status or history shows. Git's own bookkeeping
    /// (objects, logs, lock files) is ignored so a refresh doesn't trigger another one.
    static func isRelevant(_ path: String, root: URL) -> Bool {
        let rootPath = root.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return true }
        let relative = String(path.dropFirst(rootPath.count)).drop { $0 == "/" }
        guard relative == ".git" || relative.hasPrefix(".git/") else { return true }
        let inside = relative.dropFirst(".git".count).drop { $0 == "/" }
        if inside.isEmpty || inside.hasSuffix(".lock") { return false }
        for ignored in ["objects", "logs", "hooks", "info", "FETCH_HEAD", "fsmonitor", "gc.log", "ORIG_HEAD"] {
            if inside == ignored || inside.hasPrefix(ignored + "/") { return false }
        }
        return true
    }
}
