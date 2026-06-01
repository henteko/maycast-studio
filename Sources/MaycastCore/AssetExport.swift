import Foundation
import AVFoundation
import CoreMedia

/// A chapter marker positioned on the **final mix timeline** (seconds), ready
/// to be embedded. The caller (mix) is responsible for shifting voice-timeline
/// chapters by the intro lead before handing them here. See docs/chapters.md §6.
public struct ExportChapter: Sendable, Equatable {
    public var startSec: Double
    public var title: String

    public init(startSec: Double, title: String) {
        self.startSec = startSec
        self.title = title
    }
}

/// Output container for the final export.
public enum ExportFormat: Sendable {
    case m4a   // audio-only MPEG-4 (AAC) + optional chapter track
    case mp4   // audio + static-image video (artwork) — future (docs/chapters.md §7)
}

/// Writes an `AudioBuffer` to a final deliverable via `AVAssetWriter`.
///
/// M4A and MP4 share this single path: audio (AAC), chapters (a timed-metadata
/// track associated as the audio track's chapter list), and common metadata
/// (title / artwork) are all format-independent. Only the video track is
/// MP4-specific, so adding MP4 later is just one more writer input.
public struct AssetExportPipeline {
    public var audio: AudioBuffer
    public var chapters: [ExportChapter]
    public var artwork: URL?
    public var format: ExportFormat

    public init(
        audio: AudioBuffer,
        chapters: [ExportChapter] = [],
        artwork: URL? = nil,
        format: ExportFormat = .m4a
    ) {
        self.audio = audio
        self.chapters = chapters
        self.artwork = artwork
        self.format = format
    }

    public func write(to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }

