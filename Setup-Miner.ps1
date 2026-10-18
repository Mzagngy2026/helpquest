#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-mining for Windows: benchmarks the machine, picks the most profitable
    coin + miner for THIS hardware, mines it, and keeps mining forever.

.DESCRIPTION
    Run once as Administrator. The script:
      1. Detects CPU and GPUs.
      2. Installs the right open/legit miners from their official GitHub releases:
           XMRig (CPU), Rigel + T-Rex (NVIDIA), lolMiner (AMD).
      3. Pulls live coin prices/rewards from the minerstat public API.
      4. Benchmarks every candidate coin you have a wallet for (~90 s each)
         and computes USD/day for each on this exact machine.
      5. Starts the winner on CPU and on GPU (separately).
      6. Installs a watchdog (every 5 min) that restarts dead/hung miners and,
         once a day, re-checks profitability and switches coin if something
         else earns >10% more.
      7. Disables sleep/hibernate, registers logon tasks, optional auto-logon.

    Only coins with a wallet address in $WALLETS are considered. Leave a coin
    blank to skip it. The script still prints what EVERY coin would earn so
    you can see whether adding a wallet is worth it.

.PARAMETER ThreadsIdle         CPU % for mining while the PC is idle (default 95).
.PARAMETER ActiveCap           Max mining % while you work (default 70). Drops further if your own load is high.
.PARAMETER ActiveFloor         Minimum mining % while you work (default 20).
.PARAMETER Headroom            % always left free for Windows (default 5).
.PARAMETER Step                Scaling step (default 10): 70 -> 60 -> 50 ...
.PARAMETER IdleSeconds         Seconds without keyboard/mouse before "idle" (default 60).
.PARAMETER Priority            XMRig thread priority 0-5 (default 2).
.PARAMETER BenchSeconds        Seconds per benchmark (default 90).
.PARAMETER Rebench             Ignore cached benchmarks and measure again.
.PARAMETER NoGpu               CPU mining only.
.PARAMETER NoAutoStart         Don't register scheduled tasks.
.PARAMETER AutoLogon           Enable Windows auto-logon (Sysinternals Autologon).
.PARAMETER Watchdog            (internal) health check + daily re-evaluation. Used by Task Scheduler.

.EXAMPLE
    Set-ExecutionPolicy Bypass -Scope Process -Force
    .\Setup-Miner.ps1 -AutoLogon
    .\Setup-Miner.ps1 -ThreadsIdle 95 -ActiveCap 70 -ActiveFloor 20 -Headroom 5 -Step 10 -Priority 2
#>

[CmdletBinding()]
param(
    [ValidateRange(10, 100)] [int]$ThreadsIdle = 95,     # CPU % while nobody is using the PC
    [ValidateRange(10, 100)] [int]$ActiveCap = 70,       # max CPU % for mining while you are working
    [ValidateRange(0, 100)]  [int]$ActiveFloor = 20,     # never go below this while working (0 = can pause)
    [ValidateRange(0, 30)]   [int]$Headroom = 5,         # % of CPU always left free for the OS
    [ValidateRange(5, 50)]   [int]$Step = 10,            # scale up/down in steps of this %
    [ValidateRange(10, 3600)][int]$IdleSeconds = 60,     # no keyboard/mouse for this long = idle
    [ValidateRange(0, 5)]    [int]$Priority = 2,         # XMRig thread priority (0 lowest .. 5 highest)
    [switch]$IdleMonitor,                                # (internal) runs forever, scales CPU threads up/down
    [ValidateRange(30, 600)] [int]$BenchSeconds = 90,
    [switch]$Rebench,
    [switch]$NoGpu,
    [switch]$NoAutoStart,
    [switch]$AutoLogon,
    [switch]$Watchdog
)

# =============================================================================
#  USER CONFIG
# =============================================================================

# Wallet address per coin. Blank = coin is skipped.
$WALLETS = @{
    # --- CPU coins (RandomX / GhostRider) ---
    XMR  = '46pSeeqksaPb97W5ZsNibYfLGdRwTbkLqDR5nn1AMWgK58doHJVvdPhMuA8aE7J7Sd5pcXWRSK91vDeD71qqPYcZFkjgdaw'   # Monero
    ZEPH = ''   # Zephyr (RandomX)
    RTM  = ''   # Raptoreum (GhostRider)
    # --- GPU coins ---
    KAS  = ''   # Kaspa
    ERG  = ''   # Ergo
    ALPH = ''   # Alephium
    RVN  = ''   # Ravencoin (NVIDIA only - T-Rex)
    ETC  = ''   # Ethereum Classic
    IRON = ''   # Ironfish
    KLS  = ''   # Karlsen
    NEXA = ''   # Nexa
    CFX  = ''   # Conflux (NVIDIA only)
}

# host:port  -> primary, backup.  VERIFY ports on each pool's website.
$POOLS = @{
    XMR  = @('pool.supportxmr.com:3333',          'pool.hashvault.pro:3333')
    ZEPH = @('de.zephyr.herominers.com:1123',     'pool.hashvault.pro:3333')
    RTM  = @('de.raptoreum.herominers.com:1140',  'pool.woolypooly.com:3010')
    KAS  = @('de.kaspa.herominers.com:1206',      'pool.woolypooly.com:3112')
    ERG  = @('de.ergo.herominers.com:1180',       'erg.2miners.com:8888')
    ALPH = @('de.alephium.herominers.com:1199',   'pool.woolypooly.com:3106')
    RVN  = @('de.ravencoin.herominers.com:1140',  'rvn.2miners.com:6060')
    ETC  = @('de.etc.herominers.com:1150',        'etc.2miners.com:1010')
    IRON = @('de.ironfish.herominers.com:1145',   'pool.woolypooly.com:3114')
    KLS  = @('de.karlsen.herominers.com:1195',    'pool.woolypooly.com:3121')
    NEXA = @('de.nexa.herominers.com:1172',       'pool.woolypooly.com:3124')
    CFX  = @('de.conflux.herominers.com:1170',    'pool.woolypooly.com:3094')
}

