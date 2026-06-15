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
