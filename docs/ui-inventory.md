# Maycast Studio — UI インベントリ

このドキュメントは **UI デザイン刷新のためのデザイナー向けハンドオフ資料** です。Maycast Studio のコンセプトと、現状アプリ内に表示されているすべての UI 要素を画面ごとに列挙しています。実装上のロジックではなく「ユーザーが何を見て、何を触れるか」に焦点を当てています。

---

## 1. プロダクトコンセプト

**Maycast Studio** は、Podcast 配信者向けの macOS デスクトップアプリケーションです。

> **「最低限の編集を手軽に」**

Podcast 制作の現場では、DAW (Digital Audio Workstation) のような高機能ツールはオーバースペックであり、学習コストも高くなりがちです。一方で、無音削除・ノイズ除去・音量正規化・BGM/Intro の合成といった「Podcast に必須の最低限の編集」は、毎回のエピソード収録のたびに発生します。

Maycast Studio は、これら「最低限の編集」をシンプルな UI と自動化で完結できることを目指します。プロ向けの細かい操作ではなく、配信者が「録音 → 公開」までを最短距離で到達できるワークフローを提供します。

- **対象 OS**: macOS (Tahoe 26 以降)
- **対象ユーザー**: 個人 / 小規模チームの Podcast 配信者
- **ライセンス**: OSS
- **核となる 3 機能**:
  - **Slice** — マルチトラック編集 (分割 / 削除 / 移動)
  - **Polish** — クリーニング (Auphonic API 経由でノイズ除去・無音カット・音量整え)
  - **Mix** — Intro / Outro 合成 + Ducking、配信用 1 本ファイルへ書き出し

### Episode と Show という 2 階層モデル

- **Show** (`.maycastshow`) — Podcast 番組単位。Intro / Outro 音源と既定設定を保持
- **Episode** (`.maycast`) — 1 エピソード単位のバンドル。任意で 1 つの Show を参照
- Episode 作成時に Show のアセットがスナップショットコピーされる (= 過去のエピソードは Show の差し替えに影響されない)

---

## 2. 全画面共通の構造

- **メニューバー** (macOS standard):
  - File (Open Episode / Close)
  - **Edit** — Undo / Redo (操作履歴に基づく)
  - **Episode** — Open / Close / **Show History…** (履歴 sheet を開く)
- **モーダルシート**: 主要な作業 (Slice / Polish / Mix / 新規作成) はシートで提示。シートは常にコンテンツ領域 (Episode が開いている場合はその上、ホーム画面の場合はその上) に重なる
- **キーボードショートカット**:
  - `⌘O` Open Episode
  - `⌘N` New Episode
  - `⌘⇧N` New Show
  - `⌘W` Close Episode
  - `⌘Z` Undo / `⌘⇧Z` Redo (コンテキスト依存)
  - `⌥⌘H` Show History

---

## 3. ホーム画面 (`HomeView`)

Episode が何も開かれていない初期状態に表示される歓迎画面。

### レイアウト要素

| 要素 | 内容 | 備考 |
|---|---|---|
| アプリヘッダー | `waveform.path.ecg.rectangle` アイコン + 「Maycast Studio」タイトル + 「Open a recent episode, or start a fresh one.」サブタイトル | |
| アクション行 | 3 ボタン横並び | |
| - 「**New Episode…**」 | 主アクション (borderedProminent) | アイコン `plus.rectangle`、⌘N |
| - 「New Show…」 | 副アクション (bordered) | アイコン `shippingbox`、⌘⇧N |
| - 「Open…」 | 副アクション (bordered) | アイコン `folder`、⌘O |
| Recent episodes セクション | アイコン `clock` + 「Recent episodes」見出し + 「(N total)」サブテキスト | |
| Recent エピソードリスト | カード状にスクロール表示 | 空のときは "No recent episodes" プレースホルダ |

### 各 Recent エピソードのカード

