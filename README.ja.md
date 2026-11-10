# WaifuX · Wallhaven

[jipika/WaifuX](https://github.com/jipika/WaifuX)を基に、Wallhavenの静止画像だけに対応するmacOSアプリです。[Español](README.md) · [English](README.en.md)

`feat/wallhaven-static-only`は開発中です。この構成の安定版はまだ公開されていません。コンパイルと自動テストだけでは、画面表示や実機の複数ディスプレイ動作を確認できません。

Wallhavenの検索・絞り込み、アニメ画像カテゴリ、原本のダウンロード、お気に入り、フォルダとロック、キャンセル・再試行、画面別または全体の壁紙、ランダム・順番の切り替え、静止画像の切り抜き、縦長画像のぼかし余白、ローカル・WebDAV同期を保持します。シリーズの再生やダウンロード、他の壁紙プロバイダには対応しません。旧版の文書、個人のメディア、旧クラウドオブジェクトは保持します。

macOS 14.4以降が必要です。ローカル検証はXcode 27.3とXcodeGenで行います。`xcodegen generate`でプロジェクトを生成し、`WaifuX`スキームをビルドします。ターゲットはアプリと`WaifuXHelper`の2つです。正確なビルド・検証・パッケージ作成コマンドは[スペイン語README](README.md)を参照してください。

Helperの自動テストは一時フォルダと分離した設定を使い、デスクトップ描画を無効にします。インストール済みサービスの登録や個人の壁紙は変更しません。実際のAPIキー、操作画面、Spaces、スリープ、画面再接続は別途確認が必要です。

パッケージスクリプトはローカル用のアドホック署名付きDebug ZIP・DMGを作成し、インストールや起動は行いません。ReleaseのHelperはチームIDのないアドホック署名を拒否します。一般配布にはDeveloper ID署名、Helperのプロビジョニング、公証、フォーク独自のSparkleキーが必要です。自動更新は無効で、更新フィードは最初は空です。

[貢献ガイド](CONTRIBUTING.md)と[翻訳ガイド](LOCALIZATION.md)を確認してください。この変更のPRは`jesusjodar/WaifuX`に送ります。原作者の表記と[ライセンス](LICENSE)を保持しています。コードのライセンスはWallhaven画像の権利を付与しません。
