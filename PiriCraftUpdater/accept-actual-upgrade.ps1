$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force diag/upgrade | Out-Null
$homeDir=(Resolve-Path "diag/upgrade").Path
$exe=Join-Path $homeDir 'PiriCraft.exe'
gh release download launcher-v1.1.21 --repo "$env:GITHUB_REPOSITORY" --pattern PiriCraft.exe --dir $homeDir
if ($LASTEXITCODE -ne 0) { throw "Failed to obtain v1.1.21 baseline" }
$old="7457D259481445171ADBC945A163564AADA4DC2303DA8B2504EB15A09EE7CE69"
$new="112CBB4B5B4C94EC1C6188D790FDB6E650491EAFB1D40E11B23DE5C288F81D5E"
if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $old) { throw "Wrong baseline EXE" }
$start=Get-Date
Write-Host "UPGRADE_START $($start.ToString('o'))"
$proc=Start-Process -FilePath $exe -WorkingDirectory $homeDir -PassThru
$upgraded=$false
for ($i=0; $i -lt 26; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Path $exe) {
      $current=(Get-FileHash $exe -Algorithm SHA256).Hash
      if ($current -eq $new) { Write-Host "UPDATED_EXE_REPLACED_AFTER $($i*2+2) seconds"; $upgraded=$true;break }
    }
}
Start-Sleep -Seconds 5
$log=Join-Path $env:LOCALAPPDATA 'PiriCraft/debug.log'
if (Test-Path $log) {
  Write-Host 'LAUNCHER_LOG_TAIL'
  Get-Content $log -Tail 30
}
$crashes=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$start;Id=1026} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -eq '.NET Runtime' -and $_.Message -match 'PiriCraft' }
if ($crashes) { $crashes | ForEach-Object {Write-Host "CLR_CRASH" $_.Message}; throw "Automated update reproduced a .NET crash" }
if (-not $upgraded) { throw "v1.1.21 did not successfully replace itself with v1.1.22" }
Write-Host 'END_TO_END_AUTO_UPDATE_PASSED'
