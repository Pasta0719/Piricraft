$ErrorActionPreference="Stop"
$env:DOTNET_HOST_TRACE="1"
$env:DOTNET_HOST_TRACE_VERBOSITY="4"
$env:COREHOST_TRACE="1"
$env:COREHOST_TRACE_VERBOSITY="4"
New-Item -ItemType Directory -Force "diag" | Out-Null

function Test-Launcher($tag) {
    $exe=Join-Path (Resolve-Path ".").Path ("diag/"+$tag+"/PiriCraft.exe")
    New-Item -ItemType Directory -Force (Split-Path $exe) | Out-Null
    gh release download $tag --repo "$env:GITHUB_REPOSITORY" --pattern "PiriCraft.exe" --dir (Split-Path $exe)
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $tag" }
    $logFile=Join-Path (Resolve-Path ".").Path ("diag/"+$tag+"/host-trace.txt")
    $env:DOTNET_HOST_TRACEFILE=$logFile
    $env:COREHOST_TRACEFILE=$logFile
    $start=Get-Date
    Write-Host "START_TEST $tag $($start.ToString('o')) SHA256=$((Get-FileHash $exe -Algorithm SHA256).Hash)"
    try {
        $p=Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru -ErrorAction Stop
        Write-Host "START_PROCESS $tag pid=$($p.Id)"
        Start-Sleep -Seconds 12
        $p.Refresh()
        if ($p.HasExited) { Write-Host "PROCESS_EXIT $tag code=$($p.ExitCode)" }
        else {
            Write-Host "PROCESS_LIVE_AFTER_12SEC $tag"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch { Write-Host "START_EXCEPTION $tag $($_.Exception.ToString())" }
    if (Test-Path $logFile) {
        Write-Host "TRACE_TAIL $tag"
        Get-Content $logFile -Tail 120
    }
    $userlog=Join-Path $env:LOCALAPPDATA "PiriCraft/debug.log"
    if (Test-Path $userlog) {
      Write-Host "LAUNCHER_LOG_TAIL $tag"
      Get-Content $userlog -Tail 15
    }
    $events=Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$start} -ErrorAction SilentlyContinue |
      Where-Object { $_.ProviderName -in @('.NET Runtime','Application Error','Windows Error Reporting') } |
      Select-Object -First 15
    foreach($e in $events) { Write-Host "WINDOWS_EVENT $tag $($e.Id) $($e.ProviderName): $($e.Message.Substring(0,[Math]::Min($e.Message.Length,2000)))" }
}
Test-Launcher "launcher-v1.1.21"
Test-Launcher "launcher-v1.1.22"
