import Testing
import Foundation
@testable import MaycastCore

@Suite("EpisodeBundle undo / redo")
struct UndoRedoTests {
    private func makeTempBundle() throws -> (URL, URL) {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maycast-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let bundleURL = workspace.appendingPathComponent("ep01.maycast")
        return (workspace, bundleURL)
    }

    private func makeSineWaveFile(at url: URL, duration: Double = 1.0) throws {
        let buffer = AudioIO.sineWave(frequency: 440, duration: duration, amplitude: 0.3, sampleRate: 48000)
        try AudioIO.writeWAV(buffer, to: url)
    }

    private func setupHostBundle() throws -> (workspace: URL, bundle: EpisodeBundle) {
        let (workspace, bundleURL) = try makeTempBundle()
        var bundle = try EpisodeBundle.create(at: bundleURL)
        let host = workspace.appendingPathComponent("host.wav")
        try makeSineWaveFile(at: host, duration: 1.0)
        _ = try bundle.importTrack(from: host, as: "host")
        return (workspace, bundle)
    }

    @Test
    func freshBundleCannotUndoOrRedo() throws {
        let (_, bundle) = try setupHostBundle()
        #expect(bundle.canUndo == false)
        #expect(bundle.canRedo == false)
    }

    @Test
    func appendOperationRecordsAndIsUndoable() throws {
        let (_, b0) = try setupHostBundle()
        var bundle = b0
        let importPath = bundle.track(withID: "host")!.current
        _ = try bundle.appendOperationGeneration(
            trackID: "host", operation: "polish", params: nil
        )
        #expect(bundle.canUndo == true)
        #expect(bundle.canRedo == false)
        let postOp = bundle.track(withID: "host")!.current
        #expect(postOp != importPath)

        let reverted = try bundle.undo()
        #expect(reverted?.count == 1)
        #expect(bundle.track(withID: "host")!.current == importPath)
        #expect(bundle.canUndo == false)
        #expect(bundle.canRedo == true)

        let replayed = try bundle.redo()
        #expect(replayed?.count == 1)
        #expect(bundle.track(withID: "host")!.current == postOp)
        #expect(bundle.canUndo == true)
        #expect(bundle.canRedo == false)
    }

    @Test
    func successiveOperationsUndoInReverse() throws {
        let (_, b0) = try setupHostBundle()
        var bundle = b0
        let g1 = bundle.track(withID: "host")!.current
        _ = try bundle.appendOperationGeneration(trackID: "host", operation: "polish", params: nil)
        let g2 = bundle.track(withID: "host")!.current
        _ = try bundle.appendOperationGeneration(trackID: "host", operation: "polish", params: nil)
        let g3 = bundle.track(withID: "host")!.current
        #expect(g1 != g2)
        #expect(g2 != g3)

        // Undo twice → back to g1.
        try bundle.undo()
        #expect(bundle.track(withID: "host")!.current == g2)
        try bundle.undo()
        #expect(bundle.track(withID: "host")!.current == g1)
        #expect(bundle.canUndo == false)

        // Redo twice → back to g3.
        try bundle.redo()
        #expect(bundle.track(withID: "host")!.current == g2)
        try bundle.redo()
        #expect(bundle.track(withID: "host")!.current == g3)
        #expect(bundle.canRedo == false)
    }

    @Test
    func newOperationClearsRedoStack() throws {
        let (_, b0) = try setupHostBundle()
        var bundle = b0
        _ = try bundle.appendOperationGeneration(trackID: "host", operation: "polish", params: nil)
        _ = try bundle.appendOperationGeneration(trackID: "host", operation: "polish", params: nil)
        try bundle.undo()
        #expect(bundle.canRedo == true)
        // A fresh op branches the timeline.
        _ = try bundle.appendOperationGeneration(trackID: "host", operation: "polish", params: nil)
        #expect(bundle.canRedo == false)
    }

    @Test
    func batchIDGroupsMultiTrackUndo() throws {
        let (workspace, b0) = try setupHostBundle()
        var bundle = b0
        // Import a second track.
        let guest = workspace.appendingPathComponent("guest.wav")
        try makeSineWaveFile(at: guest, duration: 1.0)
        _ = try bundle.importTrack(from: guest, as: "guest")

        let hostBefore = bundle.track(withID: "host")!.current
        let guestBefore = bundle.track(withID: "guest")!.current

        // Two appendOperationGeneration calls sharing a batchID — simulating
        // an Auphonic Polish that updates both speakers from a single Apply.
        let batchID = UUID().uuidString
        _ = try bundle.appendOperationGeneration(
            trackID: "host", operation: "polish", params: nil, batchID: batchID
        )
        _ = try bundle.appendOperationGeneration(
            trackID: "guest", operation: "polish", params: nil, batchID: batchID
        )
        let hostAfter = bundle.track(withID: "host")!.current
        let guestAfter = bundle.track(withID: "guest")!.current
        #expect(hostAfter != hostBefore)
        #expect(guestAfter != guestBefore)

        // One undo should revert both tracks.
        let reverted = try bundle.undo()
        #expect(reverted?.count == 2)
        #expect(bundle.track(withID: "host")!.current == hostBefore)
        #expect(bundle.track(withID: "guest")!.current == guestBefore)

        // Redo restores both.
        let replayed = try bundle.redo()
        #expect(replayed?.count == 2)
        #expect(bundle.track(withID: "host")!.current == hostAfter)
        #expect(bundle.track(withID: "guest")!.current == guestAfter)
    }

    @Test
    func undoIsPersistedThroughReopen() throws {
        let (_, b0) = try setupHostBundle()
        var bundle = b0
        let g1 = bundle.track(withID: "host")!.current
        _ = try bundle.appendOperationGeneration(trackID: "host", operation: "polish", params: nil)
        try bundle.undo()
        #expect(bundle.track(withID: "host")!.current == g1)
        // Reopen and verify the undo persisted.
        let reopened = try EpisodeBundle.open(at: bundle.url)
        #expect(reopened.track(withID: "host")!.current == g1)
        #expect(reopened.canUndo == false)
        #expect(reopened.canRedo == true)
    }
}
