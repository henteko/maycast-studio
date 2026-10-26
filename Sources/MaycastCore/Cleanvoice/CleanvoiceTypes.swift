import Foundation

/// Codable representations of the Cleanvoice v2 REST API payloads.
///
/// Reference: https://docs.cleanvoice.ai/docs/v2/configuration
/// (+ the official SDKs' type definitions for the response shapes the docs
/// leave out).
public enum Cleanvoice {
    public static let baseURL = URL(string: "https://api.cleanvoice.ai")!

    // MARK: - Status

    /// Edit status strings. Everything that isn't `SUCCESS` / `FAILURE` is an
    /// in-progress stage (`PENDING`, `PREPROCESSING`, `EDITING`, `EXPORT`,
    /// `RETRY`, …) — new ones may appear, so only the terminal two are named.
    public enum Status {
        public static let success = "SUCCESS"
        public static let failure = "FAILURE"
    }

    // MARK: - Config

    /// Subset of the edit options Maycast Studio uses. Only set keys are sent;
    /// others use Cleanvoice's defaults.
    public struct Config: Codable, Sendable, Equatable {
        public var fillers: Bool?
        public var longSilences: Bool?
        public var mouthSounds: Bool?
        /// `true` / `false`, or a mode string (`"natural"`, `"legacy"`).
        public var breath: BoolOrString?
        public var stutters: Bool?
        public var hesitations: Bool?
        /// Silence the edits instead of cutting them (keeps original timing).
        public var muted: Bool?
        public var removeNoise: Bool?
        public var studioSound: Bool?
        public var normalize: Bool?
        public var targetLufs: Double?
        public var exportFormat: String?
        /// Also return marker / cut-list files (`timestamps_markers_urls`).
        public var exportTimestamps: Bool?
        public var merge: Bool?

        public init(
            fillers: Bool? = nil,
            longSilences: Bool? = nil,
            mouthSounds: Bool? = nil,
            breath: BoolOrString? = nil,
            stutters: Bool? = nil,
            hesitations: Bool? = nil,
            muted: Bool? = nil,
            removeNoise: Bool? = nil,
            studioSound: Bool? = nil,
            normalize: Bool? = nil,
            targetLufs: Double? = nil,
            exportFormat: String? = nil,
            exportTimestamps: Bool? = nil,
            merge: Bool? = nil
        ) {
            self.fillers = fillers
            self.longSilences = longSilences
            self.mouthSounds = mouthSounds
            self.breath = breath
            self.stutters = stutters
            self.hesitations = hesitations
            self.muted = muted
            self.removeNoise = removeNoise
            self.studioSound = studioSound
            self.normalize = normalize
            self.targetLufs = targetLufs
            self.exportFormat = exportFormat
            self.exportTimestamps = exportTimestamps
            self.merge = merge
        }

        enum CodingKeys: String, CodingKey {
            case fillers
            case longSilences = "long_silences"
            case mouthSounds = "mouth_sounds"
            case breath
            case stutters
            case hesitations
            case muted
            case removeNoise = "remove_noise"
            case studioSound = "studio_sound"
            case normalize
            case targetLufs = "target_lufs"
            case exportFormat = "export_format"
            case exportTimestamps = "export_timestamps"
            case merge
        }
    }

    // MARK: - Create edit

    public struct CreateEditRequest: Codable, Sendable, Equatable {
        public var input: Input

        public struct Input: Codable, Sendable, Equatable {
            public var files: [String]
            /// `"multitrack"` when `files` are separate tracks of one recording.
            public var uploadType: String?
            public var config: Config

            public init(files: [String], uploadType: String? = nil, config: Config) {
                self.files = files
                self.uploadType = uploadType
                self.config = config
            }

            enum CodingKeys: String, CodingKey {
                case files
                case uploadType = "upload_type"
                case config
            }
        }

        public init(input: Input) { self.input = input }
    }

    public struct CreateEditResponse: Codable, Sendable, Equatable {
        public var id: String
    }

    // MARK: - Upload

    public struct UploadURLResponse: Codable, Sendable, Equatable {
        public var signedUrl: String
    }

    // MARK: - Retrieve edit

    /// `GET /v2/edits/{id}`. While running, `result` is a progress object
    /// (`state`, `job_name`, `done`, `total`); on success it carries the
    /// output URLs. Both shapes decode into `Result` — every field is optional.
    public struct EditResponse: Codable, Sendable, Equatable {
        public var taskID: String?
        public var status: String
        public var result: Result?

