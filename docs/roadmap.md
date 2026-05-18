# Maycast Studio — 開発ロードマップ

Foundation (Phase 0) は完了。ここからは「最低限の編集を手軽に」を成立させる機能を順次積み上げる。

各機能は [`CLAUDE.md`](../CLAUDE.md) の開発順序ルールに従う:

1. SwiftUI で UI モックアップ (`#Preview` で確認可能)
2. CLI 経由の E2E テスト作成
3. 実装 (XPC サービス + CLI + GUI 配線)
4. E2E パス + UI 実データで確認 → 完了

## 全体方針

| 観点 | 方針 |
| -- | -- |
| 言語/フレームワーク | Swift 6.2 / SwiftUI / AVFoundation / Speech / Accelerate (vDSP) |
| 音声 I/O 基盤 | `AVAudioFile` + `AVAudioPCMBuffer` ベース。フォーマット差異を吸収する `AudioFile` 抽象を `MaycastCore` に追加 |
| 音声 DSP の方針 | **ハイブリッド**。Apple フレームワークで済むものは Apple を使い (`AVAudioUnitDynamicsProcessor`, `AVAudioUnitEQ`, `AVAudioEngine`)、Apple に無いもの (LUFS 測定 / Podcast 向け denoise / 無音検出) のみ `vDSP` で自前実装 |
| 文字起こし | `SpeechAnalyzer` (macOS 26 新 API) を優先、フォールバックで `SFSpeechRecognizer` |
| MVP の定義 | **Phase 1 完了時点**。`import → slice → polish (loudness) → mix → export` の一連が CLI と GUI で動作する |
| 各 milestone の進め方 | `CLAUDE.md` 準拠: **UI モックアップ (`#Preview` でビジュアル合意) → E2E → CLI 実装 → GUI 配線** の順 |
| PR の粒度 | **Phase 単位** で 1 PR を切る (milestone ごとには切らない)。Phase 内の各 milestone はコミット粒度で追える |

## Phase 1: MVP — 「録音から配信用 mix まで動く」

ゴール: ユーザーが録音した音源を取り込み、不要部分をカットし、音量を整えて結合・書き出せる。Phase 1 完了で **配信用 wav を出力できる** 状態。

| 順序 | Milestone | 概要 |
| -- | -- | -- |
| **1.1** | Audio I/O 基盤 | `AudioFile` 型の追加、WAV/AIFF/MP3 デコード・WAV エンコード。各サービスの stub を「音声を実際に読み書きする」形に置き換え |
| **1.2** | Slice (実カット) | 指定区間をカットして新しい audio を生成。transcript も追従 |
| **1.3** | Mix concat 基本 | 複数 track を時系列に結合 (ステレオ加算)。Intro/Outro/BGM は **未対応** (Phase 3 へ) |
| **1.4** | Polish loudness | LUFS 測定 + ターゲット LUFS への gain 適用 (ITU-R BS.1770) |
| **1.5** | GUI: Phase 1 機能の動線 | Slice/Polish/Mix の sheet 提示、Polish マルチトラック一括、操作呼び出し配線 |
| **1.6** | Slice エディタの実戦投入 | 実音声波形、再生 + playhead 同期、クリップ ドラッグ移動、スナップ |

### 1.1 詳細: Audio I/O 基盤

- 新規型: `MaycastCore.AudioFile` (URL ラッパ + format 情報 + 読み書き API)
- 新規型: `MaycastCore.AudioBuffer` (PCM サンプル列)
- 読込対応フォーマット: WAV / AIFF / MP3 / M4A (= AVFoundation でサポートされるもの)
- 書出対応フォーマット: WAV (Phase 1 範囲)
- 既存 stub の更新: `appendOperationGeneration` 内のファイルコピーを「audio read → 同じ内容を書き直す」に置換 (これだけでは音は変わらない / 後段の機能でこの読み書きパスに DSP を挿入する)
- E2E 追加: import / slice の出力が valid な WAV であることを `AVAudioFile` で読み戻して検証
- UI 影響: なし (CLAUDE.md の例外項に該当)

### 1.2 Slice 詳細

- UI: トラック詳細画面に「Slice 区間入力」セクション (start / end の数値入力 + プレビュー位置表示)
- E2E:
  - `maycast slice --cut 1.0-2.5` 後、出力 wav の duration が 入力 - 1.5s
  - transcript の segments が cut 区間の前後で正しく繋がる
- 実装: `AVAudioFile` 読み込み → サンプル位置で 2 つに分割 → 連結 → 書き出し。transcript は segments を時間でフィルタ & 後段の start/end をシフト

### 1.3 Mix concat 基本

- UI: Mix 画面 (出力先パス入力 + 「Mix を実行」ボタン + 結果表示)
- E2E:
  - 2 track を mix した出力の duration が `max(各 track の duration)`
  - 出力チャンネル数 = 2 (ステレオ)
- 実装: 各 track の current を `AVAudioPCMBuffer` で読み、サンプル単位で加算、出力

### 1.4 Polish loudness

- UI: Polish 画面に loudness target スライダー (-23 ~ -14 LUFS)
- E2E:
  - `maycast polish --loudness -16` 後の出力の integrated LUFS が `-16 ± 1.0`
- 実装: ITU-R BS.1770-4 の K-weighted フィルタ + gating で integrated loudness を測定 → 差分を gain として適用

### 1.5 GUI: Phase 1 統合

