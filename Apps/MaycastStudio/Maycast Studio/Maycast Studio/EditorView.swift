import SwiftUI
import AppKit
import MaycastCore

// MARK: - Selection model

/// (trackID, clipID) pair. Globally unique so we can store cross-track selection in a `Set`.
struct ClipSelection: Hashable, Sendable {
    let trackID: String
    let clipID: String
}

// MARK: - Editor State

@MainActor
@Observable
final class EditorState {
    var drafts: [String: Arrangement]
    let baseline: [String: Arrangement]
    var selectedClips: Set<ClipSelection> = []
    var pixelsPerSecond: CGFloat = 30

    /// In-progress drag of one or more clips. Lives on the state so every
    /// selected `ClipView` can render its visual offset cooperatively.
    var activeDrag: ActiveDrag?

    struct ActiveDrag: Equatable, Sendable {
        let primary: ClipSelection
        var offsetSec: Double
    }

    /// In-session edit history. Each entry is a full snapshot of `drafts`
    /// taken **before** an edit (split / delete / drag-commit) is applied, so
    /// `undo()` restores the prior state by simply popping. Cleared on Apply
    /// (the session ends) and on Reset (jumps back to baseline).
    private var undoStack: [[String: Arrangement]] = []
    private var redoStack: [[String: Arrangement]] = []
    private static let maxUndoDepth = 50

    init(initialArrangements: [String: Arrangement]) {
        self.baseline = initialArrangements
        self.drafts = initialArrangements
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Push the pre-mutation `drafts` onto the undo stack and clear redo —
    /// call right before a mutation actually happens. No-ops (e.g. delete
    /// with nothing selected) should *not* invoke this.
    private func snapshotForUndo() {
        undoStack.append(drafts)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(drafts)
        drafts = prev
        clearSelection()
        activeDrag = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drafts)
        drafts = next
        clearSelection()
        activeDrag = nil
    }

    var totalDuration: Double {
        drafts.values.map(\.totalDuration).max() ?? 30
    }

    var changedTracks: [String] {
        drafts.compactMap { (id, arr) in arr == baseline[id] ? nil : id }
    }

    var hasChanges: Bool { !changedTracks.isEmpty }

    /// Convenience for places that only care about "is exactly one clip selected".
    var soleSelection: ClipSelection? {
        selectedClips.count == 1 ? selectedClips.first : nil
    }

    func isSelected(_ sel: ClipSelection) -> Bool { selectedClips.contains(sel) }

    /// Count of selected clips whose timeline range contains `time` — used both
    /// for enabling the Split button and for showing the affected count.
    func splittableCount(atPlayhead time: Double) -> Int {
        var count = 0
        for sel in selectedClips {
            if let arr = drafts[sel.trackID],
               let clip = arr.clips.first(where: { $0.id == sel.clipID }),
               time > clip.timelineStart, time < clip.timelineEnd {
                count += 1
            }
        }
        return count
    }

    func clickSelect(_ sel: ClipSelection, extending: Bool) {
        if extending {
            if selectedClips.contains(sel) { selectedClips.remove(sel) }
            else { selectedClips.insert(sel) }
        } else {
            selectedClips = [sel]
        }
    }

    func clearSelection() { selectedClips.removeAll() }

    /// Split every selected clip whose timeline range contains `time`. Clips
    /// outside the playhead are left alone. Selection is cleared after splitting
    /// because the resulting halves are new clips with fresh IDs.
    func splitAtPlayhead(_ time: Double) {
        var newDrafts = drafts
        var didSplit = false
        for sel in selectedClips {
            if let arr = newDrafts[sel.trackID],
               let clip = arr.clips.first(where: { $0.id == sel.clipID }),
               time > clip.timelineStart, time < clip.timelineEnd {
                newDrafts[sel.trackID] = arr.splitting(clipID: sel.clipID, atTimeline: time)
                didSplit = true
            }
        }
        if didSplit {
            snapshotForUndo()
            drafts = newDrafts
            clearSelection()
        }
    }

