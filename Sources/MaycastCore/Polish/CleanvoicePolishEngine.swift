import Foundation

/// Settings for a Cleanvoice edit. Mirrors the options described at
/// https://docs.cleanvoice.ai/docs/v2/configuration .
public struct CleanvoicePolishOptions: Equatable, Sendable {
    /// Breath removal. `full` is Cleanvoice's `true` (recommended for
    /// challenging audio); `natural` keeps more breathing; `legacy` is the
    /// conservative mode for already-clean recordings.
    public enum Breath: String, CaseIterable, Sendable, Equatable {
        case off
        case natural
        case legacy
        case full

        var configValue: Cleanvoice.BoolOrString {
            switch self {
            case .off: return .bool(false)
            case .full: return .bool(true)
            case .natural, .legacy: return .string(rawValue)
            }
        }
    }

    // Loudness
    public var normalize: Bool
    public var targetLufs: Double  // used only when `normalize` is on

    // Enhancement
    public var removeNoise: Bool
    public var studioSound: Bool

    // Removal
    public var breath: Breath
    public var mouthSounds: Bool
    public var fillers: Bool
    public var longSilences: Bool
    public var stutters: Bool
    public var hesitations: Bool

    /// Silence the removed sounds instead of cutting them, keeping the
    /// original timing.
    public var muteEdits: Bool

    public init(
        normalize: Bool,
        targetLufs: Double,
        removeNoise: Bool,
        studioSound: Bool,
        breath: Breath,
        mouthSounds: Bool,
        fillers: Bool,
        longSilences: Bool,
        stutters: Bool,
        hesitations: Bool,
        muteEdits: Bool
    ) {
        self.normalize = normalize
        self.targetLufs = targetLufs
        self.removeNoise = removeNoise
        self.studioSound = studioSound
        self.breath = breath
        self.mouthSounds = mouthSounds
        self.fillers = fillers
        self.longSilences = longSilences
        self.stutters = stutters
        self.hesitations = hesitations
        self.muteEdits = muteEdits
    }

    public static let defaults = CleanvoicePolishOptions(
        normalize: true,
        targetLufs: -16,
        removeNoise: true,
        studioSound: false,
        breath: .natural,
        mouthSounds: true,
        fillers: true,
        longSilences: true,
        stutters: false,
        hesitations: false,
        muteEdits: false
    )

    /// Whether any enabled option removes audio (and so changes its length
    /// unless the edits are muted).
    public var removesAudio: Bool {
        breath != .off || mouthSounds || fillers || longSilences || stutters || hesitations
    }

    /// Whether a run will cut audio that a video track has to follow — then
    /// the cut list (`export_timestamps`) is requested and replayed onto the
    /// video edit. (Cleanvoice's own video mode returns the video uncut, so
    /// Maycast cuts the picture itself, deferred to export like every edit.)
    public func needsCutList(hasVideo: Bool) -> Bool {
        hasVideo && removesAudio && !muteEdits
    }

    /// Edit config sent to Cleanvoice. Output is always WAV so the generation
    /// is lossless; multitrack runs stay un-merged (one file per speaker).
    public func config(exportTimestamps: Bool = false) -> Cleanvoice.Config {
        Cleanvoice.Config(
            fillers: fillers,
            longSilences: longSilences,
            mouthSounds: mouthSounds,
            breath: breath.configValue,
            stutters: stutters,
            hesitations: hesitations,
            muted: muteEdits,
            removeNoise: removeNoise,
            studioSound: studioSound,
            normalize: normalize,
            targetLufs: normalize ? targetLufs : nil,
            exportFormat: "wav",
            exportTimestamps: exportTimestamps ? true : nil,
            merge: false
        )
    }
}

/// Polish via the Cleanvoice v2 API: every speaker is uploaded, submitted as
/// one multitrack edit (so cuts line up across speakers), and the cleaned
/// per-speaker files are downloaded — as a ZIP or as individual files,
/// whichever Cleanvoice returns. For video tracks the cut list is fetched too
/// and composed into the video edit, so the picture follows the cuts.
public struct CleanvoicePolishEngine: PolishEngine {
    public let provider: PolishProvider = .cleanvoice

    private let apiKey: String
    private let options: CleanvoicePolishOptions
    private let session: URLSession?
    private let baseURL: URL
    private let pollInitialDelay: Double
    private let pollInterval: Double

    public init(
        apiKey: String,
        options: CleanvoicePolishOptions,
        session: URLSession? = nil,
        baseURL: URL = Cleanvoice.baseURL,
        pollInitialDelay: Double = 15,
        pollInterval: Double = 10
    ) {
        self.apiKey = apiKey
        self.options = options
        self.session = session
        self.baseURL = baseURL
        self.pollInitialDelay = pollInitialDelay
        self.pollInterval = pollInterval
    }

