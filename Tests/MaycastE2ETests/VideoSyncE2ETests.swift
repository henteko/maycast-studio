import Testing
import Foundation
import MaycastCore

/// Regression coverage for the lip-sync drift bug: exporting a **VFR** source
/// that has been cut into many segments must keep the picture frame-aligned to
/// the (sample-accurate) edited audio. The old renderer forced a single CFR
/// rate onto VFR frames and let per-cut frame-quantization error accumulate,
/// drifting ~0.5–1.5s by the end of a real episode.
@Suite("export keeps VFR video in lip-sync after many cuts")
struct VideoSyncE2ETests {
    /// A contiguous-timeline arrangement of `count` short kept clips separated by
    /// small cuts — the shape that accumulates drift across many segments.
    private func manyCutArrangement(count: Int, keep: Double, cut: Double) -> (Arrangement, Double) {
        var clips: [Clip] = []
        var tl = 0.0
        var src = 0.0
        for i in 0..<count {
            clips.append(Clip(id: "c\(i)", sourceStart: src, sourceEnd: src + keep, timelineStart: tl))
            tl += keep
            src += keep + cut
        }
        return (Arrangement(clips: clips), tl)
    }

    private func streamDuration(_ url: URL, stream: String, harness: E2EHarness) -> Double {
        let out = harness.ffprobe([
            "-v", "error", "-select_streams", stream,
            "-show_entries", "stream=duration", "-of", "default=nw=1:nk=1", url.path,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(out) ?? -1
    }

    @Test
    func vfrExportStaysFrameAccurateAcrossManyCuts() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episode = workspace.appendingPathComponent("ep.maycast")
        _ = try harness.run(["init", episode.path])
        let video = workspace.appendingPathComponent("host.mp4")
        try harness.writeVFRTestVideo(at: video, duration: 24.0)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", video.path])

        // 20 kept clips of 0.93s with 0.17s cuts → 18.6s timeline, 20 segments.
        let (arr, timeline) = manyCutArrangement(count: 20, keep: 0.93, cut: 0.17)
        let arrFile = workspace.appendingPathComponent("cut.json")
        try JSONEncoder().encode(arr).write(to: arrFile)
        let apply = try harness.run([
            "slice", "apply", "-project", episode.path, "--track", "host",
            "--arrangement-file", arrFile.path,
        ])
        #expect(apply.succeeded, "stderr: \(apply.stderr)")

        let render = try harness.run(["render", "-project", episode.path])
        #expect(render.succeeded, "render must not drift past its own sanity check — stderr: \(render.stderr)")

        let mp4 = episode.appendingPathComponent("exports/host.mp4")
        #expect(FileManager.default.fileExists(atPath: mp4.path))

        // The exported picture must match the edited timeline to within a couple
        // frames (old code drifted ~1.5s on this VFR clip and tripped the guard).
        let videoDur = streamDuration(mp4, stream: "v:0", harness: harness)
        let audioDur = streamDuration(mp4, stream: "a:0", harness: harness)
        #expect(abs(videoDur - timeline) < 0.12,
                "video stream \(videoDur)s drifted from timeline \(timeline)s")
        #expect(abs(videoDur - audioDur) < 0.12,
                "picture (\(videoDur)s) and audio (\(audioDur)s) must stay in sync")
    }
}