    func deleteSelected() {
        guard !selectedClips.isEmpty else { return }
        var newDrafts = drafts
        var didChange = false
        for sel in selectedClips {
            if let arr = newDrafts[sel.trackID],
               arr.clips.contains(where: { $0.id == sel.clipID }) {
                newDrafts[sel.trackID] = arr.deleting(clipID: sel.clipID)
                didChange = true
            }
        }
        if didChange {
            snapshotForUndo()
            drafts = newDrafts
        }
        clearSelection()
    }

    func moveClip(trackID: String, clipID: String, toTimeline newStart: Double) {
        guard let arr = drafts[trackID] else { return }
        drafts[trackID] = arr.moving(clipID: clipID, toTimeline: max(0, newStart))
    }

    // MARK: - Drag lifecycle (multi-clip)

    /// Called at drag start. If `primary` isn't in the selection, the selection
    /// is replaced with it (= drag of an unselected clip drags only it).
    func beginDrag(primary: ClipSelection) {
        if !selectedClips.contains(primary) {
            selectedClips = [primary]
        }
        activeDrag = ActiveDrag(primary: primary, offsetSec: 0)
    }

    func updateDrag(offsetSec: Double) {
        guard activeDrag != nil else { return }
        activeDrag = ActiveDrag(primary: activeDrag!.primary, offsetSec: offsetSec)
    }

    /// Apply the drag's offset to every selected clip in a single transaction,
    /// then clear the drag state.
    func commitDrag() {
        guard let drag = activeDrag else { return }
        let offset = drag.offsetSec
        activeDrag = nil
        guard abs(offset) > 0.001 else { return }
        var newDrafts = drafts
        for sel in selectedClips {
            if let arr = newDrafts[sel.trackID],
               let clip = arr.clips.first(where: { $0.id == sel.clipID }) {
                let newStart = max(0, clip.timelineStart + offset)
                newDrafts[sel.trackID] = arr.moving(clipID: sel.clipID, toTimeline: newStart)
            }
        }
        if newDrafts != drafts {
            snapshotForUndo()
            drafts = newDrafts
        }
    }

    /// Minimum `timelineStart` across the current selection (used to clamp the
    /// drag offset so no selected clip is pushed past zero).
    func selectionMinTimelineStart() -> Double {
        var minVal: Double = .greatestFiniteMagnitude
        for sel in selectedClips {
            if let arr = drafts[sel.trackID],
               let clip = arr.clips.first(where: { $0.id == sel.clipID }) {
                if clip.timelineStart < minVal { minVal = clip.timelineStart }
            }
        }
        return minVal == .greatestFiniteMagnitude ? 0 : minVal
    }

    func reset() {
        drafts = baseline
        clearSelection()
        activeDrag = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // Zoom helpers
    static let minPxPerSec: CGFloat = 5
    static let maxPxPerSec: CGFloat = 200
    static let zoomFactor: CGFloat = 1.33

    func zoomIn() {
        pixelsPerSecond = min(Self.maxPxPerSec, pixelsPerSecond * Self.zoomFactor)
    }
    func zoomOut() {
        pixelsPerSecond = max(Self.minPxPerSec, pixelsPerSecond / Self.zoomFactor)
    }
}

// MARK: - Editor View

struct EditorView: View {
    @Bindable var state: EditorState
    @Bindable var playback: PlaybackEngine
    let waveformCache: WaveformCache
    let trackOrder: [String]
    let trackSources: [String: Double]
    /// Maps trackID -> the path to its current audio (used to look up peaks).
    let trackPaths: [String: String]

    /// Per-track transcript state shown in the bottom panel. Empty array hides
    /// the panel entirely (= no transcripts to manage yet).
    var transcripts: [TranscriptTrackInfo] = []

    var onApply: (() -> Void)? = nil
    var onTranscribeAll: (() -> Void)? = nil

    @State private var scrollPosition = ScrollPosition()
    @State private var showTranscript: Bool = true
    @State private var viewportWidth: CGFloat = 0
    @State private var currentScrollX: CGFloat = 0

