import Foundation
import MaycastCore
import MaycastIPC

ServiceHost.run { request in
    guard request.operation == .mix else {
        return .failure("Unexpected operation \(request.operation.rawValue) for MixService")
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    let bundle = try EpisodeBundle.open(at: bundleURL)
    guard !bundle.episode.tracks.isEmpty else {
        return .failure("episode has no tracks to mix")
    }

    let outputRel = request.outputPath ?? "exports/\(bundle.episode.id).wav"
    let outputURL = bundleURL.appendingPathComponent(outputRel)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    // 1) Parallel-sum the voice tracks into a single master.
    var buffers: [AudioBuffer] = []
    for track in bundle.episode.tracks {
        let trackURL = bundleURL.appendingPathComponent(track.current)
        if FileManager.default.fileExists(atPath: trackURL.path) {
            buffers.append(try AudioIO.read(from: trackURL))
        }
    }
    guard !buffers.isEmpty else {
        return .failure("no track audio found to mix")
    }
    let voiceMaster = try AudioIO.mixParallel(buffers)

    // 2) Per-request overrides take precedence over the saved MixConfig so
    //    CLI flags / GUI sliders can adjust without persisting.
    var mixCfg = bundle.episode.mix
    if case let .object(p)? = request.params {
        if case let .number(v)? = p["introOffsetSec"] { mixCfg.introOffsetSec = v }
        if case let .integer(v)? = p["introOffsetSec"] { mixCfg.introOffsetSec = Double(v) }
        if case let .number(v)? = p["outroOffsetSec"] { mixCfg.outroOffsetSec = v }
        if case let .integer(v)? = p["outroOffsetSec"] { mixCfg.outroOffsetSec = Double(v) }
        if case let .number(v)? = p["duckingGainDB"] { mixCfg.duckingGainDB = v }
        if case let .integer(v)? = p["duckingGainDB"] { mixCfg.duckingGainDB = Double(v) }
        if case let .number(v)? = p["duckingFadeSec"] { mixCfg.duckingFadeSec = v }
        if case let .integer(v)? = p["duckingFadeSec"] { mixCfg.duckingFadeSec = Double(v) }
    }

    // 3) Optionally compose with intro / outro from the episode's assets.
    let introBuffer: AudioBuffer? = try mixCfg.intro
        .map(bundleURL.appendingPathComponent)
        .flatMap { url in FileManager.default.fileExists(atPath: url.path) ? url : nil }
        .map { try AudioIO.read(from: $0) }
    let outroBuffer: AudioBuffer? = try mixCfg.outro
        .map(bundleURL.appendingPathComponent)
        .flatMap { url in FileManager.default.fileExists(atPath: url.path) ? url : nil }
        .map { try AudioIO.read(from: $0) }

    let final: AudioBuffer
    if introBuffer == nil && outroBuffer == nil {
        final = voiceMaster
    } else {
        final = try AudioIO.composeFinalMix(
            voiceMaster: voiceMaster,
            intro: introBuffer,
            outro: outroBuffer,
            introOffsetSec: mixCfg.introOffsetSec,
            outroOffsetSec: mixCfg.outroOffsetSec,
            duckingGainDB: mixCfg.duckingGainDB,
            duckingFadeSec: mixCfg.duckingFadeSec
        )
    }
    try AudioIO.writeWAV(final, to: outputURL)

    let parts = [
        introBuffer == nil ? nil : "intro",
        outroBuffer == nil ? nil : "outro",
    ].compactMap { $0 }
    let extras = parts.isEmpty ? "" : " (+ \(parts.joined(separator: ", ")))"
    return .ok(
        exportPath: outputRel,
        message: "Mixed parallel sum\(extras) → \(outputRel)"
    )
}
