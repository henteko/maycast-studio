import Foundation

/// Codable representations of the Auphonic Multitrack API JSON payloads.
/// Property names are Swift-style; `CodingKeys` maps them to the inconsistent
/// snake-case / no-separator field names that Auphonic actually uses.
///
/// Reference: https://auphonic.com/help/api/multitrack.html
public enum Auphonic {
    public static let baseURL = URL(string: "https://auphonic.com")!

    // MARK: - Status codes

    /// Auphonic returns a numeric status. 3 = Done is the only success state.
    public enum Status {
        public static let done = 3
        public static let error = 9
        public static let stopped = 10
        public static let outdated = 11
        public static let terminalErrors: Set<Int> = [9, 10, 11]
    }

    // MARK: - Algorithms

    /// Subset of the algorithms Maycast Studio uses. All fields are optional —
    /// only set keys are sent to Auphonic, others use Auphonic's defaults.
    public struct Algorithms: Codable, Sendable, Equatable {
        public var leveler: Bool?
        public var denoise: Bool?
        public var denoiseMethod: String?
        public var denoiseAmount: Double?
        public var fillerCutter: Bool?
        public var silenceCutter: Bool?
        public var coughCutter: Bool?
        public var debreathAmount: Double?
        public var cutMode: String?
        public var fadetime: Double?
        public var loudnessTarget: Double?
        public var hipfilter: Bool?
        public var backforeground: String?
        public var gain: Double?
        public var pan: Double?

        public init(
            leveler: Bool? = nil,
            denoise: Bool? = nil,
            denoiseMethod: String? = nil,
            denoiseAmount: Double? = nil,
            fillerCutter: Bool? = nil,
            silenceCutter: Bool? = nil,
            coughCutter: Bool? = nil,
            debreathAmount: Double? = nil,
            cutMode: String? = nil,
            fadetime: Double? = nil,
            loudnessTarget: Double? = nil,
            hipfilter: Bool? = nil,
            backforeground: String? = nil,
            gain: Double? = nil,
            pan: Double? = nil
        ) {
            self.leveler = leveler
            self.denoise = denoise
            self.denoiseMethod = denoiseMethod
            self.denoiseAmount = denoiseAmount
            self.fillerCutter = fillerCutter
            self.silenceCutter = silenceCutter
            self.coughCutter = coughCutter
            self.debreathAmount = debreathAmount
            self.cutMode = cutMode
            self.fadetime = fadetime
            self.loudnessTarget = loudnessTarget
            self.hipfilter = hipfilter
            self.backforeground = backforeground
            self.gain = gain
            self.pan = pan
        }

        enum CodingKeys: String, CodingKey {
            case leveler
            case denoise
            case denoiseMethod = "denoisemethod"
            case denoiseAmount = "denoiseamount"
            case fillerCutter = "filler_cutter"
            case silenceCutter = "silence_cutter"
            case coughCutter = "cough_cutter"
            case debreathAmount = "debreathamount"
            case cutMode = "cut_mode"
            case fadetime
            case loudnessTarget = "loudnesstarget"
            case hipfilter
            case backforeground
            case gain
            case pan
        }
    }

    // MARK: - Multi-input file

    public struct MultiInputFile: Codable, Sendable, Equatable {
        public var type: String        // "multitrack" | "intro" | "outro"
        public var id: String
        public var offset: Double?
        public var algorithms: Algorithms?

        public init(type: String, id: String, offset: Double? = nil, algorithms: Algorithms? = nil) {
            self.type = type
            self.id = id
            self.offset = offset
            self.algorithms = algorithms
        }
    }

    // MARK: - Output spec

    public struct OutputFile: Codable, Sendable, Equatable {
        public var format: String
        public var ending: String?
        public var bitrate: String?
        public var filename: String?

        public init(format: String, ending: String? = nil, bitrate: String? = nil, filename: String? = nil) {
            self.format = format
            self.ending = ending
            self.bitrate = bitrate
            self.filename = filename
        }
    }

    // MARK: - Production payload (create-production request body)

