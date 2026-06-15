import Foundation

/// Deterministic, offline edit-cue detector.
///
/// Used as the stub engine for tests (`MAYCAST_EDITCUE_ENGINE=fake`) and as a
/// shared keyword table. It flags any transcript segment whose text contains an
/// editing keyword ("カット", "言い直す", "飛ばして", …) and classifies it into an
/// `EditCueKind`. Unlike the chapter heuristic it is NOT used as a production
/// fallback — edit-cue detection is Gemini-only (see MaycastEditCueService) —
/// but the keyword table is reused by the Gemini prompt to anchor the model.
public enum EditCueGenerator {

    /// (kind, keywords) in priority order. The first category with a matching
    /// keyword wins, so order matters: retake before cut so "今のカット…言い直す"
    /// classifies as a retake, etc.
    public static let keywordTable: [(kind: EditCueKind, keywords: [String])] = [
        (.retake, ["言い直", "言いなお", "もう一回", "もういっかい", "もう一度", "撮り直", "録り直", "とり直", "リテイク", "今の無し", "今のなし", "今のナシ", "今の無", "やり直"]),
        (.cut, ["カット", "切って", "切る", "切っちゃ", "要らな", "いらな", "使わな", "削除", "消して", "ここ無し", "ここなし"]),
        (.skip, ["飛ばし", "とばし", "スキップ", "後で", "あとで", "保留", "一旦飛ば"]),
        (.other, ["編集で", "編集よろ", "編集お願い"]),
    ]

    /// Classify a piece of text, returning the matching kind or `nil` if it
    /// contains no editing keyword.
    public static func classify(_ text: String) -> EditCueKind? {
        for entry in keywordTable where entry.keywords.contains(where: { text.contains($0) }) {
            return entry.kind
        }
        return nil
    }

    /// Flag every transcript segment that contains an editing keyword. One cue
    /// per matching segment, carrying that segment's time range and text.
    public static func heuristic(from segments: [TranscriptSegment]) -> [EditCue] {
        segments
            .sorted { $0.start < $1.start }
            .compactMap { segment in
                guard let kind = classify(segment.text) else { return nil }
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return EditCue(start: segment.start, end: segment.end, text: text, kind: kind)
            }
    }
}
