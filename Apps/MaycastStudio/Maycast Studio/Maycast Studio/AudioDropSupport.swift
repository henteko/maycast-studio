import Foundation
import UniformTypeIdentifiers

/// Pick the first dropped URL that is an audio file AVFoundation can read.
/// Used by the speaker / intro / outro drop targets so non-audio drops bounce
/// back (the drop returns false and the system animates the item home),
/// mirroring the `[.audio]` filter the file panel uses.
func maycastFirstAudioURL(in urls: [URL]) -> URL? {
    urls.first { url in
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }
}

/// Pick the first dropped URL that is an audio **or video** file. A speaker can
/// be imported from a video (e.g. their camera recording); the audio is
/// extracted for editing and the video is kept for the per-speaker mp4 export.
/// Used by the speaker drop target only — intro / outro stay audio-only.
func maycastFirstMediaURL(in urls: [URL]) -> URL? {
    urls.first { url in
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }
}

/// True when the URL points at a video container (used by the UI to show a
/// film badge, and to decide between the audio-only transcode path and the
/// video → audio extraction path).
func maycastIsVideoURL(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .movie)
}

/// Type for a `.maycastshow` Show bundle. The app declares no exported UTI
/// yet, so this resolves to a dynamic type keyed off the extension.
let maycastShowBundleType: UTType? = UTType(filenameExtension: "maycastshow")

/// True when the URL points at a Show bundle (`.maycastshow`).
func maycastIsShowBundleURL(_ url: URL) -> Bool {
    if let show = maycastShowBundleType,
       let type = UTType(filenameExtension: url.pathExtension),
       type.conforms(to: show) {
        return true
    }
    return url.pathExtension.lowercased() == "maycastshow"
}

/// Pick the first dropped URL that is a Show bundle. Used by the New Episode
/// sheet's Show drop target so stray files bounce back.
func maycastFirstShowBundleURL(in urls: [URL]) -> URL? {
    urls.first(where: maycastIsShowBundleURL)
}
