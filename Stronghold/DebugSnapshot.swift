#if DEBUG
import AppKit

/// Debug builds only: when `STRONGHOLD_SNAPSHOT_PATH` is set, render the main window to that PNG and quit.
/// Used to capture screenshots in automated runs without Screen Recording permission.
/// Known gap: `cacheDisplay` doesn't draw the contents of the glass sidebar, so it appears blank.
enum DebugSnapshot {
    @MainActor
    static func captureIfRequested(after delay: Duration = .seconds(2)) async {
        guard let path = ProcessInfo.processInfo.environment["STRONGHOLD_SNAPSHOT_PATH"], !path.isEmpty else { return }
        try? await Task.sleep(for: delay)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
           let view = window.contentView?.superview ?? window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}
#endif
