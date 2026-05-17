# Maycast Studio アーキテクチャ

本ドキュメントは、Maycast Studio の **基盤** (各機能 Slice / Polish / Mix / Transcribe を成立させる共通土台) に関する設計判断をまとめたものです。

## 1. プロジェクトモデル

### Show / Episode の 2 階層

Xcode の **Workspace / Project** 関係をそのまま音声編集ドメインに持ち込みます。

| 概念 | 実体 | Xcode 相当 | 役割 |
| -- | -- | -- | -- |
| **Show** | `<name>.maycastshow/` (ディレクトリバンドル) | Workspace | 1 つの Podcast 番組。共通アセット (Intro / Outro / BGM) とデフォルト設定を保持 |
| **Episode** | `<name>.maycast/` (ディレクトリバンドル) | Project | 1 エピソード。元音源・編集ファイル群・最終書き出しを保持 |

- Episode は **Show なしでも単体で成立** (xcodeproj が workspace なしでも開けるのと同じ)
- 1 エピソード = 1 Episode (= 1 プロジェクト)

### ディレクトリレイアウト

```
my-podcast.maycastshow/             # Show バンドル
  show.json                         # show メタ + デフォルト Polish 設定など
  assets/
    intro.mp3
    outro.mp3
    bgm-default.mp3
  episodes/
    ep01.maycast/                   # Episode バンドル
      episode.json                  # 編集メタ情報 (current ポインタ / history など)
      sources/                      # 取り込んだ元音源 (コピー、不変)
        host.wav
        guest.wav
      intermediate/                 # 各操作の結果ファイルが積み上がる場所
        host/
          001_import.wav
          001_import.params.json
          001_import.transcript.json
          002_slice.wav
          002_slice.params.json
          002_slice.transcript.json
          003_polish.wav
          003_polish.params.json
          003_polish.transcript.json
          004_slice.wav
          004_slice.params.json
          004_slice.transcript.json
        guest/
          ...
      assets/                       # Show からスナップショットコピーされた共通アセット
        intro.mp3
        outro.mp3
        bgm.mp3
      exports/                      # 最終 Mix 出力
        ep01.wav
    ep02.maycast/
      ...
```

### アセット取り扱いポリシー

| アセット種別 | 取り扱い | 理由 |
| -- | -- | -- |
| Episode のソース音源 (録音) | プロジェクト内に **コピー取り込み** | 自己完結、可搬性 |
| Show の Intro / Outro / BGM | Episode 作成時に **スナップショットコピー** | 過去エピソードの再現性、自己完結 |

**スナップショット方式の意図**: Show 側で Intro を後から差し替えても、既に作成済みの Episode は元の Intro を保持する。古いエピソードを Mix し直しても音が変わらない。

> 全エピソードへの一括反映は将来コマンド (`maycast show update-assets` 等) で個別に対応する。

## 2. 編集モデル: File Versioning

### 基本思想

「最低限の編集を手軽に」というコンセプトと、CLI / AI エージェント連携を考慮し、**ファイル中心の素朴なモデル** を採用する。

- 各操作 (Transcribe / Slice / Polish) は **入力ファイル → 出力ファイル の変換** として実装される
- 元音源 (`sources/`) は **決して書き換えない**
- 操作のたびに `intermediate/<track>/NNN_<op>.wav` が新規生成され、ファイルが時系列に積み上がる
- 「現在のトラック状態」 = 最新ファイル (= `episode.json` の `current` が指すもの)
- 操作パラメータと文字起こしは **サイドカー** として同名で保持

```
sources/host.wav            # 不変
        │
        │ import (= intermediate にコピー + transcribe ベース)
        ▼
intermediate/host/001_import.wav        ←─── 001_import.params.json
                                              001_import.transcript.json
        │
        │ slice (cut: 12.3-15.8)
        ▼
intermediate/host/002_slice.wav         ←─── 002_slice.params.json
                                              002_slice.transcript.json (trim 済)
        │
        │ polish (denoise + loudness)
        ▼
intermediate/host/003_polish.wav        ←─── 003_polish.params.json
                                              003_polish.transcript.json
        │
        │ slice (cut: 45.2-46.0)        ← Polish の後で再 Slice 可能
        ▼
intermediate/host/004_slice.wav  ★ current ←  004_slice.params.json
                                              004_slice.transcript.json
```

### サイドカーの内容

