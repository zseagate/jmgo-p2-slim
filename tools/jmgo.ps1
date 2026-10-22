<#
    jmgo.ps1 - debloat a JMGO projector over network ADB (Windows, no Python needed).

    Everything is DISABLED for the current user, never uninstalled, so it is reversible.

    Actions:
      connect    connect to the projector over Wi-Fi
      probe      model, Android version, build, storage, ADB security
      inventory  dump every package to reports/packages-<host>-<date>.csv
      disable    disable the packages in a list, recording the previous state first
      restore    enable what a previous disable run turned off
      shell      run one shell command on the projector

    Examples:
      .\tools\jmgo.ps1 connect -Host 192.168.10.50
      .\tools\jmgo.ps1 probe
      .\tools\jmgo.ps1 inventory
      .\tools\jmgo.ps1 disable -List lists\jmgo-p2.txt -DryRun
      .\tools\jmgo.ps1 disable -List lists\jmgo-p2.txt
      .\tools\jmgo.ps1 restore -Record records\jmgo-p2-20261022-101500.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('connect', 'scan', 'probe', 'inventory', 'disable', 'restore', 'shell')]
    [string]$Action,

    [Alias('Host')]
    [string]$Address,
    [string]$List,
    [string]$Record,
    [string]$Command,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Adb = Join-Path $RepoRoot 'platform-tools\adb.exe'
if (-not (Test-Path $Adb)) {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { $Adb = $cmd.Source }
    else {
        throw "adb.exe not found. Expected $Adb or adb on PATH. Download platform-tools first."
    }
}

$StateFile = Join-Path $RepoRoot '.jmgo-host'
$Env:ADB_SERVER_SOCKET = $null

function Invoke-Adb {
    param([string[]]$Arguments, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Adb @Arguments 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String) -replace "`r", ""
    }
    finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "adb $($Arguments -join ' ') failed ($code):`n$text"
    }
    return $text
}

function Get-Serial {
    if ($script:Serial) { return $script:Serial }
    if ($Address) {
        $target = if ($Address -match ':\d+$') { $Address } else { "$Address`:5555" }
        $out = Invoke-Adb -Arguments @('connect', $target) -AllowFail
        if ($out -match 'connected to') {
            $script:Serial = $target
            Set-Content -Path $StateFile -Value $target -Encoding ascii
            return $script:Serial
        }
        throw "Could not connect to $target : $out"
    }
    if (Test-Path $StateFile) {
        $saved = (Get-Content $StateFile -Raw).Trim()
        if ($saved) {
            $out = Invoke-Adb -Arguments @('connect', $saved) -AllowFail
            if ($out -match 'connected to') { $script:Serial = $saved; return $script:Serial }
        }
    }
    $devices = Invoke-Adb -Arguments @('devices') -AllowFail
    $first = ($devices -split "`n" | Where-Object { $_ -match '\tdevice$' } | Select-Object -First 1)
    if ($first) { $script:Serial = ($first -split "`t")[0]; return $script:Serial }
    throw "No device. Run: .\tools\jmgo.ps1 connect -Host <projector ip>"
}

function Sh {
    param([string]$Cmd, [switch]$AllowFail)
    $s = Get-Serial
    return Invoke-Adb -Arguments @('-s', $s, 'shell', $Cmd) -AllowFail:$AllowFail
}