    public func run(
        bundleURL: URL,
        speakers: [PolishSpeaker],
        onProgress: @Sendable @escaping (PolishProgress) -> Void
    ) async throws -> [PolishTrackOutput] {
        let client = CleanvoiceClient(apiKey: apiKey, baseURL: baseURL, session: session)
        let speakerIDs = speakers.map(\.id)

        let bundle = try EpisodeBundle.open(at: bundleURL)
        let hasVideo = speakers.contains { bundle.track(withID: $0.id)?.hasVideo ?? false }
        let needsCutList = options.needsCutList(hasVideo: hasVideo)

        // 1) Upload each speaker under a track-derived name, so the outputs
        //    can be told apart (every generation in a bundle is `NNN_<op>.wav`).
        var uploadProgress = Dictionary(uniqueKeysWithValues: speakerIDs.map { ($0, 0.0) })
        onProgress(.uploading(uploadProgress))
        var fileURLs: [String] = []
        for sp in speakers {
            try Task.checkCancellation()
            let ext = sp.fileURL.pathExtension.isEmpty ? "wav" : sp.fileURL.pathExtension.lowercased()
            fileURLs.append(try await client.upload(fileURL: sp.fileURL, filename: "\(sp.id).\(ext)"))
            uploadProgress[sp.id] = 1.0
            onProgress(.uploading(uploadProgress))
        }

        // 2) Submit one edit. Multiple files = tracks of the same recording.
        let request = Cleanvoice.CreateEditRequest(input: .init(
            files: fileURLs,
            uploadType: speakers.count > 1 ? "multitrack" : nil,
            config: options.config(exportTimestamps: needsCutList)
        ))
        let editID = try await client.createEdit(request)

        // 3) Poll.
        onProgress(.processing("PENDING"))
        let done = try await client.pollUntilDone(
            id: editID,
            initialDelaySeconds: pollInitialDelay,
            intervalSeconds: pollInterval
        ) { tick in
            onProgress(.processing(tick.stageDescription))
        }
        let downloadURLs = (done.result?.downloadURL?.values ?? []).compactMap(URL.init(string:))
        guard !downloadURLs.isEmpty else {
            throw CleanvoiceError.unexpected("Cleanvoice returned no download URL")
        }

        // 4) Download every result; unpack ZIPs. The links expire quickly, so
        //    this happens right after SUCCESS.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanvoice-\(editID)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        onProgress(.downloading(Dictionary(uniqueKeysWithValues: speakerIDs.map { ($0, 0.0) })))
        var returnedFiles: [URL] = []
        for (index, url) in downloadURLs.enumerated() {
            try Task.checkCancellation()
            let name = url.lastPathComponent.isEmpty ? "result-\(index)" : url.lastPathComponent
            let dest = tmpDir.appendingPathComponent("\(index)-\(name)")
            let count = Double(downloadURLs.count)
            try await client.download(from: url, to: dest) { p in
                let overall = (Double(index) + p) / count
                onProgress(.downloading(Dictionary(uniqueKeysWithValues: speakerIDs.map { ($0, overall) })))
            }
            if Self.isZip(dest) {
                let extracted = try ZipExtractor.extract(archive: dest, to: tmpDir.appendingPathComponent("unzipped-\(index)"))
                returnedFiles.append(contentsOf: extracted.extractedFiles)
            } else {
                returnedFiles.append(Self.restoringFilename(dest, original: name))
            }
        }

        // 4b) Cut list for the video tracks: the removed spans on the input
        //     timeline, shared by every speaker (multitrack cuts line up).
        var removedRegions: [AuphonicCutList.Region] = []
        if needsCutList {
            guard let urlString = done.result?.timestampsMarkersURLs?["timeline_audacity"],
                  let url = URL(string: urlString)
            else {
                throw CleanvoiceError.unexpected(
                    "Cleanvoice returned no cut list, so the video can't follow the cuts. Turn on “Mute instead of cut” for this episode."
                )
            }
            let dest = tmpDir.appendingPathComponent("timeline_audacity.txt")
            try await client.download(from: url, to: dest)
            removedRegions = AuphonicCutList.parseAudacityRegions(try String(contentsOf: dest, encoding: .utf8))
        }

        // 5) Write one polish generation per track; video tracks get the cut
        //    as a kept-region arrangement, trued up to the cleaned audio's
        //    length so the picture can't drift (see `matchingOutputDuration`).
        return try PolishIngest.writeGenerations(
            bundleURL: bundleURL,
            speakers: speakers,
            cleaned: PolishIngest.assign(files: returnedFiles, to: speakerIDs),
            videoCut: { sp, cleanedFile in
                guard needsCutList else { return nil }
                return try AuphonicCutList.keptArrangement(
                    removed: removedRegions,
                    totalDuration: try AudioIO.probeDuration(of: sp.fileURL),
                    matchingOutputDuration: try AudioIO.probeDuration(of: cleanedFile)
                )
            },
            params: Self.makeParamsJSON(options: options),
            returnedFiles: returnedFiles
        )
    }

    /// ZIP local-file header magic ("PK\u{3}\u{4}").
    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// Downloaded files are stored as `<index>-<name>`; hand ingest the bare
    /// name so speaker matching sees what Cleanvoice called the file.
    private static func restoringFilename(_ url: URL, original: String) -> URL {
        let dir = url.deletingLastPathComponent().appendingPathComponent(
            url.deletingPathExtension().lastPathComponent, isDirectory: true
        )
        let target = dir.appendingPathComponent(original)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }

    static func makeParamsJSON(options: CleanvoicePolishOptions) -> JSONValue {
        var dict: [String: JSONValue] = [
            "provider": .string(PolishProvider.cleanvoice.rawValue),
            "normalize": .bool(options.normalize),
            "remove_noise": .bool(options.removeNoise),
            "studio_sound": .bool(options.studioSound),
            "breath": .string(options.breath.rawValue),
            "mouth_sounds": .bool(options.mouthSounds),
            "fillers": .bool(options.fillers),
            "long_silences": .bool(options.longSilences),
            "stutters": .bool(options.stutters),
            "hesitations": .bool(options.hesitations),
            "muted": .bool(options.muteEdits),
        ]
        if options.normalize { dict["target_lufs"] = .number(options.targetLufs) }
        return .object(dict)
    }
}
