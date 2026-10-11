using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace PiriCraftPublisher;

internal sealed record Config(string gatewayBaseUrl, string publisherCapability)
{
    public static Config Load()
    {
        using var stream = typeof(Config).Assembly.GetManifestResourceStream("PiriCraftPublisher.ClientConfig.json")
            ?? throw new InvalidOperationException("Publisher client configuration missing");
        using var json = JsonDocument.Parse(stream);
        var root = json.RootElement;
        var endpoint = root.GetProperty("gatewayBaseUrl").GetString() ?? "";
        var capability = root.GetProperty("publisherCapability").GetString() ?? "";
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) ||
            uri.Scheme != "https" || uri.UserInfo.Length > 0 || !string.IsNullOrWhiteSpace(uri.Query) ||
            uri.Host.EndsWith(".invalid", StringComparison.OrdinalIgnoreCase) ||
            capability.Length < 32)
            throw new InvalidOperationException("Publisher service has not been configured");
        return new Config(endpoint.TrimEnd('/'), capability);
    }
}

internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var cfg = Config.Load();
            if(args.Contains("--verify-embedded-config")) return 0;
            if(args.Contains("--layout-test"))
            {
                using var window = new PublisherWindow(cfg);
                window.Show();
                Application.DoEvents();
                var valid = window.HasVisibleControls();
                Console.WriteLine(valid ? "PUBLISHER_LAYOUT_PASSED" : "PUBLISHER_LAYOUT_FAILED");
                return valid ? 0 : 1;
            }
            Application.Run(new PublisherWindow(cfg));
            return 0;
        }
        catch(Exception error)
        {
            try
            {
                var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"PiriCraftPublisher");
                Directory.CreateDirectory(folder);
                File.AppendAllText(Path.Combine(folder,"crash.log"),DateTimeOffset.UtcNow + " " + error + Environment.NewLine);
            }
            catch {}
            MessageBox.Show(error.Message, "PiriCraft Publisher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}

internal sealed class PublisherWindow : Form
{
    readonly Config cfg;
    readonly HttpClient client = new() { Timeout = TimeSpan.FromMinutes(3) };
    readonly RadioButton update = new() { Text = "既存MODを更新", AutoSize = true, Checked = true };
    readonly RadioButton add = new() { Text = "新しいMODを追加", AutoSize = true };
    readonly ComboBox official = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    readonly TextBox source = new() { ReadOnly = true, Dock = DockStyle.Fill };
    readonly Button choose = new() { Text = "JARを選択", Dock = DockStyle.Fill };
    readonly Button publish = new() { Text = "更新する", Dock = DockStyle.Fill, BackColor = Color.FromArgb(27,92,171), ForeColor = Color.White };
    readonly Button refresh = new() { Text = "一覧を再読込", AutoSize = true };
    readonly Label current = new() { AutoSize = true, Text = "正規MOD一覧を取得します" };
    readonly Label progress = new() { AutoSize = true, Text = "準備中" };
    readonly TextBox log = new() { Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.Vertical, ReadOnly = true, Font = new Font("Consolas",9) };
    readonly System.Collections.Generic.List<string> modPaths = new();
    bool busy;

    public PublisherWindow(Config config)
    {
        cfg=config;
        Text = "PiriCraft MOD Publisher";
        Font = new Font("Yu Gothic UI",10);
        ClientSize = new Size(900,690);
        MinimumSize = new Size(770,590);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(247,249,253);

        var shell = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(22,18,22,18), ColumnCount = 1, RowCount=10 };
        foreach(var h in new[]{50,32,49,35,43,35,52,57,35,0})
            shell.RowStyles.Add(new RowStyle(h==0?SizeType.Percent:SizeType.Absolute,h==0?100:h));
        Controls.Add(shell);
        shell.Controls.Add(new Label { Text = "PiriCraft MOD Publisher", AutoSize=true, Font=new Font("Yu Gothic UI",19,FontStyle.Bold)},0,0);
        shell.Controls.Add(current,0,1);
        var modes=new FlowLayoutPanel {Dock=DockStyle.Fill,WrapContents=false};
        modes.Controls.Add(update);
        modes.Controls.Add(add);
        modes.Controls.Add(refresh);
        shell.Controls.Add(modes,0,2);
        shell.Controls.Add(new Label { Text = "更新元：現在配布している正規MOD", AutoSize=true },0,3);
        shell.Controls.Add(official,0,4);
        shell.Controls.Add(new Label { Text = "更新後の新しいFabric MOD（PC内のJAR）", AutoSize=true },0,5);
        var pick=new TableLayoutPanel { Dock=DockStyle.Fill, ColumnCount=2 };
        pick.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        pick.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,156));
        pick.Controls.Add(source,0,0);
        pick.Controls.Add(choose,1,0);
        shell.Controls.Add(pick,0,6);
        shell.Controls.Add(publish,0,7);
        shell.Controls.Add(progress,0,8);
        shell.Controls.Add(log,0,9);
        update.CheckedChanged+=(_,_)=>official.Enabled=update.Checked && !busy;
        add.CheckedChanged+=(_,_)=>official.Enabled=update.Checked && !busy;
        choose.Click+=(_,_)=>PickJar();
        refresh.Click+=async(_,_)=>await LoadList();
        publish.Click+=async(_,_)=>await Publish();
        Shown+=async(_,_)=>await LoadList();
        FormClosing+=(_,e)=>{if(busy){e.Cancel=true;MessageBox.Show(this,"更新処理の結果を確認しています。","PiriCraft");}};
    }

    public bool HasVisibleControls() => publish.Visible && official.Visible && log.Visible &&
        publish.Height >= 40 && log.Height >= 130 && source.Visible;

    void State(string value){progress.Text=value;WriteLog(value);}
    void WriteLog(string value)
    {
        if(IsDisposed)return;
        if(InvokeRequired){BeginInvoke(()=>WriteLog(value));return;}
        log.AppendText("["+DateTime.Now.ToString("HH:mm:ss")+"] "+value+Environment.NewLine);
        // No credentials or raw HTTP headers are logged.
    }
    void SetBusy(bool isBusy)
    {
        busy=isBusy;
        update.Enabled=!isBusy;add.Enabled=!isBusy;official.Enabled=!isBusy&&update.Checked;
        publish.Enabled=!isBusy;refresh.Enabled=!isBusy;choose.Enabled=!isBusy;
    }
    void PickJar()
    {
        using var picker = new OpenFileDialog {Filter="Fabric MOD (*.jar)|*.jar",Title="新しいJARを選択"};
        if(picker.ShowDialog(this)==DialogResult.OK){source.Text=picker.FileName;State("選択: "+Path.GetFileName(source.Text));}
    }
    HttpRequestMessage NewRequest(HttpMethod method,string endpoint)
    {
        var request=new HttpRequestMessage(method,cfg.gatewayBaseUrl+endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer",cfg.publisherCapability);
        return request;
    }
    async Task LoadList()
    {
        try
        {
            State("正規MOD一覧を取得中...");
            using var req=NewRequest(HttpMethod.Get,"/api/v1/mods");
            using var res=await client.SendAsync(req);
            if(!res.IsSuccessStatusCode)throw new InvalidOperationException("受付サーバーへの接続失敗: HTTP "+(int)res.StatusCode);
            using var data=JsonDocument.Parse(await res.Content.ReadAsStringAsync());
            official.Items.Clear();modPaths.Clear();
            foreach(var item in data.RootElement.GetProperty("mods").EnumerateArray())
            {
                var path=item.GetProperty("path").GetString();
                if(string.IsNullOrWhiteSpace(path))continue;
                modPaths.Add(path);
                official.Items.Add(Path.GetFileName(path));
            }
            if(official.Items.Count>0)official.SelectedIndex=0;
            current.Text="正規MOD "+modPaths.Count+"件 / ランチャー "+data.RootElement.GetProperty("launcher").GetString();
            State("準備完了");
        }
        catch(Exception ex){State("正規MOD一覧の取得に失敗: "+ex.Message);}
    }
    async Task Publish()
    {
        if(busy)return;
        try
        {
            if(!File.Exists(source.Text))throw new InvalidOperationException("新しいJARを選択してください");
            if(update.Checked && (official.SelectedIndex<0||official.SelectedIndex>=modPaths.Count))
                throw new InvalidOperationException("更新元の正規MODを選択してください");
            var path=source.Text;
            var info=new FileInfo(path);
            if(info.Length==0 || info.Length>64*1024*1024)throw new InvalidOperationException("JARのサイズは64MB以下にしてください");
            var mode=update.Checked?"update":"add";
            var target=update.Checked?modPaths[official.SelectedIndex]:"";
            var filename=Path.GetFileName(path);
            if(MessageBox.Show(this,"操作："+(update.Checked?"既存MODの更新":"MODの新規追加")+
                "\n更新元："+(update.Checked?target:"新規追加")+"\nJAR："+filename+
                "\n\nGitHub側でビルド・公開・自動更新まで実行します。","更新確認",
                MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return;

            SetBusy(true);
            State("1/3 JARを検証して受付サーバーへ転送中");
            string hash;
            using(var data=File.OpenRead(path)){hash=Convert.ToHexString(SHA256.HashData(data));}
            using var req=NewRequest(HttpMethod.Post,"/api/v1/publish");
            req.Headers.TryAddWithoutValidation("X-Mod-Mode",mode);
            req.Headers.TryAddWithoutValidation("X-Mod-Target",target);
            req.Headers.TryAddWithoutValidation("X-Mod-Filename",filename);
            req.Headers.TryAddWithoutValidation("X-Mod-Sha256",hash);
            req.Content=new StreamContent(File.OpenRead(path));
            req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/java-archive");
            using var reply=await client.SendAsync(req);
            var raw=await reply.Content.ReadAsStringAsync();
            if(!reply.IsSuccessStatusCode)throw new InvalidOperationException("受付エラー HTTP "+(int)reply.StatusCode+": "+SafeError(raw));
            using var job=JsonDocument.Parse(raw);
            var ticket=job.RootElement.GetProperty("ticket").GetString()??throw new Exception("受付番号が不正です");
            if(!Regex.IsMatch(ticket,@"^publisher-input-[0-9a-f]{24}$"))throw new Exception("受付番号の形式が不正です");
            State("2/3 GitHubでビルド・検証・公開を実行中");
            for(var i=0;i<540;i++)
            {
                await Task.Delay(TimeSpan.FromSeconds(5));
                using var statusRequest=NewRequest(HttpMethod.Get,"/api/v1/status/"+ticket);
                using var response=await client.SendAsync(statusRequest);
                if(!response.IsSuccessStatusCode)throw new Exception("更新の進捗を取得できません: HTTP "+(int)response.StatusCode);
                using var result=JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                var state=result.RootElement.GetProperty("status").GetString();
                if(state!="completed")continue;
                var outcome=result.RootElement.GetProperty("conclusion").GetString();
                var workflow=result.RootElement.GetProperty("workflow_url").GetString();
                if(outcome!="success")throw new Exception("更新に失敗しました。GitHubのビルド記録を確認してください: "+workflow);
                State("3/3 公開成功。ランチャーの自動更新が有効になりました。");
                MessageBox.Show(this,"MODの更新・公開が完了しました。","PiriCraft",MessageBoxButtons.OK,MessageBoxIcon.Information);
                await LoadList();
                return;
            }
            throw new Exception("完了状況を取得できませんでした。受付番号: "+ticket);
        }
        catch(Exception error){State("公開失敗: "+error.Message);MessageBox.Show(this,error.Message,"PiriCraft Publisher",MessageBoxButtons.OK,MessageBoxIcon.Error);}
        finally{SetBusy(false);}
    }

    static string SafeError(string response)
    {
        try
        {
            using var json=JsonDocument.Parse(response);
            return (json.RootElement.TryGetProperty("detail",out var value)?value.GetString():"不明なエラー")??"不明なエラー";
        }
        catch {return "エラーの詳細を取得できませんでした";}
    }
}