    private let headerWidth: CGFloat = 130
    private let rulerHeight: CGFloat = 28
    private let trackHeight: CGFloat = 96
    private let transcriptPanelHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                state: state,
                playback: playback,
                showTranscript: $showTranscript,
                hasTranscripts: !transcripts.isEmpty,
                onApply: onApply
            )
            Divider()
            timelineArea
            if showTranscript, !transcripts.isEmpty {
                Divider()
                TranscriptPanel(
                    tracks: transcripts,
                    currentTime: playback.playheadTime,
                    onTranscribeAll: onTranscribeAll,
                    onLineTap: { time in
                        playback.seek(to: time)
                        recenterOnPlayhead(viewportWidth: viewportWidth, pxPerSec: state.pixelsPerSecond)
                    },
                    onClose: { showTranscript = false }
                )
                .frame(height: transcriptPanelHeight)
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
    }

    private var timelineArea: some View {
        // `.top` alignment ensures the header column (intrinsic height) and the
        // scroll column (GeometryReader-driven, full height) share the same top
        // edge. Without this, HStack's default `.center` would push the header
        // labels to the vertical middle of the timeline area.
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: rulerHeight)
                ForEach(trackOrder, id: \.self) { trackID in
                    TrackHeaderRow(
                        trackID: trackID,
                        isSelected: state.selectedClips.contains { $0.trackID == trackID }
                    )
                    .frame(height: trackHeight)
                    Divider()
                }
                // Fill the remaining vertical area so the column background
                // extends below the last track for a tidy look.
                Spacer(minLength: 0)
            }
            .frame(width: headerWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.background.secondary)
            Divider()

            GeometryReader { geo in
                scrollableContent(viewportWidth: geo.size.width)
                    .onAppear { viewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in viewportWidth = w }
            }
        }
    }

    private func scrollableContent(viewportWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        TimeRulerView(
                            duration: state.totalDuration,
                            pixelsPerSecond: state.pixelsPerSecond,
                            onTap: { time in playback.seek(to: time) }
                        )
                        .frame(height: rulerHeight)
                        ForEach(trackOrder, id: \.self) { trackID in
                            TrackClipsView(
                                trackID: trackID,
                                arrangement: state.drafts[trackID] ?? Arrangement(),
                                selectedClips: state.selectedClips,
                                pixelsPerSecond: state.pixelsPerSecond,
                                totalDuration: state.totalDuration,
                                peaks: peaks(for: trackID),
                                state: state,
                                playback: playback,
                                onClipTap: { clipID, extending in
                                    state.clickSelect(
                                        ClipSelection(trackID: trackID, clipID: clipID),
                                        extending: extending
                                    )
                                },
                                onBackgroundTap: { time in
                                    playback.seek(to: time)
                                    state.clearSelection()
                                }
                            )
                            .frame(height: trackHeight)
                            Divider()
                        }
                    }
            PlayheadOverlay(
                playback: playback,
                pixelsPerSecond: state.pixelsPerSecond,
                totalHeight: rulerHeight + (trackHeight + 1) * CGFloat(trackOrder.count)
            )
        }
        .frame(minHeight: rulerHeight + (trackHeight + 1) * CGFloat(trackOrder.count))
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.x
        } action: { _, newX in
            currentScrollX = newX
        }
        .onChange(of: state.pixelsPerSecond) { _, newPx in
            recenterOnPlayhead(viewportWidth: viewportWidth, pxPerSec: newPx)
        }
        .onChange(of: playback.playheadTime) { oldTime, newTime in
            followPlayheadDuringPlayback(from: oldTime, to: newTime)
        }
    }

    private func recenterOnPlayhead(viewportWidth: CGFloat, pxPerSec: CGFloat) {
        let target = CGFloat(playback.playheadTime) * pxPerSec - viewportWidth / 2
        scrollPosition.scrollTo(x: max(0, target))
    }

    /// During playback, page the scroll view forward when the playhead nears
    /// the right edge so the user can keep watching what's about to play. Only
    /// fires for small forward deltas (= timer ticks); explicit seeks (handled
    /// elsewhere by `recenterOnPlayhead`) are skipped here.
    private func followPlayheadDuringPlayback(from oldTime: Double, to newTime: Double) {
        guard playback.isPlaying else { return }
        let delta = newTime - oldTime
        guard delta > 0, delta < 0.5 else { return }

        let pxPerSec = state.pixelsPerSecond
        let playheadX = CGFloat(newTime) * pxPerSec
        let rightEdgeMargin: CGFloat = 80
        let leftLandingMargin: CGFloat = 80
        let rightEdge = currentScrollX + viewportWidth

        if playheadX > rightEdge - rightEdgeMargin {
            scrollPosition.scrollTo(x: max(0, playheadX - leftLandingMargin))
        }
    }

    private func peaks(for trackID: String) -> WaveformPeaks? {
        guard let path = trackPaths[trackID] else { return nil }
        return waveformCache.peaks(for: path)
    }
}