各 `NNN_<op>.wav` には同名の `.params.json` と `.transcript.json` が並ぶ。

```json
// 003_polish.params.json
{
  "op": "polish",
  "input": "002_slice.wav",
  "params": {
    "denoise": true,
    "loudness": -16,
    "deEsser": false
  },
  "createdAt": "2026-05-17T10:00:00Z"
}
```

```json
// 003_polish.transcript.json
{
  "segments": [
    { "start": 0.0, "end": 2.5, "text": "こんにちは…" },
    ...
  ]
}
```

### episode.json (簡素化版)

```json
{
  "id": "ep01",
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "show": "../",
  "tracks": [
    {
      "id": "host",
      "source": "sources/host.wav",
      "current": "intermediate/host/004_slice.wav",
      "history": [
        "intermediate/host/001_import.wav",
        "intermediate/host/002_slice.wav",
        "intermediate/host/003_polish.wav",
        "intermediate/host/004_slice.wav"
      ]
    },
    {
      "id": "guest",
      "source": "sources/guest.wav",
      "current": "intermediate/guest/001_import.wav",
      "history": ["intermediate/guest/001_import.wav"]
    }
  ],
  "mix": {
    "intro": "assets/intro.mp3",
    "outro": "assets/outro.mp3",
    "bgm":   { "file": "assets/bgm.mp3", "duck": -12 }
  }
}
```

### 重要ルール

- **元音源は不変** — `sources/` は読み取り専用
- **Mix の入力は各 track の `current`** — operations を評価する必要がなく、Mix は単純なファイル合成
- **Polish/Slice は任意順・任意回数** — `polish → slice → polish` も自然に表現 (単にファイルが増えるだけ)
- **transcripts はファイルに紐付く** — Slice で時刻がズレる時、Slice サービスが新しい transcript を生成
- **revert は明示コマンドで世代を戻す** — Undo は持たない代わりに `maycast revert --to N` を提供

### 採用理由 (Operation Stack 案との比較)

| 観点 | File Versioning (採用) | Operation Stack (不採用) |
| -- | -- | -- |
| 概念の素朴さ | ◎ 「ファイルが溜まる」だけ | △ 仮想タイムライン / time mapping が必要 |
| 中間結果の再生 | ◎ どの世代でも単独で再生可能 | △ 都度レンダリングが必要 |
| CLI / AI エージェント連携 | ◎ file → file 変換として組みやすい | △ JSON 操作が前提 |
| デバッグ | ◎ ファイルを順に聴けば原因が分かる | △ 内部状態の解釈が必要 |
| XPC サービスの実装 | ◎ 単純な変換関数 | △ 仮想タイムラインの解釈エンジンが必要 |
| ストレージ効率 | △ ファイルが溜まる (緩和策あり) | ◎ パラメータのみ |
| 反復編集効率 | △ 後段を再生成する必要 | ◎ operation 編集で済む |

「最低限の編集を手軽に」というコンセプト上、**反復編集は頻繁ではない** ことを前提に、概念の素朴さ・CLI 連携・デバッグ容易性を優先した。

### ストレージ対策

ファイルが溜まる欠点には以下で対処する。

| 対策 | 内容 |
| -- | -- |
| 中間ファイルの形式 | デフォルト **FLAC** (可逆圧縮、WAV 比 50-60%) で保存。エクスポート時のみ WAV/MP3 等に変換 |
| `.gitignore` 推奨 | `sources/`、`assets/`、`episode.json`、`exports/` のみ git 管理。`intermediate/` は除外 |
| 履歴の上限 | 将来オプション (`show.json` の `keepHistory: N`) で古い世代を自動削除可能に |

## 3. サービス構成 (XPC)

GUI / CLI のどちらから呼んでも同じ挙動になるよう、各機能を XPC サービスとしてプロセス分離する。

| サービス | 役割 | 入力 | 出力 |
| -- | -- | -- | -- |
| **Transcribe** | 音声 → タイムコード付きテキスト | track の `current` ファイル | 同フォルダに `<NNN>_<op>.transcript.json` を生成 (新しい世代を作らず、最新ファイルに transcript を追加するだけのケースもある) |
| **Slice** | カットを適用した新しいファイルを生成 | track の `current` + 区間 | `intermediate/<track>/NNN_slice.wav` + `.params.json` + `.transcript.json` |
| **Polish** | クリーニング処理を適用した新しいファイルを生成 | track の `current` + パラメータ | `intermediate/<track>/NNN_polish.wav` + `.params.json` + `.transcript.json` |
| **Mix** | 全 track の `current` を合成してレンダリング | project 全体 | `exports/<name>.wav` |