$WORKER            = $env:COMPUTERNAME
$BaseDir           = 'C:\Miners'
$WatchdogMinutes   = 5
$ReevaluateHours   = 24      # how often the watchdog re-checks profitability
$SwitchThresholdPct = 10     # switch coin only if the new one earns this % more
$BenchCacheDays    = 14      # re-benchmark automatically after this many days

# =============================================================================
#  COIN CATALOG  (which miner + algorithm name for each coin / vendor)
# =============================================================================

$COINS = @{
    # CPU
    XMR  = @{ Type = 'cpu'; Miner = @{ CPU = 'xmrig' };                    Algo = @{ xmrig = 'rx/0' } }
    ZEPH = @{ Type = 'cpu'; Miner = @{ CPU = 'xmrig' };                    Algo = @{ xmrig = 'rx/0' } }
    RTM  = @{ Type = 'cpu'; Miner = @{ CPU = 'xmrig' };                    Algo = @{ xmrig = 'ghostrider' } }
    # GPU
    KAS  = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'rigel'; AMD = 'lolminer' }; Algo = @{ rigel = 'kheavyhash';  lolminer = 'KASPA' } }
    ERG  = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'rigel'; AMD = 'lolminer' }; Algo = @{ rigel = 'autolykos2';  lolminer = 'AUTOLYKOS2' } }
    ALPH = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'rigel'; AMD = 'lolminer' }; Algo = @{ rigel = 'alephium';    lolminer = 'ALEPH' } }
    RVN  = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'trex' };                   Algo = @{ trex  = 'kawpow' } }
    ETC  = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'rigel'; AMD = 'lolminer' }; Algo = @{ rigel = 'etchash';     lolminer = 'ETCHASH' } }
    IRON = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'rigel'; AMD = 'lolminer' }; Algo = @{ rigel = 'fishhash';    lolminer = 'FISHHASH' } }
    KLS  = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'rigel'; AMD = 'lolminer' }; Algo = @{ rigel = 'karlsenhash'; lolminer = 'KARLSEN' } }
    NEXA = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'rigel'; AMD = 'lolminer' }; Algo = @{ rigel = 'nexapow';     lolminer = 'NEXA' } }
    CFX  = @{ Type = 'gpu'; Miner = @{ NVIDIA = 'rigel' };                  Algo = @{ rigel = 'octopus' } }
}

$MINERS = @{
    xmrig    = @{ Repo = 'xmrig/xmrig';                 Pattern = 'msvc-win64\.zip$'; Exe = 'xmrig.exe';    Port = 7777 }
    lolminer = @{ Repo = 'Lolliedieb/lolMiner-releases'; Pattern = 'Win64\.zip$';      Exe = 'lolMiner.exe'; Port = 4068 }
    rigel    = @{ Repo = 'rigelminer/rigel';            Pattern = 'win\.zip$';        Exe = 'rigel.exe';    Port = 5000 }
    trex     = @{ Repo = 'trexminer/T-Rex';             Pattern = 'win\.zip$';        Exe = 't-rex.exe';    Port = 4067 }
}

# =============================================================================
#  INTERNALS
# =============================================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$LogDir    = Join-Path $BaseDir 'logs'
$StatePath = Join-Path $BaseDir 'state.json'
$SelfPath  = Join-Path $BaseDir 'Setup-Miner.ps1'
New-Item -ItemType Directory -Force -Path $BaseDir, $LogDir | Out-Null
$LogFile = if ($Watchdog) { Join-Path $LogDir 'watchdog.log' } else { Join-Path $LogDir ("setup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)) }

function Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
    if (-not $Watchdog) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
    Add-Content -Path $LogFile -Value $line
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Load-State {
    $s = $null
    if (Test-Path $StatePath) { try { $s = Get-Content $StatePath -Raw | ConvertFrom-Json } catch { } }
    if (-not $s) { $s = [pscustomobject]@{} }
    foreach ($name in 'Benchmarks','Running','Settings') {
        if (-not $s.PSObject.Properties[$name] -or $null -eq $s.$name) { $s | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{}) -Force }
    }
    foreach ($name in 'LastReevaluate','BenchDate') {
        if (-not $s.PSObject.Properties[$name]) { $s | Add-Member -NotePropertyName $name -NotePropertyValue $null }
    }
    return $s
}
function Save-State { param($State) $State | ConvertTo-Json -Depth 8 | Set-Content -Path $StatePath -Encoding UTF8 }

# --- GitHub installs ------------------------------------------------------------

function Get-LatestAsset {
    param([string]$Repo, [string]$Pattern)
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'Setup-Miner' }
    $asset = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "No Windows asset matching '$Pattern' in $Repo" }
    [pscustomobject]@{ Tag = $rel.tag_name; Name = $asset.name; Url = $asset.browser_download_url }
}

