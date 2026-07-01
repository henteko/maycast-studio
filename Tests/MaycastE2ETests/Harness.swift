import Foundation
import MaycastCore

/// Test harness for invoking the built `maycast` binary as a subprocess.
///
/// The harness assumes that `swift build` (or `swift test`) has placed the
/// `maycast` binary and the four service executables under `.build/<config>/`
/// at the package root. The service executables are also made discoverable to
/// the CLI by setting the `MAYCAST_XPC_SERVICES_DIR` environment variable.
struct E2EHarness {
    let packageRoot: URL
    let buildDirectory: URL
    let maycastBinary: URL

    init(file: String = #filePath) {
        let root = Self.findPackageRoot(startingFrom: URL(fileURLWithPath: file))
        self.packageRoot = root
        // `swift test` always builds in debug.
        let build = root.appendingPathComponent(".build/debug", isDirectory: true)
        self.buildDirectory = build
        self.maycastBinary = build.appendingPathComponent("maycast")
    }

    private static func findPackageRoot(startingFrom url: URL) -> URL {
        var current = url
        let fm = FileManager.default
        while current.pathComponents.count > 1 {
            if fm.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        fatalError("Could not locate Package.swift from \(url.path)")
    }

    // MARK: - Run

    struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { exitCode == 0 }
    }

