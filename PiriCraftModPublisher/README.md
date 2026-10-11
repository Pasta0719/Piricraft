# PiriCraft MOD Publisher v4.2

Windows用の単体EXE。GitHubの正規MOD一覧から更新対象を選択し、PC内の新しいJARを指定すると、GitHub Actionsが更新をビルド・検証・公開します。共同開発者のPCにランチャーソース・Java・Gradle・.NET SDKは不要です。

## 共同開発者をユーザー名なしで利用可能にする

GitHubは匿名の無制限Write権限を提供していません。そのため、**Pasta0719/Piricraftリポジトリだけに有効な共有公開キー**（fine-grained personal access token）を使う方式です。ユーザーをGitHubのCollaboratorsとして招待する必要はありません。

所有者が最初に一度だけ設定：
1. [GitHub Fine-grained personal access tokenを作成](https://github.com/settings/personal-access-tokens/new)
2. **Resource owner: Pasta0719 / Repository access: Only select repositories → Piricraft**
3. **Repository permissions**: Contents → Read and write, Actions → Read and write（Metadataは自動的にRead）
4. 最短の必要な有効期限を設定し、トークンを発行する。**トークンはGitHub画面で一度しか表示されません**
5. 信頼できる共同開発者に、安全な手段でトークンを渡す。ChatGPTや公開Issue、公開チャットやソースコードには貼り付けない

共同開発者の操作：
1. [PiriCraftModPublisher.exe](https://github.com/Pasta0719/Piricraft/releases/download/mod-publisher-v4.2.0/PiriCraftModPublisher.exe) をダウンロードし、起動
2. 「共有公開キー」に受け取ったキーを貼る（毎回入力。**ファイルには保存しません**）
3. 「既存MODを更新」なら更新元をGitHubの正規MOD一覧から選択。「新規追加」ならそのまま進む
4. PC内の新しい`.jar`を指定し、「更新する」を押す
5. GitHubにJARをアップロードし、クラウド上でCheckプラグイン・ランチャーを作成・Windowsで起動検証・GitHub公開・自動更新マニフェストを切り替える

**既存の自分のGitHubアカウントでログインする方式も引き続き利用可能です。** 共有キーの入力がない場合は個人のGitHub認証を使用します。

## 権限・安全性

- EXEにもGitHubリポジトリにも共有キーを埋め込みません
- キーはGitHub CLIに渡す際だけプロセス環境変数`GH_TOKEN`として使用します
- キーは共有した相手が**リポジトリに書き込む権限そのもの**です。アプリ外から操作することもできるので、**信頼できる人にだけ渡してください**
- 漏洩または共同開発終了時はGitHub設定で当該トークンを失効させて新しく発行します
- ユーザー名もキーも与えず、インターネット上の誰でも本番のクライアントMODを更新できる状態にはしません。そんな状態は第三者が悪意あるJavaコードを配布できるため危険です

## 自動処理の詳細と制限

- 同梱MODの差し替え／追加、公式MODマニフェストの更新、SHA-256登録
- CheckサーバーJARの許可ハッシュ生成
- ランチャー単体EXE生成、Windows起動検証
- GitHub Releases公開とランチャーの自動更新マニフェストの更新
- **サーバーへのCheckプラグインの直接アップロード・サーバー再起動は含みません**。配布済みプラグインの手動配置が必要です
- 他のユーザーに悪意あるMODを自動配布しないよう、公開するJARは事前に作業者が出所を確認してください

技術検証：[Publisher EXE acceptance](../../actions/workflows/publisher-exe-acceptance.yml) / [MOD cloud build](../../actions/workflows/publish-mod-from-app.yml)

トラブルシューティング：画面下部のログ、`%LOCALAPPDATA%\PiriCraftModPublisher\publisher.log`を確認してください。
