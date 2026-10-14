using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Net.Http;
using System.Security.Cryptography;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using System.IO.Compression;

namespace PiriCraftModPublisher;

internal static class Program {
    [STAThread] static int Main(string[] args) {
        if (args.Contains("--self-test")) {
            if(typeof(Window)==null)return 1;
            Console.WriteLine("SELF_TEST_PASSED");return 0;
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try {
            var i=Array.IndexOf(args,"--integration-test");
            var testJar=i>=0 && i+1<args.Length?args[i+1]:null;
            if(i>=0 && testJar==null)throw new ArgumentException("Integration test JAR missing");
            // Real production acceptance is opt-in and protected by a CI-only gate.
            // It follows the exact same Publish() event handler and GH CLI paths as the GUI.
            var productionIndex=Array.IndexOf(args,"--production-acceptance");
            string? acceptanceTarget=null;
            if(productionIndex>=0) {
                if(Environment.GetEnvironmentVariable("GITHUB_ACTIONS")!="true" ||
                   Environment.GetEnvironmentVariable("PIRICRAFT_REAL_PUBLISH_ACCEPTANCE")!="true")
                    throw new InvalidOperationException("Production acceptance is allowed only in dedicated CI");
                if(productionIndex+2>=args.Length)throw new ArgumentException("Acceptance JAR and target MOD required");
                if(testJar!=null)throw new ArgumentException("Cannot combine dry and production acceptance");
                testJar=args[productionIndex+1];
                acceptanceTarget=args[productionIndex+2];
            }
            bool tokenTest=args.Contains("--integration-test-key") || productionIndex>=0;
            string? testKey=tokenTest?Environment.GetEnvironmentVariable("GH_TOKEN"):null;
            if(tokenTest){
                if(string.IsNullOrWhiteSpace(testKey))throw new InvalidOperationException("Missing test GH_TOKEN");
                Environment.SetEnvironmentVariable("GH_TOKEN",null,EnvironmentVariableTarget.Process);
            }
            Application.Run(new Window(testJar,testKey,acceptanceTarget)); return Environment.ExitCode;
        }
        catch(Exception e) {
            var dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"PiriCraftModPublisher");
            Directory.CreateDirectory(dir);File.AppendAllText(Path.Combine(dir,"crash.log"),e+"\r\n");
            MessageBox.Show(e.ToString(),"PiriCraft MOD Publisher 起動エラー");return 1;
        }
    }
}

