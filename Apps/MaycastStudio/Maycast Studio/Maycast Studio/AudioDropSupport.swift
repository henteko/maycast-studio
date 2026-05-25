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