        let sorted = chapters.sorted { $0.startSec < $1.startSec }
        let preferred: AVFileType = (format == .mp4) ? .mp4 : .m4a
        try attempt(fileType: preferred, chapters: sorted, url: url, allowFallback: true)
    }

    // MARK: - Write attempt

    private func attempt(
        fileType: AVFileType,
        chapters sorted: [ExportChapter],
        url: URL,
        allowFallback: Bool
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw MaycastError.audioWriteFailed(url, underlying: error)
        }

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings())
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw MaycastError.audioWriteFailed(url, underlying: exportError("writer cannot add audio input"))
        }
        writer.add(audioInput)

        // Chapters are written as a QuickTime **text** track associated as the
        // audio track's chapter list — the only flavor `chapterMetadataGroups`
        // reads back. (A metadata-track association is valid in the container
        // but invisible to that reader API.)
        var chapterInput: AVAssetWriterInput?
        let textFormatDesc = sorted.isEmpty ? nil : makeTextFormatDescription()
        if !sorted.isEmpty {
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormatDesc)
            input.expectsMediaDataInRealTime = false
            // A language on the chapter track populates `availableChapterLocales`.
            input.languageCode = "en"

            if !writer.canAdd(input) {
                // .m4a may reject a text track; fall back to the .mp4 brand once
                // (still a valid MPEG-4 audio file).
                if allowFallback, fileType == .m4a {
                    FileHandle.standardError.write(Data("AssetExportPipeline: .m4a rejected chapter track, using .mp4 brand\n".utf8))
                    return try attempt(fileType: .mp4, chapters: sorted, url: url, allowFallback: false)
                }
                throw MaycastError.audioWriteFailed(url, underlying: exportError("writer cannot add chapter text track"))
            }
            writer.add(input)
            audioInput.addTrackAssociation(
                withTrackOf: input,
                type: AVAssetTrack.AssociationType.chapterList.rawValue
            )
            chapterInput = input
        }

        guard writer.startWriting() else {
            throw MaycastError.audioWriteFailed(url, underlying: writer.error ?? exportError("startWriting failed"))
        }
        writer.startSession(atSourceTime: .zero)

        // Pull-based, non-realtime writing. Each input is driven by its own
        // `requestMediaDataWhenReady` block and only appends while
        // `isReadyForMoreMediaData` is true — appending when it isn't raises an
        // exception (the crash we hit). Audio is fed in short chunks so a long
        // episode doesn't materialize one multi-GB sample buffer. All per-input
        // state lives in `MediaFeeder` (a serially-driven @unchecked Sendable
        // box) to keep the writer callbacks data-race free.
        let errorBox = ErrorBox()
        let fail: (Error?) -> Void = { errorBox.set($0 ?? writer.error ?? self.exportError("append failed")) }

        let frameCount = audio.frameCount
        let chunkFrames = max(1, Int(audio.sampleRate * 10))   // ~10s per chunk
        let audioFeeder = MediaFeeder(input: audioInput, fail: fail) { index in
            let startFrame = index * chunkFrames
            guard startFrame < frameCount else { return nil }
            let count = min(chunkFrames, frameCount - startFrame)
            return try self.makeAudioSampleBuffer(range: startFrame ..< (startFrame + count), url: url)
        }
        audioFeeder.run(on: DispatchQueue(label: "maycast.export.audio"))

        var chapterFeeder: MediaFeeder?
        if let chapterInput, let textFormatDesc {
            let audioDuration = audio.duration
            let feeder = MediaFeeder(input: chapterInput, fail: fail) { index in
                guard index < sorted.count else { return nil }
                let start = max(0, sorted[index].startSec)
                let end = (index + 1 < sorted.count) ? max(start, sorted[index + 1].startSec) : audioDuration
                return try self.makeTextSampleBuffer(
                    title: sorted[index].title,
                    start: start,
                    duration: max(end - start, 0.001),
                    formatDesc: textFormatDesc,
                    url: url
                )
            }
            feeder.run(on: DispatchQueue(label: "maycast.export.text"))
            chapterFeeder = feeder
        }

        audioFeeder.done.wait()
        chapterFeeder?.done.wait()

        if let error = errorBox.get() {
            throw MaycastError.audioWriteFailed(url, underlying: error)
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        if writer.status != .completed {
            throw MaycastError.audioWriteFailed(url, underlying: writer.error ?? exportError("finishWriting status \(writer.status.rawValue)"))
        }
    }

    /// Thread-safe slot for the first error seen across the writer callbacks.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func set(_ e: Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
    }

    /// Drives one `AVAssetWriterInput` with the pull-based, non-realtime
    /// pattern: it appends samples (produced lazily by `produce(index)`, which
    /// returns nil when finished) only while the input is ready. All mutable
    /// state is confined here and only touched from the input's serial queue.
    private final class MediaFeeder: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let input: AVAssetWriterInput
        private let produce: (Int) throws -> CMSampleBuffer?
        private let fail: (Error?) -> Void
        private var index = 0

        init(
            input: AVAssetWriterInput,
            fail: @escaping (Error?) -> Void,
            produce: @escaping (Int) throws -> CMSampleBuffer?
        ) {
            self.input = input
            self.fail = fail
            self.produce = produce
        }

        func run(on queue: DispatchQueue) {
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    do {
                        guard let sample = try produce(index) else {
                            input.markAsFinished()
                            done.signal()
                            return
                        }
                        if !input.append(sample) {
                            fail(nil)
                            input.markAsFinished()
                            done.signal()
                            return
                        }
                        index += 1
                    } catch {
                        fail(error)
                        input.markAsFinished()
                        done.signal()
                        return
                    }
                }
            }
        }
    }

    // MARK: - Chapter text track

    /// Minimal QuickTime text sample description (60 bytes, big-endian). For a
    /// chapter track only the size and data format ('text') really matter.
    private func makeTextFormatDescription() -> CMFormatDescription? {
        var d = Data()
        func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) } }
        func u8(_ v: UInt8) { d.append(v) }

        u32(60)                                    // sample description size
        d.append(contentsOf: Array("text".utf8))   // data format 'text'
        for _ in 0..<6 { u8(0) }                    // reserved
        u16(1)                                      // data reference index
        u32(0)                                      // display flags
        u32(0)                                      // text justification (0 = left)
        u16(0); u16(0); u16(0)                      // background color RGB
        u16(0); u16(0); u16(0); u16(0)              // default text box
        u32(0); u32(0)                              // reserved
        u16(0)                                      // font number
        u16(0)                                      // font face
        u8(0)                                       // reserved
        u16(0)                                      // reserved
        u16(0); u16(0); u16(0)                      // foreground color RGB
        u8(0)                                       // text name (empty Pascal string)

        var desc: CMFormatDescription?
        let status = d.withUnsafeBytes { raw -> OSStatus in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: raw.bindMemory(to: UInt8.self).baseAddress!,
                size: d.count,
                flavor: nil,
                mediaType: kCMMediaType_Text,
                formatDescriptionOut: &desc
            )
        }
        return status == noErr ? desc : nil
    }

    /// QuickTime text sample: a 16-bit big-endian byte-length prefix, then the
    /// UTF-8 title, then an `'encd'` atom declaring UTF-8 so the reader decodes
    /// non-ASCII titles (e.g. Japanese) correctly. The length prefix counts only
    /// the text bytes; the encoding atom follows.
    private func makeTextSampleBuffer(
        title: String,
        start: Double,
        duration: Double,
        formatDesc: CMFormatDescription,
        url: URL
    ) throws -> CMSampleBuffer {
        let textBytes = Array(title.utf8)
        let len = UInt16(min(textBytes.count, Int(UInt16.max)))
        var data: [UInt8] = [UInt8(len >> 8), UInt8(len & 0xFF)]
        data.append(contentsOf: textBytes)
        // 'encd' encoding atom: size(4)=12, 'encd', TextEncoding(4) for UTF-8
        // = CreateTextEncoding(kTextEncodingUnicodeDefault=0x0100, variant 0,
        //   kUnicodeUTF8Format=4) = 0x04000100.
        let encdValue: UInt32 = 0x0800_0100
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0C])
        data.append(contentsOf: Array("encd".utf8))
        data.append(contentsOf: [
            UInt8((encdValue >> 24) & 0xFF), UInt8((encdValue >> 16) & 0xFF),
            UInt8((encdValue >> 8) & 0xFF), UInt8(encdValue & 0xFF),
        ])
        let byteCount = data.count

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw MaycastError.audioWriteFailed(url, underlying: exportError("text CMBlockBufferCreate failed (\(status))"))
        }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw MaycastError.audioWriteFailed(url, underlying: exportError("text CMBlockBufferReplaceDataBytes failed (\(status))"))
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: duration, preferredTimescale: 1000),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = byteCount
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw MaycastError.audioWriteFailed(url, underlying: exportError("text CMSampleBufferCreate failed (\(status))"))
        }
        return sampleBuffer
    }

    // MARK: - Audio sample buffer

    private func aacSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: audio.channelCount,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    /// Build an interleaved Float32 LPCM `CMSampleBuffer` for a frame range of
    /// the planar `AudioBuffer`, timestamped at the range's start. Feeding the
    /// audio in ranges (chunks) keeps memory bounded on long episodes; the AAC
    /// writer input transcodes each chunk on append.
    private func makeAudioSampleBuffer(range: Range<Int>, url: URL) throws -> CMSampleBuffer {
        let channels = audio.channelCount
        let bytesPerFrame = MemoryLayout<Float>.size * channels
        let frames = range.count

        var asbd = AudioStreamBasicDescription(
            mSampleRate: audio.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let formatDesc else {
            throw MaycastError.audioWriteFailed(url, underlying: exportError("CMAudioFormatDescriptionCreate failed (\(status))"))
        }

        // Interleave planar [[Float]] → [Float] for the requested range.
        var interleaved = [Float](repeating: 0, count: max(frames * channels, 1))
        for ch in 0..<channels {
            let src = audio.samples[ch]
            for (offset, f) in range.enumerated() {
                interleaved[offset * channels + ch] = src[f]
            }
        }
        let byteCount = frames * bytesPerFrame

        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: max(byteCount, 1),
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: max(byteCount, 1),
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw MaycastError.audioWriteFailed(url, underlying: exportError("CMBlockBufferCreate failed (\(status))"))
        }
        if byteCount > 0 {
            status = interleaved.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: byteCount
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw MaycastError.audioWriteFailed(url, underlying: exportError("CMBlockBufferReplaceDataBytes failed (\(status))"))
            }
        }

        let sr = Int32(audio.sampleRate)
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sr),
            presentationTimeStamp: CMTime(value: Int64(range.lowerBound), timescale: sr),
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw MaycastError.audioWriteFailed(url, underlying: exportError("CMSampleBufferCreate failed (\(status))"))
        }
        return sampleBuffer
    }

    private func exportError(_ message: String) -> NSError {
        NSError(domain: "MaycastCore.AssetExportPipeline", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
