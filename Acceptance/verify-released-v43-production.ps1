$ErrorActionPreference='Stop'
$repo=$env:GITHUB_REPOSITORY
$checkDir=Join-Path (Get-Location) 'production-v43-check'
New-Item -ItemType Directory -Force "$checkDir/baseline","$checkDir/released","$checkDir/old-client" | Out-Null
$log=Join-Path $env:LOCALAPPDATA 'PiriCraftModPublisher/publisher.log'
$original=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$manifest=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($original.content -replace '\s',''))) | ConvertFrom-Json -Depth 80
$old=[string]$manifest.launcher.version
if($old -ne '1.1.23'){throw "Unexpected live version $old, aborting no-op acceptance"}
$modPath='mods/piri-juggler-fabric-1.0.0.jar'
$originalMod=@($manifest.files|Where-Object{$_.path -eq $modPath})
if($originalMod.Count -ne 1){throw 'Official mod not found'}
gh release download "launcher-v$old" --repo $repo --pattern 'piri-juggler-fabric-1.0.0.jar' --dir "$checkDir/baseline"
if($LASTEXITCODE -ne 0){throw 'Cannot get official mod JAR'}
$jar=(Resolve-Path "$checkDir/baseline/piri-juggler-fabric-1.0.0.jar").Path
$modHash=(Get-FileHash $jar -Algorithm SHA256).Hash
if($modHash -ne $originalMod[0].sha256){throw 'Test input JAR not byte-identical to official production MOD'}
Write-Host "ACCEPTANCE_MOD_BYTE_IDENTICAL $modHash"
gh release download mod-publisher-v4.3.0 --repo $repo --pattern PiriCraftModPublisher.exe --dir "$checkDir/released"
if($LASTEXITCODE -ne 0){throw 'Released v4.3 EXE not available'}
$exe=(Resolve-Path "$checkDir/released/PiriCraftModPublisher.exe").Path
$rel=gh api "repos/$repo/releases/tags/mod-publisher-v4.3.0" | ConvertFrom-Json
$releasedEXE=@($rel.assets | Where-Object {$_.name -eq 'PiriCraftModPublisher.exe'})
if($releasedEXE.Count -ne 1){throw 'Missing exact released EXE'}
$exeHash=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
if($releasedEXE[0].digest -ne "sha256:$exeHash"){throw 'EXE digest mismatch with public GitHub release'}
Write-Host "RELEASED_V43_EXE_SHA256_MATCH $exeHash"
if(Test-Path $log){Remove-Item $log -Force}
$p=Start-Process -FilePath $exe -WorkingDirectory $checkDir -ArgumentList @('--production-acceptance',$jar,$modPath) -Wait -PassThru
if($p.ExitCode -ne 0){
  if(Test-Path $log){Get-Content $log -Tail 120}
  throw "Released v4.3 GUI Publisher rejected or failed REAL publication, exit=$($p.ExitCode)"
}
if(!(Test-Path $log) -or !(Get-Content $log -Raw).Contains('APP_TO_REAL_PRODUCTION_AUTOUPDATE_PASSED')){
  throw 'Missing exact EXE acceptance success marker after actual process completed'
}
Write-Host "RELEASED_V43_EXE_TO_GITHUB_PRODUCTION_WORKFLOW_PASSED"
$newLive=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$newJson=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($newLive.content -replace '\s',''))) | ConvertFrom-Json -Depth 80
$parts=$old.Split('.');$parts[2]=[string]([int]$parts[2]+1);$next=$parts -join '.'
if($newJson.launcher.version -ne $next){throw "Real acceptance version mismatch expected $next"}
$newMod=@($newJson.files | Where-Object {$_.path -eq $modPath})
if($newMod.Count -ne 1 -or $newMod[0].sha256 -ne $modHash){throw 'Real publisher damaged official MOD'}
gh release download "launcher-v$next" --repo $repo --pattern PiriCraft.exe --dir "$checkDir/released"
if($LASTEXITCODE -ne 0){throw 'New launcher release missing'}
gh release download "launcher-v$next" --repo $repo --pattern PiricraftCheckServer-1.0.0.jar --dir "$checkDir/released"
if($LASTEXITCODE -ne 0){throw 'New Check JAR release missing'}
$pubHash=(Get-FileHash "$checkDir/released/PiriCraft.exe" -Algorithm SHA256).Hash
if($pubHash -ne $newJson.launcher.sha256){throw 'New release EXE differs from active manifest'}
if((Get-Item "$checkDir/released/PiriCraft.exe").Length -ne [int64]$newJson.launcher.size){throw 'New release EXE size differs'}
Write-Host "EXACT_EXE_PRODUCTION_ASSET_VERIFIED v$next SHA256=$pubHash"
gh release download "launcher-v$old" --repo $repo --pattern PiriCraft.exe --dir "$checkDir/old-client"
if($LASTEXITCODE -ne 0){throw 'Old baseline EXE unavailable'}
$oldHash=(Get-FileHash "$checkDir/old-client/PiriCraft.exe" -Algorithm SHA256).Hash
if($oldHash -ne $manifest.launcher.sha256){throw 'Baseline client download SHA does not match old manifest'}
$start=Get-Date
$upgrade=Start-Process -FilePath "$checkDir/old-client/PiriCraft.exe" -WorkingDirectory "$checkDir/old-client" -PassThru
$success=$false
for($i=0;$i -lt 110;$i++){
  Start-Sleep -Seconds 2
  try {
    if((Get-FileHash "$checkDir/old-client/PiriCraft.exe" -Algorithm SHA256).Hash -eq $pubHash){
      Write-Host "RELEASED_OLD_LAUNCHER_ACTUAL_SELF_UPGRADE_SECONDS $($i*2+2)"
      $success=$true;break
    }
  }catch{}
}
if(!$success){
  $debug=Join-Path $env:LOCALAPPDATA 'PiriCraft/debug.log'
  if(Test-Path $debug){Get-Content $debug -Tail 100}
  throw 'Real old launcher failed self upgrade to new production release'
}
Start-Sleep -Seconds 5
$errors=Get-WinEvent -FilterHashtable @{LogName='Application';Id=1026;StartTime=$start} -ErrorAction SilentlyContinue | Where-Object {$_.Message -match 'PiriCraft'}
if($errors){$errors|ForEach-Object{Write-Host $_.Message};throw 'Launcher .NET process crashed during real auto-update'}
Write-Host "RELEASED_V43_GUI_TO_REAL_PRODUCTION_TO_OLD_CLIENT_AUTOUPDATE_ALL_PASSED"
