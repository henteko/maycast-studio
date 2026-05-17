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
}