function Install-Miner {
    param([string]$Key)
    $m   = $MINERS[$Key]
    $dir = Join-Path $BaseDir $Key
    $exe = Get-ChildItem -Path $dir -Filter $m.Exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $stamp = Join-Path $dir '.version'

    try { $asset = Get-LatestAsset -Repo $m.Repo -Pattern $m.Pattern }
    catch {
        if ($exe) { Log "GitHub unreachable - using installed $Key" 'WARN'; return $exe.FullName }
        throw
    }
    if ($exe -and (Test-Path $stamp) -and ((Get-Content $stamp) -eq $asset.Tag)) { return $exe.FullName }

    Log "Downloading $Key $($asset.Tag)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $env:TEMP $asset.Name
    Invoke-WebRequest -Uri $asset.Url -OutFile $zip -UseBasicParsing
    Get-ChildItem $dir -Exclude '.version' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force
    Set-Content -Path $stamp -Value $asset.Tag
    $exe = Get-ChildItem -Path $dir -Filter $m.Exe -Recurse | Select-Object -First 1
    if (-not $exe) { throw "$($m.Exe) missing after extract" }
    Log "$Key installed" 'OK'
    return $exe.FullName
}

# --- Hardware ---------------------------------------------------------------------

function Get-Hardware {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpus = Get-CimInstance Win32_VideoController | ForEach-Object {
        $name = $_.Name
        $vendor = switch -Regex ($name) {
            'NVIDIA|GeForce|RTX|GTX|Quadro' { 'NVIDIA'; break }
            'AMD|Radeon|RX '                { 'AMD';    break }
            'Intel'                         { 'Intel';  break }
            default                         { 'Other' }
        }
        $vramGB = [math]::Round(($_.AdapterRAM / 1GB), 1)
        try {
            $reg = Get-ItemProperty -Path "HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\000*" -ErrorAction SilentlyContinue |
                   Where-Object { $_.DriverDesc -eq $name } | Select-Object -First 1
            if ($reg -and $reg.'HardwareInformation.qwMemorySize') { $vramGB = [math]::Round($reg.'HardwareInformation.qwMemorySize' / 1GB, 1) }
        } catch { }
        [pscustomobject]@{ Name = $name; Vendor = $vendor; VramGB = $vramGB }
    }
    [pscustomobject]@{
        CpuName = $cpu.Name.Trim(); CpuCores = $cpu.NumberOfCores; CpuThreads = $cpu.NumberOfLogicalProcessors; Gpus = @($gpus)
    }
}

# --- Profitability (minerstat public API) -------------------------------------------

function Get-CoinEconomics {
    # Returns @{ TICKER = @{ UsdPerHashDay = <double>; Price = <double>; Algo = <string> } }
    $out = @{}
    try {
        $coins = Invoke-RestMethod -Uri 'https://api.minerstat.com/v2/coins' -TimeoutSec 20
    } catch {
        Log "minerstat API unreachable: $($_.Exception.Message)" 'WARN'
        return $out
    }
    $unitMult = @{ H = 1; KH = 1e3; MH = 1e6; GH = 1e9; TH = 1e12 }
    foreach ($c in $coins) {
        if ($c.type -ne 'coin') { continue }
        $t = $c.coin
        if (-not $COINS.ContainsKey($t)) { continue }
        $mult = $unitMult[[string]$c.reward_unit]
        if (-not $mult -or -not $c.price -or -not $c.reward) { continue }
        # reward = coins per 1 reward_unit of hashrate per day
        $out[$t] = @{ UsdPerHashDay = ([double]$c.reward * [double]$c.price) / $mult; Price = [double]$c.price; Algo = [string]$c.algorithm }
    }
    Log "Fetched live economics for $($out.Count) coins" 'OK'
    return $out
}

# --- Miner launch / API ---------------------------------------------------------------

