---
name: release
description: Maycast Studio のリリース手順。バージョン更新 → Release コミット + タグ → make release で .dmg / CLI tarball を作成 → GitHub Release に添付して公開する。ユーザーが「リリースして」「vX.Y.Z を出して」「リリースの手順は？」と言ったときに使う。
---

# Maycast Studio リリース手順

CI はない。すべて手元 (macOS + Xcode 26+) で行う。バージョンの唯一の正は
`Sources/MaycastCLI/MaycastVersion.swift` の `MaycastVersion.current` で、
CLI の `--version`、.app の `CFBundleShortVersionString` / `CFBundleVersion`、
成果物のファイル名すべてがここから決まる。

引数でバージョンが指定されなければ、直近のタグ (`git tag --sort=-v:refname | head -1`)
と変更内容からユーザーに提案して確認する。目安: バグ修正のみ → patch、
機能追加や UI 変更 → minor、互換性を壊す変更 → major (0.x の間は minor)。

## 0. 事前チェック

```bash
git status --short          # 空であること (未コミットの変更を混ぜない)
git branch --show-current   # main であること
git tag --sort=-v:refname | head -3
swift test                  # ユニット + E2E。失敗したらリリースしない
```

GUI に影響する変更が含まれる場合は、実データで該当画面を一度操作して
確認してからリリースする (CLAUDE.md の完了条件 4)。

## 1. バージョンを上げてコミット + タグ

`MaycastVersion.swift` の `current` を書き換え、**その 1 ファイルだけ** を
`Release vX.Y.Z` というメッセージでコミットし、同名のタグを打つ。

```bash
sed -i '' 's/static let current = ".*"/static let current = "X.Y.Z"/' Sources/MaycastCLI/MaycastVersion.swift
git commit -am "Release vX.Y.Z"
git tag vX.Y.Z
```

## 2. 成果物を作る

```bash
make release
```

- `dist/Maycast-Studio-X.Y.Z.dmg` — Release 構成の .app を hdiutil で DMG 化
- `dist/maycast-X.Y.Z-macos-<arch>.tar.gz` — CLI バイナリ

署名・公証はしていない (README にその旨と初回起動の回避方法を記載済み)。
`make app` / `make cli` / `make release-app` / `make release-cli` で片方だけも作れる。

できた成果物を確認する:

```bash
ls -la dist/
.build/release/maycast --version                                   # X.Y.Z と出ること
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  "build/Build/Products/Release/Maycast Studio.app/Contents/Info.plist"
```

## 3. push と GitHub Release

push と Release 作成は外部に公開される操作なので、実行前にユーザーへ確認する
(ユーザーが「vX.Y.Z で進めて」と明示していれば、その指示で足りる)。

```bash
git push origin main
git push origin vX.Y.Z
gh release create vX.Y.Z \
  "dist/Maycast-Studio-X.Y.Z.dmg" \
  "dist/maycast-X.Y.Z-macos-$(uname -m).tar.gz" \
  --title "vX.Y.Z" --notes "<変更点の箇条書き>"
```

過去のリリースは本文なし・アセット 2 つだけだが、以後は前回タグからの
`git log --oneline vPREV..vX.Y.Z` を元に短い変更点を `--notes` に入れる。

最後に `gh release view vX.Y.Z` でアセット 2 つが付いていることを確認し、
URL をユーザーに伝える。

## やり直し

- タグを打ったあとに直したくなった: `git tag -d vX.Y.Z` → 修正をコミット → 再度タグ
- push 済み / Release 作成済みの場合は削除せず、次の patch バージョンを出す
