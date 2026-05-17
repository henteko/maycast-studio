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
}
