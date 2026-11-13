import AppKit
import Foundation

/// The only place the app makes sound. Silent when `ILLUMI_SCRIPTED=1` (automated runs and UI tests).
public struct Feedback: Sendable {
    public let isSilenced: Bool
    private let play: @Sendable () -> Void

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                play: @escaping @Sendable () -> Void = { NSSound.beep() }) {
        self.isSilenced = Feedback.isSilenced(environment)
        self.play = play
    }

    public static func isSilenced(_ environment: [String: String]) -> Bool {
        environment["ILLUMI_SCRIPTED"] == "1"
    }

    /// The standard alert sound for a failed action, unless silenced.
    public func error() {
        guard !isSilenced else { return }
        play()
    }
}