function Get-MinerArgs {
    param([string]$Key, [string]$Coin, [string]$ExePath)
    $pools = $POOLS[$Coin]; $p = $pools[0]; $b = $pools[1]
    $u = "$($WALLETS[$Coin]).$WORKER"
    $algo = $COINS[$Coin].Algo[$Key]
    $port = $MINERS[$Key].Port
    switch ($Key) {
        'rigel'    { "-a $algo -o stratum+tcp://$p -u $u -o stratum+tcp://$b -u $u --api-bind 127.0.0.1:$port --log-file `"$LogDir\rigel.log`"" }
        'lolminer' { "--algo $algo --pool $p --user $u --pool $b --user $u --apiport $port --log --logfile `"$LogDir\lolminer.log`"" }
        'trex'     { "-a $algo -o stratum+tcp://$p -u $u -p x -o stratum+tcp://$b -u $u -p x --api-bind-http 127.0.0.1:$port --log-path `"$LogDir\trex.log`"" }
        'xmrig'    { "--config=`"$(Split-Path $ExePath)\config.json`"" }
    }
}

function Write-XmrigConfig {
    param([string]$ExePath, [string]$Coin)
    $algo = $COINS[$Coin].Algo['xmrig']
    $pools = $POOLS[$Coin]
    $cfg = @{
        autosave = $false; 'donate-level' = 0; retries = 5; 'retry-pause' = 5
        cpu = @{ enabled = $true; 'huge-pages' = $true; 'max-threads-hint' = $ThreadsIdle; priority = $Priority }
        opencl = @{ enabled = $false }; cuda = @{ enabled = $false }
        randomx = @{ mode = 'auto'; '1gb-pages' = $true }
        'pause-on-active' = $false          # the IdleMonitor scales threads instead of pausing
        'pause-on-battery' = $true
        http = @{ enabled = $true; host = '0.0.0.0'; port = $MINERS.xmrig.Port; 'access-token' = (Get-ApiToken); restricted = $false }
        pools = @(
            @{ algo = $algo; url = $pools[0]; user = $WALLETS[$Coin]; pass = $WORKER; keepalive = $true },
            @{ algo = $algo; url = $pools[1]; user = $WALLETS[$Coin]; pass = $WORKER; keepalive = $true }
        )
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path (Split-Path $ExePath) 'config.json') -Encoding UTF8
}

function Get-MinerHashrate {
    # Returns H/s from the miner's local HTTP API, or $null
    param([string]$Key)
    $port = $MINERS[$Key].Port
    try {
        switch ($Key) {
            'xmrig' {
                $s = Invoke-RestMethod "http://127.0.0.1:$port/1/summary" -TimeoutSec 5
                $v = $s.hashrate.total[1]; if (-not $v) { $v = $s.hashrate.total[0] }
                return [double]$v
            }
            'trex' {
                $s = Invoke-RestMethod "http://127.0.0.1:$port/summary" -TimeoutSec 5
                return [double]$s.hashrate
            }
            'rigel' {
                $s = Invoke-RestMethod "http://127.0.0.1:$port/stat" -TimeoutSec 5
                if ($s.hashrate) { return [double]($s.hashrate | Select-Object -First 1) }
                $sum = 0; foreach ($d in $s.devices) { $sum += [double]($d.hashrate | Select-Object -First 1) }
                return $sum
            }
            'lolminer' {
                $s = Invoke-RestMethod "http://127.0.0.1:$port/" -TimeoutSec 5
                $a = $s.Algorithms | Select-Object -First 1
                $mult = switch -Regex ([string]$a.Performance_Unit) { '^g' { 1e9 } '^m' { 1e6 } '^k' { 1e3 } default { 1 } }
                return [double]$a.Total_Performance * $mult
            }
        }
    } catch { return $null }
}

function Start-MinerProcess {
    param([string]$Key, [string]$ExePath, [string]$Coin)
    if ($Key -eq 'xmrig') { Write-XmrigConfig -ExePath $ExePath -Coin $Coin }
    $minerArgs = Get-MinerArgs -Key $Key -Coin $Coin -ExePath $ExePath
    return Start-Process -FilePath $ExePath -ArgumentList $minerArgs -WorkingDirectory (Split-Path $ExePath) -WindowStyle Minimized -PassThru
}

function Stop-MinerProcess {
    param([string]$Key)
    $name = [IO.Path]::GetFileNameWithoutExtension($MINERS[$Key].Exe)
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

function Invoke-Benchmark {
    param([string]$Key, [string]$ExePath, [string]$Coin)
    Log "Benchmarking $Coin with $Key for $BenchSeconds s ..."
    Stop-MinerProcess $Key
    $p = Start-MinerProcess -Key $Key -ExePath $ExePath -Coin $Coin
    Start-Sleep -Seconds $BenchSeconds
    $hr = Get-MinerHashrate $Key
    if (-not $hr) { Start-Sleep -Seconds 20; $hr = Get-MinerHashrate $Key }
    Stop-MinerProcess $Key
    if ($hr) { Log ("  {0}: {1:N0} H/s" -f $Coin, $hr) 'OK' } else { Log "  $Coin: no hashrate reported (unsupported on this card or miner error - see $LogDir)" 'WARN' }
    return $hr
}

function Get-ApiToken {
    $f = Join-Path $BaseDir '.apitoken'
    if (-not (Test-Path $f)) { Set-Content $f ([guid]::NewGuid().ToString('N')) -NoNewline }
    return (Get-Content $f -Raw).Trim()
}

# --- Idle monitor: 95% CPU when idle, lower when you are working --------------------------

function Get-IdleSeconds {
    if (-not ('IdleTime' -as [type])) {
        Add-Type @'
using System; using System.Runtime.InteropServices;
public static class IdleTime {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static double Seconds() {
        LASTINPUTINFO l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(l);
        if (!GetLastInputInfo(ref l)) return 0;
        return ((uint)Environment.TickCount - l.dwTime) / 1000.0;
    }
}
'@
    }
    return [IdleTime]::Seconds()
}

function Set-XmrigThreads {
    # Live-apply max-threads-hint through XMRig's HTTP API (no restart of the process)
    param([int]$Percent)
    $port = $MINERS.xmrig.Port
    $hdr  = @{ Authorization = "Bearer $(Get-ApiToken)"; 'Content-Type' = 'application/json' }
    try {
        $cfg = Invoke-RestMethod "http://127.0.0.1:$port/1/config" -Headers $hdr -TimeoutSec 5
        $cur = [int]$cfg.cpu.'max-threads-hint'
        $pausedWanted = ($Percent -le 0)
        if ($pausedWanted) {
            # XMRig has no "pause" endpoint in the public API; emulate with 1 thread at lowest priority
            if ($cur -eq 1) { return $true }
            $cfg.cpu.'max-threads-hint' = 1; $cfg.cpu.priority = 0
        } else {
            if ($cur -eq $Percent) { return $true }
            $cfg.cpu.'max-threads-hint' = $Percent; $cfg.cpu.priority = $Priority
        }
        Invoke-RestMethod "http://127.0.0.1:$port/1/config" -Method Put -Headers $hdr -Body ($cfg | ConvertTo-Json -Depth 10) | Out-Null
        return $true
    } catch { return $false }
}

function Get-CpuLoad {
    # Returns @{ Total = %; Miner = % } using language-independent CIM perf data
    $cores = [Environment]::ProcessorCount
    $total = 0; $miner = 0
    try { $total = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime } catch { }
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "Name='xmrig'"
        if ($p) { $miner = ([double]($p | Measure-Object PercentProcessorTime -Sum).Sum) / $cores }
    } catch { }
    return @{ Total = [math]::Min(100, $total); Miner = [math]::Min(100, $miner) }
}

if ($IdleMonitor) {
    # Runs forever (started at logon). Adaptive controller:
    #   idle   -> ThreadsIdle (95)
    #   active -> start at ActiveCap (70); if YOUR load is high, step down (60, 50, ...) to ActiveFloor;
    #             when your load drops, step back up. Always keeps Headroom (5) free.
    $st = Load-State
    foreach ($k in 'ThreadsIdle','ActiveCap','ActiveFloor','Headroom','Step','IdleSeconds','Priority') {
        if ($null -ne $st.Settings.$k) { Set-Variable -Name $k -Value ([int]$st.Settings.$k) }
    }
    $logI = Join-Path $LogDir 'idle.log'
    function ILog($m) { Add-Content $logI ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m) }
    $current = $ThreadsIdle; $calmSince = Get-Date; $lastApplied = -1
    while ($true) {
        $idle = Get-IdleSeconds
        $load = Get-CpuLoad
        $userLoad = [math]::Max(0, $load.Total - $load.Miner)     # CPU used by everything except the miner
        $budget   = 100 - $Headroom - $userLoad                     # what mining may use right now

        if ($idle -ge $IdleSeconds) {
            $want = [math]::Min($ThreadsIdle, 100 - $Headroom)
        } else {
            $want = $current
            if ($current -gt $ActiveCap) { $want = $ActiveCap }    # just became active -> start at 70
            if ($budget -lt $current - 5) {                         # user needs more CPU -> step down now
                $want = [math]::Max($ActiveFloor, [math]::Floor($budget / $Step) * $Step)
                $calmSince = Get-Date
            } elseif ($budget -ge $current + $Step + 5 -and ((Get-Date) - $calmSince).TotalSeconds -ge 30) {
                $want = [math]::Min($ActiveCap, $current + $Step)   # calm for 30 s -> step up
                $calmSince = Get-Date
            }
            $want = [math]::Max($ActiveFloor, [math]::Min($want, $ActiveCap))
        }

        $cfgNow = $null
        try { $cfgNow = (Invoke-RestMethod "http://127.0.0.1:$($MINERS.xmrig.Port)/1/config" -Headers @{ Authorization = "Bearer $(Get-ApiToken)" } -TimeoutSec 3).cpu.'max-threads-hint' } catch { }
        $expected = $(if ($want -le 0) { 1 } else { $want })
        if ($want -ne $lastApplied -or $cfgNow -ne $expected) {
            if (Set-XmrigThreads -Percent $want) {
                if ($want -ne $lastApplied) { ILog ("idle={0:N0}s total={1:N0}% miner={2:N0}% you={3:N0}% -> mining {4}%" -f $idle, $load.Total, $load.Miner, $userLoad, $want) }
                $lastApplied = $want
            }
        }
        $current = $want
        Start-Sleep -Seconds 5
    }
}

# --- Launchers (restart loop) & keep-alive ---------------------------------------------

function Write-Launcher {
    param([string]$Slot, [string]$Key, [string]$ExePath, [string]$Coin)
    $minerArgs = Get-MinerArgs -Key $Key -Coin $Coin -ExePath $ExePath
    if ($Key -eq 'xmrig') { Write-XmrigConfig -ExePath $ExePath -Coin $Coin }
    $bat = @"
@echo off
title $Slot - $Coin ($Key)
cd /d "$(Split-Path $ExePath)"
:loop
"$ExePath" $minerArgs
timeout /t 10
goto loop
"@
    $path = Join-Path $BaseDir "start-$Slot.bat"
    Set-Content -Path $path -Value $bat -Encoding ASCII
    return $path
}

function Get-HiddenLauncher {
    # A tiny .vbs that runs the given .bat with a fully hidden window (style 0).
    param([string]$Slot, [string]$Bat)
    $vbs = @"
Set s = CreateObject("Wscript.Shell")
s.Run """$Bat""", 0, False
"@
    $path = Join-Path $BaseDir "run-$Slot.vbs"
    Set-Content -Path $path -Value $vbs -Encoding ASCII
    return $path
}

function Start-Launcher { param([string]$Slot, [string]$Bat)
    $vbs = Get-HiddenLauncher -Slot $Slot -Bat $Bat
    Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" -WindowStyle Hidden
}

function Stop-Slot { param($State, [string]$Slot)
    $r = $State.Running.$Slot
    if ($r) {
        # kill the restart loop (cmd window titled with the slot) then the miner
        Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | Where-Object { $_.CommandLine -like "*start-$Slot.bat*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-MinerProcess $r.Miner
    }
}

function Set-PowerSettings {
    try {
        foreach ($c in 'standby-timeout-ac 0','standby-timeout-dc 0','hibernate-timeout-ac 0','hibernate-timeout-dc 0') { powercfg /change $c.Split(' ')[0] $c.Split(' ')[1] | Out-Null }
        powercfg /hibernate off | Out-Null
        powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null
        Log "Power: sleep/hibernate off, lid close ignored" 'OK'
    } catch { Log "Power settings failed: $($_.Exception.Message)" 'WARN' }
}

function Register-KeepAlive {
    param([string[]]$Slots)
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -MultipleInstances IgnoreNew
    foreach ($slot in $Slots) {
        $vbs = Join-Path $BaseDir "run-$slot.vbs"
        $action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user; $trigger.Delay = 'PT1M'
        Register-ScheduledTask -TaskName "Miner-$slot" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    }
    $imAction   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`" -IdleMonitor"
    $imTrigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
    $imSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'Miner-idlemonitor' -Action $imAction -Trigger $imTrigger -Settings $imSettings -Principal $principal -Force | Out-Null

    $wdAction   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`" -Watchdog"
    $wdTrigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $WatchdogMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $wdSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName 'Miner-watchdog' -Action $wdAction -Trigger $wdTrigger -Settings $wdSettings -Principal $principal -Force | Out-Null
    Log "Scheduled tasks registered: $($Slots -join ', '), idle monitor, watchdog every $WatchdogMinutes min" 'OK'
}

function Enable-AutoLogon {
    $exe = Join-Path $BaseDir 'Autologon64.exe'
    if (-not (Test-Path $exe)) { Invoke-WebRequest -Uri 'https://live.sysinternals.com/Autologon64.exe' -OutFile $exe -UseBasicParsing }
    $sec = Read-Host -Prompt "Windows password for $env:USERNAME (stored encrypted by Sysinternals Autologon)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr); [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    & $exe /accepteula $env:USERNAME $env:USERDOMAIN $plain; $plain = $null
    Log "Auto-logon enabled" 'OK'
}

function Remove-OldMiners {
    # Stop/clean miners from PREVIOUS setups so this run starts fresh.
    Log "Cleaning up any previous miner setup..."
    try {
        Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^(XMRig|Miner|Rig)' } | ForEach-Object {
            Stop-ScheduledTask -TaskName $_.TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch { }
    foreach ($pn in 'xmrig', 'rigel', 't-rex', 'lolMiner') {
        Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    foreach ($d in 'C:\xmrig', 'C:\rig') {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; Log "  removed old folder $d" }
    }
    Start-Sleep -Seconds 2
    Log "  cleanup done" 'OK'
}

# --- Decision: best coin per slot ---------------------------------------------------------

function Get-Candidates {
    # Returns list of @{ Slot; Coin; Miner; Exe } for coins that have a wallet and a miner for this hardware
    param($Hw, $Exes)
    $list = @()
    foreach ($coin in $COINS.Keys) {
        $c = $COINS[$coin]
        $slot = $c.Type
        if ($slot -eq 'gpu' -and (-not $Hw.GpuVendor)) { continue }
        $vendorKey = if ($slot -eq 'cpu') { 'CPU' } else { $Hw.GpuVendor }
        $miner = $c.Miner[$vendorKey]
        if (-not $miner -or -not $Exes.ContainsKey($miner)) { continue }
        $list += @{ Slot = $slot; Coin = $coin; Miner = $miner; Exe = $Exes[$miner]; HasWallet = -not [string]::IsNullOrWhiteSpace($WALLETS[$coin]) }
    }
    return $list
}

function Select-Best {
    param($Candidates, $Bench, $Econ, [string]$Slot)
    $rows = @()
    foreach ($c in $Candidates | Where-Object { $_.Slot -eq $Slot }) {
        $hr = $Bench.($c.Coin)
        $e  = $Econ[$c.Coin]
        $usd = if ($hr -and $e) { [double]$hr * $e.UsdPerHashDay } else { $null }
        $rows += [pscustomobject]@{ Coin = $c.Coin; Miner = $c.Miner; Hashrate = $hr; UsdPerDay = $usd; Wallet = $c.HasWallet; Exe = $c.Exe }
    }
    $rows = $rows | Sort-Object { if ($_.UsdPerDay) { $_.UsdPerDay } else { -1 } } -Descending
    Log ("--- {0} ranking (USD/day on this machine) ---" -f $Slot.ToUpper())
    foreach ($r in $rows) {
        $hrS = if ($r.Hashrate) { ('{0:N0} H/s' -f $r.Hashrate) } else { 'n/a' }
        $usdS = if ($r.UsdPerDay -ne $null) { ('${0:N3}' -f $r.UsdPerDay) } else { 'n/a' }
        $w = if ($r.Wallet) { '' } else { '  (no wallet - add one to enable)' }
        Log ("  {0,-5} {1,-9} {2,14}  {3,10}{4}" -f $r.Coin, $r.Miner, $hrS, $usdS, $w)
    }
    return ($rows | Where-Object { $_.Wallet -and $_.UsdPerDay } | Select-Object -First 1)
}

# =============================================================================
#  WATCHDOG MODE
# =============================================================================

if ($Watchdog) {
    $state = Load-State
    if (-not @($state.Running.PSObject.Properties).Count) { Log "No state - run setup first" 'ERR'; exit }
    if ($state.Settings.ThreadsIdle) { $ThreadsIdle = [int]$state.Settings.ThreadsIdle }
    if ($null -ne $state.Settings.Priority) { $Priority = [int]$state.Settings.Priority }
    $online = (Test-Connection 1.1.1.1 -Count 1 -Quiet) -or (Test-Connection 8.8.8.8 -Count 1 -Quiet)

    # 1) make sure every slot is running
    foreach ($slot in @($state.Running.PSObject.Properties.Name)) {
        $r = $state.Running.$slot
        $pn = [IO.Path]::GetFileNameWithoutExtension($MINERS[$r.Miner].Exe)
        $proc = Get-Process -Name $pn -ErrorAction SilentlyContinue
        if (-not $proc) { Log "$slot ($($r.Coin)/$($r.Miner)) not running -> starting" 'WARN'; Start-Launcher $slot "$BaseDir\start-$slot.bat"; continue }
        if ($online -and $proc.StartTime -lt (Get-Date).AddMinutes(-10)) {
            $hr = Get-MinerHashrate $r.Miner
            $paused = $false
            if ($r.Miner -eq 'xmrig') { try { $paused = (Invoke-RestMethod "http://127.0.0.1:7777/1/summary" -TimeoutSec 5).paused } catch { } }
            if (($null -eq $hr -or $hr -eq 0) -and -not $paused) { Log "$slot hung (0 H/s / no API) -> restarting miner" 'WARN'; Stop-MinerProcess $r.Miner }
        }
    }

    # 1b) idle monitor alive?
    $im = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*-IdleMonitor*' }
    if (-not $im) { Log "idle monitor not running -> starting" 'WARN'; Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`" -IdleMonitor" -WindowStyle Hidden }

    # 2) daily re-evaluation
    $due = (-not $state.LastReevaluate) -or ([datetime]$state.LastReevaluate -lt (Get-Date).AddHours(-$ReevaluateHours))
    if ($online -and $due) {
        Log "Re-evaluating profitability"
        $econ = Get-CoinEconomics
        if ($econ.Count) {
            $hw = Get-Hardware
            $gpu = $hw.Gpus | Where-Object { $_.Vendor -in 'NVIDIA','AMD' -and $_.VramGB -ge 4 } | Sort-Object VramGB -Descending | Select-Object -First 1
            $hw | Add-Member -NotePropertyName GpuVendor -NotePropertyValue $(if ($gpu) { $gpu.Vendor } else { $null })
            $exes = @{}
            foreach ($k in $MINERS.Keys) { $e = Get-ChildItem (Join-Path $BaseDir $k) -Filter $MINERS[$k].Exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1; if ($e) { $exes[$k] = $e.FullName } }
            $cands = Get-Candidates -Hw $hw -Exes $exes
            foreach ($slot in @($state.Running.PSObject.Properties.Name)) {
                $best = Select-Best -Candidates $cands -Bench $state.Benchmarks -Econ $econ -Slot $slot
                $cur  = $state.Running.$slot
                if (-not $best) { continue }
                $curUsd = if ($state.Benchmarks.($cur.Coin) -and $econ[$cur.Coin]) { [double]$state.Benchmarks.($cur.Coin) * $econ[$cur.Coin].UsdPerHashDay } else { 0 }
                if ($best.Coin -ne $cur.Coin -and $best.UsdPerDay -gt $curUsd * (1 + $SwitchThresholdPct / 100)) {
                    Log ("SWITCH {0}: {1} (${2:N3}/day) -> {3} (${4:N3}/day)" -f $slot, $cur.Coin, $curUsd, $best.Coin, $best.UsdPerDay) 'OK'
                    Stop-Slot $state $slot
                    Write-Launcher -Slot $slot -Key $best.Miner -ExePath $best.Exe -Coin $best.Coin | Out-Null
                    $state.Running.$slot = @{ Coin = $best.Coin; Miner = $best.Miner; Exe = $best.Exe }
                    Start-Launcher $slot "$BaseDir\start-$slot.bat"
                } else {
                    Log ("{0}: keeping {1} (${2:N3}/day)" -f $slot, $cur.Coin, $curUsd)
                }
            }
        }
        $state.LastReevaluate = (Get-Date).ToString('o')
        Save-State $state
    }
    exit
}

# =============================================================================
#  SETUP MODE
# =============================================================================

Log "=== Setup-Miner on $env:COMPUTERNAME ==="
$isAdmin = Test-IsAdmin
if (-not $isAdmin) { Log "Not Administrator: Defender exclusion, huge pages, power settings and tasks will be skipped." 'WARN' }

# keep a copy of this script where the watchdog can find it
if ($PSCommandPath -and ($PSCommandPath -ne $SelfPath)) { Copy-Item $PSCommandPath $SelfPath -Force }

if ($isAdmin) {
    try { Add-MpPreference -ExclusionPath $BaseDir; Log "Defender exclusion added" 'OK' } catch { Log "Defender exclusion failed: $($_.Exception.Message)" 'WARN' }
    try {
        $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        $tmp = Join-Path $env:TEMP 'secpol.inf'; secedit /export /cfg $tmp | Out-Null
        $content = Get-Content $tmp
        if (-not ($content -match 'SeLockMemoryPrivilege.*' + [regex]::Escape($sid))) {
            if ($content -match 'SeLockMemoryPrivilege') { $content = $content -replace '(SeLockMemoryPrivilege\s*=\s*)(.*)', ('$1$2,*' + $sid) }
            else { $content += "SeLockMemoryPrivilege = *$sid" }
            Set-Content $tmp $content
            secedit /configure /db "$env:TEMP\secpol.sdb" /cfg $tmp /areas USER_RIGHTS | Out-Null
            Log "Huge pages privilege granted (active after next logon)" 'OK'
        }
        Remove-Item $tmp -ErrorAction SilentlyContinue
    } catch { Log "Huge pages privilege failed: $($_.Exception.Message)" 'WARN' }
}

Remove-OldMiners

# --- hardware
$hw = Get-Hardware
Log "CPU: $($hw.CpuName) ($($hw.CpuCores)C/$($hw.CpuThreads)T)"
foreach ($g in $hw.Gpus) { Log "GPU: $($g.Name) [$($g.Vendor), $($g.VramGB) GB]" }
$gpu = $null
if (-not $NoGpu) { $gpu = $hw.Gpus | Where-Object { $_.Vendor -in 'NVIDIA','AMD' -and $_.VramGB -ge 4 } | Sort-Object VramGB -Descending | Select-Object -First 1 }
$hw | Add-Member -NotePropertyName GpuVendor -NotePropertyValue $(if ($gpu) { $gpu.Vendor } else { $null })
if (-not $gpu) { Log "No usable discrete GPU (>=4 GB) - CPU only" 'WARN' } else { Log "GPU slot: $($gpu.Name)" 'OK' }

# --- miners
$exes = @{ xmrig = Install-Miner 'xmrig' }
if ($hw.GpuVendor -eq 'NVIDIA') { $exes.rigel = Install-Miner 'rigel'; $exes.trex = Install-Miner 'trex' }
if ($hw.GpuVendor -eq 'AMD')    { $exes.lolminer = Install-Miner 'lolminer' }

# --- candidates
$cands = Get-Candidates -Hw $hw -Exes $exes
$withWallet = $cands | Where-Object { $_.HasWallet }
if (-not $withWallet) { throw "No wallet addresses set. Fill in `$WALLETS at the top of the script (at least XMR)." }

# --- economics
$econ = Get-CoinEconomics
if (-not $econ.Count) { Log "No live prices - will fall back to first coin with a wallet per slot" 'WARN' }

# --- benchmarks (only coins with wallets; cached)
$state = Load-State
$benchStale = $Rebench -or (-not $state.BenchDate) -or ([datetime]$state.BenchDate -lt (Get-Date).AddDays(-$BenchCacheDays))
if ($benchStale) { $state.Benchmarks = [pscustomobject]@{} }
$state.Settings = @{ ThreadsIdle = $ThreadsIdle; ActiveCap = $ActiveCap; ActiveFloor = $ActiveFloor; Headroom = $Headroom; Step = $Step; IdleSeconds = $IdleSeconds; Priority = $Priority }

# stop anything currently running so benchmarks are clean
foreach ($k in $MINERS.Keys) { Stop-MinerProcess $k }
Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | Where-Object { $_.CommandLine -like '*start-*.bat*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($c in $withWallet) {
    if ($state.Benchmarks.($c.Coin)) { continue }
    $hr = Invoke-Benchmark -Key $c.Miner -ExePath $c.Exe -Coin $c.Coin
    $state.Benchmarks | Add-Member -NotePropertyName $c.Coin -NotePropertyValue $hr -Force
    Save-State $state
}
$state.BenchDate = (Get-Date).ToString('o')

# --- choose & launch
$running = [pscustomobject]@{}
$slots = @('cpu'); if ($hw.GpuVendor) { $slots += 'gpu' }
foreach ($slot in $slots) {
    $best = $null
    if ($econ.Count) { $best = Select-Best -Candidates $cands -Bench $state.Benchmarks -Econ $econ -Slot $slot }
    if (-not $best) {
        $fb = $withWallet | Where-Object { $_.Slot -eq $slot -and $state.Benchmarks.($_.Coin) } | Select-Object -First 1
        if (-not $fb) { Log "$slot: nothing mineable (no wallet or all benchmarks failed)" 'WARN'; continue }
        $best = [pscustomobject]@{ Coin = $fb.Coin; Miner = $fb.Miner; Exe = $fb.Exe; UsdPerDay = $null }
    }
    Write-Launcher -Slot $slot -Key $best.Miner -ExePath $best.Exe -Coin $best.Coin | Out-Null
    $running | Add-Member -NotePropertyName $slot -NotePropertyValue (@{ Coin = $best.Coin; Miner = $best.Miner; Exe = $best.Exe })
    $usd = if ($best.UsdPerDay) { ' (~${0:N3}/day)' -f $best.UsdPerDay } else { '' }
    Log "$($slot.ToUpper()) -> $($best.Coin) with $($best.Miner)$usd" 'OK'
}
$state.Running = $running
$state.LastReevaluate = (Get-Date).ToString('o')
Save-State $state

if ($isAdmin) {
    Set-PowerSettings
    if (-not $NoAutoStart) { Register-KeepAlive -Slots @($running.PSObject.Properties.Name) }
    if ($AutoLogon) { Enable-AutoLogon }
}

foreach ($slot in $running.PSObject.Properties.Name) { Start-Launcher $slot "$BaseDir\start-$slot.bat"; Log "Started $slot" 'OK' }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*-IdleMonitor*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`" -IdleMonitor" -WindowStyle Hidden
Log "Idle monitor started: $ThreadsIdle% idle | active: $ActiveCap% down to $ActiveFloor% by your load, $Headroom% always free" 'OK'

Log "=== Done. Logs: $LogDir | XMRig API: http://localhost:7777/1/summary ==="
if (-not $AutoLogon) { Log "TIP: re-run with -AutoLogon so mining resumes after a power cut." 'WARN' }
Log "TIP: BIOS -> 'Restore on AC Power Loss' = Power On." 'WARN'
