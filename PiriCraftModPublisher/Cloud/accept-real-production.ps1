$ErrorActionPreference = 'Stop'
$repo=$env:GITHUB_REPOSITORY
$work=Join-Path (Get-Location) "official-test"
New-Item -ItemType Directory -Force $work | Out-Null
$localManifest=Get-Content "update-manifest.json" -Raw | ConvertFrom-Json
$old=[string]$localManifest.launcher.version
if($old -ne "1.1.22"){throw "Unexpected production baseline v$old; aborting acceptance instead of guessing."}
$mod="piri-juggler-fabric-1.0.0.jar"
$target="mods/$mod"
$record=@($localManifest.files | Where-Object { $_.path -eq $target })
if($record.Count -ne 1 -or $record[0].source -ne "embedded"){
  throw "Target MOD is not the exact known official embedded Fabric JAR"
}
$stage="publisher-input-$env:GITHUB_RUN_ID-production"
$staged=$false
try {
  gh release download "launcher-v$old" --repo $repo --pattern "PiriCraft.exe" --dir $work
  if($LASTEXITCODE -ne 0){throw "Could not download official launcher"}
  $expectedLauncher=[string]$localManifest.launcher.sha256
  if((Get-FileHash "$work/PiriCraft.exe" -Algorithm SHA256).Hash -ne $expectedLauncher){
    throw "Original official PiriCraft.exe checksum mismatch"
  }
  @'
from pathlib import Path
import sys
sys.path.insert(0,"PiriCraftUpdater")
from patch_launcher import get_bundle
p=Path("official-test/PiriCraft.exe").read_bytes()
_,_,entries,_,_=get_bundle(p)
dll=next(e for e in entries if e["path"]=="PiriCraft.dll")
Path("official-test/PiriCraft.dll").write_bytes(p[dll["off"]:dll["off"]+dll["size"]])
'@ | python -
  if($LASTEXITCODE -ne 0){throw "Could not inspect official executable bundle"}
  dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- export "$work/PiriCraft.dll" "PiriCraft.Mods.pirijuggler.jar" "$work/$mod"
  if($LASTEXITCODE -ne 0){throw "Could not export official Fabric JAR"}
  $digest=(Get-FileHash "$work/$mod" -Algorithm SHA256).Hash
  if($digest -ne $record[0].sha256){throw "No-op production update file not byte-identical to currently approved MOD"}
  Write-Host "OFFICIAL_MOD_BYTE_IDENTICAL $target $digest"
  gh release create $stage --repo $repo --draft --target main --title "Publisher no-change acceptance" --notes "Temporary, byte-identical official Fabric JAR for real production pipeline validation."
  if($LASTEXITCODE -ne 0){throw "Cannot create production-test staging"}
  $staged=$true
  gh release upload $stage "$work/$mod" --repo $repo
  if($LASTEXITCODE -ne 0){throw "Cannot upload verified JAR"}
  gh workflow run publish-mod-from-app.yml --repo $repo --ref main -f "mode=update" -f "target=$target" -f "stage_tag=$stage" -f "filename=$mod" -f "sha256=$digest" -f "dry_run=false"
  if($LASTEXITCODE -ne 0){throw "Could not dispatch REAL publishing workflow"}
  $runId=$null
  for($i=0;$i -lt 180;$i++){
    Start-Sleep -Seconds 5
    $runs=gh run list --repo $repo --workflow publish-mod-from-app.yml --limit 30 --json databaseId,displayTitle,status,conclusion | ConvertFrom-Json
    $found=@($runs | Where-Object {$_.displayTitle -like "*$stage*"})
    if($found.Count -eq 0){continue}
    $runId=[string]$found[0].databaseId
    if($found[0].status -ne "completed"){continue}
    if($found[0].conclusion -ne "success"){throw "Production publication failed: https://github.com/$repo/actions/runs/$runId"}
    Write-Host "PRODUCTION_RELEASE_PUBLISHED_BY_REAL_WORKFLOW https://github.com/$repo/actions/runs/$runId"
    break
  }
  if($null -eq $runId){throw "Publication workflow did not start"}
  if($found[0].status -ne "completed"){throw "Production publication workflow did not finish"}

  $published=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
  $liveJson=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($published.content -replace '\s',''))) | ConvertFrom-Json
  $new="1.1.23"
  if($liveJson.launcher.version -ne $new){throw "Live auto-updater manifest did not advance to $new"}
  $newMod=@($liveJson.files | Where-Object {$_.path -eq $target})
  if($newMod.Count -ne 1 -or $newMod[0].sha256 -ne $digest){throw "Same bytes MOD not present in final live manifest"}

  gh release download "launcher-v$new" --repo $repo --pattern PiriCraft.exe --dir "$work/published"
  if($LASTEXITCODE -ne 0){throw "Could not download the newly published launcher"}
  gh release download "launcher-v$new" --repo $repo --pattern PiricraftCheckServer-1.0.0.jar --dir "$work/published"
  if($LASTEXITCODE -ne 0){throw "Could not download the published Check server plugin"}
  $expectedNew=[string]$liveJson.launcher.sha256
  $gotNew=(Get-FileHash "$work/published/PiriCraft.exe" -Algorithm SHA256).Hash
  if($expectedNew -ne $gotNew){throw "Published EXE checksum differs from live manifest"}
  if((Get-Item "$work/published/PiriCraft.exe").Length -ne [int64]$liveJson.launcher.size){throw "Published EXE length differs from manifest"}
  if((Get-Item "$work/published/PiricraftCheckServer-1.0.0.jar").Length -lt 1000){throw "Invalid published Check plugin"}
  Write-Host "REAL_PRODUCTION_ASSETS_AND_MANIFEST_VERIFIED $new $expectedNew"

  $installed=Join-Path $work 'installed'
  New-Item -ItemType Directory -Force $installed | Out-Null
  Copy-Item "$work/PiriCraft.exe" "$installed/PiriCraft.exe"
  $begin=Get-Date
  $process=Start-Process -FilePath "$installed/PiriCraft.exe" -WorkingDirectory $installed -PassThru
  $upgraded=$false
  for($i=0;$i -lt 90;$i++){
    Start-Sleep -Seconds 2
    if(Test-Path "$installed/PiriCraft.exe"){
      try{$actual=(Get-FileHash "$installed/PiriCraft.exe" -Algorithm SHA256).Hash}catch{continue}
      if($actual -eq $expectedNew){Write-Host "RUNNING_OLD_LAUNCHER_SELF_UPDATED_IN_SECONDS $($i*2+2)";$upgraded=$true;break}
    }
  }
  if(-not $upgraded){
    $log=Join-Path $env:LOCALAPPDATA 'PiriCraft/debug.log'
    if(Test-Path $log){Get-Content $log -Tail 80}
    throw "Actual v$old launcher did not download and install v$new"
  }
  Start-Sleep -Seconds 6
  $crashes=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$begin;Id=1026} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Message -match 'PiriCraft' }
  if($crashes){$crashes | ForEach-Object {Write-Host $_.Message};throw "Launcher crashed during genuine automatic update"}
  Write-Host "REAL_PRODUCTION_PUBLICATION_AND_AUTOUPDATE_PASSED"
} finally {
  if($staged){
    gh release delete $stage --repo $repo --yes --cleanup-tag
    if($LASTEXITCODE -ne 0){Write-Warning "Staged acceptance asset requires manual cleanup: $stage"}
  }
}
