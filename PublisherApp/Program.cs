using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace PiriCraftModPublisher;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) =>
        {
            CrashLog(e.Exception);
            MessageBox.Show(e.Exception.Message, "PiriCraft Publisher - エラー", MessageBoxButtons.OK, MessageBoxIcon.Error);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            CrashLog(e.ExceptionObject as Exception ?? new Exception("Unknown fatal error"));
        Application.Run(new PublisherWindow());
    }

    internal static string Storage => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PiriCraftModPublisher");

    internal static void CrashLog(Exception e)
    {
        try
        {
            Directory.CreateDirectory(Storage);
            File.AppendAllText(Path.Combine(Storage, "crash.log"),
                $"[{DateTime.Now:O}] {e}\r\n", Encoding.UTF8);
        }
        catch { }
    }
}

internal sealed class ModEntry
{
    public string Path { get; init; } = "";
    public string Source { get; init; } = "";
    public string Sha256 { get; init; } = "";
    public override string ToString() => $"{System.IO.Path.GetFileName(Path)}   [{(Source == "modrinth" ? "Modrinth" : "同梱")}]";
}

internal sealed class PublisherWindow : Form
{
    private const string Repo = "Pasta0719/Piricraft";
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(25) };
    private readonly ComboBox target = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly RadioButton update = new() { Text = "既存MODを更新", Checked = true };
    private readonly RadioButton add = new() { Text = "MODを新規追加" };
    private readonly TextBox filePath = new() { ReadOnly = true };
    private readonly TextBox launcherRoot = new();
    private readonly TextBox checkRoot = new();
    private readonly TextBox output = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
    private readonly Label remoteVersion = new();
    private readonly Label localHash = new();
    private readonly Label status = new();
    private readonly Button refresh = new() { Text = "再取得" };
    private readonly Button run = new() { Text = "更新を実行", Height = 48 };
    private readonly Button browse = new() { Text = "参照…" };
    private readonly Button browseLauncher = new() { Text = "参照…" };
    private readonly Button browseCheck = new() { Text = "参照…" };
    private readonly ProgressBar progress = new() { Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 20, Visible = false };
    private readonly string settingsFile = Path.Combine(Program.Storage, "settings.json");
    private readonly string logFile = Path.Combine(Program.Storage, "publisher.log");
    private List<ModEntry> authorized = new();
    private bool busy = false;
    private readonly Color dark = Color.FromArgb(19, 30, 49);
    private readonly Color slate = Color.FromArgb(87, 101, 122);
    private readonly Color blue = Color.FromArgb(41, 105, 224);

    public PublisherWindow()
    {
        Text = "PiriCraft MOD Publisher";
        ClientSize = new Size(860, 780);
        MinimumSize = MaximumSize = Size;
        MaximizeBox = false;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Yu Gothic UI", 10f);
        BackColor = Color.FromArgb(245, 248, 252);
        ForeColor = dark;
        AutoScaleMode = AutoScaleMode.Dpi;
        Padding = new Padding(0);
        BuildUi();
        LoadSettings();
        Shown += async (_, _) => await RefreshListAsync();
        FormClosing += (_, _) => SaveSettings();
    }

    private static Label TextLabel(string value, int x, int y, int width, bool headline = false) =>
        new()
        {
            Text = value,
            Bounds = new Rectangle(x, y, width, headline ? 31 : 25),
            Font = new Font("Yu Gothic UI", headline ? 13f : 9.6f, headline ? FontStyle.Bold : FontStyle.Regular),
            ForeColor = Color.FromArgb(19, 30, 49)
        };

    private void BuildUi()
    {
        var header = new Panel { Bounds = new Rectangle(0, 0, 860, 117), BackColor = dark };
        header.Controls.Add(new Label {
            Bounds = new Rectangle(28, 20, 795, 39), Text = "PiriCraft  MOD Publisher",
            ForeColor = Color.White, Font = new Font("Segoe UI", 21, FontStyle.Bold)
        });
        header.Controls.Add(new Label {
            Bounds = new Rectangle(30, 66, 800, 31),
            Text = "正規MOD一覧から対象を選択 → 新しいJARを指定 → 公開・自動更新まで一括実行",
            ForeColor = Color.FromArgb(188, 205, 233), Font = new Font("Yu Gothic UI", 9.8f)
        });
        Controls.Add(header);
        Controls.Add(TextLabel("01   操作", 30, 137, 650, true));

        update.SetBounds(34, 175, 195, 30);
        add.SetBounds(265, 175, 218, 30);
        Controls.AddRange(new Control[] { update, add });
        update.CheckedChanged += (_, _) => RefreshMode();
        add.CheckedChanged += (_, _) => RefreshMode();

        Controls.Add(TextLabel("02   現在の正規MODから更新対象を選択", 30, 225, 700, true));
        target.SetBounds(33, 263, 661, 32);
        target.Font = new Font("Yu Gothic UI", 10.5f);
        refresh.SetBounds(708, 263, 119, 32);
        Controls.AddRange(new Control[] { target, refresh });
        refresh.Click += async (_, _) => await RefreshListAsync();
        remoteVersion.SetBounds(34, 301, 810, 25);
        remoteVersion.ForeColor = slate;
        Controls.Add(remoteVersion);

        Controls.Add(TextLabel("03   PC内の新しいMOD（.jar）を選択", 30, 342, 700, true));
        filePath.SetBounds(33, 380, 661, 30);
        browse.SetBounds(708, 380, 119, 32);
        localHash.SetBounds(34, 419, 810, 25);
        localHash.ForeColor = slate;
        localHash.Font = new Font("Consolas", 9f);
        localHash.Text = "SHA-256：未選択";
        Controls.AddRange(new Control[] { filePath, browse, localHash });
        browse.Click += async (_, _) => {
            using var picker = new OpenFileDialog { Title = "新しいFabric MODを選択", Filter = "Java Archive (*.jar)|*.jar" };
            if (picker.ShowDialog(this) != DialogResult.OK) return;
            filePath.Text = picker.FileName;
            try
            {
                localHash.Text = "SHA-256: 計算中";
                var hash = await Task.Run(() => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(picker.FileName))));
                localHash.Text = "SHA-256: " + hash;
            }
            catch (Exception e) { ShowError("JARを読み取れません", e); }
        };

        Controls.Add(TextLabel("04   ビルド環境（初回のみ設定）", 30, 462, 700, true));
        Controls.Add(TextLabel("PiriCraft ランチャーのソース", 33, 496, 420));
        launcherRoot.SetBounds(33, 520, 661, 30);
        browseLauncher.SetBounds(708, 520, 119, 32);
        Controls.AddRange(new Control[] { launcherRoot, browseLauncher });
        browseLauncher.Click += (_, _) => BrowseFolder(launcherRoot, "PiriCraft.csproj のあるフォルダ");

        Controls.Add(TextLabel("PiriCraftCheck サーバープラグインのソース", 33, 558, 510));
        checkRoot.SetBounds(33, 582, 661, 30);
        browseCheck.SetBounds(708, 582, 119, 32);
        Controls.AddRange(new Control[] { checkRoot, browseCheck });
        browseCheck.Click += (_, _) => BrowseFolder(checkRoot, "PiricraftCheckServerのプロジェクトフォルダ");

        run.SetBounds(32, 630, 794, 52);
        run.BackColor = blue;
        run.ForeColor = Color.White;
        run.FlatStyle = FlatStyle.Flat;
        run.FlatAppearance.BorderSize = 0;
        run.Font = new Font("Yu Gothic UI", 12f, FontStyle.Bold);
        Controls.Add(run);
        run.Click += async (_, _) => await PublishAsync();
        status.SetBounds(33, 688, 782, 23);
        status.Text = "準備中";
        status.ForeColor = slate;
        Controls.Add(status);
        progress.SetBounds(34, 712, 791, 5);
        Controls.Add(progress);

        output.SetBounds(33, 723, 795, 40);
        output.BackColor = Color.FromArgb(232, 237, 245);
        output.ForeColor = dark;
        output.Font = new Font("Consolas", 8.7f);
        Controls.Add(output);

        RefreshMode();
    }

    private void RefreshMode()
    {
        target.Enabled = update.Checked && !busy;
        refresh.Enabled = update.Checked && !busy;
        if (add.Checked) remoteVersion.Text = "新規追加では更新元の選択は不要です。";
        else if (authorized.Count > 0) remoteVersion.Text = $"GitHub 正規MOD: {authorized.Count}件  ・  自動取得済み";
    }

    private async Task RefreshListAsync()
    {
        if (busy) return;
        refresh.Enabled = false;
        status.Text = "GitHubから現在の正規MOD一覧を取得中…";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"https://raw.githubusercontent.com/{Repo}/main/update-manifest.json?ts={DateTimeOffset.UtcNow.ToUnixTimeSeconds()}");
            req.Headers.UserAgent.ParseAdd("PiriCraftModPublisher/2.0");
            using var response = await http.SendAsync(req);
            response.EnsureSuccessStatusCode();
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var mods = new List<ModEntry>();
            foreach (var item in json.RootElement.GetProperty("files").EnumerateArray())
            {
                string path = item.GetProperty("path").GetString() ?? "";
                if (!path.StartsWith("mods/", StringComparison.Ordinal) ||
                    !path.EndsWith(".jar", StringComparison.OrdinalIgnoreCase)) continue;
                mods.Add(new ModEntry {
                    Path = path,
                    Source = item.TryGetProperty("source", out var src) ? src.GetString() ?? "" : "",
                    Sha256 = item.TryGetProperty("sha256", out var sha) ? sha.GetString() ?? "" : ""
                });
            }
            authorized = mods;
            target.Items.Clear();
            target.Items.AddRange(mods.Cast<object>().ToArray());
            if (target.Items.Count > 0) target.SelectedIndex = 0;
            string v = json.RootElement.GetProperty("launcher").GetProperty("version").GetString() ?? "不明";
            status.Text = $"正規MOD {mods.Count}件を取得 ・ ランチャー v{v}";
            RefreshMode();
            Log($"正規MOD一覧取得: {mods.Count}件 / launcher-v{v}");
        }
        catch (Exception e)
        {
            authorized.Clear();
            target.Items.Clear();
            status.Text = "正規一覧の取得に失敗。再取得してください";
            ShowError("GitHubの正規MOD一覧を取得できません", e);
        }
        finally { refresh.Enabled = update.Checked && !busy; }
    }

    private void BrowseFolder(TextBox box, string title)
    {
        using var picker = new FolderBrowserDialog { Description = title, UseDescriptionForTitle = true };
        if (Directory.Exists(box.Text)) picker.InitialDirectory = box.Text;
        if (picker.ShowDialog(this) == DialogResult.OK) { box.Text = picker.SelectedPath; SaveSettings(); }
    }

    private void LoadSettings()
    {
        launcherRoot.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PiriCraft");
        checkRoot.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PiricraftCheckServer");
        if (!File.Exists(settingsFile)) return;
        try
        {
            using var root = JsonDocument.Parse(File.ReadAllText(settingsFile));
            if (root.RootElement.TryGetProperty("launcherRoot", out var l)) launcherRoot.Text = l.GetString() ?? launcherRoot.Text;
            if (root.RootElement.TryGetProperty("checkRoot", out var c)) checkRoot.Text = c.GetString() ?? checkRoot.Text;
        }
        catch (Exception e) { Program.CrashLog(e); }
    }

    private void SaveSettings()
    {
        try
        {
            Directory.CreateDirectory(Program.Storage);
            File.WriteAllText(settingsFile,
                JsonSerializer.Serialize(new { launcherRoot = launcherRoot.Text, checkRoot = checkRoot.Text }),
                Encoding.UTF8);
        }
        catch (Exception e) { Program.CrashLog(e); }
    }

    private void Log(string message)
    {
        if (InvokeRequired) { BeginInvoke(new Action<string>(Log), message); return; }
        output.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}\r\n");
        try
        {
            Directory.CreateDirectory(Program.Storage);
            File.AppendAllText(logFile, $"[{DateTime.Now:O}] {message}\r\n", Encoding.UTF8);
        }
        catch { }
    }

    private void ShowError(string title, Exception e)
    {
        Log("ERROR " + e);
        MessageBox.Show(this, title + "\n\n" + e.Message + "\n\nログ: " + logFile,
            "PiriCraft MOD Publisher", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    private static async Task<int> RunProcessAsync(string executable, params string[] args)
    {
        using var p = new Process();
        p.StartInfo = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var a in args) p.StartInfo.ArgumentList.Add(a);
        if (!p.Start()) throw new InvalidOperationException("起動できません: " + executable);
        await p.WaitForExitAsync();
        return p.ExitCode;
    }

    private async Task PublishAsync()
    {
        if (busy) return;
        try
        {
            if (update.Checked && target.SelectedItem is not ModEntry)
                throw new InvalidOperationException("更新元の正規MODを選択してください。");
            if (!File.Exists(filePath.Text) || !filePath.Text.EndsWith(".jar", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("今回入れる新しいJARファイルを選択してください。");
            if (!File.Exists(Path.Combine(launcherRoot.Text, "PiriCraft.csproj")))
                throw new FileNotFoundException("ランチャーのPiriCraft.csprojが見つかりません。ソースフォルダを指定してください。");
            if (!File.Exists(Path.Combine(checkRoot.Text, "src", "main", "java", "jp", "piricraft", "check", "PiricraftCheckPlugin.java")))
                throw new FileNotFoundException("CheckサーバープラグインのJavaソースが見つかりません。");
            status.Text = "GitHub認証と開発ツールを確認中…";
            foreach (var name in new[] { "gh", "dotnet", "powershell.exe" })
            {
                if (await RunProcessAsync("where.exe", name) != 0)
                    throw new InvalidOperationException($"必要なツールが見つかりません: {name}\nghと.NET 10 SDKは最初に一度だけセットアップしてください。");
            }
            if (await RunProcessAsync("gh", "auth", "status") != 0)
                throw new InvalidOperationException("GitHub認証が未設定です。\nこのPCで一度だけ gh auth login を実行してください。あなたの認証情報はツールに入力しません。");
            SaveSettings();
            string nameOfMod = update.Checked ? ((ModEntry)target.SelectedItem!).Path : System.IO.Path.GetFileName(filePath.Text);
            var decision = MessageBox.Show(this,
                $"操作: {(update.Checked ? "既存MODを更新" : "新規MODを追加")}\n" +
                $"対象: {nameOfMod}\n新しいJAR: {System.IO.Path.GetFileName(filePath.Text)}\n\n" +
                "EXE/CheckのビルドとGitHub公開後、最後に自動更新を有効にします。\n実行しますか？",
                "公開の最終確認", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (decision != DialogResult.Yes) return;

            busy = true;
            run.Enabled = false;
            browse.Enabled = false;
            browseLauncher.Enabled = false;
            browseCheck.Enabled = false;
            update.Enabled = false;
            add.Enabled = false;
            target.Enabled = false;
            refresh.Enabled = false;
            progress.Visible = true;
            status.Text = "公開処理を実行しています（ログを記録中）";
            output.Clear();
            Log($"操作開始: {nameOfMod}");
            string engineFile = Path.Combine(Program.Storage, "publish-engine-v2.ps1");
            using (Stream? stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("PiriCraftModPublisher.publish.ps1"))
            {
                if (stream is null) throw new InvalidOperationException("内蔵の更新エンジンが見つかりません。");
                Directory.CreateDirectory(Program.Storage);
                using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
                var script = await reader.ReadToEndAsync();
                File.WriteAllText(engineFile, script, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
            }
            string mode = update.Checked ? "update" : "add";
            string jar = filePath.Text, launcher = launcherRoot.Text, checker = checkRoot.Text;
            string targetPath = update.Checked ? ((ModEntry)target.SelectedItem!).Path : "";
            string executionLog = Path.Combine(Program.Storage, "last-run.log");
            await Task.Run(async () => {
                using var p = new Process();
                p.StartInfo = new ProcessStartInfo("powershell.exe") {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                foreach (string argument in new[] {
                    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", engineFile,
                    "-Mode", mode, "-JarPath", jar, "-LauncherRoot", launcher,
                    "-CheckRoot", checker, "-Repository", Repo, "-LogPath", executionLog
                }.Concat(update.Checked ? new[] { "-TargetPath", targetPath } : Array.Empty<string>()))
                    p.StartInfo.ArgumentList.Add(argument);
                p.OutputDataReceived += (_, e) => { if (e.Data is not null) Log(e.Data); };
                p.ErrorDataReceived += (_, e) => { if (e.Data is not null) Log("STDERR " + e.Data); };
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                await p.WaitForExitAsync();
                if (p.ExitCode != 0) throw new InvalidOperationException(
                    $"更新処理が終了コード {p.ExitCode} で停止しました。ログを確認してください: {executionLog}");
            });
            Log("公開と自動更新設定が完了しました。");
            status.Text = "完了：新しいMODを公開しました";
            MessageBox.Show(this, "更新処理が完了しました。\nEXE・Check JARと自動更新マニフェストを公開しました。",
                "完了", MessageBoxButtons.OK, MessageBoxIcon.Information);
            busy = false;
            await RefreshListAsync();
        }
        catch (Exception e)
        {
            status.Text = "失敗：ログを確認してください。自動更新の切替状況も確認してください。";
            ShowError("処理を完了できませんでした", e);
        }
        finally
        {
            busy = false; run.Enabled = true; browse.Enabled = true; browseLauncher.Enabled = true;
            browseCheck.Enabled = true; update.Enabled = true; add.Enabled = true;
            progress.Visible = false; RefreshMode();
        }
    }
}
