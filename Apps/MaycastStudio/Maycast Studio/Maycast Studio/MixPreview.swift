import Foundation
import AVFoundation
import MaycastCore

/// Plays short Mix overlap previews. Internally writes the rendered overlap
/// to a temp WAV and plays it via `AVAudioPlayer` — much simpler than
/// driving `AVAudioEngine` for a one-shot snippet.
@MainActor
@Observable
final class MixPreviewPlayer: NSObject {
    var isPlaying: Bool = false

    private var player: AVAudioPlayer?
    private var tempURL: URL?
    private var coordinator = Coordinator()

    func play(_ buffer: MaycastCore.AudioBuffer  /* qualified to disambiguate from AVFoundation.AudioBuffer */) throws {
        stop()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maycast-mix-preview-\(UUID().uuidString).wav")
        try AudioIO.writeWAV(buffer, to: url)
        print("[MixPreview] wrote temp wav → \(url.path)")
        let p = try AVAudioPlayer(contentsOf: url)
        coordinator.onFinish = { [weak self] in
            Task { @MainActor in
                self?.isPlaying = false
                self?.cleanupTemp()
            }
        }
        p.delegate = coordinator
        p.prepareToPlay()
        p.play()
        self.player = p
        self.tempURL = url
        self.isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        cleanupTemp()
    }

    private func cleanupTemp() {
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
        }
    }

    /// `AVAudioPlayerDelegate` requires an NSObject — keep it separate from
    /// the @Observable Swift class so we don't pull NSObject into the model.
    private final class Coordinator: NSObject, AVAudioPlayerDelegate {
        var onFinish: (() -> Void)?
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
            onFinish?()
        }
    }
}

// MARK: - Render helpers

enum MixOverlapKind: String, Sendable, Equatable {
    case intro
    case outro

    var displayName: String {
        switch self {
        case .intro: return "intro"
        case .outro: return "outro"
        }
    }
}

enum MixPreviewError: Error, CustomStringConvertible, Sendable {
    case noTracks
    case missingAsset(String)
    case message(String)

    var description: String {
        switch self {
        case .noTracks: return "No tracks to mix yet."
        case .missingAsset(let s): return "\(s) not found in the episode's assets."
        case .message(let s): return s
        }
    }
}

/// Render only the overlap region as a standalone clip so previews stay
/// snappy — reads just `overlapOffset + padSec` of each speaker via
/// `readRange` instead of loading the entire generation.
@MainActor
func renderMixOverlapPreview(
    kind: MixOverlapKind,
    bundleURL: URL,
    overlay: MixOverlaySettings,
    padSec: Double = 2.0
) async throws -> MaycastCore.AudioBuffer  /* qualified to disambiguate from AVFoundation.AudioBuffer */ {
    let bundle = try EpisodeBundle.open(at: bundleURL)
    let trackPaths: [URL] = bundle.episode.tracks.map {
        bundleURL.appendingPathComponent($0.current)
    }
    guard !trackPaths.isEmpty else { throw MixPreviewError.noTracks }

    // Resolve the relevant asset.
    let assetRel: String?
    switch kind {
    case .intro: assetRel = overlay.introPath
    case .outro: assetRel = overlay.outroPath
    }
    guard let assetRel else {
        throw MixPreviewError.missingAsset(kind.displayName)
    }
    let assetURL = bundleURL.appendingPathComponent(assetRel)
    guard FileManager.default.fileExists(atPath: assetURL.path) else {
        throw MixPreviewError.missingAsset(kind.displayName)
    }

    let snapshot = overlay
    return try await Task.detached(priority: .userInitiated) {
        let asset = try AudioIO.read(from: assetURL)

        // Read only the window we need from each speaker's current generation.
        let voiceWindowSec: Double
        let windowStartSec: (URL) throws -> Double
        let windowEndSec: (URL) throws -> Double
        switch kind {
        case .intro:
            // Need voice from t=0 to t=introOffset + padSec.
            voiceWindowSec = snapshot.introOffsetSec + padSec
            windowStartSec = { _ in 0 }
            windowEndSec = { _ in snapshot.introOffsetSec + padSec }
        case .outro:
            // Need voice from t=voiceEnd-(outroOffset+padSec) to t=voiceEnd.
            voiceWindowSec = snapshot.outroOffsetSec + padSec
            windowStartSec = { url in
                let file = try AVAudioFile(forReading: url)
                let total = Double(file.length) / file.processingFormat.sampleRate
                return max(0, total - (snapshot.outroOffsetSec + padSec))
            }
            windowEndSec = { url in
                let file = try AVAudioFile(forReading: url)
                return Double(file.length) / file.processingFormat.sampleRate
            }
        }
        _ = voiceWindowSec  // captured by closures above

        var voiceWindows: [MaycastCore.AudioBuffer] = []
        voiceWindows.reserveCapacity(trackPaths.count)
        for url in trackPaths {
            let s = try windowStartSec(url)
            let e = try windowEndSec(url)
            let buf = try AudioIO.readRange(from: url, startSec: s, endSec: e)
            print(String(
                format: "[MixPreview] voice %@: window=%.2f..%.2fs read=%@",
                url.lastPathComponent, s, e, mixPreviewStats(buf)
            ))
            voiceWindows.append(buf)
        }
        let voiceMaster = try AudioIO.mixParallel(voiceWindows)
        print("[MixPreview] voiceMaster: \(mixPreviewStats(voiceMaster))")
        print("[MixPreview] asset (\(kind.displayName)): \(mixPreviewStats(asset))")

        // Compose: only the relevant transition gets an overlay.
        let mix = try AudioIO.composeFinalMix(
            voiceMaster: voiceMaster,
            intro: kind == .intro ? asset : nil,
            outro: kind == .outro ? asset : nil,
            introOffsetSec: snapshot.introOffsetSec,
            outroOffsetSec: snapshot.outroOffsetSec,
            duckingGainDB: snapshot.duckingGainDB,
            duckingFadeSec: snapshot.duckingFadeSec
        )
        print("[MixPreview] composed: \(mixPreviewStats(mix))")
        return mix
    }.value
}

/// "frames=… sr=… ch=… RMS=… peak=…" one-liner used by Mix preview's logs.
/// Made `nonisolated` (`@Sendable`-friendly) so it can be called from inside
/// `Task.detached`.
private func mixPreviewStats(_ buf: MaycastCore.AudioBuffer) -> String {
    var peak: Float = 0
    var sumSq: Double = 0
    var count: Double = 0
    for ch in buf.samples {
        for s in ch {
            let a = abs(s)
            if a > peak { peak = a }
            sumSq += Double(s * s)
            count += 1
        }
    }
    let rms = count > 0 ? sqrt(sumSq / count) : 0
    return String(
        format: "frames=%d sr=%.0f ch=%d RMS=%.4f peak=%.4f dur=%.2fs",
        buf.frameCount, buf.sampleRate, buf.channelCount, rms, Double(peak), buf.duration
    )
}