        public struct Result: Codable, Sendable, Equatable {
            // Success
            public var downloadURL: StringOrArray?
            public var mergedAudioURL: StringOrArray?
            public var filename: String?
            /// With `export_timestamps`: marker files by kind. Observed keys:
            /// `timeline_audacity` (removed `[start, end)` spans on the input
            /// timeline, Audacity-regions format), `timeline_edl`,
            /// `timeline_reaper`, `timeline_audition`, `markers_*` (cut
            /// points on the output timeline). Empty `[]` when not requested.
            public var timestampsMarkersURLs: [String: String]?
            // Progress
            public var state: String?
            public var jobName: String?
            public var done: Double?
            public var total: Double?
            // Failure (best effort — the shape isn't documented)
            public var error: String?

            enum CodingKeys: String, CodingKey {
                case downloadURL = "download_url"
                case mergedAudioURL = "merged_audio_url"
                case filename
                case timestampsMarkersURLs = "timestamps_markers_urls"
                case state
                case jobName = "job_name"
                case done
                case total
                case error
            }

            public init(from decoder: Decoder) throws {
                // Lenient: a field of an unexpected type is treated as absent
                // instead of failing the whole poll.
                let c = try decoder.container(keyedBy: CodingKeys.self)
                downloadURL = try? c.decodeIfPresent(StringOrArray.self, forKey: .downloadURL)
                mergedAudioURL = try? c.decodeIfPresent(StringOrArray.self, forKey: .mergedAudioURL)
                filename = try? c.decodeIfPresent(String.self, forKey: .filename)
                timestampsMarkersURLs = try? c.decodeIfPresent([String: String].self, forKey: .timestampsMarkersURLs)
                state = try? c.decodeIfPresent(String.self, forKey: .state)
                jobName = try? c.decodeIfPresent(String.self, forKey: .jobName)
                done = try? c.decodeIfPresent(Double.self, forKey: .done)
                total = try? c.decodeIfPresent(Double.self, forKey: .total)
                error = try? c.decodeIfPresent(String.self, forKey: .error)
            }

            public init(
                downloadURL: StringOrArray? = nil,
                mergedAudioURL: StringOrArray? = nil,
                filename: String? = nil,
                timestampsMarkersURLs: [String: String]? = nil,
                state: String? = nil,
                jobName: String? = nil,
                done: Double? = nil,
                total: Double? = nil,
                error: String? = nil
            ) {
                self.downloadURL = downloadURL
                self.mergedAudioURL = mergedAudioURL
                self.filename = filename
                self.timestampsMarkersURLs = timestampsMarkersURLs
                self.state = state
                self.jobName = jobName
                self.done = done
                self.total = total
                self.error = error
            }
        }

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case status
            case result
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
            status = try c.decode(String.self, forKey: .status)
            // `result` is `null`, a progress object, a success object — or,
            // on failure, sometimes a bare string. Anything non-object → nil.
            result = try? c.decodeIfPresent(Result.self, forKey: .result)
        }

        /// Human-readable stage for the UI, e.g. "PREPROCESSING 14%".
        /// (`job_name` is just the uploaded file names, so it isn't shown;
        /// `done` / `total` is a percentage of the whole edit.)
        public var stageDescription: String {
            if let done = result?.done, let total = result?.total, total > 0 {
                return "\(status) \(Int((done / total * 100).rounded()))%"
            }
            return status
        }
    }

    // MARK: - Helpers

    /// A JSON value that is either a bool or a string (e.g. `breath`).
    public enum BoolOrString: Codable, Sendable, Equatable {
        case bool(Bool)
        case string(String)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) } else { self = .string(try c.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let b): try c.encode(b)
            case .string(let s): try c.encode(s)
            }
        }
    }

    /// A JSON value that is either one string or an array of strings
    /// (`download_url`, `merged_audio_url`). Empty strings are dropped.
    public struct StringOrArray: Codable, Sendable, Equatable {
        public var values: [String]

        public init(_ values: [String]) { self.values = values }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                values = s.isEmpty ? [] : [s]
            } else {
                values = try c.decode([String].self).filter { !$0.isEmpty }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(values)
        }
    }
}

// MARK: - Errors

public enum CleanvoiceError: Error, CustomStringConvertible, Sendable {
    case http(status: Int, body: String?)
    case decoding(underlying: Error)
    case timeout(editID: String, waited: TimeInterval)
    case editFailed(editID: String, message: String?)
    case fileNotFound(URL)
    case unexpected(String)

    public var description: String {
        switch self {
        case .http(let s, let b): return "Cleanvoice API: HTTP \(s)" + (b.map { " — \($0)" } ?? "")
        case .decoding(let e): return "Failed to decode Cleanvoice response: \(e)"
        case .timeout(let id, let t): return "Cleanvoice edit \(id) timed out after \(Int(t))s"
        case .editFailed(let id, let m): return "Cleanvoice edit \(id) failed" + (m.map { " — \($0)" } ?? "")
        case .fileNotFound(let u): return "File not found: \(u.path)"
        case .unexpected(let s): return s
        }
    }
}
