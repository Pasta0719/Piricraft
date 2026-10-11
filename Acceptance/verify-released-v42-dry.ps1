$ErrorActionPreference='Stop'
$repo=$env:GITHUB_REPOSITORY
$work=Join-Path (Get-Location) 'released-v42-check'
New-Item -ItemType Directory -Force $work | Out-Null
$exe=Join-Path $work 'PiriCraftModPublisher.exe'
gh release download mod-publisher-v4.2.0 --repo $repo --pattern PiriCraftModPublisher.exe --dir $work
if($LASTEXITCODE -ne 0){throw 'Unable to download shipped v4.2 EXE'}
$published=gh api "repos/$repo/releases/tags/mod-publisher-v4.2.0" | ConvertFrom-Json
$asset=@($published.assets | Where-Object {$_.name -eq 'PiriCraftModPublisher.exe'})
$hash=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
if($asset.Count -ne 1 -or $asset[0].digest -ne "sha256:$hash"){throw 'Release EXE not matching official sha256'}
Write-Host "RELEASED_V42_EXACT_EXE_SHA_VERIFIED $hash"
$jar=Join-Path $work 'publisher-released-acceptance.jar'
@'
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],"w") as z:
  z.writestr("fabric.mod.json",'{"schemaVersion":1,"id":"publisherreleasedacceptance","version":"1.0","name":"Publisher Released Binary CI","environment":"client"}')
'@ | python - $jar
if($LASTEXITCODE -ne 0){throw 'Fixture JAR preparation failed'}
$log=Join-Path $env:LOCALAPPDATA 'PiriCraftModPublisher/publisher.log'
if(Test-Path $log){Remove-Item $log -Force}
$p=Start-Process -FilePath $exe -ArgumentList @('--integration-test',$jar,'--integration-test-key') -Wait -PassThru -WorkingDirectory $work
if($p.ExitCode -ne 0){
 if(Test-Path $log){Get-Content $log -Tail 120}
 throw "Original released v4.2 EXE end-to-end run failed with $($p.ExitCode)"
}
if(!(Test-Path $log) -or !(Get-Content $log -Raw).Contains('APP_TO_GITHUB_ACTIONS_END_TO_END_PASSED')){
 throw 'Original released v4.2 did not report successful pipeline'
}
Write-Host 'EXACT_RELEASED_V42_TO_GITHUB_DRY_BUILD_AND_GUI_PROCESS_EXIT_PASSED'