| 要素 | 内容 |
|---|---|
| アイコン | `rectangle.stack.fill` (accent color) |
| エピソード名 | `.maycast` 拡張子を除いた basename (例: `ep01`) |
| Show 名 | 紐付いている Show 名 (`· my-podcast`) |
| 絶対パス | `monospaced.caption` で 1 行省略表示 |
| 最終オープン時刻 | 相対 (`2 minutes ago`, `yesterday`) |
| Remove ボタン | `xmark.circle` (ホバー時 / 右クリック) |
| コンテキストメニュー | Open / Reveal in Finder / Remove from Recents |

---

## 4. エピソード画面 (`EpisodeView`)

Episode が 1 つ開かれているときに表示。**メインワークスペース**。

### ヘッダー

| 要素 | 内容 |
|---|---|
| エピソード ID | `.title.bold()` で大きく表示 |
| UUID | 右上に `monospaced.caption` で薄く |
| Show バッジ | `shippingbox` アイコン + Show 名 (Show 紐付きエピソードのみ) |
| バンドルパス | `monospaced.caption` で 1 行 |

### Tracks セクション (スクロール領域)

各トラックがカード状に並ぶ:

| 要素 | 内容 |
|---|---|
| Track ID | 太字 (例: `host`, `guest`) |
| source | "source: sources/host.wav" を monospaced caption で |
| current | "current: intermediate/host/00X_xxx.wav" |
| 世代数 | "N generation(s)" 表記 |

トラックが 0 の場合は `waveform` 大きいアイコン + 「No tracks yet」プレースホルダ。

### Recent activity セクション (Tracks の下)

ホーム画面で見られない代わりに、エピソード画面では **常駐**:

| 要素 | 内容 |
|---|---|
| 見出し | `clock.arrow.circlepath` アイコン + 「Recent activity」+ 「(N total)」 |
| 「Show all…」リンク | 右端、`HistorySheet` を開く |
| バッチ行 (最大 5 件) | 各操作グループ |

各バッチ行の要素:
- 種別アイコン (`scissors` / `wand.and.sparkles` / `rectangle.stack`)
- 種別名 (Slice / Polish / Mix)
- 影響 track 列挙 (例: `host, guest`)
- 相対タイムスタンプ (`2 minutes ago`)
- 「(undone)」マーカー (redo 待ちの場合 dim 表示)

### アクションバー (画面下部)

左から右に:

| 要素 | 内容 | 備考 |
|---|---|---|
| 「Undo `<kind>`」 | `arrow.uturn.backward` アイコン | 最新 batch の種別 (例: "Undo polish") を動的にラベル化、`⌘Z` |
| 「Redo」 | `arrow.uturn.forward` | redo 可能時のみ表示、`⇧⌘Z` |
| ─ (divider) | | |
| 「Slice (multi-track)」 | `scissors` | 主編集ボタン |
| 「Polish (multi-track)」 | `sparkles` | クリーニング |
| 「**Mix**」 | `square.stack.3d.down.forward` | borderedProminent (最終出力アクション) |

---

## 5. 新規作成シート

### 5.1 NewEpisodeSheet

新しい Episode バンドルを作成。

| セクション | 要素 |
|---|---|
| ヘッダー | 「New Episode」タイトル + 説明文 |
| **Bundle path** | アイコン `folder.badge.plus` + 「Choose…」ボタン + パス入力 TextField (monospaced) + 「Episode ID: derived」表示 |
| **Show (optional)** | 「Select Show…」or 選択済みの場合 `checkmark.seal.fill` + パス + 「Change…」「Remove」 |
| **Speakers (optional)** | `person.2.wave.2` アイコン見出し + 「Add」ボタン |
| - 各 speaker 行 | trackID 入力 TextField (幅 110px) + アイコン (`waveform` or `circle.dashed`) + ファイル名 (monospaced) + 「Choose…/Change…」ボタン + 「×」削除 |
| - 説明文 | 「Each speaker becomes a track in the new Episode. Audio files are copied into sources/...」 |
| - エラー表示 | trackID 重複 / 不正文字時、赤の caption |
| Status | 「Creating…」表示 + 現在ステージの monospaced 文字列 (例: 「Importing speaker 1/2: host ← host.wav (45.0 MB)」) |
| Footer | Cancel (キャンセル) + 「Create」(主アクション、`⌘↩`) |

