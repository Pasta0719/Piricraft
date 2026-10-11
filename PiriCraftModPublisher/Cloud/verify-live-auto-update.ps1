$ErrorActionPreference='Stop'
$repo=$env:GITHUB_REPOSITORY
$work=Join-Path (Get-Location) "live-upgrade-proof"
New-Item -ItemType Directory -Force "$work/installed","$work/expected" | Out-Null
$raw=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$manifest=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($raw.content -replace '\s','')))
try{$live=$manifest | ConvertFrom-Json -Depth 64}catch{throw 'LIVE_MANIFEST_JSON_INVALID: '+$_}
if($live.launcher.version -ne '1.1.23'){throw "Wrong target version: $($live.launcher.version)"}
$entry=@($live.files|Where-Object{$_.path -eq 'mods/piri-juggler-fabric-1.0.0.jar'})
if($entry.Count -ne 1 -or $entry[0].sha256 -ne '0FA5B2C12E4E8D59D728F5485ECFC6A002CA6B04750D2E8BC775B3F0DFA2B083'){throw 'Real MOD SHA changed; abort'}
gh release download launcher-v1.1.22 --repo $repo --pattern PiriCraft.exe --dir "$work/installed"
if($LASTEXITCODE -ne 0){throw 'Cannot obtain official v1.1.22 launcher'}
gh release download launcher-v1.1.23 --repo $repo --pattern PiriCraft.exe --dir "$work/expected"
if($LASTEXITCODE -ne 0){throw 'Cannot obtain production v1.1.23 launcher'}
gh release download launcher-v1.1.23 --repo $repo --pattern PiricraftCheckServer-1.0.0.jar --dir "$work/expected"
if($LASTEXITCODE -ne 0){throw 'Cannot obtain Check server JAR'}
$expectedHash=[string]$live.launcher.sha256
$actual=(Get-FileHash "$work/expected/PiriCraft.exe" -Algorithm SHA256).Hash
if($actual -ne $expectedHash){throw 'Production released launcher bytes do not match updater manifest'}
if((Get-Item "$work/expected/PiriCraft.exe").Length -ne [int64]$live.launcher.size){throw 'Production released launcher size mismatch'}
if((Get-Item "$work/expected/PiricraftCheckServer-1.0.0.jar").Length -lt 1000){throw 'Check server JAR missing or empty'}
Write-Host "PRODUCTION_MANIFEST_AND_RELEASE_BYTES_MATCH $expectedHash"
$start=Get-Date
$process=Start-Process -FilePath "$work/installed/PiriCraft.exe" -WorkingDirectory "$work/installed" -PassThru
$updated=$false
for($i=0;$i -lt 120;$i++){
  Start-Sleep -Seconds 2
  try{
    if(Test-Path "$work/installed/PiriCraft.exe"){
      $current=(Get-FileHash "$work/installed/PiriCraft.exe" -Algorithm SHA256).Hash
      if($current -eq $expectedHash){
        Write-Host "REAL_OLD_CLIENT_AUTO_UPGRADED seconds=$($i*2+2)"
        $updated=$true;break
      }
    }
  }catch{
    # Updater may temporarily replace/lock the destination EXE.
  }
}
if(-not $updated){
  $log=Join-Path $env:LOCALAPPDATA 'PiriCraft/debug.log'
  if(Test-Path $log){Get-Content $log -Tail 70}
  throw 'REAL_CLIENT_DID_NOT_AUTO_UPDATE'
}
Start-Sleep -Seconds 7
$crashes=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$start;Id=1026} -ErrorAction SilentlyContinue |
  Where-Object{$_.ProviderName -eq '.NET Runtime' -and $_.Message -match 'PiriCraft'}
if($crashes){$crashes | ForEach-Object {Write-Host "DOTNET_CRASH" $_.Message};throw 'Real auto-update caused CLR crash'}
Write-Host 'REAL_PRODUCTION_LAUNCHER_AUTO_UPDATE_E2E_PASSED'