各サービスは:
1. `episode.json` を読む
2. 該当 track の `current` ファイルを入力として処理
3. 新しい `NNN_<op>.*` を `intermediate/` に生成
4. `episode.json` の `current` と `history` を更新

### 共有状態としての episode.json

各サービスは「ファイルを引数で受け渡す」のではなく、**episode.json を読み・更新する** ことで連携する。

```
        ┌──────────────── episode.json ────────────────┐
        │       current / history / mix メタ情報        │
        └─▲────────────▲────────────▲────────────▲─────┘
          │            │            │            │
        update       update       update      read-only
          │            │            │            │
    Transcribe       Slice        Polish         Mix
      (XPC)          (XPC)        (XPC)         (XPC)
          ▲            ▲            ▲            ▲
          └────────────┴──── XPC ───┴────────────┘
                       │             │
                  Maycast Studio   maycast (CLI)
                     (SwiftUI)
```

## 4. CLI (`maycast`)

### 方針

- **xcodebuild 流**: プロジェクト/ショーの指定は常に **明示的なフラグ** で行う (cwd 自動検出は **しない**)
- GUI で行える操作は全て CLI からも実行可能
- AI エージェント (Claude Code 等) と E2E テストが主要クライアント

### コマンド例

```bash
# --- Show 操作 ---
maycast show init my-podcast.maycastshow
maycast show set-asset -show my-podcast.maycastshow \
  --intro intro.mp3 --outro outro.mp3 --bgm bgm.mp3

# --- Episode 作成 ---
maycast init ep01.maycast                                # Show なし
maycast init ep02.maycast -show my-podcast.maycastshow   # Show 配下 (Intro/Outro/BGM がコピーされる)

# --- 音源取り込み (sources/ にコピー + intermediate/<track>/001_import.* を生成) ---
maycast import -project ep02.maycast --as host  host.wav
maycast import -project ep02.maycast --as guest guest.wav

# --- 編集 (intermediate/ に新ファイルを生成し、current を更新) ---
maycast transcribe -project ep02.maycast --track host
maycast slice      -project ep02.maycast --track host --cut 12.3-15.8
maycast polish     -project ep02.maycast --track host --denoise --loudness -16
maycast slice      -project ep02.maycast --track host --cut 45.2-46.0   # 再 Slice 可

# --- 状態確認 ---
maycast list    -project ep02.maycast                    # tracks 一覧 + 現世代
maycast inspect -project ep02.maycast --track host       # history と params

# --- 世代を戻す ---
maycast revert  -project ep02.maycast --track host --to 2

# --- 書き出し (各 track の current を読んで合成) ---
maycast mix -project ep02.maycast --output exports/ep02.wav
```

## 5. キャッシュ・履歴

| 項目 | 方針 |
| -- | -- |
| 中間ファイル (`intermediate/`) | **プロジェクト内** に保持。state そのもの (= キャッシュではない) |
| 揮発キャッシュ (波形画像等) | `~/Library/Caches/Maycast/<project-uuid>/` (プロジェクト外) |
| project UUID | `episode.json` 作成時に発行・固定 |
| Undo / 操作履歴 | **サポートしない**。世代を戻したい時は `maycast revert` か git に委ねる (xcodeproj 同様) |

`intermediate/` と揮発キャッシュを分ける意図: 中間ファイルは「やり直したいときに必要な状態」なのでプロジェクトに同梱、波形プレビューやサムネイル等は再生成可能なので OS のキャッシュ領域に逃がす。

## 6. 将来拡張との接続点

- **Maycast Cloud / Room** — 各話者のローカル収録ファイルは Episode の `sources/` に取り込まれる形で接続
- **Maycast Cloud / Knowledge** — Show 単位で番組ネタ DB を持つ。`show.json` 経由でクラウドと紐付け
- **一括 asset 更新** — Show の Intro 差し替えを全エピソードへ反映する `maycast show update-assets` 等
- **履歴上限** — `show.json` の `keepHistory: N` で古い `intermediate/` を自動掃除

## 7. Episode の状態遷移

`docs/diagrams/episode-state.puml` を参照。

