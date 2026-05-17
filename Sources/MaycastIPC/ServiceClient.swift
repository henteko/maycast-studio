import Foundation
import MaycastCore

public enum ServiceClientError: Error, CustomStringConvertible {
    case serviceNotFound(String)
    case launchFailed(String, underlying: Error)
    case invalidResponse(String, raw: String)
    case nonZeroExit(String, code: Int32, stderr: String)

    public var description: String {
        switch self {
        case .serviceNotFound(let name):
            return "Service executable not found: \(name). Set MAYCAST_XPC_SERVICES_DIR or build the package."
        case .launchFailed(let name, let underlying):
            return "Failed to launch service \(name): \(underlying)"
        case .invalidResponse(let name, let raw):
            return "Invalid response from \(name): \(raw)"
        case .nonZeroExit(let name, let code, let stderr):
            return "Service \(name) exited with code \(code). stderr: \(stderr)"
        }
    }
}

/// Client used by the CLI to invoke a service executable.
///
/// Spawns the service as a child process, writes a JSON-encoded `ServiceRequest`
/// to its stdin, reads a JSON-encoded `ServiceResponse` from its stdout.
public struct ServiceClient {
    public let resolver: ServiceResolver
    public let cliBinaryURL: URL?

    public init(resolver: ServiceResolver = ServiceResolver(), cliBinaryURL: URL? = nil) {
        self.resolver = resolver
        self.cliBinaryURL = cliBinaryURL
    }

    public func invoke(_ service: ServiceResolver.Service, request: ServiceRequest) throws -> ServiceResponse {
        guard let executable = resolver.executableURL(for: service, cliBinaryURL: cliBinaryURL) else {
            throw ServiceClientError.serviceNotFound(service.rawValue)
        }

        let process = Process()
        process.executableURL = executable
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ServiceClientError.launchFailed(service.rawValue, underlying: error)
        }

        let requestData = try JSONCoders.makeEncoder().encode(request)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: requestData)
            try stdin.fileHandleForWriting.close()
        } catch {
            throw ServiceClientError.launchFailed(service.rawValue, underlying: error)
        }

        let responseData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderrText = String(data: errorData, encoding: .utf8) ?? ""

        if responseData.isEmpty {
            throw ServiceClientError.nonZeroExit(service.rawValue, code: process.terminationStatus, stderr: stderrText)
        }

        do {
            return try JSONCoders.makeDecoder().decode(ServiceResponse.self, from: responseData)
        } catch {
            let raw = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw ServiceClientError.invalidResponse(service.rawValue, raw: raw)
        }
    }
}
