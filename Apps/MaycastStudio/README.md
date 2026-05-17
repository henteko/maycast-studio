# Maycast Studio — SwiftUI App セットアップ

このディレクトリには Maycast Studio の SwiftUI 骨格コードが置かれている。**Xcode プロジェクト本体は手動で作成する必要がある** (Xcode が生成するファイル群はバージョン管理に乗せにくいため)。

このドキュメントは「初回セットアップ」の手順書。

## ゴール

- macOS App `Maycast Studio.app` が起動する
- メニューから `.maycast` ディレクトリを開ける
- 開いたエピソードの tracks 一覧と current 世代が表示される
- ※ この時点では編集機能はナシ (CLI 経由で操作する)

## 前提

- macOS 26 (Tahoe) 以降
- Xcode 16+ (Swift 6 対応)
- リポジトリルートで `swift build` が成功している

## 手順

### 1. Xcode プロジェクトを新規作成

1. Xcode を起動 → `File → New → Project…`
2. テンプレート: **macOS → App** を選択 → Next
3. オプションを設定:
   - **Product Name**: `Maycast Studio`
   - **Team**: 任意 (個人開発なら自身の Apple ID)
   - **Organization Identifier**: 任意 (例: `dev.henteko`)
   - **Interface**: **SwiftUI**
   - **Language**: **Swift**
   - **Storage**: **None**
   - **Include Tests**: チェックを外す (テストは Swift Package 側で管理)
4. **保存先**: このリポジトリの `Apps/MaycastStudio/` を選択
   - 「Source Control: Create Git repository on my Mac」の **チェックを外す** (既存リポジトリの配下に作るため)
5. Create を押すと、`Apps/MaycastStudio/Maycast Studio.xcodeproj` と `Apps/MaycastStudio/Maycast Studio/` (デフォルト Swift ファイル入り) が生成される

### 2. デプロイメントターゲットを macOS 26 に設定

1. Project Navigator で `Maycast Studio` プロジェクトを選択 → TARGETS の `Maycast Studio` を選択
2. `General` タブ → `Minimum Deployments` → **macOS** を `26.0` に変更

### 3. Swift Package をローカル依存として追加

1. プロジェクトを選択した状態で `File → Add Package Dependencies…`
2. ダイアログ右下の **Add Local…** をクリック
3. リポジトリルート (`maycast-studio/`) を選択 → `Add Package`
4. ライブラリ選択: `MaycastCore` と `MaycastIPC` の両方にチェック → `Maycast Studio` ターゲットに追加

> `MaycastIPC` は GUI 骨格時点では未使用だが、後続の機能フェーズで `ServiceClient` を使うため最初から繋いでおく。

### 4. デフォルト生成された Swift ファイルを削除

Xcode が作った `Maycast Studio/` フォルダ内の以下を削除:
- `Maycast_StudioApp.swift`
- `ContentView.swift`
- `Assets.xcassets` の中身は残す (アイコン等で後で使う)

削除確認: `Move to Trash` を選択。

### 5. 骨格 Swift ファイルをプロジェクトに追加

1. Project Navigator で `Maycast Studio` グループ (ソースの入っているフォルダ) を右クリック → `Add Files to "Maycast Studio"…`
2. `Apps/MaycastStudio/Sources/` 配下の以下 3 ファイルを **すべて選択**:
   - `MaycastStudioApp.swift`
   - `EpisodeStore.swift`
   - `ContentView.swift`
3. オプション (Xcode 16 以降):
   - **Action**: `Move files to destination` を選択 (= Xcode プロジェクトのソースフォルダに移動)
   - **Add to targets**: `Maycast Studio` をチェック
4. Add を押す
5. 完了後、空になった `Apps/MaycastStudio/Sources/` フォルダは Finder で削除する

> 旧 Xcode の `Copy items if needed` チェックボックスは Xcode 16 で廃止された。`Move` を使い、ソースを Xcode 管理下に置くのが現状のベストプラクティス。

### 6. App Sandbox の調整 (User-Selected Files の読み取り)

`.maycast` ディレクトリを `NSOpenPanel` で開けるようにする。

1. ターゲット → `Signing & Capabilities` タブ
2. デフォルトで `App Sandbox` が有効になっているはず
3. `App Sandbox` の中で:
   - **File Access → User Selected Files**: `Read/Write`

### 7. ビルドして実行

`Cmd + R` で起動。以下が確認できれば OK:

1. アプリが立ち上がり、`No Episode open` の画面が表示される
2. メニューバー → `Episode → Open…` (または `Cmd + O`)
3. CLI で作ったテスト用 `.maycast` を選択
4. tracks 一覧と current 世代が表示される

テスト用エピソードを作るには:
```sh
cd /tmp
/path/to/maycast-studio/.build/debug/maycast init demo.maycast
/path/to/maycast-studio/.build/debug/maycast import -project demo.maycast --as host /System/Library/Sounds/Glass.aiff
```

`/tmp/demo.maycast` を Open すれば 1 トラック (host) が表示される。

## 機能フェーズに進むとき

GUI から各機能を呼ぶ準備として、以下を追加することになる (今は不要):

1. ターゲットの `Build Phases → Copy Files Phase` を追加し、4 つの XPC サービス executable を `Contents/XPCServices/` にコピー
2. `ServiceClient` の利用箇所で `Bundle.main.bundleURL/Contents/XPCServices/<name>.xpc/Contents/MacOS/<name>` を解決
3. または、`NSXPCConnection(serviceName:)` に切り替え

それまでは GUI は読み取り専用、編集は CLI から行う運用で十分。

## トラブルシューティング

| 現象 | 対処 |
| -- | -- |
| `Cannot find type 'EpisodeBundle' in scope` | `Add Package Dependencies` が完了し `MaycastCore` がターゲットに追加されているか確認 |
| アプリ起動時に Open Panel が出ない | `App Sandbox → User Selected Files = Read/Write` を確認 |
| `swift build` で警告が出る | `swift-tools-version` が 6.0 になっているか確認 |