- ContentView に「Slice / Polish / Mix」ボタン → sheet で該当画面を提示
- **Polish は全 track 一括** (= 同じ設定を全 track に適用)
- 操作ごとの進行状況 (`ProgressView`)、エラー表示、結果表示
- 内部は GUI から MaycastCore を直接呼び出し (in-process)。XPC 切り替えは将来フェーズ

### 1.6 Slice エディタの実戦投入

Phase 1.5 までは Slice エディタは「Apply で arrangement を確定できる」状態。1.6 で **編集体験そのもの** を仕上げる。

| サブ項目 | 内容 |
| -- | -- |
| 1.6.1 波形生成・表示 | 各 generation の WAV から peak pair 列を計算 → PNG キャッシュ (`~/Library/Caches/Maycast/<uuid>/waveforms/`) → エディタの ClipView に実波形を描画 |
| 1.6.2 再生エンジン | `AVAudioEngine` ベースで複数トラックを同時再生。play / pause / stop / scrub。playhead 位置を SwiftUI 側に同期 (60fps) |
| 1.6.3 クリップ ジェスチャ | クリップのドラッグ移動 (左右)、クリック選択、shift クリック範囲拡張 (将来) |
| 1.6.4 スナップ | 他クリップの edge、playhead、グリッド (秒単位) へのスナップ。ホールド (Cmd 等) で一時解除 |

これらが揃った時点で Phase 1 MVP の「ユーザーが実用できる Podcast 編集」が成立する。

### Phase 1.5 と 1.6 の境界

- 1.5 は **「機能を一通り呼べる動線」** = ボタン押せばコマンドラインと同じ結果が得られる
- 1.6 は **「マウスで触って編集できる体験」** = 再生しながら波形を見て切れる

両者は独立して機能フェーズへの進行を阻害しないため、Phase 2 (再生 + 文字起こし) や Phase 3 (Polish 拡張) と並行可能。ただし 1.6 で実装する再生エンジンは Phase 2.1 (GUI 再生機能) の前提となるため、Phase 2 着手前に 1.6.2 までは終えておきたい。

## Phase 2: 編集 UX 強化 — 文字起こしと再生

ゴール: 編集中に音を聴けて、文字起こしを見ながらカットできる。

| 順序 | Milestone | 概要 |
| -- | -- | -- |
| 2.1 | GUI 再生機能 | 任意の track / 任意の generation の音声を再生 (play / pause / scrub) |
| 2.2 | Transcribe (実装) | `SpeechAnalyzer` で track の transcript を生成 |
| 2.3 | GUI 文字起こしビュー | transcript を **時系列リスト** で表示 (タイムスタンプ + 話者バッジ + 文)、現在の再生位置を行ハイライト、行クリックで playhead seek |

> Phase 2.4 (transcript-driven slice) は **削除**。ユーザフィードバック (2026-05-18): 文字起こしは「何秒の時点で何を喋っているかを荒く確認する」用途であり、編集起点としては使わない。編集は timeline (Phase 1.2/1.6) 経由で行う。

## Phase 3: 仕上げ機能 — Polish 拡張 + Mix 拡張

ゴール: 配信品質に近づける。BGM 入り mix が作れる。

| 順序 | Milestone | 概要 |
| -- | -- | -- |
| 3.1 | Polish: silence removal | **マルチトラックを横断した無音区間** を閾値検出してカット (全 track が無音の区間のみ対象。audio + transcript 連動) |
| 3.2 | Polish: denoise | ノイズ除去 (Spectral subtraction または Apple framework) |
| 3.3 | Polish: de-esser | 高音域の歯擦音抑制 |
| 3.4 | Mix: Intro / Outro | Show の Intro を mix の頭に、Outro を末尾に追加 |
| 3.5 | Mix: BGM with ducking | BGM を全体に被せ、voice 区間で sidechain ducking |

## Phase 4: Maycast Cloud 準備 (将来)

| 順序 | Milestone | 概要 |
| -- | -- | -- |
| 4.1 | Show metadata 拡張 | エピソード概要・タグなどを Show 層に追加 |
| 4.2 | Knowledge データ構造 | 番組のネタ DB を `show.json` 配下にスキーマ化 |
| 4.3 | Room の WebRTC ローカル収録 | リモート収録、各話者ローカル録音 |
| 4.4 | Cloud 同期 | Knowledge / Show を Maycast Cloud と双方向同期 |

## 並列実施可能性

依存関係:
- 1.1 (Audio I/O) は全ての前提
- 1.1 完了後、1.2 / 1.3 / 1.4 は **並列実施可能** (各々独立した変換)
- 1.5 (GUI 動線) は 1.2-1.4 の各機能ができた順に積み上げる
- 1.6 (エディタ実戦投入) は 1.5 完了後。`1.6.2 再生エンジン` は Phase 2.1 の前提
- Phase 2 / 3 は Phase 1.5 完了後に着手可能 (1.6 と並行 OK)
- Phase 3 内では各 polish 効果は並列可能、Mix 拡張は Intro/Outro → BGM の順

## 検討項目 (確定済み)

| # | 項目 | 決定 |
| - | -- | -- |
| 1 | MVP 範囲 | **Phase 1 完了 = MVP** (`import → slice → polish loudness → mix → export`) |
| 2 | DSP の方針 | **ハイブリッド**: Apple フレームワーク優先、不足分のみ `vDSP` で自前実装 |
| 3 | UI/CLI の順序 | **UI 先行**: 各 milestone で `#Preview` モックアップ → E2E → CLI 実装 → GUI 配線 |
| 4 | PR 粒度 | **Phase 単位** で 1 PR |
| 5 | Transcript-driven Slice | **Phase 2 に据え置き** (差別化点だが MVP には含めない) |
