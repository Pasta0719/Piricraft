# PiriCraft MOD Publisher v4.0

**Windows の単体 EXE から公式 MOD 一覧の更新・追加を公開できます。** ランチャーと Check サーバーのローカルソース、Java、Gradle、.NET SDK は共同開発者側に不要です。

## 初回セットアップ

1. [v4.0のPiriCraftModPublisher.exe](https://github.com/Pasta0719/Piricraft/releases/download/mod-publisher-v4.0.0/PiriCraftModPublisher.exe) をダウンロードして起動
2. GitHub にログイン。GitHub CLI がない場合、EXE が GitHub 公式配布から導入します
3. リポジトリ所有者は共同開発者の GitHub アカウントを **Pasta0719/Piricraft の Write 権限で招待**してください（[Manage access](https://github.com/Pasta0719/Piricraft/settings/access)）
4. 「既存MODを更新」なら **GitHub の正規MOD一覧から更新元を選択**、次にPCの新しい `.jar` を選択。「新しいMODを追加」ならPCの `.jar` を選択するだけ
5. 「更新する」を押すと、JARをGitHubの非公開下書きReleaseにアップロードし、GitHub Actionsでランチャー/Checkを生成・Windows起動検証・正式Release公開・自動更新マニフェスト更新まで実行します

GitHubの所有者パスワードやトークンをEXEに埋め込んだり、共同開発者と共有したりしません。各作業者は自分の GitHub アカウントでログインします。Write 権限はこのリポジトリだけに付与できます。

## 公開と検証

公開処理: [Publish MOD change from standalone publisher](../../actions/workflows/publish-mod-from-app.yml)

検証: [Test staged JAR and cloud publisher](../../actions/workflows/test-publisher-upload.yml)

1つの更新で自動的に次の新Releaseを作成します。

- `PiriCraft.exe`（管理対象の Fabric JAR を内蔵）
- `PiricraftCheckServer-1.0.0.jar`（公式MODのSHA-256の許可一覧を反映）
- 新しく選択された Fabric JAR
- `update-manifest.json`（EXEのURL・ハッシュ・サイズ、公式MOD構成を更新）

**Windows実起動が失敗した場合は自動更新に切り替えません。** GH Actionsのテストは新規追加と2回連続更新まで検証済みです。

MinecraftのレンタルサーバーへのCheckプラグイン設置・差し替えは管理者が行います。GitHub公開とランチャー自動更新は自動化されていますが、第三者のサーバーへの自動設置は実装していません。

## 問題が起きたとき

EXE内の進捗ログと `%LOCALAPPDATA%\PiriCraftModPublisher\publisher.log` を確認してください。実際の公開処理のGitHub Actions URLも画面に表示されます。

バージョン更新処理はGitHubで行うため、共同開発者のPCでCodexやChatGPTを動かす必要はありません。
