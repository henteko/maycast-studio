# Maycast Studio — 基盤構築 (Foundation)

本ドキュメントは、Maycast Studio の **基盤フェーズ** におけるスコープ・決定事項・開発の進め方をまとめたものです。基盤の完了とは「以降は各機能の中身の実装に専念できる状態」を指します。

詳細なアーキテクチャ判断は [`architecture.md`](architecture.md) を参照。

## 1. 確定した設計判断

| 論点 | 決定 |
| -- | -- |
| リポジトリ構成 | **ハイブリッド** (SwiftPM をコアに、GUI のみ Xcode プロジェクト) |
| XPC 接続方式 | **App 同梱共有** (Maycast Studio.app/Contents/XPCServices/ を CLI も参照)。開発時は SwiftPM executable を直接起動する debug モードを併用 |
| E2E テスト形式 | **ブラックボックス** (`maycast` バイナリを Process で起動して検証) |
| テストフレームワーク | **Swift Testing** |
| 最低 macOS | **macOS Tahoe (26)** |
| CI / Lint | **なし** (基盤では仕込まない。後回し) |

## 2. リポジトリ構成

```
maycast-studio/
  Package.swift                          # SwiftPM ルート
  Sources/
    MaycastCore/                         # バンドル I/O、Episode/Show/Track 型、JSON スキーマ
    MaycastIPC/                          # XPC プロトコル定義 (共有)
    MaycastCLI/                          # maycast バイナリ
    MaycastTranscribeService/            # XPC サービス (executable)
    MaycastSliceService/
    MaycastPolishService/
    MaycastMixService/
  Apps/
    MaycastStudio/                       # SwiftUI アプリ用 Xcode プロジェクト (生成方法を README で案内)
  Tests/
    MaycastCoreTests/                    # ユニットテスト
    MaycastE2ETests/                     # CLI 経由のブラックボックス E2E
  Makefile                               # build / test / e2e の便利ターゲット
  CLAUDE.md
  docs/
    concept.md
    architecture.md
    foundation.md
    diagrams/
      episode-state.puml
```

## 3. スコープ

### 3.1 含めるもの

| 項目 | 実装 / Stub |
| -- | -- |
| `Package.swift` と全 target の骨格 | 実装 |
| `MaycastCore`: Episode / Show バンドルの作成・読み書き、`episode.json` / `show.json` 型と I/O、UUID 発行、パス解決 | 実装 |
| `MaycastIPC`: 4 サービスの XPC プロトコル定義 | 実装 |
| `maycast` CLI 全コマンド (`init` / `import` / `transcribe` / `slice` / `polish` / `mix` / `list` / `inspect` / `revert` / `show init` / `show set-asset`) | **音声処理を除き実装** |
| Transcribe / Slice / Polish / Mix XPC サービス骨格 | **stub** (入力をコピーして所定の出力ファイルを生成する程度) |
| 共通基盤: ロギング、エラー型、JSON スキーマ | 実装 |
| E2E テストハーネス (`MaycastE2ETests`) | 実装 |
| Makefile (`build` / `test` / `e2e` / `clean`) | 実装 |
| GUI 最小骨格 (Xcode プロジェクト) | 後回し可。Apps/ ディレクトリと作成手順のみ用意 |

### 3.2 含めないもの

- 音声処理ロジック (Slice / Polish / Mix / Transcribe の本体)
- 編集 UI (波形表示・タイムライン・カット操作)
- FLAC エンコード、出力フォーマット選択
- CI / SwiftLint / SwiftFormat
- コード署名 / Notarization
- Maycast Cloud 連携 (Room / Knowledge)

## 4. XPC サービスの取り扱い (フェーズ別)

XPC のバンドリングは macOS 流儀がいくつかある。**フェーズで使い分ける** 方針:

| フェーズ | サービス配置 | CLI からの接続 |
| -- | -- | -- |
| **基盤フェーズ (今)** | SwiftPM executable target としてビルド | CLI が `Foundation.Process` で executable を起動し、`NSXPCListener.anonymous()` の endpoint を介して `NSXPCConnection` で接続 |
| **GUI 統合フェーズ (後)** | Xcode プロジェクト側で `.xpc` バンドル化し `Maycast Studio.app/Contents/XPCServices/` に配置 | `NSXPCConnection(serviceName:)` で App 内のサービスに接続 |

CLI 内部にサービスパスの解決ロジックを置き:
1. 環境変数 `MAYCAST_XPC_SERVICES_DIR` が指定されていればそこを探す (開発時)
2. なければ `Maycast Studio.app/Contents/XPCServices/` を探す (リリース時)

この設計により、**基盤フェーズで .app に依存せず E2E が回せる** ようにする。

## 5. 開発の進め方 (E2E 先行)

[`CLAUDE.md`](../CLAUDE.md) の開発順序ルールに従う:

1. 関連する E2E テストを **先に作成** (CLI 経由)
2. 実装
3. E2E が通ることを確認して完了

### 例外

- 例外 1: Package.swift / target 骨格・型定義の初期セットアップ (ビルド設定相当)
- 例外 2: ドキュメントのみ・既存テストのリファクタのみ・依存関係更新のみ

## 6. 完了条件 (Definition of Done)

基盤フェーズは以下を全て満たした時に完了とする。

- [ ] `swift build` で全 target がビルド成功
- [ ] `swift test` で全ユニットテストがパス
- [ ] E2E テストで以下のシナリオが通ること:
  - [ ] `maycast init` で Episode バンドルが作成される
  - [ ] `maycast init -show ...` で Show 配下に作成され、アセットがコピーされる
  - [ ] `maycast import` で `sources/` に音源がコピーされ、`intermediate/<track>/001_import.wav` が生成される
  - [ ] `maycast transcribe / slice / polish` が XPC サービス経由で stub 動作し、新しい世代ファイルとサイドカーが追加される
  - [ ] `maycast mix` が `exports/` に stub の出力を生成する
  - [ ] `maycast list / inspect` が `episode.json` の内容を正しく表示する
  - [ ] `maycast revert --to N` が `current` を過去世代に戻す
  - [ ] `maycast show init` / `show set-asset` が Show バンドルを管理する
- [ ] `Makefile` で `make build` / `make test` / `make e2e` が動く

GUI 最小骨格は完了条件には含めない (基盤フェーズ後半 or 機能フェーズで追加)。

## 7. 次フェーズへの引き継ぎ

基盤完了後、各機能の実装フェーズに移る。その際は以下のパターンを繰り返す:

1. 機能の受け入れ条件を E2E に追記 (例: 「Polish に denoise を実装したら、出力 wav の RMS が入力より下がる」)
2. 該当 XPC サービスの stub を実装に置き換え
3. E2E パスを確認
