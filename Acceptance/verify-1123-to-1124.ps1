$ErrorActionPreference='Stop'
$repo=$env:GITHUB_REPOSITORY
$dir=Join-Path (Get-Location) 'verify-1123-to-1124'
New-Item -ItemType Directory -Force "$dir/old","$dir/new" | Out-Null
$m=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$live=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($m.content -replace '\s',''))) | ConvertFrom-Json -Depth 60
if($live.launcher.version -ne '1.1.24'){throw 'Wrong live version'}
gh release download launcher-v1.1.23 --repo $repo --pattern PiriCraft.exe --dir "$dir/old"
if($LASTEXITCODE -ne 0){throw 'Cannot get old EXE'}
gh release download launcher-v1.1.24 --repo $repo --pattern PiriCraft.exe --dir "$dir/new"
if($LASTEXITCODE -ne 0){throw 'Cannot get new EXE'}
$hash=(Get-FileHash "$dir/new/PiriCraft.exe" -Algorithm SHA256).Hash
if($hash -ne $live.launcher.sha256){throw 'New SHA mismatch'}
$start=Get-Date
$p=Start-Process -FilePath (Resolve-Path "$dir/old/PiriCraft.exe").Path -WorkingDirectory (Resolve-Path "$dir/old").Path -PassThru
$ok=$false
for($i=0;$i -lt 75;$i++){
  Start-Sleep -Seconds 2
  try{
    if((Get-FileHash "$dir/old/PiriCraft.exe" -Algorithm SHA256).Hash -eq $hash){
      Write-Host "REAL_1123_TO_1124_SELF_UPGRADE_DONE elapsedSeconds=$($i*2+2)"
      $ok=$true
      break
    }
  }catch{}
}
if(-not $ok){
  $log=Join-Path $env:LOCALAPPDATA 'PiriCraft/debug.log'
  if(Test-Path $log){Get-Content $log -Tail 100}
  throw 'Old launcher did not auto-upgrade to 1.1.24'
}
Start-Sleep -Seconds 5
$bad=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$start;Id=1026} -ErrorAction SilentlyContinue | Where-Object{$_.Message -match 'PiriCraft'}
if($bad){$bad|ForEach-Object{Write-Host $_.Message};throw 'CLR crash during upgrade'}
Write-Host 'REAL_RELEASED_1123_TO_1124_UPGRADE_AND_CRASH_CHECK_PASSED'
