import Foundation

/// A tiny MainActor-isolated, observable carrier for background-task progress.
///
/// Because it's `@MainActor`-isolated it is `Sendable`, so it can be captured in
/// the `@Sendable` progress callbacks handed to `Task.detached` work (ffmpeg
/// encodes, exports). The callback hops back to the main actor before mutating;
/// views read `fraction` / `label` and re-render via Observation.
@MainActor
@Observable
final class ProgressRelay {
    var fraction: Double = 0
    var label: String = ""

    func reset(label: String = "") {
        self.fraction = 0
        self.label = label
    }

    func update(_ fraction: Double, label: String? = nil) {
        self.fraction = fraction
        if let label { self.label = label }
    }
}
