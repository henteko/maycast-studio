import Foundation

/// Module-level constants. Renamed from `MaycastCore` (which collided with
/// the module name when consumers want to disambiguate types like
/// `MaycastCore.AudioBuffer` against the AVFoundation `AudioBuffer`).
public enum MaycastCoreInfo {
    public static let version = "0.0.1"

    public static let episodeBundleExtension = "maycast"
    public static let showBundleExtension = "maycastshow"
    public static let episodeManifestFileName = "episode.json"
    public static let showManifestFileName = "show.json"
}