// MARK: - Toolbar

private struct EditorToolbar: View {
    @Bindable var state: EditorState
    @Bindable var playback: PlaybackEngine
    @Binding var showTranscript: Bool
    let hasTranscripts: Bool
    var onApply: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Transport
            Group {
                Button {
                    if playback.isPlaying {
                        playback.pause()
                    } else {
                        // Reflect any in-progress edits in playback (deletions
                        // render as silence, moves shift clip positions).
                        playback.setArrangements(state.drafts)
                        playback.play()
                    }
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { playback.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!playback.isPlaying && playback.playheadTime == 0)
            }
            .buttonStyle(.bordered)

            PlaybackRatePicker(rate: $playback.playbackRate)

            Divider().frame(height: 24)

            // Edit-session undo / redo (in-memory; cleared on Apply / Reset).
            Group {
                Button { state.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!state.canUndo)
                .help("Undo edit in this Slice session (⌘Z)")

                Button { state.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!state.canRedo)
                .help("Redo edit in this Slice session (⇧⌘Z)")
            }
            .buttonStyle(.bordered)

            Divider().frame(height: 24)

            // Edit
            Group {
                Button { state.splitAtPlayhead(playback.playheadTime) } label: {
                    Label("Split\(splittableCount > 1 ? " (\(splittableCount))" : "") @ playhead",
                          systemImage: "scissors")
                }
                .disabled(splittableCount == 0)

                Button(role: .destructive) { state.deleteSelected() } label: {
                    Label("Delete\(state.selectedClips.count > 1 ? " (\(state.selectedClips.count))" : "")",
                          systemImage: "trash")
                }
                .disabled(state.selectedClips.isEmpty)
            }
            .buttonStyle(.bordered)

            if hasTranscripts {
                Button { showTranscript.toggle() } label: {
                    Label("Transcript", systemImage: showTranscript ? "text.quote" : "text.quote")
                }
                .buttonStyle(.bordered)
                .help(showTranscript ? "Hide transcript panel" : "Show transcript panel")
                .symbolVariant(showTranscript ? .fill : .none)
            }

            Divider().frame(height: 24)

            // Zoom
            HStack(spacing: 4) {
                Button { state.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(state.pixelsPerSecond <= EditorState.minPxPerSec + 0.1)
                Slider(value: $state.pixelsPerSecond, in: EditorState.minPxPerSec...EditorState.maxPxPerSec)
                    .frame(width: 100)
                Button { state.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(state.pixelsPerSecond >= EditorState.maxPxPerSec - 0.1)
                Text("\(Int(state.pixelsPerSecond))px/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Spacer()

            Text(String(format: "%.2fs", playback.playheadTime))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)

            Divider().frame(height: 24)

            Button("Reset") { state.reset() }
                .buttonStyle(.bordered)
                .disabled(!state.hasChanges)

            Button {
                onApply?()
            } label: {
                if state.hasChanges {
                    Text("Apply (\(state.changedTracks.count) track\(state.changedTracks.count == 1 ? "" : "s"))")
                } else {
                    Text("Apply")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.hasChanges)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private var splittableCount: Int {
        state.splittableCount(atPlayhead: playback.playheadTime)
    }
}

// MARK: - Playback rate picker

/// Preset playback speeds for scanning content. Pitch is preserved (TimePitch),
/// so 1.5–2x is comfortable for spoken-word review.
private struct PlaybackRatePicker: View {
    @Binding var rate: Float

    private static let options: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        Picker("Speed", selection: $rate) {
            ForEach(Self.options, id: \.self) { value in
                Text(label(for: value)).tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .help("Playback speed (pitch preserved)")
        .frame(width: 78)
    }

    private func label(for value: Float) -> String {
        // "1x" instead of "1.0x" for the canonical speed; otherwise show one
        // decimal (or two for 0.75 / 1.25 / 1.75).
        if value == 1.0 { return "1x" }
        if value.truncatingRemainder(dividingBy: 0.5) == 0 {
            return String(format: "%.1fx", value)
        }
        return String(format: "%.2fx", value)
    }
}

// MARK: - Track Header

private struct TrackHeaderRow: View {
    let trackID: String
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(trackID).font(.headline)
                Text("draft").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
    }
}

// MARK: - Time Ruler (clickable)

private struct TimeRulerView: View {
    let duration: Double
    let pixelsPerSecond: CGFloat
    let onTap: (Double) -> Void

    var body: some View {
        Canvas { context, size in
            let majorInterval: Double = step(for: pixelsPerSecond)
            let minorInterval: Double = majorInterval / 5
            var t: Double = 0
            while t <= duration {
                let x = CGFloat(t) * pixelsPerSecond
                let isMajor = (t.truncatingRemainder(dividingBy: majorInterval) == 0)
                let tickHeight: CGFloat = isMajor ? 10 : 5
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: size.height))
                        p.addLine(to: CGPoint(x: x, y: size.height - tickHeight))
                    },
                    with: .color(.secondary),
                    lineWidth: 1
                )
                if isMajor {
                    let label = Text(formattedTick(t)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: 4), anchor: .topLeading)
                }
                t += minorInterval
            }
        }
        .frame(width: max(CGFloat(duration) * pixelsPerSecond, 200))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    onTap(max(0, Double(value.location.x) / Double(pixelsPerSecond)))
                }
        )
    }

    /// Pick a ruler step (in seconds) that produces tick spacing around 30–60px.
    private func step(for px: CGFloat) -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        for c in candidates where c * Double(px) >= 30 { return c }
        return 600
    }

    private func formattedTick(_ t: Double) -> String {
        if t >= 60 {
            let m = Int(t) / 60
            let s = Int(t) % 60
            return s == 0 ? "\(m)m" : String(format: "%d:%02d", m, s)
        }
        return String(format: "%gs", t)
    }
}

