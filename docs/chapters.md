# チャプター機能 設計

本ドキュメントは、mix で書き出す音声ファイルに **チャプター (章) メタデータ** を埋め込む機能の設計をまとめたものです。チャプターは文字起こしからクラウド LLM (Google Gemini) で生成し、ユーザーが微修正できるようにします。

基盤の前提は [`architecture.md`](architecture.md) に従います。本ドキュメントはその上に乗る 1 機能の設計です。

## 1. ゴールとスコープ

- mix の最終出力に、ポッドキャストの **チャプターマーカー** を埋め込む
- チャプターは各トラックの **文字起こし (transcript)** を元に、ローカル LLM が自動生成する
- 生成されたチャプターは GUI / CLI から **手で微修正** できる (時刻・タイトルの編集、追加、削除)
- mix の出力フォーマットを **M4A (AAC) に統一** する (生 WAV は残さない)
- 将来の **MP4 (アートワーク動画) 対応** を見越し、書き出し基盤を共通化する

### スコープ外 (将来拡張)

- MP4 (静止画アートワーク動画) の書き出し — 基盤は本設計で用意するが実装は別途 (§8)
- Title / Artist / Artwork 等の一般メタデータ埋め込み — 同じ書き出し経路に乗るが別件

## 2. 全体フロー

```
import → (slice/polish) → transcribe (各 track)
                              │  intermediate/<track>/NNN_*.transcript.json
                              ▼
                    ┌─ chapter generate ─────────────┐
                    │  MaycastChapterService (新規)    │
                    │  全 track の transcript を時系列マージ │
                    │  → Google Gemini で生成            │
                    │  → [{start, title}] を提案         │
                    └────────────┬───────────────────┘
                                 ▼
                    episode.json の chapters[] に保存
                                 │
                    ┌─ 微修正 ───┴──────────┐
                    │  CLI: maycast chapter   │
                    │  GUI: チャプター編集 View │
                    └────────────┬──────────┘
                                 ▼
                    mix (M4A に統一) ─ chapters[] を最終時間軸へ変換し
                                       AssetExportPipeline で chapter track を埋め込み
                                 ▼
                    exports/{episodeID}.m4a  (AAC + チャプター)
```

**設計の核心**: チャプターは **トラック変換ではなくエピソード単位のメタデータ**。したがって `intermediate/` の世代 (per-track 変換) には乗せず、`episode.json` に持たせる。これにより「intermediate は per-track 変換」という基盤の不変条件 ([`architecture.md`](architecture.md) §2) を壊さない。

## 3. データモデル

チャプターは `episode.json` に `chapters` フィールドとして追加する。mix が read-only で参照する「共有状態」に置くのが既存パターン ([`architecture.md`](architecture.md) §3) と整合する。

```swift
// MaycastCore/Models.swift に追加
public struct Chapter: Codable, Sendable, Equatable, Identifiable {
    public var id: String          // UUID
    public var start: Double        // ★ ボイス時間軸 (= 各 track の current の t=0 基準) の秒
    public var title: String
    public var source: ChapterSource
}

public enum ChapterSource: String, Codable, Sendable {
    case generated   // LLM 生成のまま
    case manual      // 手動追加
    case edited      // LLM 生成を手動修正
}

// Episode に追加
public var chapters: [Chapter]
```

### 時間軸の方針

チャプターは **ボイス時間軸** (transcript と同じ、各 track の `current` の t=0 基準) で保存する。intro のリード時間ぶんのシフトは **mix の埋め込み時に適用** する (§6)。

こうすることで、後から intro オフセットを変えてもチャプターの編集内容が壊れない。チャプターは「内容 (ボイス)」に固定され、書き出し時にだけ最終ファイルの時間軸へ写像される。

### episode.json 例

```json
{
  "id": "ep01",
  "tracks": [ ... ],
  "mix": { ... },
  "chapters": [
    { "id": "c1", "start": 0.0,   "title": "オープニング",       "source": "generated" },
    { "id": "c2", "start": 92.4,  "title": "今週のニュース",     "source": "edited" },
    { "id": "c3", "start": 540.0, "title": "ゲストトーク",       "source": "manual" }
  ]
}
```

## 4. チャプター生成サービス (MaycastChapterService)

既存の transcribe / slice / mix と同じ **JSON-over-stdio 子プロセス型 XPC サービス** ([`architecture.md`](architecture.md) §3) として追加する。

```swift
// MaycastIPC/ServiceDTO.swift
public enum ServiceOperation: String, Codable, Sendable {
    case transcribe, slice, mix
    case chapter   // 追加
}
```

### 処理内容

