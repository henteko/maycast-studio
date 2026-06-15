import Foundation

/// Lightweight, deterministic classification of an imported media file by its
/// path extension. Kept extension-based (rather than `UTType`) so it behaves
/// identically across the CLI, XPC services, and tests without depending on a
/// running file system or Launch Services.
public enum MediaKind: Sendable {
    case audio
    case video

    /// Video container extensions we accept on import. A speaker imported from
    /// one of these has its audio extracted for editing while the picture is
    /// kept for the per-speaker mp4 export.
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "flv",
    ]

    /// Classify by file extension (case-insensitive). Anything not recognized
    /// as video is treated as audio (the existing import path).
    public static func of(_ url: URL) -> MediaKind {
        videoExtensions.contains(url.pathExtension.lowercased()) ? .video : .audio
    }
}