    public struct ProductionPayload: Codable, Sendable, Equatable {
        public var isMultitrack: Bool
        public var metadata: Metadata?
        public var multiInputFiles: [MultiInputFile]
        public var algorithms: Algorithms
        public var outputFiles: [OutputFile]

        public struct Metadata: Codable, Sendable, Equatable {
            public var title: String?
            public init(title: String? = nil) { self.title = title }
        }

        public init(
            isMultitrack: Bool,
            metadata: Metadata? = nil,
            multiInputFiles: [MultiInputFile],
            algorithms: Algorithms,
            outputFiles: [OutputFile]
        ) {
            self.isMultitrack = isMultitrack
            self.metadata = metadata
            self.multiInputFiles = multiInputFiles
            self.algorithms = algorithms
            self.outputFiles = outputFiles
        }

        enum CodingKeys: String, CodingKey {
            case isMultitrack = "is_multitrack"
            case metadata
            case multiInputFiles = "multi_input_files"
            case algorithms
            case outputFiles = "output_files"
        }
    }

    // MARK: - Output file in response

    public struct OutputFileResponse: Codable, Sendable, Equatable {
        public var format: String?
        public var ending: String?
        public var filename: String?
        public var downloadURL: String?
        public var size: Int?

        enum CodingKeys: String, CodingKey {
            case format
            case ending
            case filename
            case downloadURL = "download_url"
            case size
        }
    }

    // MARK: - Production response

    public struct ProductionResponse: Codable, Sendable, Equatable {
        public var uuid: String
        public var status: Int
        public var statusString: String?
        public var errorMessage: String?
        public var warningMessage: String?
        public var outputFiles: [OutputFileResponse]?
        // NOTE: `multi_input_files` is **intentionally not decoded**. Auphonic
        // echoes the per-track algorithm overrides as strings in the response
        // (e.g. `"pan": "0.0"`), which doesn't round-trip cleanly with our
        // strict `Double?` field. We never read this field after creation, so
        // dropping it from decode avoids a brittle and pointless mapping.
        public var length: Double?
        public var lengthTimestring: String?

        enum CodingKeys: String, CodingKey {
            case uuid
            case status
            case statusString = "status_string"
            case errorMessage = "error_message"
            case warningMessage = "warning_message"
            case outputFiles = "output_files"
            case length
            case lengthTimestring = "length_timestring"
        }
    }

    // MARK: - API envelope

    /// Auphonic wraps responses in `{ status_code, error_code?, error_message?, data }`.
    public struct Envelope<Data: Codable & Sendable>: Codable, Sendable {
        public var statusCode: Int?
        public var errorCode: Int?
        public var errorMessage: String?
        public var data: Data?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case errorCode = "error_code"
            case errorMessage = "error_message"
            case data
        }
    }
}

// MARK: - Errors

public enum AuphonicError: Error, CustomStringConvertible, Sendable {
    case missingAPIKey
    case http(status: Int, body: String?)
    case decoding(underlying: Error)
    case apiError(message: String, statusCode: Int)
    case timeout(uuid: String, waited: TimeInterval)
    case productionFailed(uuid: String, status: Int, statusString: String?, error: String?)
    case download(url: URL, underlying: Error?)
    case fileNotFound(URL)
    case unexpected(String)

    public var description: String {
        switch self {
        case .missingAPIKey: return "Auphonic API key is missing"
        case .http(let s, let b): return "HTTP \(s)" + (b.map { ": \($0)" } ?? "")
        case .decoding(let e): return "Failed to decode Auphonic response: \(e)"
        case .apiError(let m, let s): return "Auphonic API error (HTTP \(s)): \(m)"
        case .timeout(let u, let t): return "Auphonic production \(u) timed out after \(Int(t))s"
        case .productionFailed(let u, let s, let str, let err):
            return "Auphonic production \(u) failed: status=\(s) \(str ?? "")" + (err.map { " — \($0)" } ?? "")
        case .download(let url, let e): return "Failed to download \(url): \(e.map { String(describing: $0) } ?? "unknown error")"
        case .fileNotFound(let u): return "File not found: \(u.path)"
        case .unexpected(let s): return s
        }
    }
}