function Get-Packages {
    param([string]$Flag)
    $args = @('pm', 'list', 'packages')
    if ($Flag) { $args += $Flag }
    $lines = Sh -Cmd ($args -join ' ') -AllowFail
    return @($lines -split "`n" |
        ForEach-Object { ($_ -replace '^package:', '').Trim() } |
        Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' })
}

# Packages that must stay enabled: optics, remote, launcher, system plumbing.
# A list can never disable these, no matter what it says.
$CriticalExact = @(
    'com.android.systemui', 'com.android.settings', 'com.android.providers.settings',
    'com.android.shell', 'com.android.packageinstaller', 'com.android.inputdevices',
    'com.android.keychain', 'com.android.defcontainer', 'com.android.externalstorage',
    'com.android.providers.media', 'com.android.providers.downloads',
    'com.android.providers.downloads.ui', 'com.android.providers.telephony',
    'com.android.bluetooth', 'com.android.inputmethod.pinyin', 'com.android.keyguard',
    'com.android.location.fused', 'com.android.provision', 'com.android.phone',
    'com.android.settings'
)

$ProtectedPatterns = @(
    '^com\.jmgo\.(launcher|setting|systemapi|update|upgrade|factory)$',
    '^com\.mstar\.', '^com\.mediatek\.', '^com\.dolby\.', '^com\.softwinner\.', '^com\.broadcom\.',
    'launcher|home',
    'tvinput|tuner|dtv',
    'wifi|bluetooth',
    '^com\.android\.inputmethod'
)

$ProtectedReason = @{
    '^com\.jmgo\.(launcher|setting|systemapi|update|upgrade|factory)$' = 'JMGO core: Home, Settings, system API'
    '^com\.mstar\.|^com\.mediatek\.|^com\.dolby\.|^com\.softwinner\.|^com\.broadcom\.' = 'vendor HAL / remote server'
    'launcher|home'                                = 'home screen'
    'tvinput|tuner|dtv'                            = 'HDMI / AV / tuner input layer'
    'wifi|bluetooth'                               = 'radios'
    '^com\.android\.inputmethod'                   = 'input method'
}

function Get-ProtectedReason {
    param([string]$Package)
    if ($CriticalExact -contains $Package) { return 'core Android plumbing' }
    foreach ($p in $ProtectedPatterns) {
        if ($Package -match $p) {
            foreach ($k in $ProtectedReason.Keys) {
                if ($p -like $k -or $k -eq $p) { return $ProtectedReason[$k] }
            }
            return 'matched keep rule'
        }
    }
    return $null
}

function Read-List {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "List not found: $Path" }
    $raw = [IO.File]::ReadAllText((Resolve-Path $Path))
    $raw = $raw -replace "^\uFEFF", ''
    $pkgs = @()
    foreach ($line in ($raw -split "`r?`n")) {
        $l = ($line -replace '\s+#.*$', '').Trim()
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        $l = ($l -split '\s+')[0]
        if ($l -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') {
            throw "Refusing ${Path}: not a package name: $l"
        }
        $pkgs += $l
    }
    return $pkgs
}

function Get-Property {
    param([string]$Name)
    return ((Sh -Cmd "getprop $Name" -AllowFail) -split "`n")[0].Trim()
}

function Show-Probe {
    $props = @(
        'ro.product.manufacturer', 'ro.product.model', 'ro.product.device',
        'ro.build.version.release', 'ro.build.version.sdk', 'ro.build.display.id',
        'ro.build.fingerprint', 'ro.adb.secure'
    )
    Write-Host "Target: $(Get-Serial)" -ForegroundColor Cyan
    foreach ($p in $props) {
        $v = Get-Property $p
        Write-Host ("  {0,-32} {1}" -f $p, $v)
    }
    Write-Host ''
    Write-Host "Storage / memory:" -ForegroundColor Cyan
    Sh -Cmd 'df /data' -AllowFail | ForEach-Object { "  $_" }
    Sh -Cmd 'cat /proc/meminfo | head -n 1' -AllowFail | ForEach-Object { "  $_" }
    Write-Host ''
    Write-Host "Package tools available:" -ForegroundColor Cyan
    $pmHelp = Sh -Cmd 'pm' -AllowFail
    foreach ($c in @('disable-user', 'disable', 'enable', 'hide', 'unhide', 'block', 'suspend')) {
        $has = if ($pmHelp -match "(\s|^)$c(\s|$)") { 'yes' } else { 'no' }
        Write-Host ("  pm {0,-14} {1}" -f $c, $has)
    }
    $homePkg = Get-HomePackage
    Write-Host ''
    Write-Host "Home package: $(if ($homePkg) { $homePkg } else { 'unknown' })"
}