### 5.2 NewShowSheet

新しい Show バンドルを作成。

| セクション | 要素 |
|---|---|
| ヘッダー | 「New Show」タイトル + 説明文 (アセットの snapshot 動作を説明) |
| **Bundle path** | `folder.badge.plus` + 「Choose…」 + パス TextField |
| Display name | 任意の表示名 TextField (空なら basename にフォールバック) |
| **Assets (optional)** | `music.note.list` アイコン見出し |
| - Intro 行 | アイコン (`checkmark.seal.fill` or `circle.dashed`) + パス (monospaced) + 「Choose…/Change…」+ 「×」 |
| - Outro 行 | 同上 |
| - 説明文 | 「Selected files are copied into the bundle」 |
| Status | 同じく「Creating…」 |
| Footer | Cancel + 「Create」 |

---

## 6. Slice Editor (`EditorSheet` / `EditorView`)

最も操作頻度が高い画面。マルチトラックタイムライン上で **分割 / 削除 / 移動 / 試聴** を行う。

### EditorToolbar (画面上部)

横並びの 3 ブロック:

#### Transport
- 「Play / Pause」ボタン (`play.fill` / `pause.fill`)
- 「Stop」ボタン (`stop.fill`)、playhead が 0 のときは disable
- **Speed Picker** (`PlaybackRatePicker`) — `0.5x` / `0.75x` / `1x` / `1.25x` / `1.5x` / `1.75x` / `2.0x` メニュー (pitch 保持)

#### Edit-session Undo / Redo
- Undo (`arrow.uturn.backward`) — Slice セッション内、`⌘Z`
- Redo (`arrow.uturn.forward`) — `⇧⌘Z`
- どちらも disable 状態あり

#### Edit
- **Split @ playhead** (`scissors` + ラベル「Split (N) @ playhead」、N は影響クリップ数)
- **Delete (N)** — 選択クリップを削除、destructive role、`trash` アイコン
- Transcript 表示トグル (`text.quote`、文字起こしがあるとき)

#### Zoom 領域
- `−` / `+` アイコンボタン
- Slider (5–200 px/s)
- 現在の値 (`N px/s`)、monospaced

#### 右端
- 現在の playhead 時刻 (`12.34s`, monospaced)
- ─ divider
- **Reset** (変更なし時 disable)
- **Apply** (borderedProminent、`⌘↩`)

### Timeline 領域

水平方向にスクロールするタイムライン。

#### 左サイドの Track Header カラム (固定幅 130px)
- 上部に Ruler 高さぶんの空白
- トラック ID をリスト表示 (`TrackHeaderRow`)
- 選択中クリップを含むトラックはハイライト

#### 上部の Time Ruler (`TimeRulerView`、高さ 28px)
- 秒単位グリッド + 時刻ラベル
- クリックで playhead を seek

#### Tracks エリア
各トラック行 (高さ 96px) に `TrackClipsView` を表示。

各クリップ (`ClipView` + `ClipContent`) の描画要素:
- 角丸長方形の背景 (accent color の薄塗り、選択中は濃く + 太い枠線)
- **波形** (`WaveformView`、`Canvas` で min/max ピーク描画、accent color)
- クリップの長さ表示 (`12.3s`, monospaced caption)

#### Playhead Overlay (`PlayheadOverlay`)
- 縦の細い線 + 上端の三角ハンドル
- 再生中はリアルタイムで進む

### Transcript Panel (画面下半分、表示トグルで開閉)

開いているとき、Tracks エリアの下に固定高 240px で配置。

#### TranscriptPanel ヘッダー
- 「Transcript」見出し
- 「Transcribe all」/ 「Re-transcribe all」 ボタン (`waveform.badge.magnifyingglass`)
- 「×」閉じるボタン

#### 各トラックのカラム (横並び)
- トラック ID 見出し
- 状態に応じた表示:
  - **empty**: 「Transcribe」ボタン
  - **generating**: スピナー + ステータス文字 + これまで認識した部分 (グレー)
  - **populated**: タイムスタンプ付きの行リスト (タイムスタンプ + 話者バッジ + 発話テキスト)
  - **failed**: エラー表示 + Retry
