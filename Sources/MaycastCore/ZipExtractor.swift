import Foundation

/// Minimal ZIP extraction by shelling out to `/usr/bin/unzip` (bundled with
/// every macOS release). Used to extract the per-speaker tracks ZIP that
/// Auphonic returns.
public enum ZipExtractor {
    public struct Result: Sendable, Equatable {
        public let extractedFiles: [URL]
    }

    public enum ExtractError: Error, CustomStringConvertible, Sendable {
        case unzipMissing
        case nonZeroExit(code: Int32, stderr: String)
        case io(String)
        public var description: String {
            switch self {
            case .unzipMissing: return "/usr/bin/unzip is not available on this system"
            case .nonZeroExit(let c, let s): return "unzip failed (exit \(c)): \(s)"
            case .io(let s): return s
            }
        }
    }

    /// Unzip `archive` into `destination`, creating the destination if needed.
    /// Returns a list of regular files (not directories) that ended up under
    /// `destination` after extraction.
    public static func extract(archive: URL, to destination: URL) throws -> Result {
        let fm = FileManager.default
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        guard fm.fileExists(atPath: unzip.path) else {
            throw ExtractError.unzipMissing
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = unzip
        // -o: overwrite, -qq: super quiet (stderr only on errors).
        process.arguments = ["-oqq", archive.path, "-d", destination.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw ExtractError.io("could not launch unzip: \(error)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let msg = String(data: errData ?? Data(), encoding: .utf8) ?? ""
            throw ExtractError.nonZeroExit(code: process.terminationStatus, stderr: msg)
        }

        // Walk the destination and collect regular files.
        var files: [URL] = []
        if let enumerator = fm.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true {
                    files.append(url)
                }
            }
        }
        return Result(extractedFiles: files)
    }
}
