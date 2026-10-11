$ErrorActionPreference = 'Stop'
$repo=$env:GITHUB_REPOSITORY
$stageDir=Join-Path (Get-Location) 'actual-v42-e2e'
New-Item -ItemType Directory -Force $stageDir | Out-Null
$log=Join-Path $env:LOCALAPPDATA 'PiriCraftModPublisher/publisher.log'
$baseline=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$before=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($baseline.content -replace '\s',''))) | ConvertFrom-Json
$old=[string]$before.launcher.version
if($old -ne '1.1.23'){throw "Wrong production baseline v$old; refusing unplanned live modification"}
$path='mods/piri-juggler-fabric-1.0.0.jar'
$entry=@($before.files | Where-Object {$_.path -eq $path})
if($entry.Count -ne 1){throw 'Target official JAR not found'}
gh release download "launcher-v$old" --repo $repo --pattern 'piri-juggler-fabric-1.0.0.jar' --dir $stageDir
if($LASTEXITCODE -ne 0){throw 'Unable to obtain byte-identical production mod'}
$jar=(Resolve-Path "$stageDir/piri-juggler-fabric-1.0.0.jar").Path
$hash=(Get-FileHash $jar -Algorithm SHA256).Hash
if($hash -ne $entry[0].sha256){throw 'JAR bytes are NOT identical to official production mod'}
gh release download mod-publisher-v4.2.0 --repo $repo --pattern 'PiriCraftModPublisher.exe' --dir $stageDir
if($LASTEXITCODE -ne 0){throw 'Unable to obtain actual released v4.2 publisher'}
$exe=(Resolve-Path "$stageDir/PiriCraftModPublisher.exe").Path
$release=gh api "repos/$repo/releases/tags/mod-publisher-v4.2.0" | ConvertFrom-Json
$asset=@($release.assets | Where-Object {$_.name -eq 'PiriCraftModPublisher.exe'})
if($asset.Count -ne 1){throw 'Released publisher EXE missing or duplicated'}
$actual=(Get-FileHash $exe -Algorithm SHA256).Hash
if("sha256:$($actual.ToLowerInvariant())" -ne $asset[0].digest){throw 'Released v4.2 EXE SHA256 mismatch'}
Write-Host "EXACT_RELEASE_V42_EXE_HASH_VERIFIED $actual"
Write-Host "BYTE_IDENTICAL_OFFICIAL_MOD_VERIFIED $hash"
# Run as ordinary Windows user with scoped GitHub Actions token, no shared token embedded in EXE.
if(Test-Path $log){Remove-Item $log -Force}
$proc=Start-Process -FilePath $exe -WorkingDirectory $stageDir -PassThru
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class PublisherWin32 {
  public delegate bool EnumCallback(IntPtr hwnd, IntPtr param);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string klass, string text);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumChildWindows(IntPtr parent, EnumCallback callback, IntPtr param);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder output, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder output, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SetWindowText(IntPtr hwnd, string text);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr a, IntPtr b);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr a, string b);
  public class Ctrl {
    public IntPtr hwnd;
    public string klass;
    public string label;
    public long style;
  }
  public static List<Ctrl> Children(IntPtr parent) {
    var result=new List<Ctrl>();
    EnumChildWindows(parent, (h, p)=>{
      var cl=new StringBuilder(256); var label=new StringBuilder(1024);
      GetClassName(h,cl,cl.Capacity); GetWindowText(h,label,label.Capacity);
      result.Add(new Ctrl{hwnd=h,klass=cl.ToString(),label=label.ToString(),style=GetWindowLongPtr(h,-16).ToInt64()});
      return true;
    },IntPtr.Zero);
    return result;
  }
}
'@
$window=[IntPtr]::Zero
for($i=0;$i -lt 60;$i++){
  Start-Sleep -Milliseconds 500
  $window=[PublisherWin32]::FindWindow($null,'PiriCraft MOD Publisher v4.2')
  if($window -ne [IntPtr]::Zero){break}
}
if($window -eq [IntPtr]::Zero){throw 'Actual released v4.2 GUI never opened'}
# Wait for the real official mod list to populate.
$combo=[IntPtr]::Zero
for($i=0;$i -lt 90;$i++){
  $children=[PublisherWin32]::Children($window)
  $list=@($children | Where-Object {$_.klass -like '*COMBOBOX*'})
  if($list.Count -ge 1){
    $combo=$list[0].hwnd
    $count=[PublisherWin32]::SendMessage($combo,0x146,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
    if($count -ge 10){break}
  }
  Start-Sleep -Seconds 1
}
if($combo -eq [IntPtr]::Zero -or $count -lt 10){throw 'Real v4.2 failed to load official MOD manifest into ComboBox'}
$targetIndex=-1
for($i=0;$i -lt $count;$i++){
  $str=New-Object System.Text.StringBuilder 1024
  # Real ComboBox CB_GETLBTEXT copies into unmanaged buffer.
  $mem=[Runtime.InteropServices.Marshal]::AllocHGlobal(2048)
  try{
    [Runtime.InteropServices.Marshal]::WriteInt16($mem,0)
    [void][PublisherWin32]::SendMessage($combo,0x148,[IntPtr]$i,$mem)
    $value=[Runtime.InteropServices.Marshal]::PtrToStringUni($mem)
    if($value -like 'piri-juggler-fabric-1.0.0.jar*'){$targetIndex=$i;break}
  }finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($mem)}
}
if($targetIndex -lt 0){throw 'Target PiriJuggler not shown in actual v4.2 update dropdown'}
[void][PublisherWin32]::SendMessage($combo,0x14e,[IntPtr]$targetIndex,[IntPtr]::Zero)
$selected=[PublisherWin32]::SendMessage($combo,0x147,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
if($selected -ne $targetIndex){throw 'Cannot select official target in actual v4.2 app'}
Write-Host "ACTUAL_V42_GUI_SELECTED_OFFICIAL_MOD_INDEX $selected"
# WinForms ReadOnly text box single-line is the selected JAR path, not the credential field or multiline log.
$children=[PublisherWin32]::Children($window)
$edits=@($children | Where-Object {$_.klass -like '*EDIT*' -and ($_.style -band 0x800) -ne 0 -and ($_.style -band 0x4) -eq 0})
if($edits.Count -ne 1){throw "Could not uniquely identify JAR picker text field (count=$($edits.Count))"}
if(-not [PublisherWin32]::SetWindowText($edits[0].hwnd,$jar)){throw 'Could not set new JAR path in actual GUI'}
$buttons=@($children | Where-Object {$_.klass -like '*BUTTON*' -and $_.label -like '更新する*'})
if($buttons.Count -ne 1){throw "Cannot uniquely identify publish button (count=$($buttons.Count))"}
# Click ACTUAL publish button, not a CLI substitute. Click results in actual confirmation popup.
[void][PublisherWin32]::SendMessage($buttons[0].hwnd,0xf5,[IntPtr]::Zero,[IntPtr]::Zero)
$dialog=[IntPtr]::Zero
for($i=0;$i -lt 50;$i++){
  Start-Sleep -Milliseconds 200
  $dialog=[PublisherWin32]::FindWindow('#32770','確認')
  if($dialog -ne [IntPtr]::Zero){break}
}
if($dialog -eq [IntPtr]::Zero){throw 'Clicking actual publish button did not open the production confirmation dialog'}
$confirms=[PublisherWin32]::Children($dialog)
$yes=@($confirms|Where-Object {$_.klass -eq 'Button' -and $_.label -in @('Yes','はい','&Yes')})
if($yes.Count -ne 1){throw "Unable to find explicit user confirmation button: $($confirms.label -join ' | ')"}
[void][PublisherWin32]::SendMessage($yes[0].hwnd,0xf5,[IntPtr]::Zero,[IntPtr]::Zero)
Write-Host 'RELEASED_V42_GUI_REAL_PUBLISH_CONFIRMED'
$done=$false
for($i=0;$i -lt 230;$i++){
  Start-Sleep -Seconds 5
  if(Test-Path $log){
    $logText=Get-Content $log -Raw
    if($logText.Contains('更新失敗') -or $logText.Contains('ERROR ')){throw "Actual EXE reported failure. Log: $logText"}
    if($logText.Contains('4/4 公開成功') -or $logText.Contains('完成: https://github.com/Pasta0719/Piricraft/actions/runs/')){
      $done=$true;break
    }
  }
  if($i%12 -eq 0){Write-Host "WAITING_RELEASED_V42_CLOUD_PUBLISH elapsed=$($i*5)s"}
}
if(-not $done){throw 'Released EXE never reported successful real production build'}
Write-Host "ACTUAL_V42_EXE_PRODUCTION_WORKFLOW_COMPLETED"
# The release workflows update the manifest after asset publication. Verify all data after the actual binary completed.
$newData=gh api "repos/$repo/contents/update-manifest.json" | ConvertFrom-Json
$after=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($newData.content -replace '\s',''))) | ConvertFrom-Json
$oldParts=$old.Split('.')
$oldParts[2]=[string]([int]$oldParts[2]+1)
$next=$oldParts -join '.'
if($after.launcher.version -ne $next){throw "Real v4.2 did not advance production launcher version to expected $next"}
$targetAfter=@($after.files|Where-Object{$_.path -eq $path})
if($targetAfter.Count -ne 1 -or $targetAfter[0].sha256 -ne $hash){throw 'Real production MOD bytes changed unexpectedly'}
gh release download "launcher-v$next" --repo $repo --pattern PiriCraft.exe --dir "$stageDir/new-release"
if($LASTEXITCODE -ne 0){throw 'Real production launcher release missing'}
$expectedHash=[string]$after.launcher.sha256
$received=(Get-FileHash "$stageDir/new-release/PiriCraft.exe" -Algorithm SHA256).Hash
if($expectedHash -ne $received){throw 'New production launcher does not match official manifest SHA'}
Write-Host "RELEASED_V42_TO_REAL_PRODUCTION_MANIFEST_PASSED version=$next launcherSHA=$received"
# Clean up GUI success dialog and process if still running.
if(-not $proc.HasExited){Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue}
