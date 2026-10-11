$ErrorActionPreference='Stop'
$repo=$env:GITHUB_REPOSITORY
$tag="publisher-input-$env:GITHUB_RUN_ID-ci"
$jar="integration-cloud-$($env:GITHUB_RUN_ID).jar"
$input=Join-Path (Get-Location) $jar
@'
import zipfile,sys
with zipfile.ZipFile(sys.argv[1],'w') as z:
  z.writestr('fabric.mod.json','{"schemaVersion":1,"id":"integrationcloudtest","version":"1.0.0","name":"Integration Test","environment":"client"}')
'@ | python - $input
if($LASTEXITCODE -ne 0){throw "Cannot create staged test JAR"}
$sha=(Get-FileHash $input -Algorithm SHA256).Hash
try{
  gh release create $tag --repo $repo --draft --target main --title "CI staged MOD" --notes "Temporary integration test"
  if($LASTEXITCODE -ne 0){throw "Cannot create staging release"}
  gh release upload $tag $input --repo $repo
  if($LASTEXITCODE -ne 0){throw "Cannot upload staging JAR"}
  gh workflow run publish-mod-from-app.yml --repo $repo --ref main -f mode=add -f target= -f stage_tag=$tag -f filename=$jar -f sha256=$sha -f dry_run=true
  if($LASTEXITCODE -ne 0){throw "Cannot dispatch cloud publisher"}
  $seen=$false
  for($i=0;$i -lt 100;$i++){
    Start-Sleep -Seconds 5
    $runs=gh run list --repo $repo --workflow publish-mod-from-app.yml --limit 20 --json databaseId,displayTitle,status,conclusion | ConvertFrom-Json
    $match=@($runs|Where-Object {$_.displayTitle -like "*$tag*"})
    if(!$match.Count){continue}
    $seen=$true
    $run=$match[0]
    Write-Host "STAGING_PUBLISH_RUN id=$($run.databaseId) status=$($run.status) conclusion=$($run.conclusion)"
    if($run.status -ne 'completed'){continue}
    if($run.conclusion -ne 'success'){throw "Staging cloud publisher failed: https://github.com/$repo/actions/runs/$($run.databaseId)"}
    Write-Host 'STAGING_TO_WINDOWS_CLOUD_PUBLISHER_PASSED'
    exit 0
  }
  if(!$seen){throw "No staging workflow was started"}
  throw "Staging workflow did not complete"
} finally {
  gh release delete $tag --repo $repo --yes --cleanup-tag 2>$null
}