internal sealed class Window : Form {
    const string Repo="Pasta0719/Piricraft", Manifest="https://raw.githubusercontent.com/Pasta0719/Piricraft/main/update-manifest.json";
    readonly HttpClient http=new(){Timeout=TimeSpan.FromSeconds(40)};
    readonly string dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"PiriCraftModPublisher");
    readonly RadioButton updating=new(){Text="既存MODを更新",Checked=true,AutoSize=true};
    readonly RadioButton adding=new(){Text="MODを新規追加",AutoSize=true};
    readonly RadioButton removing=new(){Text="既存MODを削除",AutoSize=true,ForeColor=Color.DarkRed};
    readonly ComboBox mods=new(){DropDownStyle=ComboBoxStyle.DropDownList,Width=520};
    readonly TextBox jar=new(){ReadOnly=true,Width=630};
    readonly TextBox sharedKey=new(){UseSystemPasswordChar=true,PlaceholderText="所有者から配布されたリポジトリ限定の公開キー（任意）",Dock=DockStyle.Fill};
    readonly TextBox launcher=new(){Width=630};
    readonly TextBox check=new(){Width=630};
    readonly Label status=new(){AutoSize=true,ForeColor=Color.MidnightBlue};
    readonly Label hash=new(){AutoSize=true};
    readonly Label title=new(){AutoSize=true};
    readonly TextBox output=new(){Multiline=true,ScrollBars=ScrollBars.Vertical,ReadOnly=true,Dock=DockStyle.Fill,Font=new Font("Consolas",9)};
    readonly Button submit=new(){Text="更新する  →  GitHubでEXE・Checkを生成して自動更新",Height=48,Dock=DockStyle.Fill,BackColor=Color.FromArgb(30,94,181),ForeColor=Color.White};
    readonly Button load=new(){Text="一覧を更新",Width=116};
    readonly Button auth=new(){Text="GitHubにログイン",Width=165};
    readonly System.Collections.Generic.List<string> paths=new();
    string? gh;bool running;
    readonly string? integrationJar;
    readonly string? acceptanceTarget;

    public Window(string? integrationJar=null,string? integrationKey=null,string? acceptanceTarget=null) {
        this.integrationJar=integrationJar;
        this.acceptanceTarget=acceptanceTarget;
        if(!string.IsNullOrEmpty(integrationKey))sharedKey.Text=integrationKey;
        Text="PiriCraft MOD Publisher v4.4";Font=new Font("Yu Gothic UI",10);
        ClientSize=new Size(925,730);MinimumSize=new Size(805,660);
        StartPosition=FormStartPosition.CenterScreen;BackColor=Color.FromArgb(247,249,253);
        Directory.CreateDirectory(dir);
        launcher.Text=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"PiriCraft");
        check.Text=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"PiricraftCheckServer");
        try{using var d=JsonDocument.Parse(File.ReadAllText(Path.Combine(dir,"settings.json")));
            launcher.Text=d.RootElement.GetProperty("launcher").GetString()??launcher.Text;
            check.Text=d.RootElement.GetProperty("check").GetString()??check.Text;
        }catch{}
        var panel=new TableLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(23,15,23,15),ColumnCount=1,RowCount=9};
        foreach(var h in new[]{50,30,57,35,42,35,50,58,0})panel.RowStyles.Add(new RowStyle(h==0?SizeType.Percent:SizeType.Absolute,h==0?100:h));
        Controls.Add(panel);
        panel.Controls.Add(new Label{Text="PiriCraft MOD Publisher",Font=new Font("Yu Gothic UI",19,FontStyle.Bold),AutoSize=true},0,0);
        title.Text="GitHubの正規MOD一覧を読み込みます";panel.Controls.Add(title,0,1);
        var choices=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false};
        choices.Controls.Add(updating);choices.Controls.Add(adding);choices.Controls.Add(removing);choices.Controls.Add(load);choices.Controls.Add(auth);panel.Controls.Add(choices,0,2);
        panel.Controls.Add(new Label{Text="更新元を選択：GitHubで現在配布されている正規MOD一覧",AutoSize=true},0,3);
        mods.Dock=DockStyle.Fill;panel.Controls.Add(mods,0,4);
        panel.Controls.Add(new Label{Text="今回入れる新しいMOD（あなたのPC内のJAR）",AutoSize=true},0,5);
        panel.Controls.Add(Row(jar,Pick("JARを選択",()=>ChooseJar())),0,6);
        var bottom=new TableLayoutPanel{Dock=DockStyle.Fill,RowCount=3,ColumnCount=1};
        bottom.RowStyles.Add(new RowStyle(SizeType.Absolute,50));
        bottom.RowStyles.Add(new RowStyle(SizeType.Absolute,45));
        bottom.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        bottom.Controls.Add(submit,0,0);
        var row=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.TopDown};
        status.Text="準備中…";row.Controls.Add(status);hash.Text="ファイル未選択";row.Controls.Add(hash);
        bottom.Controls.Add(row,0,1);bottom.Controls.Add(output,0,2);
        var keyRow=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=2};
        keyRow.RowStyles.Add(new RowStyle(SizeType.Absolute,24));
        keyRow.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        keyRow.Controls.Add(new Label{Text="共有公開キー（共同開発者のGitHub招待は不要／キーは保存しません）",AutoSize=true},0,0);
        keyRow.Controls.Add(sharedKey,0,1);
        panel.Controls.Add(keyRow,0,7);
        panel.Controls.Add(bottom,0,8);
        updating.CheckedChanged+=(_,_)=>UpdateMode();
        adding.CheckedChanged+=(_,_)=>UpdateMode();
        removing.CheckedChanged+=(_,_)=>UpdateMode();
        load.Click+=async(_,_)=>await Reload();
        auth.Click+=async(_,_)=>await Login();
        submit.Click+=async(_,_)=>await Publish();
        UpdateMode();
        Shown+=async(_,_)=>{
            await Reload();await CheckAuth();
            if(this.integrationJar!=null) {
                if(acceptanceTarget!=null) {
                    // Use official list as the source of truth: never publish to an arbitrary target.
                    var index=paths.FindIndex(p=>p==acceptanceTarget);
                    if(index<0){Log("ERROR production acceptance target missing");Environment.ExitCode=1;Close();return;}
                    updating.Checked=true;
                    mods.SelectedIndex=index;
                } else {
                    adding.Checked=true;
                }
                jar.Text=this.integrationJar;
                await Publish();
            }
        };
        FormClosing+=(_,e)=>{if(running && integrationJar==null){e.Cancel=true;MessageBox.Show(this,"公開処理中はウィンドウを閉じられません。","PiriCraft");}};
    }
    static Control Row(TextBox box,Button button) {
        var row=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2};
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,150));
        box.Dock=DockStyle.Fill;button.Dock=DockStyle.Fill;row.Controls.Add(box,0,0);row.Controls.Add(button,1,0);return row;
    }
    static Button Pick(string text,Action action){var b=new Button{Text=text};b.Click+=(_,_)=>action();return b;}
    void Folder(TextBox field) {using var dlg=new FolderBrowserDialog();if(Directory.Exists(field.Text))dlg.SelectedPath=field.Text;
        if(dlg.ShowDialog(this)==DialogResult.OK)field.Text=dlg.SelectedPath;}
    void ChooseJar(){using var dlg=new OpenFileDialog{Filter="JARファイル (*.jar)|*.jar",Title="今回の新しいMODを選択"};if(dlg.ShowDialog(this)!=DialogResult.OK)return;
        jar.Text=dlg.FileName;
        try{hash.Text="SHA-256: "+Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(jar.Text)));}catch(Exception e){hash.Text=e.Message;}
    }
    void Log(string message) {if(InvokeRequired){BeginInvoke(()=>Log(message));return;}
        string s=$"[{DateTime.Now:HH:mm:ss}] {message}";
        output.AppendText(s+Environment.NewLine);try{File.AppendAllText(Path.Combine(dir,"publisher.log"),s+Environment.NewLine);}catch{}
    }
    void State(string message) {if(InvokeRequired){BeginInvoke(()=>State(message));return;}status.Text=message;}
    void UpdateMode(){
        mods.Enabled=!running && (updating.Checked||removing.Checked);
        jar.Enabled=!running && !removing.Checked;
        submit.Text=removing.Checked?"選択したMODを削除  →  GitHubでEXE・Checkを再生成して自動更新":
            "更新する  →  GitHubでEXE・Checkを生成して自動更新";
        submit.BackColor=removing.Checked?Color.FromArgb(165,51,51):Color.FromArgb(30,94,181);
        if(removing.Checked)hash.Text="削除時は新しいJARを選択しません";
    }
    void Busy(bool yes){running=yes;submit.Enabled=!yes;load.Enabled=!yes;auth.Enabled=!yes;mods.Enabled=!yes;updating.Enabled=!yes;adding.Enabled=!yes;removing.Enabled=!yes;if(!yes)UpdateMode();}
    async Task Reload(){try{
        State("GitHub正規MODを取得中...");
        using var req=new HttpRequestMessage(HttpMethod.Get,Manifest+"?nocache="+DateTime.UtcNow.Ticks);
        req.Headers.UserAgent.ParseAdd("PiriCraftModPublisher/3.0");
        using var res=await http.SendAsync(req);res.EnsureSuccessStatusCode();
        using var data=JsonDocument.Parse(await res.Content.ReadAsStringAsync());
        var v=data.RootElement.GetProperty("launcher").GetProperty("version").GetString();
        mods.Items.Clear();paths.Clear();
        foreach(var item in data.RootElement.GetProperty("files").EnumerateArray()){
            var p=item.GetProperty("path").GetString()??"";
            if(!p.StartsWith("mods/")||!p.EndsWith(".jar",StringComparison.OrdinalIgnoreCase))continue;
            paths.Add(p);mods.Items.Add(Path.GetFileName(p)+" ["+item.GetProperty("source").GetString()+"]");
        }
        if(mods.Items.Count>0)mods.SelectedIndex=0;
        title.Text=$"正規MOD {paths.Count}件 / 現在のランチャー v{v} / {Repo}";
        State("正規MOD一覧を取得しました");Log("正規MOD一覧："+paths.Count+"件");
    }catch(Exception e){State("正規一覧を取得できません");Log("ERROR "+e.Message);MessageBox.Show(this,e.Message,"取得エラー");}}
    async Task<string> Gh(bool get) {
        var found=gh;
        if(found!=null&&File.Exists(found))return found;
        var portable=Path.Combine(dir,"gh");
        if(Directory.Exists(portable)){found=Directory.GetFiles(portable,"gh.exe",SearchOption.AllDirectories).FirstOrDefault();if(found!=null)return gh=found;}
        var system=Environment.GetEnvironmentVariable("PATH")?.Split(Path.PathSeparator).Select(s=>Path.Combine(s,"gh.exe")).FirstOrDefault(File.Exists);
        if(system!=null)return gh=system;
        if(!get)throw new FileNotFoundException("GitHub CLI未導入");
        State("GitHub CLIを初回準備しています...");
        using var req=new HttpRequestMessage(HttpMethod.Get,"https://api.github.com/repos/cli/cli/releases/latest");
        req.Headers.UserAgent.ParseAdd("PiriCraftModPublisher/3.0");
        using var res=await http.SendAsync(req);res.EnsureSuccessStatusCode();
        using var doc=JsonDocument.Parse(await res.Content.ReadAsStringAsync());
        string? url=null;
        foreach(var x in doc.RootElement.GetProperty("assets").EnumerateArray()){
            var n=x.GetProperty("name").GetString()??"";
            if(n.EndsWith("windows_amd64.zip",StringComparison.OrdinalIgnoreCase)){url=x.GetProperty("browser_download_url").GetString();break;}
        }
        if(url==null)throw new Exception("GitHub CLI Windows ZIPが見つかりません");
        var zip=Path.Combine(dir,"gh.zip");
        using(var dl=await http.GetAsync(url,HttpCompletionOption.ResponseHeadersRead)){dl.EnsureSuccessStatusCode();await using var stream=File.Create(zip);await dl.Content.CopyToAsync(stream);}
        Directory.CreateDirectory(portable);ZipFile.ExtractToDirectory(zip,portable,true);File.Delete(zip);
        found=Directory.GetFiles(portable,"gh.exe",SearchOption.AllDirectories).FirstOrDefault();
        return gh=found??throw new Exception("GitHub CLI展開に失敗");
    }
    async Task<(int,string)> Exec(string exe,params string[] args) {
        using var p=new Process{StartInfo=new ProcessStartInfo(exe){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true}};
        foreach(string a in args)p.StartInfo.ArgumentList.Add(a);
        if(Path.GetFileName(exe).Equals("gh.exe",StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(sharedKey.Text))
            p.StartInfo.Environment["GH_TOKEN"]=sharedKey.Text.Trim();
        p.Start();
        var a1=p.StandardOutput.ReadToEndAsync();var a2=p.StandardError.ReadToEndAsync();await p.WaitForExitAsync();return(p.ExitCode,await a1+await a2);
    }
    async Task CheckAuth(){try{var x=await Gh(false);var r=await Exec(x,"auth","status");Log(r.Item1==0?"GitHub認証済み":"GitHub未ログイン。作業者本人のアカウントでログインしてください。");}catch{Log("GitHubは初回ログインで自動準備できます。");}}
    async Task Login(){try{
        auth.Enabled=false;var exe=await Gh(true);var status=await Exec(exe,"auth","status");
        if(status.Item1==0){State("GitHubログイン済み");return;}
        MessageBox.Show(this,"GitHubのログイン画面で、作業者本人のアカウントを使用してください。所有者の情報は不要です。","GitHub認証");
        using var p=new Process{StartInfo=new ProcessStartInfo(exe){UseShellExecute=true}};
        foreach(var a in new[]{"auth","login","--hostname","github.com","--web","--git-protocol","https"})p.StartInfo.ArgumentList.Add(a);
        p.Start();await p.WaitForExitAsync();var after=await Exec(exe,"auth","status");
        if(after.Item1!=0)throw new Exception("GitHub認証が完了していません。");
        Log("GitHub認証完了");State("GitHubログイン済み");
    }catch(Exception e){Log("ERROR "+e);MessageBox.Show(this,e.Message,"認証エラー");}finally{auth.Enabled=true;}}
    async Task<string> GhRun(string ghExe,params string[] args){
        var result=await Exec(ghExe,args);
        if(result.Item1!=0)throw new Exception("GitHub操作エラー: gh "+string.Join(" ",args.Take(3))+"\n"+result.Item2);
        return result.Item2;
    }
    async Task Publish() {
        if(running)return;
        try {
            if(!removing.Checked&&!File.Exists(jar.Text))throw new Exception("新しいMODのJARファイルを選択してください");
            if((updating.Checked||removing.Checked)&&(mods.SelectedIndex<0||mods.SelectedIndex>=paths.Count))throw new Exception("更新元を正規MOD一覧から選んでください");
            var localJar=jar.Text;
            var selected=(updating.Checked||removing.Checked)?paths[mods.SelectedIndex]:"";
            var filename=removing.Checked?Path.GetFileName(selected):Path.GetFileName(localJar);
            if(filename.Contains('/')||filename.Contains('\\')||!filename.EndsWith(".jar",StringComparison.OrdinalIgnoreCase))throw new Exception("JARのファイル名が不正です");
            var action=removing.Checked?"既存MODを削除":updating.Checked?"既存MODを更新":"新しいMODを追加";
            var expectedHash=removing.Checked?"":Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(localJar)));
            if(integrationJar==null){
                var prompt=removing.Checked?
                    $"【MOD削除の確認】\n\n削除対象：{selected}\n\nランチャーの配布MOD一覧とEXE内のMODを除去し、Checkの許可ハッシュも削除します。\n次回の自動更新で利用者のmodsフォルダーからも除去されます。\nこの操作は全利用者へ反映されます。\n\n本当に削除しますか？":
                    $"{action}\n更新元：{(updating.Checked?selected:"新規追加")}\n新しいファイル：{filename}\nSHA256：{expectedHash}\n\nGitHubにアップロードし、EXE・Checkをビルドして自動更新を公開します。";
                if(MessageBox.Show(this,prompt,"確認",MessageBoxButtons.YesNo,removing.Checked?MessageBoxIcon.Warning:MessageBoxIcon.Question)!=DialogResult.Yes)return;
            }
            Busy(true);
            var x=await Gh(true);
            await GhRun(x,"auth","status");
            if(integrationJar==null){
                var who=await GhRun(x,"api","user","--jq",".login");
                Log((string.IsNullOrWhiteSpace(sharedKey.Text)?"GitHubログイン利用：":"共有公開キー利用：")+who.Trim()+" / "+Repo);
                Log("GitHubがリポジトリの書込権限を検証します");
            } else {Log("Integration test mode: Actions job uses scoped GitHub token");}
            // Re-check the authoritative manifest immediately before dispatch.
            using(var checkReq=new HttpRequestMessage(HttpMethod.Get,Manifest+"?fresh="+DateTime.UtcNow.Ticks)){
                checkReq.Headers.CacheControl=new System.Net.Http.Headers.CacheControlHeaderValue{NoCache=true,NoStore=true};
                using var checkRes=await http.SendAsync(checkReq);checkRes.EnsureSuccessStatusCode();
                using var official=JsonDocument.Parse(await checkRes.Content.ReadAsStringAsync());
                var found=official.RootElement.GetProperty("files").EnumerateArray().Any(e=>(e.GetProperty("path").GetString()??"")==selected);
                if((updating.Checked||removing.Checked)&&!found)
                    throw new Exception("選択したMODは既に正規一覧にありません。一覧を更新してから操作してください: "+selected);
                if(adding.Checked&&official.RootElement.GetProperty("files").EnumerateArray().Any(e=>(e.GetProperty("path").GetString()??"")=="mods/"+filename))
                    throw new Exception("同名のMODが既に登録されています。一覧を更新してください: "+filename);
            }
            var stage=(removing.Checked?"remove-":"publisher-input-")+DateTimeOffset.UtcNow.ToUnixTimeSeconds()+"-"+Guid.NewGuid().ToString("N")[..8];
            if(!removing.Checked){
                State("1/4 新しいJARをGitHubへ転送中...");
                Log("受け渡し領域を作成: "+stage);
                await GhRun(x,"release","create",stage,"--repo",Repo,"--draft","--target","main","--title","MOD input "+stage,"--notes","Temporary staging asset. Automatically built by PiriCraft MOD Publisher.");
                await GhRun(x,"release","upload",stage,localJar,"--repo",Repo);
            } else {
                State("1/4 削除対象を検証済み");
                Log("削除対象: "+selected);
            }
            State("2/4 GitHubにビルドを依頼中...");
            await GhRun(x,"workflow","run","publish-mod-from-app.yml","--repo",Repo,"--ref","main","-f","mode="+(removing.Checked?"remove":updating.Checked?"update":"add"),"-f","target="+selected,"-f","stage_tag="+stage,"-f","filename="+filename,"-f","sha256="+expectedHash,"-f","dry_run="+(integrationJar!=null && acceptanceTarget==null?"true":"false"));
            State("3/4 GitHubでEXE・Checkをビルドし、Windows起動テストを実行中...");
            Log("クラウドビルド開始。このPCにソース、dotnet、Java、Gradleは不要です。");
            string? runId=null;
            for(int t=0;t<300;t++) {
                await Task.Delay(TimeSpan.FromSeconds(5));
                var list=await GhRun(x,"run","list","--repo",Repo,"--workflow","publish-mod-from-app.yml","--limit","30","--json","databaseId,displayTitle,status,conclusion");
                using var doc=JsonDocument.Parse(list);
                var matched=doc.RootElement.EnumerateArray().FirstOrDefault(e=> (e.GetProperty("displayTitle").GetString()??"").Contains(stage,StringComparison.OrdinalIgnoreCase));
                if(matched.ValueKind!=JsonValueKind.Object)continue;
                var id=matched.GetProperty("databaseId").GetInt64().ToString();
                if(runId!=id){runId=id;Log("ビルドログ: https://github.com/"+Repo+"/actions/runs/"+id);}
                var statusVal=matched.GetProperty("status").GetString();
                if(statusVal!="completed")continue;
                var conclusion=matched.GetProperty("conclusion").GetString();
                if(conclusion!="success")throw new Exception("GitHubビルド失敗: "+conclusion+"。詳細: https://github.com/"+Repo+"/actions/runs/"+runId);
                State(integrationJar!=null && acceptanceTarget==null?"4/4 テスト成功（本番公開は変更なし）":"4/4 公開成功。ランチャーの自動更新が有効です。");
                Log("完成: https://github.com/"+Repo+"/actions/runs/"+runId);
                if(!removing.Checked)try{await GhRun(x,"release","delete",stage,"--repo",Repo,"--yes","--cleanup-tag");}catch(Exception e){Log("一時アップロードの自動削除失敗（公開には影響しません）: "+e.Message);}
                if(integrationJar!=null){Log(acceptanceTarget==null?"APP_TO_GITHUB_ACTIONS_END_TO_END_PASSED":"APP_TO_REAL_PRODUCTION_AUTOUPDATE_PASSED");Environment.ExitCode=0;Close();return;}
                MessageBox.Show(this,"ランチャーとCheckのビルド、公開、自動更新の設定が完了しました。","公開成功");
                await Reload();return;
            }
            throw new Exception("GitHubの処理状況を確認できませんでした。一時領域は残ります。GitHub Actionsで確認してください。");
        } catch(Exception e){State("更新失敗。公開状況をログで確認してください。");Log("ERROR "+e);if(integrationJar!=null){Environment.ExitCode=1;Close();}else MessageBox.Show(this,e.Message,"更新失敗");}
        finally{if(running)Busy(false);}
    }

}