1. `episode.json` を開き、全 track の **current transcript** (`intermediate/<track>/NNN_*.transcript.json`) を読む
2. 複数トラックの segments を **start 昇順でマージ** し、話者ラベル付きの 1 本の時系列テキストに整形する
3. **Google Gemini** (クラウド LLM) で生成する
   - 入力: transcript の**全文**を番号付き行に整形して一括で渡す。各行は `<index> [<mm:ss>] <text>`（先頭時刻つき）。語/文字単位の segments は読みやすい行にマージ（**切り詰めなし**、文末・最大文字数・長い無音で改行）
   - 出力: `responseSchema`（構造化出力）で「チャプターが始まる**行番号** + タイトル」の配列を取得
4. 出力を検証する (行番号 → その行の実時刻にマップ、start 昇順・範囲内にクランプ、title をトリム、start 重複除去)
5. `episode.chapters` に書き込み、`ServiceResponse` で提案チャプターを返す

### LLM

当初 MLX + Gemma 4 を検討し、その後オンデバイスの Apple Foundation Models を採用したが、**チャプター境界の精度が実用に足りなかった**ため **Google Gemini** (クラウド API) に変更した。

| 項目 | 内容 |
| -- | -- |
| ランタイム | **Google Gemini** (Generative Language API、クラウド) |
| API キー | GUI: macOS Keychain (`GeminiKeychain`)。CLI/XPC: 環境変数 `GEMINI_API_KEY`（または `--api-key` / params.apiKey） |
| モデル | 既定 `gemini-3.5-flash`（`GeminiChapterEngine.defaultModel`、環境変数 `MAYCAST_GEMINI_MODEL` で上書き可） |
| 構造化出力 | `generationConfig.responseSchema` で `{chunks: [{chunk:Int, title:String}]}` を強制（JSON テキストをパース） |
| 認証 | `x-goog-api-key` ヘッダ（キーを URL に載せない） |
| 可用性 | キー未設定 / ネットワーク失敗 / 不正レスポンス時は **ヒューリスティックにフォールバック**（hard-fail しない） |
| 入力整形 | transcript **全文**を行に整形（`makeLines`、切り詰めなし）。各行に先頭時刻を付与し、文末 (`。.!?…`) / `maxLineChars=140` / `lineGapSec=8s` の無音で改行 |
| 生成の安定化 | 行番号で位置指定（LLM は長文から正確なタイムスタンプを再現できないため）。プロンプトで「transcript と同じ言語のタイトル」「先頭 0 始まり」「4〜8 章程度」を指示 + 出力後の検証クランプ |

## 5. 編集インターフェース

GUI も CLI も同じ I/F とする。**生成 (XPC) のみプロセス分離**し、**編集は `episode.json` を直接更新** する (軽量・プロセス分離不要)。

### CLI (`maycast chapter`)

swift-argument-parser ベースの既存パターンに従う。

```bash
maycast chapter generate -project ep01.maycast      # LLM で生成 → chapters[] に保存 (XPC)
maycast chapter list     -project ep01.maycast      # 一覧表示
maycast chapter add      -project ep01.maycast --at 123.4 --title "..."
maycast chapter edit     -project ep01.maycast --id <id> [--at ..] [--title ..]
maycast chapter remove   -project ep01.maycast --id <id>
maycast chapter apply    -project ep01.maycast --file chapters.json   # 一括差し替え
```

- `generate` のみ `MaycastChapterService` (XPC) を呼ぶ
- `list` / `add` / `edit` / `remove` / `apply` は `episode.json` を直接更新する

### GUI (チャプター編集 View)

- チャプター一覧テーブル (時刻 / タイトル、行内編集、追加・削除・並べ替え)
- 「自動生成」ボタン → `MaycastChapterService` 実行 → 提案を流し込み、その後手で微修正
- 各行から再生位置へジャンプ (再生機能があれば)

CLAUDE.md の順序ルールに従い、実装前に SwiftUI モックアップを作成し `#Preview` で **正常 / 空 / 生成エラー** の 3 状態を確認する。サンプルデータは `ContentView.swift` の `#if DEBUG` ブロックのパターンを再利用し、`Chapter` のサンプルを追加する。

## 6. 時間軸変換 (埋め込み時)

チャプターはボイス時間軸で保存されているため、mix での書き出し時に最終ファイルの時間軸へ変換する。

```
voiceStartInFinal = max(0, introDuration - introOffsetSec)
finalStart(chapter) = chapter.start + voiceStartInFinal
```

- intro 素材の長さと `MixConfig.introOffsetSec` から voice の開始位置を算出する
- この計算は composeFinalMix と同じ知識を要するため、**mix 側が持つ**
- 先頭に「Intro」チャプター (start = 0) を自動付与するかは任意 (§8)

