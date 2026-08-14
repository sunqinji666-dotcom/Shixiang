# 拾響 Shixiang

> 散らばった音を、本来あるべき場所へ。

[简体中文](../README.md) · [English](README.en.md) · [日本語](README.ja.md)

![拾響のローカルサウンドワークスペース](../Marketing/ecommerce/01-hero.jpg)

拾響は、映像制作者向けのネイティブ macOS 効果音管理アプリです。内蔵・外付けドライブに散在する音素材を、検索、試聴、分析、整理できるローカルライブラリにまとめ、Final Cut Pro へ直接ドラッグできます。

[公式サイト](https://shixiang.jack-sun.com) · [完全ガイド](https://shixiang.jack-sun.com/guide/) · [最新版をダウンロード](https://github.com/sunqinji666-dotcom/Shixiang/releases/latest) · [リリースノート](../RELEASE_NOTES.md)

## 現在のリリース

| 項目 | 要件 |
|---|---|
| バージョン | 1.0.0 · Build 111 |
| プロセッサ | Apple Silicon（arm64） |
| 基本機能 | macOS 14.0 以降 |
| ローカル AI 自然言語検索 | macOS 26.2 以降 |
| ネットワーク | インデックス、検索、試聴、分析は標準でローカル処理 |
| 外部環境 | 配布 App に AI ランタイムとモデルを同梱。Python、Homebrew、Xcode は不要 |

macOS 26.2 未満でも、対応 OS であればライブラリ、通常検索、試聴、お気に入り、サウンドワークベンチ、編集ソフトへのドラッグを利用できます。使えないのはローカル AI 自然言語検索のみです。

## 主な機能

- WAV、AIFF/AIF、MP3、M4A、CAF、FLAC のフォルダを、元の名前と階層を保ったまま読み込み。
- SQLite FTS5、中国語文字インデックス、フォルダ・形式・長さ・お気に入り・スマートコレクションによる複合検索。
- ショット、感情、材質、距離、強さ、長さを自然言語で伝え、端末内だけで AI 検索。
- 波形、A/B 範囲、キュー、類似音、クイック比較、非破壊の中国語別名で高速試聴。
- サウンドワークベンチで BPM、概算ラウドネス、キー、軽量な音響指紋を分析。
- 元音源や A/B 範囲を Final Cut Pro へ直接ドラッグし、必要に応じて受け渡し診断を実行。
- 増分スキャン、遅延展開ツリー、ウィンドウ化リスト、キャッシュ、バックグラウンド分析で数万件規模に対応。
- ローカル優先。音声、ファイル名、フォルダ、タグ、検索内容、音響指紋をアップロードしません。

## 製品画面

### 制作者の言葉で音を探す

![拾響のローカル AI 検索](../Marketing/ecommerce/03-ai-search.jpg)

### 一つの音も、制作素材として丁寧に分析

![拾響サウンドワークベンチ](../Marketing/ecommerce/09-workbench.jpg)

### 素材は自分のデバイスに残す

![拾響のローカル優先設計](../Marketing/ecommerce/11-private.jpg)

これらのプロモーション画像内のアプリ画面は、実際に動作する拾響ビルドを使用しています。周囲のシーン、光、タイポグラフィは広告表現であり、OS の UI ではありません。

## インストール

1. [GitHub Releases](https://github.com/sunqinji666-dotcom/Shixiang/releases/latest) または [公式サイト](https://shixiang.jack-sun.com/#download) から DMG をダウンロードします。
2. DMG を開き、`拾响.app` を `Applications` へドラッグします。
3. 「アプリケーション」フォルダから起動します。

Build 111 は安定したローカル署名を使用していますが、Apple Developer ID による公証は未実施です。初回起動が macOS に止められた場合は、Control キーを押しながら App をクリックして「開く」を選ぶか、「システム設定 → プライバシーとセキュリティ → このまま開く」を使用してください。macOS の安全機能は無効にしないでください。

## 効果音ライブラリ

アプリ本体に音声ファイルは含まれません。空のライブラリ向けガイドから、作者が長年収集・購入・整理した 5 万点以上の別配布ライブラリを公式サイトで受け取るか、自分のフォルダを読み込めます。

著作権は各作者・配布元に帰属し、利用・再配布条件は素材ごとに異なります。詳細は追加パック内の出典・ライセンス説明をご確認ください。このパックは本リポジトリに含まれません。

## ソースからビルド

Apple Silicon Mac、macOS 14+、Swift 6.1 ツールチェーンが必要です。

```bash
git clone https://github.com/sunqinji666-dotcom/Shixiang.git
cd Shixiang
swift test
./scripts/build-app.sh
```

成果物は `dist/拾响.app` です。DMG の作成：

```bash
./scripts/package-dmg.sh
```

配布用 App には、リポジトリ外で管理される AI ランタイムとモデルも必要です。ビルドスクリプトはローカル依存関係を検証しますが、モデルやユーザー音声を Git に追加しません。

## リポジトリ構成

```text
Sources/Shixiang/   SwiftUI・AppKit・AVFoundation のアプリソース
Tests/              検索・音声・ライブラリ・互換性・操作の回帰テスト
Support/            Info.plist、DMG 補助、公開製品リソース
scripts/            ビルド・パッケージ・署名・リリース検査
Docs/               インストール・プライバシー・配布・技術文書
Website/            公式サイトと完全図解ガイド
Marketing/          README とリリース用に選定したビジュアル
```

## データとプライバシー

標準データベースは `~/Library/Application Support/Shixiang/library.sqlite3`、波形キャッシュは隣接する `Waveforms` に保存されます。拾響は元の音声を移動、改名、コピー、アップロードしません。詳しくは [プライバシー説明](PRIVACY.md) を参照してください。

## Build 111 の検証

- 自動テスト 144 件（143 件合格、環境条件によるスキップ 1 件）、失敗 0 件。
- arm64 と macOS 14.0 最低バージョンを確認。
- App の deep strict 署名検証と DMG ファイルシステム検証に合格。
- 同梱 AI ランタイム、Qwen モデル、公式サイトリンク、支援 QR リソースを確認。

DMG SHA-256：

```text
17818ce885ea5fe3e52e7c99340c01a5a0f21405e5b79e70c2d9276f7551ccbb
```

## ライセンスの状態

本リポジトリには、現時点で正式なオープンソースライセンスがありません。ソースは公開閲覧できますが、利用、変更、再配布の権利は今後の `LICENSE` ファイルで定義されます。追加効果音ライブラリは別物であり、将来のコードライセンスの対象にもなりません。

## 作者とサポート

[Jacksun](https://www.jack-sun.com) が制作しています。拾響は無料で利用でき、アプリ内の支援は完全に任意で、機能差はありません。

- 公式サイト：[shixiang.jack-sun.com](https://shixiang.jack-sun.com)
- 使用ガイド：[shixiang.jack-sun.com/guide](https://shixiang.jack-sun.com/guide/)
- 不具合・要望：[GitHub Issues](https://github.com/sunqinji666-dotcom/Shixiang/issues)
