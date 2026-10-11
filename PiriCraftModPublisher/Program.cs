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
            using var stream=typeof(Program).Assembly.GetManifestResourceStream("PiriCraftModPublisher.publish.ps1");
            if(stream==null || stream.Length<14000) return 1;
            Console.WriteLine("SELF_TEST_PASSED");return 0;
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try { Application.Run(new Window()); return 0; }
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
    readonly ComboBox mods=new(){DropDownStyle=ComboBoxStyle.DropDownList,Width=520};
    readonly TextBox jar=new(){ReadOnly=true,Width=630};
    readonly TextBox launcher=new(){Width=630};
    readonly TextBox check=new(){Width=630};
    readonly Label status=new(){AutoSize=true,ForeColor=Color.MidnightBlue};
    readonly Label hash=new(){AutoSize=true};
    readonly Label title=new(){AutoSize=true};
    readonly TextBox output=new(){Multiline=true,ScrollBars=ScrollBars.Vertical,ReadOnly=true,Dock=DockStyle.Fill,Font=new Font("Consolas",9)};
    readonly Button submit=new(){Text="更新する  →  EXE・Check・GitHub公開・自動更新",Height=48,Dock=DockStyle.Fill,BackColor=Color.FromArgb(30,94,181),ForeColor=Color.White};
    readonly Button load=new(){Text="一覧を更新",Width=116};
    readonly Button auth=new(){Text="GitHubにログイン",Width=165};
    readonly System.Collections.Generic.List<string> paths=new();
    string? gh;bool running;

    public Window() {
        Text="PiriCraft MOD Publisher";Font=new Font("Yu Gothic UI",10);
        ClientSize=new Size(925,730);MinimumSize=new Size(805,660);
        StartPosition=FormStartPosition.CenterScreen;BackColor=Color.FromArgb(247,249,253);
        Directory.CreateDirectory(dir);
        launcher.Text=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"PiriCraft");
        check.Text=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"PiricraftCheckServer");
        try{using var d=JsonDocument.Parse(File.ReadAllText(Path.Combine(dir,"settings.json")));
            launcher.Text=d.RootElement.GetProperty("launcher").GetString()??launcher.Text;
            check.Text=d.RootElement.GetProperty("check").GetString()??check.Text;
        }catch{}
        var panel=new TableLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(23,15,23,15),ColumnCount=1,RowCount=11};
        foreach(var h in new[]{50,30,57,35,42,35,42,35,42,58,0})panel.RowStyles.Add(new RowStyle(h==0?SizeType.Percent:SizeType.Absolute,h==0?100:h));
        Controls.Add(panel);
        panel.Controls.Add(new Label{Text="PiriCraft MOD Publisher",Font=new Font("Yu Gothic UI",19,FontStyle.Bold),AutoSize=true},0,0);
        title.Text="GitHubの正規MOD一覧を読み込みます";panel.Controls.Add(title,0,1);
        var choices=new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false};
        choices.Controls.Add(updating);choices.Controls.Add(adding);choices.Controls.Add(load);choices.Controls.Add(auth);panel.Controls.Add(choices,0,2);
        panel.Controls.Add(new Label{Text="更新元を選択：GitHubで現在配布されている正規MOD一覧",AutoSize=true},0,3);
        mods.Dock=DockStyle.Fill;panel.Controls.Add(mods,0,4);
        panel.Controls.Add(new Label{Text="今回入れる新しいMOD（あなたのPC内のJAR）",AutoSize=true},0,5);
        panel.Controls.Add(Row(jar,Pick("JARを選択",()=>ChooseJar())),0,6);
        panel.Controls.Add(new Label{Text="ランチャーソース：PiriCraft.csproj のあるフォルダ（初回のみ）",AutoSize=true},0,7);
        panel.Controls.Add(Row(launcher,Pick("参照",()=>Folder(launcher))),0,8);
        var bottom=new TableLayoutPanel{Dock=DockStyle.Fill,RowCount=4,ColumnCount=1};
        bottom.RowStyles.Add(new RowStyle(SizeType.Absolute,60));
        bottom.RowStyles.Add(new RowStyle(SizeType.Absolute,48));
        bottom.RowStyles.Add(new RowStyle(SizeType.Absolute,38));
        bottom.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        var checkRow=new TableLayoutPanel{Dock=DockStyle.Fill,RowCount=2,ColumnCount=1};
        checkRow.RowStyles.Add(new RowStyle(SizeType.Absolute,23));checkRow.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        checkRow.Controls.Add(new Label{Text="Checkサーバーソース：PiricraftCheckServer（初回のみ）",AutoSize=true},0,0);
        checkRow.Controls.Add(Row(check,Pick("参照",()=>Folder(check))),0,1);
        bottom.Controls.Add(checkRow,0,0);bottom.Controls.Add(submit,0,1);
        var row=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.TopDown};
        status.Text="準備中…";row.Controls.Add(status);hash.Text="ファイル未選択";row.Controls.Add(hash);
        bottom.Controls.Add(row,0,2);bottom.Controls.Add(output,0,3);panel.Controls.Add(bottom,0,10);
        updating.CheckedChanged+=(_,_)=>mods.Enabled=updating.Checked&&!running;
        adding.CheckedChanged+=(_,_)=>mods.Enabled=updating.Checked&&!running;
        load.Click+=async(_,_)=>await Reload();
        auth.Click+=async(_,_)=>await Login();
        submit.Click+=async(_,_)=>await Publish();
        Shown+=async(_,_)=>{await Reload();await CheckAuth();};
        FormClosing+=(_,e)=>{if(running){e.Cancel=true;MessageBox.Show(this,"公開処理中はウィンドウを閉じられません。","PiriCraft");}};
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
    void Busy(bool yes){running=yes;submit.Enabled=!yes;load.Enabled=!yes;auth.Enabled=!yes;mods.Enabled=!yes;updating.Enabled=!yes;adding.Enabled=!yes;if(!yes)mods.Enabled=updating.Checked;}
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
        foreach(string a in args)p.StartInfo.ArgumentList.Add(a);p.Start();
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
    async Task Publish() {
        try{
            if(!File.Exists(jar.Text))throw new Exception("更新後のJARを選択してください");
            if(updating.Checked&&(mods.SelectedIndex<0||mods.SelectedIndex>=paths.Count))throw new Exception("更新元を正規一覧から選んでください");
            if(!File.Exists(Path.Combine(launcher.Text,"PiriCraft.csproj")))throw new Exception("PiriCraft.csprojが見つかりません。");
            if(!File.Exists(Path.Combine(check.Text,"src","main","java","jp","piricraft","check","PiricraftCheckPlugin.java")))throw new Exception("Checkサーバーのソースが見つかりません。");
            var exe=await Gh(true);var authState=await Exec(exe,"auth","status");
            if(authState.Item1!=0)throw new Exception("GitHubで先にログインしてください");
            string target=updating.Checked?paths[mods.SelectedIndex]:"新規追加";
            if(MessageBox.Show(this,$"更新元: {target}\n新しいJAR: {jar.Text}\n公開先: {Repo}\n\nビルド・検証後に公開し、自動更新を有効化します。","公開確認",MessageBoxButtons.YesNo)!=DialogResult.Yes)return;
            Busy(true);State("実行中：Check・EXE生成→起動検証→GitHub公開→自動更新設定");
            File.WriteAllText(Path.Combine(dir,"settings.json"),JsonSerializer.Serialize(new{launcher=launcher.Text,check=check.Text}));
            string run=Path.Combine(dir,"runs",DateTime.Now.ToString("yyyyMMdd_HHmmss"));Directory.CreateDirectory(run);
            var script=Path.Combine(run,"publish.ps1");
            using(var stream=typeof(Program).Assembly.GetManifestResourceStream("PiriCraftModPublisher.publish.ps1")??throw new Exception("更新エンジン未同梱"))
            using(var rd=new StreamReader(stream,Encoding.UTF8)){
                string src=rd.ReadToEnd();
                // PowerShell 5.1 requires explicit named array arguments for external commands.
                src=src.Replace("GhJson @(","GhJson -parameters @(");
                src=Regex.Replace(src,@"\bRun\s+('(?:[^']+)'|[A-Za-z]+)\s+@\(","Run -exe $1 -arguments @(");
                File.WriteAllText(script,src,new UTF8Encoding(true));
            }
            var psi=new ProcessStartInfo("powershell.exe"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=run};
            foreach(var a in new[]{"-NoLogo","-NoProfile","-ExecutionPolicy","RemoteSigned","-File",script,"-Mode",updating.Checked?"update":"add","-JarPath",jar.Text,"-LauncherRoot",launcher.Text,"-CheckRoot",check.Text,"-Repository",Repo,"-LogPath",Path.Combine(run,"publish.log")})psi.ArgumentList.Add(a);
            if(updating.Checked){psi.ArgumentList.Add("-TargetPath");psi.ArgumentList.Add(paths[mods.SelectedIndex]);}
            psi.Environment["PATH"]=Path.GetDirectoryName(exe)+Path.PathSeparator+psi.Environment["PATH"];
            psi.Environment["GH_PAGER"]="cat";
            using var p=new Process{StartInfo=psi,EnableRaisingEvents=true};
            p.OutputDataReceived+=(_,e)=>{if(e.Data!=null)Log(e.Data);};
            p.ErrorDataReceived+=(_,e)=>{if(e.Data!=null)Log("ERR: "+e.Data);};
            p.Start();p.BeginOutputReadLine();p.BeginErrorReadLine();await p.WaitForExitAsync();
            if(p.ExitCode!=0)throw new Exception($"更新エラー（コード {p.ExitCode}）。詳細は {Path.Combine(dir,"publisher.log")}");
            State("公開成功。自動更新が有効です。");MessageBox.Show(this,"Check・ランチャーの更新と公開が完了しました。","成功");
            await Reload();
        }catch(Exception e){State("更新失敗。原因はログを確認してください。");Log("ERROR "+e);MessageBox.Show(this,e.Message,"更新失敗");}
        finally{if(running)Busy(false);}
    }
}