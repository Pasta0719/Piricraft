param()
$ErrorActionPreference='Stop'
$repo=$env:GITHUB_REPOSITORY
$fixture=$env:GITHUB_EVENT_NAME -ne 'workflow_dispatch'
$dry=$fixture -or ($env:INPUT_DRY_RUN -eq 'true')
New-Item -ItemType Directory -Force work,dist | Out-Null
$mode=$env:INPUT_MODE
$target=$env:INPUT_TARGET
$stage=$env:INPUT_STAGE_TAG
$filename=$env:INPUT_FILENAME
if($fixture){
  $mode='add';$target=''
  $filename='test-publisher-cloud.jar'
  @'
import zipfile
with zipfile.ZipFile("work/test-publisher-cloud.jar","w") as z:
  z.writestr("fabric.mod.json",'{"schemaVersion":1,"id":"testpublishercloud","version":"1.0","name":"Publisher CI fixture","environment":"client"}')
'@ | python -
} else {
  if($mode -notin @('add','update','remove')){throw 'Invalid mode'}
  if($mode -ne 'remove' -and $stage -notmatch '^publisher-input-[a-z0-9-]{1,70}
  if($filename -notmatch '^[^\\/]+\.jar$'){throw 'Invalid uploaded JAR file name'}
  if($mode -in @('update','remove') -and $target -notmatch '^mods/[^/]+\.jar
  if($mode -eq 'remove'){
    if($filename -ne [IO.Path]::GetFileName($target)){throw 'Removal filename must equal target basename'}
    if($env:INPUT_SHA256){throw 'Removal must not provide a JAR hash'}
    if($stage){throw 'Removal must not use a staging release'}
  } else {
    gh release download $stage --repo $repo --pattern $filename --dir work
    if($LASTEXITCODE -ne 0){throw 'Cannot download staged JAR'}
    $actual=(Get-FileHash "work/$filename" -Algorithm SHA256).Hash
    if($actual -ne $env:INPUT_SHA256){throw 'Uploaded JAR SHA mismatch'}
  }
}
$release=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$manifest=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($release.content -replace '\s',''))) | ConvertFrom-Json
$old=[string]$manifest.launcher.version
$parts=$old.Split('.')
if($parts.Length -ne 3){throw 'Unexpected published launcher version'}
$parts[2]=[string]([int]$parts[2]+1)
$new=$parts -join '.'
$tag="launcher-v$new"
$oldtag="launcher-v$old"
Write-Host "BASE_VERSION=$old NEXT_VERSION=$new MODE=$mode"
$jar=if($mode -eq 'remove'){'__NO_JAR_ON_REMOVE__'}else{"work/$filename"}
gh release download $oldtag --repo $repo --pattern PiriCraft.exe --dir work
if($LASTEXITCODE -ne 0){throw 'Baseline launcher download failed'}
@'
from pathlib import Path
import sys
sys.path.insert(0,'PiriCraftUpdater')
from patch_launcher import get_bundle
exe=Path("work/PiriCraft.exe").read_bytes()
_,_,entries,_,_=get_bundle(exe)
item=next(x for x in entries if x["path"]=="PiriCraft.dll")
Path("work/PiriCraft.dll").write_bytes(exe[item["off"]:item["off"]+item["size"]])
'@ | python -
if($LASTEXITCODE -ne 0){throw 'Bundle extraction failed'}
$manifest | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath work/manifest.json -Encoding utf8
dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- patch work/PiriCraft.dll work/PiriCraft.updated.dll work/manifest.json work/updated-manifest.json $jar $mode $target $new $repo $tag
if($LASTEXITCODE -ne 0){throw 'Cecil resource patch failed'}
python PiriCraftModPublisher/ServerBuilder/repack.py --base work/PiriCraft.exe --dll work/PiriCraft.updated.dll --out dist/PiriCraft.exe --old $old --new $new
if($LASTEXITCODE -ne 0){throw 'EXE bundle repack failed'}
$env:JAVA_TOOL_OPTIONS='--add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED'
Push-Location PiricraftCheckServer
try {
  ./gradlew.bat --no-daemon build "-PreleaseVersion=$new"
  if($LASTEXITCODE -ne 0){throw 'Check server source build or updater tests failed'}
} finally { Pop-Location }
javac --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -d work PiriCraftModPublisher/ServerBuilder/PatchCheck.java PiriCraftModPublisher/ServerBuilder/TestPatchCheck.java
if($LASTEXITCODE -ne 0){throw 'Check server Java tool compilation failed'}
java --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -cp work PatchCheck PiricraftCheckServer/build/libs/PiricraftCheckServer-1.0.0.jar dist/PiricraftCheckServer-1.0.0.jar work/updated-manifest.json
if($LASTEXITCODE -ne 0){throw 'Check server SHA rewrite failed'}
java --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -cp work TestPatchCheck dist/PiricraftCheckServer-1.0.0.jar work/updated-manifest.json
if($LASTEXITCODE -ne 0){throw 'Check server initialization and manifest validation failed'}
$begin=Get-Date
$p=Start-Process -FilePath (Resolve-Path 'dist/PiriCraft.exe').Path -PassThru
Start-Sleep -Seconds 10
$p.Refresh()
if($p.HasExited){
  if($p.ExitCode -ne 0){throw "Launcher failed Windows smoke test (exit=$($p.ExitCode))"}
} else { Write-Host 'EXE_LIVE_AFTER_10_SECONDS';Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
$crashes=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$begin;Id=1026} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Message -match 'PiriCraft' }
if($crashes){$crashes | ForEach-Object {Write-Host $_.Message};throw 'Windows runtime crash - nothing published'}
Write-Host 'CLOUD_BUILD_AND_WINDOWS_STARTUP_PASS'
if($dry){
  # Verify a SECOND consecutive update is possible without any local sources.
  $nextParts=$new.Split('.')
  $nextParts[2]=[string]([int]$nextParts[2]+1)
  $following=$nextParts -join '.'
  $currentTarget="mods/$filename"
  if($mode -eq 'remove'){
    $afterRemoval=Get-Content work/updated-manifest.json -Raw | ConvertFrom-Json
    if(@($afterRemoval.files | Where-Object {$_.path -eq $target}).Count -ne 0){throw 'Removed MOD remains in manifest'}
    Write-Host 'DRY_REMOVE_MANIFEST_VERIFIED'
  } else {
    dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- patch work/PiriCraft.updated.dll work/PiriCraft.follow.dll work/updated-manifest.json work/follow-manifest.json $jar update $currentTarget $following $repo "launcher-v$following"
  if($LASTEXITCODE -ne 0){throw 'Second consecutive update failed'}
    python PiriCraftModPublisher/ServerBuilder/repack.py --base dist/PiriCraft.exe --dll work/PiriCraft.follow.dll --out dist/PiriCraft.follow.exe --old $new --new $following
    if($LASTEXITCODE -ne 0){throw 'Consecutive launcher repack failed'}
    $again=Start-Process -FilePath (Resolve-Path 'dist/PiriCraft.follow.exe').Path -PassThru
    Start-Sleep -Seconds 5
    $again.Refresh()
    if($again.HasExited -and $again.ExitCode -ne 0){throw 'Follow-up update launcher failed startup'}
    if(!$again.HasExited){Stop-Process -Id $again.Id -Force -ErrorAction SilentlyContinue}
    Write-Host 'DRY_ADD_THEN_UPDATE_AND_RESTART_PASS'
  }
  Write-Host 'DRY_RUN_COMPLETE: no release or automatic update changes'
  exit 0
}
$confirmed=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
if($confirmed.sha -ne $release.sha){throw 'Official MOD list changed during build; refusing to publish stale update'}
$allReleases=gh release list --repo $repo --limit 100 --json tagName | ConvertFrom-Json
if(@($allReleases | Where-Object { $_.tagName -eq $tag }).Count -gt 0){throw "Release $tag exists; refusing replacement"}
gh release create $tag --repo $repo --title "PiriCraft launcher v$new" --notes "Uploaded using PiriCraft MOD Publisher. Validated by Windows startup test."
if($LASTEXITCODE -ne 0){throw 'Cannot create launcher release'}
if($mode -eq 'remove'){
  gh release upload $tag dist/PiriCraft.exe dist/PiricraftCheckServer-1.0.0.jar --repo $repo
} else {
  gh release upload $tag dist/PiriCraft.exe dist/PiricraftCheckServer-1.0.0.jar $jar --repo $repo
}
if($LASTEXITCODE -ne 0){throw 'Release upload failed; automatic update remains unchanged'}
$final=Get-Content work/updated-manifest.json -Raw | ConvertFrom-Json
$final.launcher.version=$new
$final.launcher.url="https://github.com/$repo/releases/download/$tag/PiriCraft.exe"
$final.launcher.sha256=(Get-FileHash dist/PiriCraft.exe -Algorithm SHA256).Hash
$final.launcher.size=[int64](Get-Item dist/PiriCraft.exe).Length
$final | Add-Member -Force -NotePropertyName checkServer -NotePropertyValue @{
  version=$new
  url="https://github.com/$repo/releases/download/$tag/PiricraftCheckServer-1.0.0.jar"
  sha256=(Get-FileHash dist/PiricraftCheckServer-1.0.0.jar -Algorithm SHA256).Hash
  size=[int64](Get-Item dist/PiricraftCheckServer-1.0.0.jar).Length
}
$payload=$final | ConvertTo-Json -Depth 60
$null=$payload | ConvertFrom-Json -Depth 60
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload+"`n"))
$body=@{message="PiriCraft MOD Publisher: update to v$new";content=$encoded;sha=[string]$release.sha} | ConvertTo-Json -Compress
$body | gh api "repos/$repo/contents/update-manifest.json" -X PUT --input -
if($LASTEXITCODE -ne 0){throw 'Failed to activate automatic update'}
$remote=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$verify=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($remote.content -replace '\s',''))) | ConvertFrom-Json
if($verify.launcher.version -ne $new -or $verify.launcher.sha256 -ne $final.launcher.sha256){throw 'Automatic update verification failed'}
Write-Host "AUTO_UPDATE_PUBLISHED_SUCCESS=$new"
){throw 'Invalid staging tag'}
  if($filename -notmatch '^[^\\/]+\.jar$'){throw 'Invalid uploaded JAR file name'}
  if($mode -eq 'update' -and $target -notmatch '^mods/[^/]+\.jar$'){throw 'Invalid existing MOD path'}
  gh release download $stage --repo $repo --pattern $filename --dir work
  if($LASTEXITCODE -ne 0){throw 'Cannot download staged JAR'}
  $actual=(Get-FileHash "work/$filename" -Algorithm SHA256).Hash
  if($actual -ne $env:INPUT_SHA256){throw 'Uploaded JAR SHA mismatch'}
}
$release=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$manifest=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($release.content -replace '\s',''))) | ConvertFrom-Json
$old=[string]$manifest.launcher.version
$parts=$old.Split('.')
if($parts.Length -ne 3){throw 'Unexpected published launcher version'}
$parts[2]=[string]([int]$parts[2]+1)
$new=$parts -join '.'
$tag="launcher-v$new"
$oldtag="launcher-v$old"
Write-Host "BASE_VERSION=$old NEXT_VERSION=$new MODE=$mode"
if($dry){$jar="work/$filename"}else{$jar="work/$filename"}
gh release download $oldtag --repo $repo --pattern PiriCraft.exe --dir work
if($LASTEXITCODE -ne 0){throw 'Baseline launcher download failed'}
@'
from pathlib import Path
import sys
sys.path.insert(0,'PiriCraftUpdater')
from patch_launcher import get_bundle
exe=Path("work/PiriCraft.exe").read_bytes()
_,_,entries,_,_=get_bundle(exe)
item=next(x for x in entries if x["path"]=="PiriCraft.dll")
Path("work/PiriCraft.dll").write_bytes(exe[item["off"]:item["off"]+item["size"]])
'@ | python -
if($LASTEXITCODE -ne 0){throw 'Bundle extraction failed'}
$manifest | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath work/manifest.json -Encoding utf8
dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- patch work/PiriCraft.dll work/PiriCraft.updated.dll work/manifest.json work/updated-manifest.json $jar $mode $target $new $repo $tag
if($LASTEXITCODE -ne 0){throw 'Cecil resource patch failed'}
python PiriCraftModPublisher/ServerBuilder/repack.py --base work/PiriCraft.exe --dll work/PiriCraft.updated.dll --out dist/PiriCraft.exe --old $old --new $new
if($LASTEXITCODE -ne 0){throw 'EXE bundle repack failed'}
$env:JAVA_TOOL_OPTIONS='--add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED'
Push-Location PiricraftCheckServer
try {
  ./gradlew.bat --no-daemon build "-PreleaseVersion=$new"
  if($LASTEXITCODE -ne 0){throw 'Check server source build or updater tests failed'}
} finally { Pop-Location }
javac --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -d work PiriCraftModPublisher/ServerBuilder/PatchCheck.java PiriCraftModPublisher/ServerBuilder/TestPatchCheck.java
if($LASTEXITCODE -ne 0){throw 'Check server Java tool compilation failed'}
java --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -cp work PatchCheck PiricraftCheckServer/build/libs/PiricraftCheckServer-1.0.0.jar dist/PiricraftCheckServer-1.0.0.jar work/updated-manifest.json
if($LASTEXITCODE -ne 0){throw 'Check server SHA rewrite failed'}
java --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -cp work TestPatchCheck dist/PiricraftCheckServer-1.0.0.jar work/updated-manifest.json
if($LASTEXITCODE -ne 0){throw 'Check server initialization and manifest validation failed'}
$begin=Get-Date
$p=Start-Process -FilePath (Resolve-Path 'dist/PiriCraft.exe').Path -PassThru
Start-Sleep -Seconds 10
$p.Refresh()
if($p.HasExited){
  if($p.ExitCode -ne 0){throw "Launcher failed Windows smoke test (exit=$($p.ExitCode))"}
} else { Write-Host 'EXE_LIVE_AFTER_10_SECONDS';Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
$crashes=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$begin;Id=1026} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Message -match 'PiriCraft' }
if($crashes){$crashes | ForEach-Object {Write-Host $_.Message};throw 'Windows runtime crash - nothing published'}
Write-Host 'CLOUD_BUILD_AND_WINDOWS_STARTUP_PASS'
if($dry){
  # Verify a SECOND consecutive update is possible without any local sources.
  $nextParts=$new.Split('.')
  $nextParts[2]=[string]([int]$nextParts[2]+1)
  $following=$nextParts -join '.'
  $currentTarget="mods/$filename"
  dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- patch work/PiriCraft.updated.dll work/PiriCraft.follow.dll work/updated-manifest.json work/follow-manifest.json $jar update $currentTarget $following $repo "launcher-v$following"
  if($LASTEXITCODE -ne 0){throw 'Second consecutive update failed'}
  python PiriCraftModPublisher/ServerBuilder/repack.py --base dist/PiriCraft.exe --dll work/PiriCraft.follow.dll --out dist/PiriCraft.follow.exe --old $new --new $following
  if($LASTEXITCODE -ne 0){throw 'Consecutive launcher repack failed'}
  $again=Start-Process -FilePath (Resolve-Path 'dist/PiriCraft.follow.exe').Path -PassThru
  Start-Sleep -Seconds 5
  $again.Refresh()
  if($again.HasExited -and $again.ExitCode -ne 0){throw 'Follow-up update launcher failed startup'}
  if(!$again.HasExited){Stop-Process -Id $again.Id -Force -ErrorAction SilentlyContinue}
  Write-Host 'DRY_ADD_THEN_UPDATE_AND_RESTART_PASS'
  Write-Host 'DRY_RUN_COMPLETE: no release or automatic update changes'
  exit 0
}
$confirmed=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
if($confirmed.sha -ne $release.sha){throw 'Official MOD list changed during build; refusing to publish stale update'}
$allReleases=gh release list --repo $repo --limit 100 --json tagName | ConvertFrom-Json
if(@($allReleases | Where-Object { $_.tagName -eq $tag }).Count -gt 0){throw "Release $tag exists; refusing replacement"}
gh release create $tag --repo $repo --title "PiriCraft launcher v$new" --notes "Uploaded using PiriCraft MOD Publisher. Validated by Windows startup test."
if($LASTEXITCODE -ne 0){throw 'Cannot create launcher release'}
gh release upload $tag dist/PiriCraft.exe dist/PiricraftCheckServer-1.0.0.jar $jar --repo $repo
if($LASTEXITCODE -ne 0){throw 'Release upload failed; automatic update remains unchanged'}
$final=Get-Content work/updated-manifest.json -Raw | ConvertFrom-Json
$final.launcher.version=$new
$final.launcher.url="https://github.com/$repo/releases/download/$tag/PiriCraft.exe"
$final.launcher.sha256=(Get-FileHash dist/PiriCraft.exe -Algorithm SHA256).Hash
$final.launcher.size=[int64](Get-Item dist/PiriCraft.exe).Length
$final | Add-Member -Force -NotePropertyName checkServer -NotePropertyValue @{
  version=$new
  url="https://github.com/$repo/releases/download/$tag/PiricraftCheckServer-1.0.0.jar"
  sha256=(Get-FileHash dist/PiricraftCheckServer-1.0.0.jar -Algorithm SHA256).Hash
  size=[int64](Get-Item dist/PiricraftCheckServer-1.0.0.jar).Length
}
$payload=$final | ConvertTo-Json -Depth 60
$null=$payload | ConvertFrom-Json -Depth 60
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload+"`n"))
$body=@{message="PiriCraft MOD Publisher: update to v$new";content=$encoded;sha=[string]$release.sha} | ConvertTo-Json -Compress
$body | gh api "repos/$repo/contents/update-manifest.json" -X PUT --input -
if($LASTEXITCODE -ne 0){throw 'Failed to activate automatic update'}
$remote=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$verify=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($remote.content -replace '\s',''))) | ConvertFrom-Json
if($verify.launcher.version -ne $new -or $verify.launcher.sha256 -ne $final.launcher.sha256){throw 'Automatic update verification failed'}
Write-Host "AUTO_UPDATE_PUBLISHED_SUCCESS=$new"
){throw 'Invalid existing MOD path'}
  gh release download $stage --repo $repo --pattern $filename --dir work
  if($LASTEXITCODE -ne 0){throw 'Cannot download staged JAR'}
  $actual=(Get-FileHash "work/$filename" -Algorithm SHA256).Hash
  if($actual -ne $env:INPUT_SHA256){throw 'Uploaded JAR SHA mismatch'}
}
$release=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$manifest=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($release.content -replace '\s',''))) | ConvertFrom-Json
$old=[string]$manifest.launcher.version
$parts=$old.Split('.')
if($parts.Length -ne 3){throw 'Unexpected published launcher version'}
$parts[2]=[string]([int]$parts[2]+1)
$new=$parts -join '.'
$tag="launcher-v$new"
$oldtag="launcher-v$old"
Write-Host "BASE_VERSION=$old NEXT_VERSION=$new MODE=$mode"
if($dry){$jar="work/$filename"}else{$jar="work/$filename"}
gh release download $oldtag --repo $repo --pattern PiriCraft.exe --dir work
if($LASTEXITCODE -ne 0){throw 'Baseline launcher download failed'}
@'
from pathlib import Path
import sys
sys.path.insert(0,'PiriCraftUpdater')
from patch_launcher import get_bundle
exe=Path("work/PiriCraft.exe").read_bytes()
_,_,entries,_,_=get_bundle(exe)
item=next(x for x in entries if x["path"]=="PiriCraft.dll")
Path("work/PiriCraft.dll").write_bytes(exe[item["off"]:item["off"]+item["size"]])
'@ | python -
if($LASTEXITCODE -ne 0){throw 'Bundle extraction failed'}
$manifest | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath work/manifest.json -Encoding utf8
dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- patch work/PiriCraft.dll work/PiriCraft.updated.dll work/manifest.json work/updated-manifest.json $jar $mode $target $new $repo $tag
if($LASTEXITCODE -ne 0){throw 'Cecil resource patch failed'}
python PiriCraftModPublisher/ServerBuilder/repack.py --base work/PiriCraft.exe --dll work/PiriCraft.updated.dll --out dist/PiriCraft.exe --old $old --new $new
if($LASTEXITCODE -ne 0){throw 'EXE bundle repack failed'}
$env:JAVA_TOOL_OPTIONS='--add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED'
Push-Location PiricraftCheckServer
try {
  ./gradlew.bat --no-daemon build "-PreleaseVersion=$new"
  if($LASTEXITCODE -ne 0){throw 'Check server source build or updater tests failed'}
} finally { Pop-Location }
javac --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -d work PiriCraftModPublisher/ServerBuilder/PatchCheck.java PiriCraftModPublisher/ServerBuilder/TestPatchCheck.java
if($LASTEXITCODE -ne 0){throw 'Check server Java tool compilation failed'}
java --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -cp work PatchCheck PiricraftCheckServer/build/libs/PiricraftCheckServer-1.0.0.jar dist/PiricraftCheckServer-1.0.0.jar work/updated-manifest.json
if($LASTEXITCODE -ne 0){throw 'Check server SHA rewrite failed'}
java --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -cp work TestPatchCheck dist/PiricraftCheckServer-1.0.0.jar work/updated-manifest.json
if($LASTEXITCODE -ne 0){throw 'Check server initialization and manifest validation failed'}
$begin=Get-Date
$p=Start-Process -FilePath (Resolve-Path 'dist/PiriCraft.exe').Path -PassThru
Start-Sleep -Seconds 10
$p.Refresh()
if($p.HasExited){
  if($p.ExitCode -ne 0){throw "Launcher failed Windows smoke test (exit=$($p.ExitCode))"}
} else { Write-Host 'EXE_LIVE_AFTER_10_SECONDS';Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
$crashes=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$begin;Id=1026} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Message -match 'PiriCraft' }
if($crashes){$crashes | ForEach-Object {Write-Host $_.Message};throw 'Windows runtime crash - nothing published'}
Write-Host 'CLOUD_BUILD_AND_WINDOWS_STARTUP_PASS'
if($dry){
  # Verify a SECOND consecutive update is possible without any local sources.
  $nextParts=$new.Split('.')
  $nextParts[2]=[string]([int]$nextParts[2]+1)
  $following=$nextParts -join '.'
  $currentTarget="mods/$filename"
  dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- patch work/PiriCraft.updated.dll work/PiriCraft.follow.dll work/updated-manifest.json work/follow-manifest.json $jar update $currentTarget $following $repo "launcher-v$following"
  if($LASTEXITCODE -ne 0){throw 'Second consecutive update failed'}
  python PiriCraftModPublisher/ServerBuilder/repack.py --base dist/PiriCraft.exe --dll work/PiriCraft.follow.dll --out dist/PiriCraft.follow.exe --old $new --new $following
  if($LASTEXITCODE -ne 0){throw 'Consecutive launcher repack failed'}
  $again=Start-Process -FilePath (Resolve-Path 'dist/PiriCraft.follow.exe').Path -PassThru
  Start-Sleep -Seconds 5
  $again.Refresh()
  if($again.HasExited -and $again.ExitCode -ne 0){throw 'Follow-up update launcher failed startup'}
  if(!$again.HasExited){Stop-Process -Id $again.Id -Force -ErrorAction SilentlyContinue}
  Write-Host 'DRY_ADD_THEN_UPDATE_AND_RESTART_PASS'
  Write-Host 'DRY_RUN_COMPLETE: no release or automatic update changes'
  exit 0
}
$confirmed=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
if($confirmed.sha -ne $release.sha){throw 'Official MOD list changed during build; refusing to publish stale update'}
$allReleases=gh release list --repo $repo --limit 100 --json tagName | ConvertFrom-Json
if(@($allReleases | Where-Object { $_.tagName -eq $tag }).Count -gt 0){throw "Release $tag exists; refusing replacement"}
gh release create $tag --repo $repo --title "PiriCraft launcher v$new" --notes "Uploaded using PiriCraft MOD Publisher. Validated by Windows startup test."
if($LASTEXITCODE -ne 0){throw 'Cannot create launcher release'}
gh release upload $tag dist/PiriCraft.exe dist/PiricraftCheckServer-1.0.0.jar $jar --repo $repo
if($LASTEXITCODE -ne 0){throw 'Release upload failed; automatic update remains unchanged'}
$final=Get-Content work/updated-manifest.json -Raw | ConvertFrom-Json
$final.launcher.version=$new
$final.launcher.url="https://github.com/$repo/releases/download/$tag/PiriCraft.exe"
$final.launcher.sha256=(Get-FileHash dist/PiriCraft.exe -Algorithm SHA256).Hash
$final.launcher.size=[int64](Get-Item dist/PiriCraft.exe).Length
$final | Add-Member -Force -NotePropertyName checkServer -NotePropertyValue @{
  version=$new
  url="https://github.com/$repo/releases/download/$tag/PiricraftCheckServer-1.0.0.jar"
  sha256=(Get-FileHash dist/PiricraftCheckServer-1.0.0.jar -Algorithm SHA256).Hash
  size=[int64](Get-Item dist/PiricraftCheckServer-1.0.0.jar).Length
}
$payload=$final | ConvertTo-Json -Depth 60
$null=$payload | ConvertFrom-Json -Depth 60
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload+"`n"))
$body=@{message="PiriCraft MOD Publisher: update to v$new";content=$encoded;sha=[string]$release.sha} | ConvertTo-Json -Compress
$body | gh api "repos/$repo/contents/update-manifest.json" -X PUT --input -
if($LASTEXITCODE -ne 0){throw 'Failed to activate automatic update'}
$remote=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$verify=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($remote.content -replace '\s',''))) | ConvertFrom-Json
if($verify.launcher.version -ne $new -or $verify.launcher.sha256 -ne $final.launcher.sha256){throw 'Automatic update verification failed'}
Write-Host "AUTO_UPDATE_PUBLISHED_SUCCESS=$new"
){throw 'Invalid staging tag'}
  if($filename -notmatch '^[^\\/]+\.jar$'){throw 'Invalid uploaded JAR file name'}
  if($mode -eq 'update' -and $target -notmatch '^mods/[^/]+\.jar$'){throw 'Invalid existing MOD path'}
  gh release download $stage --repo $repo --pattern $filename --dir work
  if($LASTEXITCODE -ne 0){throw 'Cannot download staged JAR'}
  $actual=(Get-FileHash "work/$filename" -Algorithm SHA256).Hash
  if($actual -ne $env:INPUT_SHA256){throw 'Uploaded JAR SHA mismatch'}
}
$release=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$manifest=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($release.content -replace '\s',''))) | ConvertFrom-Json
$old=[string]$manifest.launcher.version
$parts=$old.Split('.')
if($parts.Length -ne 3){throw 'Unexpected published launcher version'}
$parts[2]=[string]([int]$parts[2]+1)
$new=$parts -join '.'
$tag="launcher-v$new"
$oldtag="launcher-v$old"
Write-Host "BASE_VERSION=$old NEXT_VERSION=$new MODE=$mode"
if($dry){$jar="work/$filename"}else{$jar="work/$filename"}
gh release download $oldtag --repo $repo --pattern PiriCraft.exe --dir work
if($LASTEXITCODE -ne 0){throw 'Baseline launcher download failed'}
@'
from pathlib import Path
import sys
sys.path.insert(0,'PiriCraftUpdater')
from patch_launcher import get_bundle
exe=Path("work/PiriCraft.exe").read_bytes()
_,_,entries,_,_=get_bundle(exe)
item=next(x for x in entries if x["path"]=="PiriCraft.dll")
Path("work/PiriCraft.dll").write_bytes(exe[item["off"]:item["off"]+item["size"]])
'@ | python -
if($LASTEXITCODE -ne 0){throw 'Bundle extraction failed'}
$manifest | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath work/manifest.json -Encoding utf8
dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- patch work/PiriCraft.dll work/PiriCraft.updated.dll work/manifest.json work/updated-manifest.json $jar $mode $target $new $repo $tag
if($LASTEXITCODE -ne 0){throw 'Cecil resource patch failed'}
python PiriCraftModPublisher/ServerBuilder/repack.py --base work/PiriCraft.exe --dll work/PiriCraft.updated.dll --out dist/PiriCraft.exe --old $old --new $new
if($LASTEXITCODE -ne 0){throw 'EXE bundle repack failed'}
$env:JAVA_TOOL_OPTIONS='--add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED'
Push-Location PiricraftCheckServer
try {
  ./gradlew.bat --no-daemon build "-PreleaseVersion=$new"
  if($LASTEXITCODE -ne 0){throw 'Check server source build or updater tests failed'}
} finally { Pop-Location }
javac --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -d work PiriCraftModPublisher/ServerBuilder/PatchCheck.java PiriCraftModPublisher/ServerBuilder/TestPatchCheck.java
if($LASTEXITCODE -ne 0){throw 'Check server Java tool compilation failed'}
java --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -cp work PatchCheck PiricraftCheckServer/build/libs/PiricraftCheckServer-1.0.0.jar dist/PiricraftCheckServer-1.0.0.jar work/updated-manifest.json
if($LASTEXITCODE -ne 0){throw 'Check server SHA rewrite failed'}
java --add-exports=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED -cp work TestPatchCheck dist/PiricraftCheckServer-1.0.0.jar work/updated-manifest.json
if($LASTEXITCODE -ne 0){throw 'Check server initialization and manifest validation failed'}
$begin=Get-Date
$p=Start-Process -FilePath (Resolve-Path 'dist/PiriCraft.exe').Path -PassThru
Start-Sleep -Seconds 10
$p.Refresh()
if($p.HasExited){
  if($p.ExitCode -ne 0){throw "Launcher failed Windows smoke test (exit=$($p.ExitCode))"}
} else { Write-Host 'EXE_LIVE_AFTER_10_SECONDS';Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
$crashes=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$begin;Id=1026} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Message -match 'PiriCraft' }
if($crashes){$crashes | ForEach-Object {Write-Host $_.Message};throw 'Windows runtime crash - nothing published'}
Write-Host 'CLOUD_BUILD_AND_WINDOWS_STARTUP_PASS'
if($dry){
  # Verify a SECOND consecutive update is possible without any local sources.
  $nextParts=$new.Split('.')
  $nextParts[2]=[string]([int]$nextParts[2]+1)
  $following=$nextParts -join '.'
  $currentTarget="mods/$filename"
  dotnet run --project PiriCraftModPublisher/ServerBuilder/PiriCraftPatch.csproj -c Release -- patch work/PiriCraft.updated.dll work/PiriCraft.follow.dll work/updated-manifest.json work/follow-manifest.json $jar update $currentTarget $following $repo "launcher-v$following"
  if($LASTEXITCODE -ne 0){throw 'Second consecutive update failed'}
  python PiriCraftModPublisher/ServerBuilder/repack.py --base dist/PiriCraft.exe --dll work/PiriCraft.follow.dll --out dist/PiriCraft.follow.exe --old $new --new $following
  if($LASTEXITCODE -ne 0){throw 'Consecutive launcher repack failed'}
  $again=Start-Process -FilePath (Resolve-Path 'dist/PiriCraft.follow.exe').Path -PassThru
  Start-Sleep -Seconds 5
  $again.Refresh()
  if($again.HasExited -and $again.ExitCode -ne 0){throw 'Follow-up update launcher failed startup'}
  if(!$again.HasExited){Stop-Process -Id $again.Id -Force -ErrorAction SilentlyContinue}
  Write-Host 'DRY_ADD_THEN_UPDATE_AND_RESTART_PASS'
  Write-Host 'DRY_RUN_COMPLETE: no release or automatic update changes'
  exit 0
}
$confirmed=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
if($confirmed.sha -ne $release.sha){throw 'Official MOD list changed during build; refusing to publish stale update'}
$allReleases=gh release list --repo $repo --limit 100 --json tagName | ConvertFrom-Json
if(@($allReleases | Where-Object { $_.tagName -eq $tag }).Count -gt 0){throw "Release $tag exists; refusing replacement"}
gh release create $tag --repo $repo --title "PiriCraft launcher v$new" --notes "Uploaded using PiriCraft MOD Publisher. Validated by Windows startup test."
if($LASTEXITCODE -ne 0){throw 'Cannot create launcher release'}
gh release upload $tag dist/PiriCraft.exe dist/PiricraftCheckServer-1.0.0.jar $jar --repo $repo
if($LASTEXITCODE -ne 0){throw 'Release upload failed; automatic update remains unchanged'}
$final=Get-Content work/updated-manifest.json -Raw | ConvertFrom-Json
$final.launcher.version=$new
$final.launcher.url="https://github.com/$repo/releases/download/$tag/PiriCraft.exe"
$final.launcher.sha256=(Get-FileHash dist/PiriCraft.exe -Algorithm SHA256).Hash
$final.launcher.size=[int64](Get-Item dist/PiriCraft.exe).Length
$final | Add-Member -Force -NotePropertyName checkServer -NotePropertyValue @{
  version=$new
  url="https://github.com/$repo/releases/download/$tag/PiricraftCheckServer-1.0.0.jar"
  sha256=(Get-FileHash dist/PiricraftCheckServer-1.0.0.jar -Algorithm SHA256).Hash
  size=[int64](Get-Item dist/PiricraftCheckServer-1.0.0.jar).Length
}
$payload=$final | ConvertTo-Json -Depth 60
$null=$payload | ConvertFrom-Json -Depth 60
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload+"`n"))
$body=@{message="PiriCraft MOD Publisher: update to v$new";content=$encoded;sha=[string]$release.sha} | ConvertTo-Json -Compress
$body | gh api "repos/$repo/contents/update-manifest.json" -X PUT --input -
if($LASTEXITCODE -ne 0){throw 'Failed to activate automatic update'}
$remote=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$verify=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($remote.content -replace '\s',''))) | ConvertFrom-Json
if($verify.launcher.version -ne $new -or $verify.launcher.sha256 -ne $final.launcher.sha256){throw 'Automatic update verification failed'}
Write-Host "AUTO_UPDATE_PUBLISHED_SUCCESS=$new"