// MARK: - Track Clips Lane

private struct TrackClipsView: View {
    let trackID: String
    let arrangement: Arrangement
    let selectedClips: Set<ClipSelection>
    let pixelsPerSecond: CGFloat
    let totalDuration: Double
    let peaks: WaveformPeaks?
    let state: EditorState
    let playback: PlaybackEngine
    let onClipTap: (String, Bool) -> Void           // clipID, extending (shift/cmd)
    let onBackgroundTap: (Double) -> Void

    private var laneWidth: CGFloat { max(CGFloat(totalDuration) * pixelsPerSecond, 200) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.background.tertiary)
                .frame(width: laneWidth)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            onBackgroundTap(max(0, Double(value.location.x) / Double(pixelsPerSecond)))
                        }
                )

            ForEach(arrangement.clips) { clip in
                ClipView(
                    clip: clip,
                    trackID: trackID,
                    isSelected: selectedClips.contains(ClipSelection(trackID: trackID, clipID: clip.id)),
                    pixelsPerSecond: pixelsPerSecond,
                    peaks: peaks,
                    state: state,
                    playback: playback,
                    onTap: { extending in onClipTap(clip.id, extending) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Single Clip (with drag + snap)

/// Visual content of a clip — extracted out of `ClipView` so that the heavy
/// child views (notably the waveform `Canvas`) don't re-evaluate on every drag
/// tick. With `Equatable` + `.equatable()`, SwiftUI skips re-running this body
/// when none of its parameters changed, and only the outer `.offset` animates.
private struct ClipContent: View, Equatable {
    let clip: Clip
    let isSelected: Bool
    let pixelsPerSecond: CGFloat
    let peaks: WaveformPeaks?

    private var width: CGFloat { CGFloat(clip.duration) * pixelsPerSecond }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.accentColor.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.accentColor.opacity(0.5),
                            lineWidth: isSelected ? 2 : 1
                        )
                )

            if let peaks {
                // Waveform always reflects the clip's **source** range (the
                // actual audio content the clip points at), so moving or
                // re-arranging clips doesn't visually swap which audio is
                // shown. After Apply the arrangement is reset to a single
                // clip whose source range matches its timeline position, so
                // the two coincide again on the next session.
                WaveformView(
                    peaks: peaks,
                    startTime: clip.sourceStart,
                    endTime: clip.sourceEnd,
                    color: .accentColor
                )
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }

            Text("\(String(format: "%.1f", clip.duration))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .frame(width: max(width, 8), height: 76)
    }
}

private struct ClipView: View {
    let clip: Clip
    let trackID: String
    let isSelected: Bool
    let pixelsPerSecond: CGFloat
    let peaks: WaveformPeaks?
    let state: EditorState
    let playback: PlaybackEngine
    let onTap: (Bool) -> Void

    /// Only read `state.activeDrag` if this clip is part of the selection —
    /// keeps un-selected clips from observing drag updates and re-rendering.
    private var visualStart: CGFloat {
        var offset: Double = 0
        if isSelected, let drag = state.activeDrag {
            offset = drag.offsetSec
        }
        return max(0, CGFloat(clip.timelineStart + offset) * pixelsPerSecond)
    }

    var body: some View {
        ClipContent(clip: clip, isSelected: isSelected, pixelsPerSecond: pixelsPerSecond, peaks: peaks)
            .equatable()
            .offset(x: visualStart, y: 6)
            .onTapGesture {
                let mods = NSEvent.modifierFlags
                let extending = mods.contains(.shift) || mods.contains(.command)
                onTap(extending)
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let me = ClipSelection(trackID: trackID, clipID: clip.id)
                        if state.activeDrag == nil {
                            state.beginDrag(primary: me)
                        }
                        let rawOffset = Double(value.translation.width) / Double(pixelsPerSecond)
                        let minStart = state.selectionMinTimelineStart()
                        let clamped = (minStart + rawOffset < 0) ? -minStart : rawOffset
                        state.updateDrag(offsetSec: clamped)
                    }
                    .onEnded { _ in
                        state.commitDrag()
                    }
            )
    }
}

