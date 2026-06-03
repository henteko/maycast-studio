import Foundation

/// Locating and invoking the system `ffmpeg`.
///
/// Maycast does not bundle an MP3 encoder: macOS CoreAudio (`afconvert`,
/// `AVAssetWriter`) can decode MP3 but cannot encode it, so the final-mix
/// export shells out to a system `ffmpeg` (libmp3lame). The requirement is
/// documented in the README — install with `brew install ffmpeg`.
public enum FFmpeg {
    /// Directories searched (after `PATH`) when `ffmpeg` isn't on `PATH` — the
    /// GUI / XPC process can launch with a minimal environment that lacks the
    /// shell's Homebrew additions.
    private static let fallbackDirs = [
        "/opt/homebrew/bin",   // Apple-silicon Homebrew
        "/usr/local/bin",      // Intel Homebrew
        "/opt/local/bin",      // MacPorts
        "/usr/bin",
    ]

    /// Resolve an executable by name. Resolution order:
    /// 1. `MAYCAST_<UPPERCASED>` env override (e.g. `MAYCAST_FFMPEG`) — used by
    ///    tests / unusual installs to point at a specific binary.
    /// 2. Each directory in `PATH`.
    /// 3. The common install locations in `fallbackDirs`.
    ///
    /// Throws `MaycastError.externalToolNotFound` with an install hint if no
    /// executable file is found.
    public static func locate(
        _ name: String = "ffmpeg",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let fm = FileManager.default

        let overrideKey = "MAYCAST_\(name.uppercased())"
        if let override = environment[overrideKey], !override.isEmpty {
            if fm.isExecutableFile(atPath: override) {
                return URL(fileURLWithPath: override)
            }
            throw MaycastError.externalToolNotFound(
                tool: name,
                hint: "\(overrideKey)=\(override) is not an executable file."
            )
        }

        var searchDirs: [String] = []
        if let path = environment["PATH"] {
            searchDirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        searchDirs.append(contentsOf: fallbackDirs)

        var seen = Set<String>()
        for dir in searchDirs where seen.insert(dir).inserted {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw MaycastError.externalToolNotFound(
            tool: name,
            hint: "Install it with `brew install ffmpeg` (the final mix is encoded to MP3 with chapters via ffmpeg)."
        )
    }

    /// Run `ffmpeg` with the given arguments, throwing on a non-zero exit.
    /// stdin is closed (`-nostdin`) so a missing input never blocks the process.
    public static func run(
        _ arguments: [String],
        executable: URL? = nil
    ) throws {
        let exe = try executable ?? locate()
        let process = Process()
        process.executableURL = exe
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + arguments

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw MaycastError.externalToolFailed(
                tool: exe.lastPathComponent, code: -1, message: "\(error)"
            )
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MaycastError.externalToolFailed(
                tool: exe.lastPathComponent,
                code: process.terminationStatus,
                message: message.isEmpty ? "(no stderr)" : message
            )
        }
    }
}
