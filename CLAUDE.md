# Maycast Studio — 開発ルール

このリポジトリで作業する際に Claude (および開発者) が従うルールをまとめる。

## プロジェクト概要

Podcast 向け macOS デスクトップアプリ。Swift + SwiftUI 製、OSS。
コンセプトは「最低限の編集を手軽に」。

主要ドキュメント:
- [`docs/concept.md`](docs/concept.md) — プロダクトコンセプトと機能の全体像
- [`docs/architecture.md`](docs/architecture.md) — 基盤アーキテクチャ (Show/Episode モデル、File Versioning、XPC、CLI)
- [`docs/diagrams/episode-state.puml`](docs/diagrams/episode-state.puml) — Episode の状態遷移

## 開発の順序ルール

機能追加・変更を行う際は **必ず以下の順序で実装する**。

1. **関連する E2E テストを先に作成する**
   - 期待する振る舞い (= 受け入れ条件) をテストとして書く
   - GUI 機能でも XPC サービス機能でも、原則 CLI 経由の E2E テストを書く (CLI を経由するとプロセス分離後の挙動を含めて検証できる)
   - この時点ではテストは **失敗する状態** で良い (機能未実装なので)

2. **実装を行う**
   - 1 で書いた E2E が通ることをゴールとして実装する
   - 実装中に E2E のシナリオを直す必要が出た場合は、E2E 側を意図して更新する (= 仕様変更を明示)

3. **すべての E2E が通ることを確認してから完了とする**

### 理由

- Maycast Studio は **CLI 経由で AI エージェント / E2E テストから操作されることを前提に設計** されている (`docs/architecture.md` §3-4 参照)
- 仕様を E2E で先に固定することで、XPC / CLI / GUI のいずれを変更しても挙動の一貫性が保たれる
- 機能を後から E2E で覆おうとすると、CLI I/F が「実装の都合」に引きずられて不自然になりがち。**先に書くことで CLI I/F が利用者視点になる**

### 例外

- ドキュメントのみの変更
- 既存テストのリファクタリングのみ
- ビルド設定・依存関係の更新のみ

上記の場合は E2E 作成をスキップしてよい。

## 設計上の不変条件 (壊さないこと)

`docs/architecture.md` の以下は **基盤の前提** であり、安易に変更しない。

- 元音源 (`sources/`) は不変。各操作は `intermediate/<track>/NNN_<op>.*` に新ファイルを生成する
- 各操作は `episode.json` の `current` / `history` を更新する
- 各機能は XPC サービスとしてプロセス分離され、GUI と CLI から同じ I/F で呼ばれる
- CLI のプロジェクト/ショー指定は **常に明示** (cwd 自動検出はしない)
- Show のアセットは Episode 作成時に **スナップショットコピー**