// MARK: - Playhead

private struct PlayheadOverlay: View {
    let playback: PlaybackEngine
    let pixelsPerSecond: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 2, height: totalHeight)
            Triangle()
                .fill(Color.orange)
                .frame(width: 12, height: 10)
                .offset(x: -5, y: -3)
        }
        .offset(x: CGFloat(playback.playheadTime) * pixelsPerSecond, y: 0)
        .allowsHitTesting(false)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Preview Samples

#if DEBUG
extension Arrangement {
    static var sampleHost: Arrangement {
        Arrangement(clips: [
            Clip(id: "h1", sourceStart: 0,  sourceEnd: 8,  timelineStart: 0),
            Clip(id: "h2", sourceStart: 10, sourceEnd: 18, timelineStart: 9),
            Clip(id: "h3", sourceStart: 20, sourceEnd: 30, timelineStart: 18),
        ])
    }
    static var sampleGuest: Arrangement {
        Arrangement(clips: [
            Clip(id: "g1", sourceStart: 0,  sourceEnd: 12, timelineStart: 0),
            Clip(id: "g2", sourceStart: 15, sourceEnd: 25, timelineStart: 14),
        ])
    }
    static var sampleSingle: Arrangement {
        Arrangement(clips: [Clip(id: "s1", sourceStart: 0, sourceEnd: 25, timelineStart: 0)])
    }
}
#endif