## 7. mix の M4A 統一と書き出し基盤

現状 `AudioIO.writeWAV` 一択だった出力を **M4A (AAC) に変更** する。同時に、将来の MP4 対応を見越して書き出しを共通モジュールに切り出す。

### AssetExportPipeline (新設)

M4A と MP4 は同じ **MP4 (ISO BMFF) コンテナファミリー**であり、AVAssetWriter から見た違いは「動画トラックの入力があるか否か」だけ。音声 (AAC)・チャプター (timed metadata track)・一般メタデータの経路はすべて共通になる。そこで以下を `MaycastCore` に新設する。

```swift
struct AssetExportPipeline {
    var audio: AudioBuffer        // 常に AAC で書く
    var chapters: [Chapter]       // timed metadata track (あれば)
    var artwork: URL?             // 画像 (M4A ではカバーアート、MP4 では動画の中身)
    var format: ExportFormat      // .m4a / .mp4

    func write(to url: URL) throws {
        // AVAssetWriter を構築:
        //  - audioInput   : 常に追加 (AAC)
        //  - chapterInput : chapters があれば timed metadata group
        //  - metadata     : title / artwork (カバーアート)
        //  - videoInput   : format == .mp4 のときだけ追加。
        //                   artwork を CVPixelBuffer 化して全尺に貼る
    }
}

enum ExportFormat {
    case m4a   // fileType .m4a, 音声のみ
    case mp4   // fileType .mp4, 音声 + 静止画ビデオ
}
```

`MaycastMixService` は composeFinalMix で作った最終バッファを `AssetExportPipeline` に渡し、`format: .m4a` で書き出す。

### 出力パス

- デフォルト出力: `exports/{episodeID}.wav` → **`exports/{episodeID}.m4a`**
- チャプターが空でも M4A で出力する (チャプターは任意)

### M4A / MP4 の共通性

| 要素 | M4A | MP4 (アートワーク動画) | 扱い |
| -- | -- | -- | -- |
| 音声 (AAC) | ✅ | ✅ | 完全共通 |
| チャプター (timed metadata track) | ✅ | ✅ | 完全共通 |
| Title / Artist 等 | ✅ | ✅ | 完全共通 |
| アートワーク | カバーアート (metadata) | 動画トラックの中身 | 入口は共通、出力先が違う |
| 動画トラック (H.264) | なし | ✅ 静止画フレーム | **MP4 のみ追加** |

MP4 対応は「既存の音声 + チャプター経路に動画用 `AVAssetWriterInput` を 1 本足すだけ」になる。音声・チャプター・メタデータのコードは変更不要。

### 実装メモ (チャプタートラックの埋め込み)

実装時に判明した、`AVAsset.chapterMetadataGroups` で読み戻せるチャプターの作り方:

- チャプターは **QuickTime テキストトラック** (`kCMMediaType_Text`) として書き、音声トラックに `chapterList` で関連付ける。**メタデータトラック** (`AVAssetWriterInputMetadataAdaptor`) で関連付けても、コンテナ上は有効だが `chapterMetadataGroups` からは**読めない**（この API はテキスト系チャプタートラックのみ読む）。
- チャプタートラックに `languageCode` を設定しないと `availableChapterLocales` が空になり、`chapterMetadataGroups(bestMatchingPreferredLanguages:)` が何も返さない。
- テキストサンプルは「2 byte ビッグエンディアン長 + UTF-8 本文 + `encd` アトコム (UTF-8 = `0x08000100`)」。`encd` を付けないと日本語が文字化けする。
- `.m4a` の `AVAssetWriter` はテキストチャプタートラックを拒否する (`canAdd` が false) ため、**チャプターを含む書き出しのみ `.mp4` ブランドにフォールバック**する（拡張子は `.m4a` のまま、中身は MPEG-4 で実用上問題なし）。チャプターなしの書き出しは純正 `.m4a`。
- mix 出力の検証は E2E (`ChapterE2ETests.mixEmbedsChaptersIntoM4A`) が `loadChapterMetadataGroups` 経由で実施。

### 生成エンジンの現状

- `MaycastChapterService` (XPC) がエンジンを選択する:
  - `engine=auto`（既定）/ `llm` / `gemini` → **Google Gemini** で生成（`GeminiChapterEngine`、`responseSchema` 構造化出力）。キーは `params.apiKey`、なければ環境変数 `GEMINI_API_KEY`。キー未設定 / ネットワーク失敗 / 生成失敗時は **ヒューリスティックにフォールバック**し、生成が hard-fail しない
  - `engine=fake` / `heuristic` → 決定的な `ChapterGenerator.heuristic`（E2E 用）