- 現在の playhead 位置に対応する行はハイライト
- 行クリックで playhead seek + そこへスクロール

---

## 7. Polish Sheet (`PolishSheet` / `PolishView`)

Auphonic Multitrack API 経由で音声を一括クリーニング。

### ヘッダー
- 「Polish」タイトル + 「via Auphonic」ラベル
- 右側に「N tracks」(`rectangle.stack`)
- 説明文: 「Cleans each track via the Auphonic Multitrack API... 」

### API Key 状態行
- アイコン `key.fill` (緑) or `key.slash` (赤)
- 「Auphonic API key (configured / not set)」ラベル
- マスク表示 (例: `configured (••••2f1a)`)
- 「Configure… / Change…」ボタン → `AuphonicSettingsSheet`

### Speakers 一覧
各トラックを `waveform` アイコン + Track ID + パス (monospaced) + 長さ (`38:51.61`) で 1 行表示。

### Effects セクション (スクロール領域、最大高 280px)

| 項目 | UI |
|---|---|
| Loudness target | `speaker.wave.2` アイコン + Slider (-23 〜 -14 LUFS, step 0.5) + 値表示 (`-16.0 LUFS`) |
| Adaptive Leveler | `slider.horizontal.3` + Toggle |
| Denoise | `wand.and.sparkles` + Toggle + Method Picker (Dynamic / Static / Speech isolation) |
| Cuts | `scissors` 見出し + 3 Toggle (Filler / Silence / Cough cutter) |
| Debreath amount | Picker (Off / 3 / 6 / 9 / 12 / 15 / 18 / 24 / 30 / 36 / Max dB) |
| High-pass filter | `waveform.path` + Toggle |
| Keep production on Auphonic dashboard | `tray.full` + Toggle (デバッグ用途) |

### Status 表示
状態によって切り替わる:
- **idle**: `circle.dashed` + 「Ready」
- **needsApiKey**: 警告アイコン + 「Set an Auphonic API key to continue.」
- **uploading**: スピナー + `arrow.up.circle` + 「Uploading to Auphonic…」+ 各 track の `ProgressView` (0–100%)
- **processing**: スピナー + 「Auphonic processing — Audio Algorithms」(現在ステージ表示)
- **downloading**: スピナー + `arrow.down.circle` + per-track プログレス
- **completed**: 緑チェック + 「Polish complete (N tracks)」+ 各 track の新世代パス
- **failed**: 赤三角 + エラーメッセージ

### Footer
- Cancel ボタン (再生中のみ表示)
- 「Send to Auphonic」(borderedProminent、進行中は「Uploading…/Processing…/Downloading…」)

---

## 8. AuphonicSettingsSheet

API key の Keychain 管理。

| 要素 | 内容 |
|---|---|
| タイトル | 「Auphonic API key」 |
| 説明文 | 「Issue an API key from https://auphonic.com/engine/account/. ... Keychain に保存」 |
| 状態行 | `key.fill` (緑) / `key.slash` (赤) + 説明 |
| 入力 | `SecureField` (現値はマスクで表示せず、新規入力のみ) |
| Footer | (key 設定済み時) **Remove** destructive + Cancel + 「Save / Replace」 |

---

## 9. Mix Sheet (`MixSheet` / `MixView`)

複数 track + Intro/Outro を合成して配信用 1 本のファイルを書き出す。

### ヘッダー
- 「Mix」タイトル + 「N tracks」

### Tracks セクション
各トラックを `waveform` アイコン + Track ID + パス + 時間 (`38:51.61`) で表示。
末尾に:
- 「Output duration」: `38:51.61`
- 「Output format」: `16-bit PCM WAV · stereo`

### Intro / Outro overlap セクション

