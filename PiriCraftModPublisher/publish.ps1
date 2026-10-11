param(
    [Parameter(Mandatory=$true)][ValidateSet('update','add')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$JarPath,
    [Parameter(Mandatory=$true)][string]$LauncherRoot,
    [Parameter(Mandatory=$true)][string]$CheckRoot,
    [string]$TargetPath = '',
    [string]$Repository = 'Pasta0719/Piricraft',
    [string]$LogPath = '',
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Say([string]$msg) {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg
    Write-Host $line
    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 }
}
function Fail([string]$message) { throw $message }
function Sha256([string]$file) { return (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToUpperInvariant() }
function Run([string]$exe, [string[]]$arguments) {
    Say ('実行: ' + $exe + ' ' + ($arguments -join ' '))
    $savedPreference = $ErrorActionPreference
    try {
        # Native tools such as Gradle and dotnet may emit harmless stderr lines;
        # rely on the exit code, not PowerShell 5.1 NativeCommandError promotion.
        $ErrorActionPreference = 'Continue'
        $result = & $exe @arguments 2>&1
        $status = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    foreach ($line in $result) { Say ([string]$line) }
    if ($status -ne 0) { Fail ("コマンド失敗 [$status]: $exe") }
    return $result
}
function GhJson([string[]]$parameters) {
    $raw = & gh @parameters 2>&1
    if ($LASTEXITCODE -ne 0) { Fail ('GitHubへのアクセス失敗: ' + ($raw -join "`n")) }
    return (($raw | Out-String) | ConvertFrom-Json)
}
function Get-RemoteManifest {
    $doc = GhJson @('api', "repos/$Repository/contents/update-manifest.json")
    $body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$doc.content -replace '\s','')))
    return @{ object = ($body | ConvertFrom-Json); sha = [string]$doc.sha }
}
function Write-Json([string]$path, $object) {
    $text = ConvertTo-Json -InputObject $object -Depth 40
    [IO.File]::WriteAllText($path, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Get-Optional($object,[string]$property) {
    $p = $object.PSObject.Properties[$property]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function Set-Optional($object,[string]$property,$value) {
    $p = $object.PSObject.Properties[$property]
    if ($null -eq $p) { Add-Member -InputObject $object -MemberType NoteProperty -Name $property -Value $value }
    else { $p.Value=$value }
}
function Safe-LogicalName([string]$file) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($file).ToLowerInvariant() -replace '[^a-z0-9]',''
    if (-not $stem) { Fail '有効な論理リソース名を生成できません' }
    return ('PiriCraft.Mods.' + $stem + '.jar')
}
function Ensure-EmbeddedResource([string]$csproj, [string]$filename, [string]$logicalName) {
    [xml]$doc = Get-Content -LiteralPath $csproj -Raw
    $source = 'Bundled\' + $filename
    $found = $false
    foreach ($node in @($doc.SelectNodes("//*[local-name()='EmbeddedResource']"))) {
        if ([string]$node.GetAttribute('Include') -ieq $source) {
            $inner = $node.SelectSingleNode("*[local-name()='LogicalName']")
            if ($null -eq $inner) { $inner = $doc.CreateElement('LogicalName'); [void]$node.AppendChild($inner) }
            $inner.InnerText = $logicalName
            $found = $true
        }
    }
    if (-not $found) {
        $group = $doc.CreateElement('ItemGroup')
        $embedded = $doc.CreateElement('EmbeddedResource')
        $embedded.SetAttribute('Include', $source)
        $logical = $doc.CreateElement('LogicalName')
        $logical.InnerText = $logicalName
        [void]$embedded.AppendChild($logical)
        [void]$group.AppendChild($embedded)
        [void]$doc.DocumentElement.AppendChild($group)
    }
    $doc.Save($csproj)
}
function Update-AllowedHashes([string]$source, [string[]]$hashes) {
    $text = [IO.File]::ReadAllText($source)
    $pattern = '(?s)(private\s+static\s+final\s+Set<String>\s+ALLOWED_HASHES\s*=\s*Set\.of\s*\()(.*?)(\)\s*;)'
    $regex = New-Object System.Text.RegularExpressions.Regex($pattern)
    $matches = $regex.Matches($text)
    if ($matches.Count -ne 1) { Fail 'CheckサーバーにALLOWED_HASHESの定義が1つ見つかりません。誤更新を防ぐため停止します' }
    $all = @($hashes | Sort-Object -Unique)
    if ($all.Count -ne $hashes.Count) { Fail '同一SHA-256のMODが重複しています' }
    $values = ($all | ForEach-Object { '        "' + $_ + '"' }) -join ",`r`n"
    $replace = $matches[0].Groups[1].Value + "`r`n" + $values + "`r`n    " + $matches[0].Groups[3].Value
    $text = $text.Substring(0, $matches[0].Index) + $replace + $text.Substring($matches[0].Index + $matches[0].Length)
    [IO.File]::WriteAllText($source, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Test-ZipContainsHashes([string]$jar, [string[]]$hashes) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($jar)
    try {
        $entries = @($zip.Entries | Where-Object { $_.FullName -match 'PiricraftCheckPlugin\.class$' })
        if ($entries.Count -ne 1) { Fail "生成したCheckプラグインに認証クラスがありません: $jar" }
        $stream = $entries[0].Open()
        $memory = New-Object IO.MemoryStream
        try { $stream.CopyTo($memory); $class = [Text.Encoding]::GetEncoding(28591).GetString($memory.ToArray()) }
        finally { $stream.Dispose(); $memory.Dispose() }
        foreach($h in $hashes) {
            if (-not $class.Contains($h)) { Fail ('CheckサーバーJARの許可SHA-256が不足しています: ' + $h) }
        }
        Say ('Check認証クラス：' + $hashes.Count + '件のSHA-256登録を検証済み')
    }
    finally { $zip.Dispose() }
}
function Rollback($backups) {
    foreach ($entry in $backups) {
        if ($entry.existed) { Copy-Item -LiteralPath $entry.saved -Destination $entry.original -Force }
        else { Remove-Item -LiteralPath $entry.original -Force -ErrorAction SilentlyContinue }
    }
}
function Backup([string]$path, [string]$backupDir, $backupList) {
    $exists = Test-Path -LiteralPath $path
    $saved = Join-Path $backupDir (([guid]::NewGuid()).ToString('N') + '.bak')
    if ($exists) { Copy-Item -LiteralPath $path -Destination $saved -Force }
    [void]$backupList.Add(@{ original=$path; saved=$saved; existed=$exists })
}
function RequireCmd([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { Fail ("必要なコマンドがありません: $name") }
}

try {
    Say 'PiriCraft MOD Publisher 開始'
    RequireCmd 'gh'
    RequireCmd 'dotnet'
    if (-not (Test-Path -LiteralPath $JarPath -PathType Leaf)) { Fail '指定したJARがありません' }
    if ([IO.Path]::GetExtension($JarPath).ToLowerInvariant() -ne '.jar') { Fail '対応しているのはFabric MODの.jarファイルです' }
    $LauncherRoot = [IO.Path]::GetFullPath($LauncherRoot)
    $CheckRoot = [IO.Path]::GetFullPath($CheckRoot)
    $project = Join-Path $LauncherRoot 'PiriCraft.csproj'
    $localManifestFile = Join-Path $LauncherRoot 'ModsManifest.json'
    $checkSource = Join-Path $CheckRoot 'src\main\java\jp\piricraft\check\PiricraftCheckPlugin.java'
    if (-not (Test-Path $project)) { Fail ("ランチャーのPiriCraft.csprojが見つかりません: $project") }
    if (-not (Test-Path $localManifestFile)) { Fail ("ランチャーのModsManifest.jsonが見つかりません: $localManifestFile") }
    if (-not (Test-Path $checkSource)) { Fail ("Checkサーバーのソースが見つかりません: $checkSource") }
    $gradlew = Join-Path $CheckRoot 'gradlew.bat'
    $gradleCmd = if (Test-Path $gradlew) { $gradlew } elseif (Get-Command 'gradle' -ErrorAction SilentlyContinue) { 'gradle' } else { Fail 'Gradleがありません。Checkサーバーにgradlew.batを置くかGradleをインストールしてください' }
    $remote = Get-RemoteManifest
    $feed = $remote.object
    $oldVersion = [version]([string]$feed.launcher.version)
    $version = "$($oldVersion.Major).$($oldVersion.Minor).$($oldVersion.Build + 1)"
    $tag = "launcher-v$version"
    $modFiles = @($feed.files | Where-Object { $_.path -match '^mods/[^/]+\.jar$' })
    $incomingHash = Sha256 $JarPath
    $filename = [IO.Path]::GetFileName($JarPath) -replace '\s*\(\d+\)(?=\.jar$)',''
    if ($Mode -eq 'update') {
        $match = @($modFiles | Where-Object { $_.path -ceq $TargetPath })
        if ($match.Count -ne 1) { Fail ('更新するファイルを配布リストから特定できません: ' + $TargetPath) }
        $filename = [IO.Path]::GetFileName([string]$match[0].path)
        $existingResource = Get-Optional $match[0] 'resource'
        $resourceName = if ($existingResource) { [string]$existingResource } else { Safe-LogicalName $filename }
        $match[0].sha256 = $incomingHash
        Set-Optional $match[0] 'source' 'embedded'
        Set-Optional $match[0] 'resource' $resourceName
        foreach ($property in @('project','version')) { if ($match[0].PSObject.Properties[$property]) { $match[0].PSObject.Properties.Remove($property) } }
    } else {
        if ($filename -notmatch '^[a-zA-Z0-9_+.\-]+\.jar$') { Fail '追加ファイルの名前には英数字・_・+・-・.のみ使用してください' }
        $dest = 'mods/' + $filename
        if (@($modFiles | Where-Object { $_.path -ieq $dest }).Count -gt 0) { Fail '同じファイル名が登録済みです。更新を選択してください' }
        $resourceName = Safe-LogicalName $filename
        if (@($modFiles | Where-Object { (Get-Optional $_ 'resource') -eq $resourceName }).Count -gt 0) { Fail '同じリソース名が存在します。ファイル名を変えてください' }
        $newItem = [pscustomobject]@{ path=$dest; sha256=$incomingHash; source='embedded'; resource=$resourceName }
        $feed.files = @($feed.files) + @($newItem)
    }
    $hashes = @($feed.files | Where-Object { $_.path -match '^mods/[^/]+\.jar$' } | ForEach-Object { [string]$_.sha256 })
    Say ("操作=$Mode ファイル=$filename SHA256=$incomingHash")
    Say ("更新前=$($oldVersion.ToString()) 更新後=$version 登録MOD数=$($hashes.Count)")
    if ($PlanOnly) { Say '事前検証成功。PlanOnlyのためファイル変更・GitHub公開なし'; exit 0 }
    $dir = Join-Path $env:LOCALAPPDATA ('PiriCraftModPublisher\runs\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $backupDir = Join-Path $dir 'backup'
    $buildDir = Join-Path $dir 'dist'
    New-Item -ItemType Directory -Force $backupDir,$buildDir | Out-Null
    $backups = New-Object System.Collections.ArrayList
    $published = $false
    $oldLocation = Get-Location
    try {
        $bundledDir = Join-Path $LauncherRoot 'Bundled'
        New-Item -ItemType Directory -Force $bundledDir | Out-Null
        $localJar = Join-Path $bundledDir $filename
        foreach($file in @($project,$localManifestFile,$checkSource,$localJar)) { Backup $file $backupDir $backups }
        $localManifestRaw = Get-Content -LiteralPath $localManifestFile -Raw | ConvertFrom-Json
        $localManifestWrapper = $null
        # Supports a root JSON array and a { files: [...] } wrapper.
        if ($localManifestRaw -is [array]) { $localManifest = @($localManifestRaw) }
        elseif ($localManifestRaw.PSObject.Properties['files']) {
            $localManifestWrapper = $localManifestRaw
            $localManifest = @($localManifestRaw.files)
        }
        else { $localManifest = @($localManifestRaw) }
        if ($localManifest.Count -eq 0 -or $null -eq $localManifest[0].PSObject.Properties['fileName']) { Fail 'ローカルModsManifest.jsonの形式が想定外です。変更を中断します' }
        if ($Mode -eq 'update') {
            $localEntry = @($localManifest | Where-Object { $_.fileName -ceq $filename })
            if ($localEntry.Count -ne 1) { Fail ("ローカルModsManifest.jsonに更新対象がありません: $filename") }
            Set-Optional $localEntry[0] 'sha256' $incomingHash
            Set-Optional $localEntry[0] 'source' 'embedded'
            Set-Optional $localEntry[0] 'resource' $resourceName
            if ($localEntry[0].PSObject.Properties['url']) { $localEntry[0].url = $null }
        } else {
            if (@($localManifest | Where-Object { $_.fileName -ieq $filename }).Count) { Fail 'ローカルにも既存の同名MODがあります' }
            $localManifest += [pscustomobject]@{name=[IO.Path]::GetFileNameWithoutExtension($filename);fileName=$filename;sha256=$incomingHash;source='embedded';url=$null;resource=$resourceName}
        }
        Copy-Item -LiteralPath $JarPath -Destination $localJar -Force
        if ((Sha256 $localJar) -ne $incomingHash) { Fail 'Bundledへのコピー検証が失敗しました' }
        if ($null -ne $localManifestWrapper) {
            $localManifestWrapper.files = $localManifest
            Write-Json $localManifestFile $localManifestWrapper
        } else { Write-Json $localManifestFile $localManifest }
        Ensure-EmbeddedResource $project $filename $resourceName
        # A mismatch between OTHER officially embedded MODs and the local source
        # must never be published as a broken update. The selected MOD is
        # already copied and verified above.
        foreach ($item in @($feed.files | Where-Object { $_.source -eq 'embedded' -and $_.path -match '^mods/[^/]+\.jar$' })) {
            $otherFile = Join-Path $bundledDir ([IO.Path]::GetFileName([string]$item.path))
            if (-not (Test-Path -LiteralPath $otherFile -PathType Leaf)) {
                Fail ('ローカルに必須同梱MODが見つかりません: ' + $otherFile)
            }
            if ((Sha256 $otherFile) -ne [string]$item.sha256) {
                Fail ('ローカルの同梱MODがGitHub正規版と一致しません: ' + $otherFile + ' / ローカルプロジェクトの素材を同期してください')
            }
        }
        Update-AllowedHashes $checkSource $hashes
        Say 'ローカルのランチャー素材・MOD定義・Check許可SHAを更新済み'

        Push-Location $CheckRoot
        try { [void](Run $gradleCmd @('clean','build','--no-daemon','--console=plain')) } finally { Pop-Location }
        $checkCandidates = @(Get-ChildItem -Path (Join-Path $CheckRoot 'build\libs') -Filter '*CheckServer*.jar' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch 'sources|javadoc|plain|dev' } | Sort-Object LastWriteTime -Descending)
        if (-not $checkCandidates.Count) { Fail 'ビルド済みのPiricraftCheckServer JARが見つかりません' }
        $checkBuild = $checkCandidates[0].FullName
        Test-ZipContainsHashes $checkBuild $hashes
        $checkOutput = Join-Path $buildDir 'PiricraftCheckServer-1.0.0.jar'
        Copy-Item -LiteralPath $checkBuild -Destination $checkOutput -Force
        Say 'Checkサーバープラグイン生成成功'

        $exe = Join-Path $buildDir 'PiriCraft.exe'
        $rid = 'win-x64'
        Push-Location $LauncherRoot
        try {
            [void](Run 'dotnet' @('publish',$project,'-c','Release','-r',$rid,'--self-contained','true',
                '-p:PublishSingleFile=true','-p:IncludeNativeLibrariesForSelfExtract=true',
                "-p:Version=$version", "-p:AssemblyVersion=$version.0", "-p:FileVersion=$version.0",
                '-o',$buildDir))
        } finally { Pop-Location }
        if (-not (Test-Path $exe) -or (Get-Item $exe).Length -lt 4MB) { Fail 'EXEの出力サイズが異常です' }
        $exeHash = Sha256 $exe
        $fileVersion = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
        if (-not $fileVersion -or -not $fileVersion.StartsWith($version + ".")) { Fail ("EXEのAssembly/FileVersionが期待値と不一致です: "+$fileVersion) }
        Say "EXE生成成功 SHA256=$exeHash"
        # Smoke-test the actual Windows executable. BadImageFormatException in
        # v1.1.22 must never be published again.
        Say 'Windowsで更新済みEXEの起動検証を実施'
        $smokeSince=Get-Date
        $smokeProcess=Start-Process -FilePath $exe -WorkingDirectory $buildDir -PassThru
        try {
            Start-Sleep -Seconds 7
            $smokeProcess.Refresh()
            if ($smokeProcess.HasExited -and $smokeProcess.ExitCode -ne 0) {
                Fail ("Windows起動検証に失敗しました。終了コード="+$smokeProcess.ExitCode)
            }
        } finally {
            if (-not $smokeProcess.HasExited) { Stop-Process -Id $smokeProcess.Id -Force -ErrorAction SilentlyContinue }
        }
        $clrfailures=@(Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$smokeSince;Id=1026} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Message -match 'PiriCraft' })
        if ($clrfailures.Count -gt 0) { Fail 'Windowsの.NET Runtimeエラーを検出したため公開を中断します' }
        Say 'EXEのWindows起動検証が成功しました'
        # Release is made DRAFT first; users must never see unverified bits in the update feed.
        $confirm = Get-RemoteManifest
        if ([string]$confirm.object.launcher.version -ne [string]$oldVersion) { Fail '公開中に別の更新が入りました。競合を避けて停止します' }
        $allTags = GhJson @('release','list','--repo',$Repository,'--limit','200','--json','tagName')
        if (@($allTags | Where-Object { $_.tagName -eq $tag }).Count -gt 0) { Fail ("GitHubに$tagが既にあります。上書きしません") }
        Say 'GitHubドラフトリリースを作成'
        [void](Run 'gh' @('release','create',$tag,'--repo',$Repository,'--draft','--title',("PiriCraft Launcher v$version"),
            '--notes',"Automated MOD $Mode: $filename (SHA256 $incomingHash); updates PiriCraftCheck Server."))
        [void](Run 'gh' @('release','upload',$tag,$exe,$checkOutput,'--repo',$Repository))
        $assets=GhJson @('release','view',$tag,'--repo',$Repository,'--json','assets')
        $exeAsset=@($assets.assets | Where-Object {$_.name -eq 'PiriCraft.exe'})
        $checkAsset=@($assets.assets | Where-Object {$_.name -eq 'PiricraftCheckServer-1.0.0.jar'})
        if ($exeAsset.Count -ne 1 -or $checkAsset.Count -ne 1 -or [int64]$exeAsset[0].size -ne (Get-Item $exe).Length) { Fail 'GitHubへアップロードされたファイルが一致しません' }
        [void](Run 'gh' @('release','edit',$tag,'--repo',$Repository,'--draft=false'))
        $published = $true
        # Only after the Release exists do we commit the remote manifest for self-update.
        $fresh = Get-RemoteManifest
        if ($fresh.sha -ne $remote.sha) { Fail 'GitHubマニフェストが操作中に変更されました。競合防止のため自動更新設定は変更しません' }
        $feed.launcher.version = $version
        $feed.launcher.url = "https://github.com/$Repository/releases/download/$tag/PiriCraft.exe"
        $feed.launcher.sha256 = $exeHash
        $feed.launcher.size = [int64](Get-Item $exe).Length
        $json = (ConvertTo-Json -InputObject $feed -Depth 40) + "`n"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        [void](Run 'gh' @('api',"repos/$Repository/contents/update-manifest.json",'-X','PUT','-f',"sha=$($fresh.sha)",
            '-f',"message=Enable PiriCraft $version self-update for $filename",'-f',"content=$encoded"))
        $verify = Get-RemoteManifest
        if ([string]$verify.object.launcher.version -ne $version -or [string]$verify.object.launcher.sha256 -ne $exeHash) { Fail '自動更新マニフェストの読戻し検証に失敗しました' }
        Say "公開・自動更新有効化成功: v$version"
        Say "完成EXE: $exe"
        Say "完成CheckサーバーJAR: $checkOutput"
        Say "GitHub: https://github.com/$Repository/releases/tag/$tag"
        Say 'SUCCESS'
    }
    catch {
        Say ('ERROR: ' + $_.Exception.Message)
        if (-not $published) { Say 'ローカルファイルをバックアップから復元します'; Rollback $backups }
        else { Say 'リリースは作成済みです。安全のためマニフェスト切替前なら旧版のままです。ログを確認してください' }
        throw
    }
    finally { Set-Location $oldLocation }
}
catch {
    Say ('FAILED: ' + $_.Exception.Message)
    exit 1
}