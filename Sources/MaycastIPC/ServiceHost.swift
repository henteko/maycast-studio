import Foundation
import MaycastCore

/// Helper for service executables. Reads a `ServiceRequest` from stdin,
/// invokes the provided handler, writes a `ServiceResponse` to stdout, exits.
public enum ServiceHost {
    public static func run(handler: (ServiceRequest) throws -> ServiceResponse) -> Never {
        let encoder = JSONCoders.makeEncoder()
        do {
            let requestData = FileHandle.standardInput.readDataToEndOfFile()
            let request = try JSONCoders.makeDecoder().decode(ServiceRequest.self, from: requestData)
            let response = try handler(request)
            let responseData = try encoder.encode(response)
            FileHandle.standardOutput.write(responseData)
            exit(response.success ? 0 : 1)
        } catch {
            let failure = ServiceResponse.failure("Service crashed: \(error)")
            if let data = try? encoder.encode(failure) {
                FileHandle.standardOutput.write(data)
            }
            exit(2)
        }
    }

    /// Async variant of `run` for services that need to await Swift Concurrency
    /// APIs (e.g. `SpeechAnalyzer`). Bridges the async handler to the sync
    /// process lifecycle with a single DispatchSemaphore.
    public static func runAsync(handler: @escaping @Sendable (ServiceRequest) async throws -> ServiceResponse) -> Never {
        let encoder = JSONCoders.makeEncoder()
        let semaphore = DispatchSemaphore(value: 0)

        let requestData = FileHandle.standardInput.readDataToEndOfFile()
        let parsedRequest: ServiceRequest
        do {
            parsedRequest = try JSONCoders.makeDecoder().decode(ServiceRequest.self, from: requestData)
        } catch {
            let failure = ServiceResponse.failure("Failed to decode request: \(error)")
            if let data = try? encoder.encode(failure) {
                FileHandle.standardOutput.write(data)
            }
            exit(2)
        }

        // Box for moving the result back from the detached Task. Memory
        // ordering is provided by the semaphore signal/wait pair.
        let box = OutcomeBox()
        Task {
            do {
                box.set(.success(try await handler(parsedRequest)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()

        let response: ServiceResponse
        switch box.get() {
        case .some(.success(let r)): response = r
        case .some(.failure(let e)): response = .failure("Service crashed: \(e)")
        case .none: response = .failure("Service produced no response")
        }
        if let data = try? encoder.encode(response) {
            FileHandle.standardOutput.write(data)
        }
        exit(response.success ? 0 : 1)
    }
}

/// Synchronisation box used by `runAsync` to ferry a result across the
/// async/sync boundary.
private final class OutcomeBox: @unchecked Sendable {
    private var value: Result<ServiceResponse, Error>?
    private let lock = NSLock()

    func set(_ v: Result<ServiceResponse, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = v
    }

    func get() -> Result<ServiceResponse, Error>? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
