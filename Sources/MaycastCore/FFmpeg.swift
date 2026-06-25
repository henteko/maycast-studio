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

    /// Like `run`, but streams ffmpeg's machine-readable `-progress` output and
    /// reports a 0...1 fraction via `onProgress` as encoding proceeds.
    ///
    /// `expectedDurationSec` is the output media's duration; progress is
    /// `out_time / expectedDuration`. The callback may be invoked many times a
    /// second on the calling thread — hop to the main actor before touching UI.
    /// Blocks until ffmpeg exits (same contract as `run`).
    public static func runWithProgress(
        _ arguments: [String],
        executable: URL? = nil,
        expectedDurationSec: Double?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let exe = try executable ?? locate()
        let process = Process()
        process.executableURL = exe
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                             "-progress", "pipe:1", "-nostats"] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain stderr concurrently on a background thread. Otherwise a chatty
        // encoder (e.g. h264_videotoolbox can emit a warning per frame) fills
        // the 64 KB stderr pipe buffer, blocks ffmpeg's write, which stops it
        // emitting progress on stdout — and we'd deadlock reading stdout while
        // ffmpeg is stuck writing stderr.
        final class ErrBox: @unchecked Sendable { var data = Data() }
        let errBox = ErrBox()
        let errHandle = errPipe.fileHandleForReading
        let errQueue = DispatchQueue(label: "maycast.ffmpeg.stderr")
        errQueue.async { errBox.data = errHandle.readDataToEndOfFile() }

        do {
            try process.run()
        } catch {
            throw MaycastError.externalToolFailed(tool: exe.lastPathComponent, code: -1, message: "\(error)")
        }

        // Read the progress stream live on this thread. `-progress` emits
        // `key=value` lines; `out_time_us=<microseconds>` is the position.
        let outHandle = outPipe.fileHandleForReading
        var buffer = ""
        while true {
            let chunk = outHandle.availableData
            if chunk.isEmpty { break }   // EOF → ffmpeg closed stdout (exiting)
            buffer += String(decoding: chunk, as: UTF8.self)
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                if let onProgress, let total = expectedDurationSec, total > 0,
                   let us = Self.parseOutTimeMicroseconds(line) {
                    let frac = min(1.0, max(0.0, (Double(us) / 1_000_000.0) / total))
                    onProgress(frac)
                }
            }
        }

        process.waitUntilExit()
        errQueue.sync {}                 // ensure stderr is fully drained
        let errData = errBox.data

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MaycastError.externalToolFailed(
                tool: exe.lastPathComponent,
                code: process.terminationStatus,
                message: message.isEmpty ? "(no stderr)" : message
            )
        }
        onProgress?(1.0)
    }

    /// Parse `out_time_us=<microseconds>` from a `-progress` line, else nil.
    private static func parseOutTimeMicroseconds(_ line: String) -> Int64? {
        let prefix = "out_time_us="
        guard line.hasPrefix(prefix) else { return nil }
        return Int64(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    }
}
