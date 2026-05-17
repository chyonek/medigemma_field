# Landing Page Deployment Guide

このフォルダ (`submission/docs/`) を GitHub Pages で公開する手順。
最終的に `https://chyonek.github.io/medigemma_field/` で動画 + APK ダウンロードリンク付きランディングページが表示される。

---

## 前提

- GitHub repo `chyonek/medigemma_field` が **public** になっている (Pages は public でないと使えない)
- このフォルダ (`submission/docs/`) が **repo の `docs/` 配下**にコピーされている
  - もし repo がアプリ本体 (`medigemma_field`) と別構造なら、`docs/` をルートに置く

---

## Step 1: アセットを repo の docs/ に移植

オプション A (アプリ本体 repo に統合):
```powershell
# medigemma_field repo のルートに docs/ を作って index.html + 画像を入れる
$src = "C:\Users\chyon\Desktop\MediGemma\submission\docs"
$dst = "C:\Users\chyon\Desktop\medigemma_field\docs"
if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst | Out-Null }
Copy-Item "$src\*" $dst -Recurse -Force
```

オプション B (独立 repo として deploy):
```powershell
# 新しい repo (e.g. medigemma-landing) を作って submission/docs/ の中身を上げる
```

→ オプション A 推奨 (1 repo で完結・URL もアプリ名と一致)

---

## Step 2: プレースホルダ置換

`index.html` を開いて以下 2 つを実際の URL に置換:

| プレースホルダ | 置換先 |
|---|---|
| `[YOUTUBE_VIDEO_ID]` | YouTube 動画 ID (例: `dQw4w9WgXcQ`) — Shot 1-7 編集 + YouTube アップ後 |
| `[APK_RELEASE_URL]` | `https://github.com/chyonek/medigemma_field/releases/download/v1.0/app-release.apk` |

ワンライナー:
```powershell
$file = "C:\Users\chyon\Desktop\medigemma_field\docs\index.html"
(Get-Content $file) `
  -replace '\[YOUTUBE_VIDEO_ID\]', 'ACTUAL_YOUTUBE_ID' `
  -replace '\[APK_RELEASE_URL\]', 'https://github.com/chyonek/medigemma_field/releases/download/v1.0/app-release.apk' `
  | Set-Content $file -Encoding UTF8
```

---

## Step 3: GitHub Pages 有効化

1. **GitHub repo** → **Settings** → サイドバー左 **Pages**
2. **Source**: "Deploy from a branch"
3. **Branch**: `main` (or `master`) — フォルダは `/docs`
4. **Save** 押す
5. 数分待つ → 上部に「Your site is live at https://chyonek.github.io/medigemma_field/」が出る

---

## Step 4: 確認

ブラウザで URL を開いて以下確認:
- [ ] Hero icon (cupped hand) が表示される
- [ ] YouTube 埋め込みが再生できる
- [ ] APK ダウンロードリンクが正しい (404 でない)
- [ ] GitHub 'View source' リンクが正しい
- [ ] モバイルで開いても layout 崩れない
- [ ] ダークモード OS でも視認性 OK

---

## Step 5: Kaggle Writeup の Live Demo URL に登録

Writeup 提出時の Live Demo URL 欄に:
```
https://chyonek.github.io/medigemma_field/
```
を貼る。

---

## トラブルシューティング

| 症状 | 対応 |
|---|---|
| 「404 Not Found」が出る | Pages デプロイは数分かかる。10 分待つ |
| 画像が出ない | パスを確認。`docs/` 配下に `app_icon.png`, `landing_hero.png`, `og_image.png` 全てあるか |
| YouTube 動画が embed 失敗 | YouTube 動画が "Unlisted" 以上 (Private は不可)。動画 ID 末尾の `&` 等が混入してないか |
| APK ダウンロードが 404 | Release タグ + Assets に APK 上げたか確認 |