    func run(_ arguments: [String], extraEnvironment: [String: String] = [:]) throws -> RunResult {
        let process = Process()
        process.executableURL = maycastBinary
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["MAYCAST_XPC_SERVICES_DIR"] = buildDirectory.path
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Workspace helpers

    func makeTempWorkspace(prefix: String = "maycast-e2e") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Write a tiny dummy file. **Does not produce a valid audio file** — use this
    /// only for tests that verify file copy semantics (e.g. Show assets).
    func writeDummyAudio(at url: URL, content: String = "DUMMY_AUDIO") throws {
        try content.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// Write a real, valid WAV file containing silence. Use this whenever the
    /// CLI under test will actually decode the file (import / slice / polish / mix).
    func writeSilentWAV(
        at url: URL,
        duration: TimeInterval = 1.0,
        sampleRate: Double = 48000,
        channelCount: Int = 1
    ) throws {
        let buffer = AudioIO.silence(
            duration: duration,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        try AudioIO.writeWAV(buffer, to: url)
    }

    /// Write a real WAV containing a sine wave (useful when the test needs
    /// audible content rather than silence).
    func writeSineWaveWAV(
        at url: URL,
        frequency: Double = 440,
        duration: TimeInterval = 1.0,
        sampleRate: Double = 48000,
        channelCount: Int = 1
    ) throws {
        let buffer = AudioIO.sineWave(
            frequency: frequency,
            duration: duration,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        try AudioIO.writeWAV(buffer, to: url)
    }

    /// Synthesize a real, valid video file (H.264 + AAC) via ffmpeg's lavfi
    /// sources. Used to exercise the video import / mp4 export paths. Requires a
    /// system ffmpeg with libx264 — the same dependency the MP3 export needs.
    func writeTestVideo(
        at url: URL,
        duration: TimeInterval = 1.0,
        frequency: Double = 440
    ) throws {
        try FFmpeg.run([
            "-f", "lavfi", "-i", "testsrc=duration=\(duration):size=160x120:rate=15",
            "-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=\(duration)",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-shortest",
            url.path,
        ])
    }

    /// Synthesize a **variable-frame-rate** (VFR) H.264 + AAC video by
    /// concatenating short chunks encoded at alternating frame rates. Real
    /// screen / webcam recordings are VFR (the source of the lip-sync drift bug:
    /// the export forces a single CFR rate, so frame-quantization error
    /// accumulates across cuts). The container's `avg_frame_rate` ends up between
    /// the two chunk rates, which is exactly what the renderer keys off.
    func writeVFRTestVideo(
        at url: URL,
        duration: TimeInterval = 24.0,
        chunk: TimeInterval = 2.0,
        rates: [Int] = [23, 24],
        frequency: Double = 300
    ) throws {
        let fm = FileManager.default
        let scratch = url.deletingLastPathComponent()
            .appendingPathComponent("vfr-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        var listLines: [String] = []
        let chunks = max(1, Int((duration / chunk).rounded()))
        for i in 0..<chunks {
            let rate = rates[i % rates.count]
            let seg = scratch.appendingPathComponent("seg_\(i).mp4")
            try FFmpeg.run([
                "-f", "lavfi", "-i", "testsrc=duration=\(chunk):size=160x120:rate=\(rate)",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", seg.path,
            ])
            listLines.append("file '\(seg.path)'")
        }
        let listURL = scratch.appendingPathComponent("list.txt")
        try listLines.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)

        let videoOnly = scratch.appendingPathComponent("vfr_v.mp4")
        try FFmpeg.run(["-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", videoOnly.path])
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try FFmpeg.run([
            "-i", videoOnly.path,
            "-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=\(duration)",
            "-c:v", "copy", "-c:a", "aac", "-shortest", url.path,
        ])
    }

    /// Synthesize an in-sync video whose **video stream starts `offset`s after
    /// its audio** (camera lags mic), with a white-flash + tone burst that
    /// coincide at `eventPTS`. This is the shape that desyncs when the export
    /// ignores the stream's `start_time`: the picture shifts by `offset`. The
    /// flash is detectable via `blackdetect`, the tone via `silencedetect`.
    func writeOffsetStartTimeVideo(
        at url: URL,
        duration: TimeInterval = 16.0,
        offset: TimeInterval = 2.0,
        eventPTS: TimeInterval = 10.0,
        eventLength: TimeInterval = 0.3
    ) throws {
        let scratch = url.deletingLastPathComponent()
            .appendingPathComponent("off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Video is 0-based; the flash sits at (eventPTS - offset) so that after
        // the +offset mux it lands exactly on `eventPTS`.
        let flashStart = eventPTS - offset
        let vid = scratch.appendingPathComponent("v.mp4")
        try FFmpeg.run([
            "-f", "lavfi", "-i", "color=c=black:s=160x120:d=\(duration):r=30",
            "-vf", "drawbox=color=white:t=fill:enable='between(t,\(flashStart),\(flashStart + eventLength))'",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", vid.path,
        ])
        let aud = scratch.appendingPathComponent("a.wav")
        try FFmpeg.run([
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=\(duration)",
            "-af", "volume=0:enable='not(between(t,\(eventPTS),\(eventPTS + eventLength)))'",
            aud.path,
        ])
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FFmpeg.run([
            "-itsoffset", "\(offset)", "-i", vid.path, "-i", aud.path,
            "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-shortest", url.path,
        ])
    }

    /// Run `ffmpeg` (which logs analysis filters to stderr) and return stderr.
    func ffmpegStderr(_ arguments: [String]) -> String {
        guard let exe = try? FFmpeg.locate("ffmpeg") else { return "" }
        let process = Process()
        process.executableURL = exe
        process.arguments = ["-nostdin", "-hide_banner"] + arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do { try process.run() } catch { return "" }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// First `key:value` (e.g. `black_end`, `silence_end`) number in ffmpeg's
    /// analysis output, or nil.
    func firstMarker(_ text: String, key: String) -> Double? {
        guard let range = text.range(of: key) else { return nil }
        let tail = text[range.upperBound...].drop { $0 == ":" || $0 == " " }
        let number = tail.prefix { "0123456789.".contains($0) }
        return Double(number)
    }

    /// Run `ffprobe` and return its stdout (used to assert mp4 stream / chapter
    /// contents). Returns an empty string if ffprobe can't be located.
    func ffprobe(_ arguments: [String]) -> String {
        guard let exe = try? FFmpeg.locate("ffprobe") else { return "" }
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
