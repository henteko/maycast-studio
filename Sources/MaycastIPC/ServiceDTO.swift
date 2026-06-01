import Foundation
import MaycastCore

public enum ServiceOperation: String, Codable, Sendable {
    case transcribe
    case slice
    case mix
    case chapter
}

public struct ServiceRequest: Codable, Sendable {
    public var operation: ServiceOperation
    public var episodeBundlePath: String
    public var trackID: String?
    public var params: JSONValue?
    public var outputPath: String?

    public init(
        operation: ServiceOperation,
        episodeBundlePath: String,
        trackID: String? = nil,
        params: JSONValue? = nil,
        outputPath: String? = nil
    ) {
        self.operation = operation
        self.episodeBundlePath = episodeBundlePath
        self.trackID = trackID
        self.params = params
        self.outputPath = outputPath
    }
}

public struct ServiceResponse: Codable, Sendable {
    public var success: Bool
    public var generationPath: String?
    public var exportPath: String?
    public var message: String?
    public var errorMessage: String?

    public init(
        success: Bool,
        generationPath: String? = nil,
        exportPath: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil
    ) {
        self.success = success
        self.generationPath = generationPath
        self.exportPath = exportPath
        self.message = message
        self.errorMessage = errorMessage
    }

    public static func ok(generationPath: String? = nil, exportPath: String? = nil, message: String? = nil) -> ServiceResponse {
        ServiceResponse(success: true, generationPath: generationPath, exportPath: exportPath, message: message)
    }

    public static func failure(_ message: String) -> ServiceResponse {
        ServiceResponse(success: false, errorMessage: message)
    }
}