function Get-HomePackage {
    $r = Sh -Cmd 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' -AllowFail
    $cand = @($r -split "`n" | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/' } | Select-Object -Last 1)
    if ($cand) { return ($cand[0] -split '/')[0] }
    $d = Sh -Cmd 'dumpsys activity' -AllowFail
    $m = [regex]::Match($d, 'mHomeProcess:.*?[: ]([A-Za-z0-9_.]+)/[A-Za-z0-9_.]+')
    if ($m.Success) { return $m.Groups[1].Value }
    $d2 = Sh -Cmd 'dumpsys window' -AllowFail
    $m2 = [regex]::Match($d2, 'mCurrentFocus=.*?([A-Za-z0-9_.]+)/[A-Za-z0-9_.]+')
    if ($m2.Success -and $m2.Groups[1].Value -match 'launcher|home') { return $m2.Groups[1].Value }
    return $null
}

function Invoke-Inventory {
    $serial = Get-Serial
    $installed = Get-Packages
    $disabled = Get-Packages '-d'
    $reportDir = Join-Path $RepoRoot 'reports'
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $safe = ($serial -replace '[^A-Za-z0-9_.-]', '_')
    $file = Join-Path $reportDir ("packages-{0}-{1}.csv" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    Write-Host "Reading $($installed.Count) packages from $serial..." -ForegroundColor Cyan
    # One round trip for every path: `pm list packages -f` prints package:/system/app/X.apk=com.pkg
    $paths = @{}
    foreach ($line in ((Sh -Cmd 'pm list packages -f' -AllowFail) -split "`n")) {
        $m = [regex]::Match($line, '^package:(.+?)=([A-Za-z0-9_.]+)\s*$')
        if ($m.Success) { $paths[$m.Groups[2].Value] = $m.Groups[1].Value }
    }
    $rows = @()
    foreach ($p in $installed) {
        $path = if ($paths.ContainsKey($p)) { $paths[$p] } else { '' }
        $rows += [pscustomobject]@{
            Package   = $p
            Enabled   = -not ($disabled -contains $p)
            ApkPath   = $path
            System    = if ($path -match '^/system/') { 'system' } elseif ($path -match '^/data/') { 'data' } else { '' }
            Protected = if (Get-ProtectedReason $p) { 'keep' } else { '' }
        }
    }
    $rows | Sort-Object Package | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    Write-Host "Wrote $file" -ForegroundColor Green
    Write-Host "Already disabled: $($disabled.Count) package(s)"
    return $file
}

function Invoke-Disable {
    if (-not $List) { throw 'disable needs -List <file>' }
    $serial = Get-Serial
    $wanted = Read-List $List
    $installed = Get-Packages
    $disabledBefore = Get-Packages '-d'
    $homePkg = Get-HomePackage

    $plan = @()
    $skipped = @()
    foreach ($p in $wanted) {
        if ($installed -notcontains $p) { $skipped += "$p (not installed)"; continue }
        if ($disabledBefore -contains $p) { $skipped += "$p (already disabled)"; continue }
        $reason = Get-ProtectedReason $p
        if ($reason -and -not $Force) { $skipped += "$p (protected: $reason)"; continue }
        if ($homePkg -and $p -eq $homePkg -and -not $Force) { $skipped += "$p (owns Home)"; continue }
        $plan += $p
    }

    Write-Host "Home: $(if ($homePkg) { $homePkg } else { 'unknown' })"
    Write-Host "Will disable $($plan.Count) package(s):"
    $plan | ForEach-Object { "  $_" }
    if ($skipped.Count) {
        Write-Host "Skipped $($skipped.Count):" -ForegroundColor Yellow
        $skipped | ForEach-Object { "  $_" }
    }
    if ($plan.Count -eq 0) { Write-Host 'Nothing to do.'; return }

    if ($DryRun) { Write-Host 'Dry run: nothing changed.' -ForegroundColor Yellow; return }

    # Record first: the state undo needs must exist before the first change.
    $recordDir = Join-Path $RepoRoot 'records'
    New-Item -ItemType Directory -Force -Path $recordDir | Out-Null
    $recordFile = Join-Path $recordDir ("{0}-{1}.json" -f [IO.Path]::GetFileNameWithoutExtension($List), (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $record = [pscustomobject]@{
        serial         = $serial
        list           = (Resolve-Path $List).Path
        date           = (Get-Date).ToString('s')
        model          = (Get-Property 'ro.product.model')
        android        = (Get-Property 'ro.build.version.release')
        homePackage    = $homePkg
        disabledBefore = @($disabledBefore)
        planned        = @($plan)
        disabled       = @()
    }
    $record | ConvertTo-Json -Depth 4 | Set-Content -Path $recordFile -Encoding UTF8
    Write-Host "Record: $recordFile" -ForegroundColor Cyan

    $ok = @(); $fail = @()
    foreach ($p in $plan) {
        $done = Disable-One -Package $p
        if ($done) { $ok += $p; Write-Host "  disabled $p" -ForegroundColor Green }
        else { $fail += $p; Write-Host "  FAILED   $p" -ForegroundColor Red }
    }

    $record.disabled = @($ok)
    $record | ConvertTo-Json -Depth 4 | Set-Content -Path $recordFile -Encoding UTF8

    Write-Host ''
    Write-Host "Disabled $($ok.Count), failed $($fail.Count)." -ForegroundColor Cyan
    $stillDisabled = Get-Packages '-d'
    Write-Host "Verification: $($stillDisabled.Count) package(s) now disabled."
    if ($fail.Count) {
        Write-Host 'Failed packages may need a root shell; nothing was uninstalled.' -ForegroundColor Yellow
    }
    $secure = Get-Property 'ro.adb.secure'
    if ($secure -eq '0') {
        Write-Host 'Warning: ro.adb.secure=0, so port 5555 accepts any device on this network without a prompt. Turn ADB debugging off on the projector when done.' -ForegroundColor Yellow
    }
    Write-Host "Undo: .\tools\jmgo.ps1 restore -Record `"$recordFile`"" -ForegroundColor Cyan
}

function Disable-One {
    param([string]$Package)
    $attempts = @(
        "pm disable-user --user 0 $Package",
        "pm disable --user 0 $Package",
        "pm disable $Package",
        "pm hide $Package"
    )
    foreach ($c in $attempts) {
        $out = Sh -Cmd $c -AllowFail
        if ($out -notmatch 'Error|Exception|Unknown|not found|Permission denial') {
            Start-Sleep -Milliseconds 150
            $d = Get-Packages '-d'
            if ($d -contains $Package) { return $true }
        }
    }
    return $false
}

function Invoke-Restore {
    if (-not $Record) {
        $dir = Join-Path $RepoRoot 'records'
        if (-not (Test-Path $dir)) { throw 'No records directory; nothing to restore.' }
        $latest = Get-ChildItem $dir -Filter *.json | Sort-Object LastWriteTime | Select-Object -Last 1
        if (-not $latest) { throw 'No record found; nothing to restore.' }
        $Record = $latest.FullName
        Write-Host "Using latest record: $Record" -ForegroundColor Cyan
    }
    $r = Get-Content $Record -Raw | ConvertFrom-Json
    $before = @($r.disabledBefore)
    $targets = @($r.disabled)
    if (-not $targets -or $targets.Count -eq 0) { $targets = @($r.planned) }

    Write-Host "Record: $($r.list) from $($r.date)"
    Write-Host "Re-enabling $($targets.Count) package(s) disabled by that run."
    if ($DryRun) { $targets | ForEach-Object { "  $_" }; Write-Host 'Dry run: nothing changed.' -ForegroundColor Yellow; return }

    $ok = 0; $fail = @()
    foreach ($p in $targets) {
        if ($before -contains $p) { Write-Host "  keep disabled $p (was already off before)" -ForegroundColor DarkGray; continue }
        $out = Sh -Cmd "pm enable --user 0 $p" -AllowFail
        if ($out -match 'Error|Exception|Unknown|Permission denial') {
            $out = Sh -Cmd "pm enable $p" -AllowFail
        }
        if ($out -match 'Error|Exception|Unknown|Permission denial') { $fail += $p; Write-Host "  FAILED $p" -ForegroundColor Red }
        else { $ok++; Write-Host "  enabled $p" -ForegroundColor Green }
    }
    Write-Host "Re-enabled $ok package(s)." -ForegroundColor Cyan
    if ($r.homePackage) {
        Write-Host "Home should be $($r.homePackage). Press HOME on the projector to check."
    }
    if ($fail.Count) { Write-Host "Could not enable: $($fail -join ', ')" -ForegroundColor Yellow }
}

function Invoke-Connect {
    if (-not $Address) { throw 'connect needs -Host <projector ip>' }
    $target = if ($Address -match ':\d+$') { $Address } else { "$Address`:5555" }
    $out = Invoke-Adb -Arguments @('connect', $target) -AllowFail
    Write-Host $out
    if ($out -notmatch 'connected to') { throw "No connection. Is ADB debugging on in the projector settings?" }
    $script:Serial = $target
    Set-Content -Path $StateFile -Value $target -Encoding ascii
    # A userdebug build can restart adbd as root, which the debloat needs: on some JMGO firmware
    # the shell user may not change package state (SecurityException). Root here is only used for
    # `pm disable-user`; nothing is written to /system.
    $root = Invoke-Adb -Arguments @('root') -AllowFail
    if ($root -match 'restarting adbd as root') {
        Start-Sleep -Seconds 2
        Invoke-Adb -Arguments @('connect', $target) -AllowFail | Out-Null
        $who = (Invoke-Adb -Arguments @('-s', $target, 'shell', 'id') -AllowFail).Trim()
        Write-Host "ADB shell: $who" -ForegroundColor Green
    }
    $state = (Invoke-Adb -Arguments @('-s', $target, 'get-state') -AllowFail).Trim()
    Write-Host "Device state: $state" -ForegroundColor Green
    Write-Host "Next: .\tools\jmgo.ps1 probe" -ForegroundColor Cyan
}

function Invoke-Scan {
    $subnet = $Address
    if (-not $subnet) {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixLength -eq 24 } |
            Select-Object -First 1).IPAddress
        if (-not $ip) { throw 'Could not guess the subnet; pass it with -Host 192.168.10' }
        $subnet = ($ip -split '\.')[0..2] -join '.'
    }
    $subnet = $subnet -replace '\.0$', ''
    Write-Host "Scanning $subnet.1-254 for open port 5555 (ADB)..." -ForegroundColor Cyan
    $found = @()
    $jobs = @()
    for ($i = 1; $i -le 254; $i++) {
        $ip = "$subnet.$i"
        $client = New-Object System.Net.Sockets.TcpClient
        $jobs += [pscustomobject]@{ Ip = $ip; Client = $client; Async = $client.BeginConnect($ip, 5555, $null, $null) }
    }
    Start-Sleep -Milliseconds 1200
    foreach ($j in $jobs) {
        try {
            if ($j.Client.Connected) { $found += $j.Ip }
        } catch { }
        $j.Client.Close()
    }
    if ($found.Count) {
        $found | ForEach-Object { Write-Host "  ADB open: $_" -ForegroundColor Green }
        Write-Host "Next: .\tools\jmgo.ps1 connect -Host $($found[0])" -ForegroundColor Cyan
    }
    else {
        Write-Host 'No device with port 5555. Turn on ADB debugging on the projector and reboot it.' -ForegroundColor Yellow
    }
}

switch ($Action) {
    'connect' { Invoke-Connect }
    'scan' { Invoke-Scan }
    'probe' { Get-Serial | Out-Null; Show-Probe }
    'inventory' { Invoke-Inventory | Out-Null }
    'disable' { Invoke-Disable }
    'restore' { Invoke-Restore }
    'shell' {
        if (-not $Command) { throw 'shell needs -Command "<shell command>"' }
        Sh -Cmd $Command
    }
}