| 要素 | 内容 |
|---|---|
| 見出し | `music.note` + 「Intro / Outro overlap」 |
| Intro 行 | アイコン (`checkmark.seal.fill` or `circle.dashed`) + パス + (attached なら) 長さ表示 (`8.5s`) |
| Outro 行 | 同上 |
| Intro overlap スライダー | 0 〜 intro file length (s), step 0.5 |
| Outro overlap スライダー | 0 〜 outro file length (s), step 0.5 |
| Ducking gain スライダー | -24 〜 0 dB, step 1 |
| Ducking fade スライダー | 0 〜 2 s, step 0.1 |
| **Preview 行** | |
| - 「Preview intro transition」 | `play.circle` アイコン |
| - 「Preview outro transition」 | 同上 |
| - 状態表示 | 「Rendering…」スピナー / 再生中は `waveform` の pulse / 失敗時は赤エラー |
| - 「Stop」 | 再生中のみ表示 |

### Output path セクション
- 「Output path」見出し
- TextField (デフォルト `exports/<episodeID>.wav`)

### Status 表示
- **idle**: `circle.dashed` + 「Ready to mix」
- **mixing**: スピナー + 「Mixing…」+ 線状 ProgressView
- **completed**: 緑チェック + 「Mix complete」+ パス + 時間 + ファイルサイズ
- **failed**: 赤三角 + エラー

### Footer
- 「Reveal in Finder」(completed 時のみ)
- 「Mix / Mixing… / Mix again」(borderedProminent)

---

## 10. History Sheet

エピソードの操作履歴を確認するための専用シート (`⌥⌘H` で開く / Recent activity の「Show all…」から)。

### ヘッダー
- 「Episode History」タイトル
- 「Close」(`⎋`)

### Applied セクション
- 見出し: 「Applied」+ 「Newest first — N batch(es)」
- 各バッチカード:
  - 種別アイコン (`scissors` / `wand.and.sparkles` / `rectangle.stack`)
  - 種別名 + 影響 track 列挙
  - 右上にタイムスタンプ
  - その下に **per-track の from → to パス** (monospaced caption)

### Available to redo セクション (条件付き)
- 見出し: 「Available to redo」+ batch 数
- 同様のカード、ただし全体を opacity 0.55 で dim 表示

空状態の場合は 「No operations recorded yet.」プレースホルダ。

---

## 11. エラー画面 (`ErrorView`)

Episode を開く際の致命的エラー時。

| 要素 | 内容 |
|---|---|
| アイコン | `exclamationmark.triangle` (橙、大きい) |
| タイトル | 「Failed to open Episode」 |
| 詳細 | エラーメッセージ (monospaced) |
| Dismiss ボタン | コンテンツ領域に戻る (ホーム画面へ) |

---

## 12. 共通の状態表現

### アイコン慣習
- 🎙 トラック → `waveform`
- ✂️ Slice → `scissors`
- 🪄 Polish → `wand.and.sparkles`
- 📚 Mix → `rectangle.stack` / `square.stack.3d.down.forward`
- 🕐 履歴 → `clock` / `clock.arrow.circlepath`
- 🔑 API key → `key.fill` / `key.slash`
- ✓ 設定済 → `checkmark.seal.fill` (green)
- ○ 未設定 → `circle.dashed`
- ⚠ エラー → `exclamationmark.triangle.fill` (red / orange)

### 進行状態
すべての「重い操作」は同一の状態列を使用:
**idle → uploading/rendering/processing/mixing/downloading → completed / failed**

スピナー、線状 ProgressView、絶対値テキスト (`45.2 MB`, `3.4s`, `progress=42%`) が頻出。

### Track 列挙
- mono-spaced で trackID
- ファイルパスは monospaced caption + 1 行省略 (truncationMode: .middle)
- 長い時間は `MM:SS.ss` で

---

## 13. 操作の流れ (Happy Path)

1. **ホーム画面** で「New Episode…」または Recent からエピソード選択
2. **エピソード画面** が開く
3. 必要に応じて **Polish** を実行 → 自動クリーニング
4. **Slice** で不要部分のカット (split → delete → move、Apply 前なら ⌘Z で取り消し可)
5. **Mix** で Intro / Outro を被せて書き出し
6. エクスポート完了 (Reveal in Finder)
7. 失敗時は **Undo** または **History** から戻る
