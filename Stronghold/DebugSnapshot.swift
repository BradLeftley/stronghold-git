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
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }) {
            write(window, to: path)
            // A sheet is a window of its own: it goes to "<name>-sheet.png".
            if let sheet = window.attachedSheet {
                write(sheet, to: (path as NSString).deletingPathExtension + "-sheet.png")
            }
        }
        NSApp.terminate(nil)
    }

    @MainActor
    private static func write(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