private func makeSampleEnvironment(
    arrangements: [String: Arrangement] = ["host": .sampleHost, "guest": .sampleGuest]
) -> (state: EditorState, playback: PlaybackEngine, cache: WaveformCache) {
    let state = EditorState(initialArrangements: arrangements)
    let playback = PlaybackEngine()
    let cache = WaveformCache()
    return (state, playback, cache)
}

#Preview("Multi-track, no peaks") {
    let env = makeSampleEnvironment()
    return EditorView(
        state: env.state,
        playback: env.playback,
        waveformCache: env.cache,
        trackOrder: ["host", "guest"],
        trackSources: ["host": 60, "guest": 60],
        trackPaths: [:]
    )
}

#Preview("Multi-selection across tracks") {
    let env = makeSampleEnvironment()
    env.state.selectedClips = [
        ClipSelection(trackID: "host", clipID: "h2"),
        ClipSelection(trackID: "guest", clipID: "g1"),
    ]
    return EditorView(
        state: env.state,
        playback: env.playback,
        waveformCache: env.cache,
        trackOrder: ["host", "guest"],
        trackSources: ["host": 60, "guest": 60],
        trackPaths: [:]
    )
}

#Preview("With pending changes") {
    let env = makeSampleEnvironment()
    env.state.drafts["host"] = Arrangement.sampleHost.deleting(clipID: "h2")
    return EditorView(
        state: env.state,
        playback: env.playback,
        waveformCache: env.cache,
        trackOrder: ["host", "guest"],
        trackSources: ["host": 60, "guest": 60],
        trackPaths: [:]
    )
}

#if DEBUG
private let editorPreviewTranscripts: [TranscriptTrackInfo] = [
    TranscriptTrackInfo(id: "host", state: .populated(segments: [
        TranscriptSegment(start: 0.0, end: 0.4, text: "It"),
        TranscriptSegment(start: 0.4, end: 0.7, text: "was"),
        TranscriptSegment(start: 0.7, end: 0.9, text: "a"),
        TranscriptSegment(start: 0.9, end: 1.4, text: "dark"),
        TranscriptSegment(start: 1.4, end: 1.7, text: "and"),
        TranscriptSegment(start: 1.7, end: 2.4, text: "stormy"),
        TranscriptSegment(start: 2.4, end: 3.0, text: "night."),
        TranscriptSegment(start: 3.0, end: 3.4, text: "The"),
        TranscriptSegment(start: 3.4, end: 3.9, text: "wind"),
        TranscriptSegment(start: 3.9, end: 4.5, text: "howled"),
        TranscriptSegment(start: 4.5, end: 4.8, text: "through"),
        TranscriptSegment(start: 4.8, end: 5.1, text: "the"),
        TranscriptSegment(start: 5.1, end: 5.8, text: "trees."),
    ])),
    TranscriptTrackInfo(id: "guest", state: .populated(segments: [
        TranscriptSegment(start: 6.0, end: 6.4, text: "Indeed,"),
        TranscriptSegment(start: 6.4, end: 6.7, text: "it"),
        TranscriptSegment(start: 6.7, end: 7.0, text: "was"),
        TranscriptSegment(start: 7.0, end: 7.2, text: "a"),
        TranscriptSegment(start: 7.2, end: 8.0, text: "tempestuous"),
        TranscriptSegment(start: 8.0, end: 8.7, text: "evening."),
    ])),
]
#endif

#Preview("With transcript panel (populated)") {
    let env = makeSampleEnvironment()
    return EditorView(
        state: env.state,
        playback: env.playback,
        waveformCache: env.cache,
        trackOrder: ["host", "guest"],
        trackSources: ["host": 60, "guest": 60],
        trackPaths: [:],
        transcripts: editorPreviewTranscripts
    )
}

#Preview("With transcript panel (empty, need transcribe)") {
    let env = makeSampleEnvironment()
    return EditorView(
        state: env.state,
        playback: env.playback,
        waveformCache: env.cache,
        trackOrder: ["host", "guest"],
        trackSources: ["host": 60, "guest": 60],
        trackPaths: [:],
        transcripts: [
            TranscriptTrackInfo(id: "host",  state: .empty),
            TranscriptTrackInfo(id: "guest", state: .empty),
        ]
    )
}
