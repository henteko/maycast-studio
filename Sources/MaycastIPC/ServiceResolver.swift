import Foundation

/// Resolves the on-disk location of a service executable.
///
/// Resolution order:
/// 1. `MAYCAST_XPC_SERVICES_DIR` environment variable (dev mode)
/// 2. Installed `Maycast Studio.app/Contents/XPCServices/` (release mode)
/// 3. `.build/debug/` next to the CLI binary (fallback during local development)
public struct ServiceResolver {
    public enum Service: String, Sendable {
        case transcribe = "MaycastTranscribeService"
        case slice = "MaycastSliceService"
        case mix = "MaycastMixService"
        case chapter = "MaycastChapterService"
    }

    public init() {}

    public func executableURL(for service: Service, environment: [String: String] = ProcessInfo.processInfo.environment, cliBinaryURL: URL? = nil) -> URL? {
        let candidates = candidatePaths(for: service, environment: environment, cliBinaryURL: cliBinaryURL)
        let fm = FileManager.default
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    func candidatePaths(for service: Service, environment: [String: String], cliBinaryURL: URL?) -> [URL] {
        var paths: [URL] = []

        if let dir = environment["MAYCAST_XPC_SERVICES_DIR"] {
            let envURL = URL(fileURLWithPath: dir).appendingPathComponent(service.rawValue)
            paths.append(envURL)
        }

        if let cliBinaryURL {
            paths.append(cliBinaryURL.deletingLastPathComponent().appendingPathComponent(service.rawValue))
        }

        let installed = URL(fileURLWithPath: "/Applications/Maycast Studio.app/Contents/XPCServices/\(service.rawValue).xpc/Contents/MacOS/\(service.rawValue)")
        paths.append(installed)

        return paths
    }
}