- GUI の「自動生成」は `OperationsService.generateChapters(bundleURL:apiKey:)` がプロセス内で `GeminiChapterEngine` を直接呼ぶ（キーは Keychain から `ChapterSheet` が渡す）。キー未設定時は `ChapterEditorView` が「Set API key」導線（`GeminiSettingsSheet`）を提示し、Generate を無効化する
- ネットワーク権限: GUI アプリは `ENABLE_OUTGOING_NETWORK_CONNECTIONS=YES`。CLI 経路のサービスは非サンドボックスの実行ファイルなので追加権限不要

### 実機検証

`GEMINI_API_KEY=… maycast chapter generate --engine gemini -project <ep>` を実行し、日本語 transcript から **日本語のチャプタータイトル + 正しいタイムスタンプ**が生成されることを確認する。`GeminiChapterEngine` のリクエスト整形・レスポンス解析・チャンク→時刻マップは `GeminiChapterEngineTests`（スタブ URLSession）で検証。E2E は `MAYCAST_CHAPTER_ENGINE=fake` で決定的に配管を検証し、キー無し時のフォールバックは `generateChaptersFallsBackWhenGeminiKeyMissing` で検証する。

## 8. 実装順序 (CLAUDE.md 準拠)

1. **SwiftUI モックアップ**: チャプター編集 View を `#Preview` (正常 / 空 / 生成エラーの 3 状態)。`ContentView.swift` の `#if DEBUG` パターンを再利用し `Chapter` サンプルを追加
2. **E2E テスト (CLI 経由)** — この時点では失敗してよい:
   - `chapter generate` で `chapters[]` が書かれる
   - `chapter add` / `edit` / `remove` の挙動
   - `mix` 出力が **M4A** で、AVAsset から **chapter track が読める** (時間軸シフト込み)
   - 既存の WAV ベース mix テストの M4A 移行 (= 仕様変更として明示)
3. **実装**: `MaycastChapterService` (Google Gemini) → CLI → mix の M4A 化 (`AssetExportPipeline`) → GUI
4. **完了条件**: 全 E2E が green、GUI がモック通りに動く

## 9. 要検討・リスク

| 項目 | 内容 |
| -- | -- |
| モデル可用性 | Gemini はクラウド API。API キー必須・ネットワーク必須。未設定/失敗時はヒューリスティックにフォールバック |
| プライバシー / コスト | transcript テキストが Google に送信される。利用は Google アカウントに課金される（GUI の設定シートに明記） |
| 生成の決定性 | LLM 出力ゆれ。`responseSchema` でスキーマ強制 + 検証クランプで吸収 |
| stale 検知 | チャプター生成後に slice すると時間軸がズレる。任意で `derivedFromGenerations: [trackID: relativePath]` を持たせ警告する余地を残す |
| Intro チャプター | 先頭に自動「Intro」マーカー (start = 0) を付けるか |
| 一般メタデータ | M4A 化のついでに Title / Artist / Artwork も埋めるか (同じ `AssetExportPipeline` 経路) |
| 既存テスト移行 | `MixE2ETests` / `MixIntroOutroE2ETests` / `MixComposeTests` は WAV 前提。M4A 移行が必要 |

## 10. 影響を受ける既存コード (参考)

| ファイル | 変更内容 |
| -- | -- |
| `MaycastCore/Models.swift` | `Chapter` / `ChapterSource` 追加、`Episode.chapters` 追加 |
| `MaycastCore/Audio.swift` | `AssetExportPipeline` 新設 (M4A 書き出し)。`writeWAV` は中間ファイル用に残置 |
| `MaycastIPC/ServiceDTO.swift` | `ServiceOperation.chapter` 追加 |
| `MaycastIPC/ServiceResolver.swift` | `Service.chapter = "MaycastChapterService"` 追加 |
| `Sources/MaycastChapterService/` | 新規サービス (Google Gemini) |
| `MaycastCore/GeminiChapterEngine.swift` | Gemini API クライアント + チャンク→時刻マップ |
| GUI `GeminiSettings.swift` | API キーの Keychain 保存 + 設定シート |
| `MaycastMixService/main.swift` | 出力を `AssetExportPipeline` (M4A) に変更、チャプター埋め込み |
| `MaycastCLI/Commands/` | `ChapterCommand` 群追加。`MixCommand` の出力デフォルトを `.m4a` に |
| `MaycastCLI/Maycast.swift` | `ChapterCommand` をサブコマンド登録 |
| GUI (SwiftUI) | チャプター編集 View 追加 |
| Package.swift | `MaycastChapterService` ターゲット追加（外部依存なし — Gemini は `URLSession` で呼ぶ） |
