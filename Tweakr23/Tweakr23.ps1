# =====================================================================
#  Tweakr23 engine - local-only control panel backend (Windows 10/11)
#  Serves ui.html on http://localhost:<random port>/ and answers API
#  calls from it. Every call needs the per-session token. No telemetry,
#  no downloads, nothing leaves this PC except a Windows Update driver
#  search if you press that button.
# =====================================================================
#Requires -Version 5.1
$ErrorActionPreference = 'Continue'
$Root  = $PSScriptRoot
$Token = [guid]::NewGuid().ToString('N')
$script:LastPing = Get-Date
$IdleExitSeconds = 300
$Shell = New-Object -ComObject WScript.Shell
Add-Type -AssemblyName Microsoft.VisualBasic

$Host.UI.RawUI.WindowTitle = 'Tweakr23 engine (close this window to quit)'

# ---------------------------------------------------------------- helpers
function Out-Line($msg, $color = 'Gray') { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor $color }

function Test-FileLocked([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  try { $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false } catch { return $true }
}

function Get-FilesSafe([string]$dir) {
  # Recursive file listing that never follows junctions/symlinks.
  if (-not (Test-Path -LiteralPath $dir)) { return }
  $stack = New-Object System.Collections.Stack
  $stack.Push($dir)
  while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    try {
      foreach ($e in ([IO.DirectoryInfo]$d).EnumerateFileSystemInfos()) {
        if ($e -is [IO.DirectoryInfo]) {
          if (-not ($e.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($e.FullName) }
        } else { $e }
      }
    } catch {}
  }
}

function Remove-EmptyDirs([string]$dir) {
  $dirs = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push($dir)
  while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    try {
      foreach ($e in ([IO.DirectoryInfo]$d).EnumerateDirectories()) {
        if (-not ($e.Attributes -band [IO.FileAttributes]::ReparsePoint)) { [void]$dirs.Add($e.FullName); $stack.Push($e.FullName) }
      }
    } catch {}
  }
  foreach ($d in ($dirs | Sort-Object Length -Descending)) { try { [IO.Directory]::Delete($d, $false) } catch {} }
}

function Get-DirSize([string]$dir) {
  $s = 0; foreach ($f in (Get-FilesSafe $dir)) { $s += $f.Length }; return $s
}

function Get-ExePath([string]$cmd) {
  if (-not $cmd) { return $null }
  $c = [Environment]::ExpandEnvironmentVariables($cmd).Trim()
  if ($c.StartsWith('"')) { $e = $c.IndexOf('"', 1); if ($e -gt 1) { return $c.Substring(1, $e - 1) } }
  $m = [regex]::Match($c, '^(.+?\.(exe|com|bat|cmd|vbs|lnk))(\s|$)', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value }
  return ($c -split ' ')[0]
}

function Get-Publisher([string]$exe) {
  try { if ($exe -and (Test-Path -LiteralPath $exe)) { return (Get-Item -LiteralPath $exe).VersionInfo.CompanyName } } catch {}
  return ''
}

function Resolve-AppExe([string]$exe) {
  foreach ($h in 'HKLM:', 'HKCU:') {
    $k = "$h\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe"
    if (Test-Path $k) {
      $v = (Get-ItemProperty -LiteralPath $k -EA SilentlyContinue).'(default)'
      if ($v) { $v = $v.Trim('"'); if (Test-Path -LiteralPath $v) { return $v } }
    }
  }
  return $exe
}

function Get-RegValue([string]$path, [string]$name) {
  try { return (Get-ItemProperty -LiteralPath $path -Name $name -EA Stop).$name } catch { return $null }
}

function Set-RegValue([string]$path, [string]$name, $value, [string]$type = 'DWord') {
  if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
  New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

function Restart-Explorer {
  Get-Process explorer -EA SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 1500
  if (-not (Get-Process explorer -EA SilentlyContinue)) { Start-Process explorer.exe }
}

function Start-Window([string]$title, [string]$command) {
  # Long jobs run in their own visible console so the panel stays responsive.
  Start-Process cmd.exe -ArgumentList '/k', "title $title & $command"
}

# ---------------------------------------------------------------- browsers
function Get-ChromiumBrowsers {
  $defs = @(
    @{ Name = 'Chrome';  Data = "$env:LOCALAPPDATA\Google\Chrome\User Data";            Exe = 'chrome.exe';  Scheme = 'chrome' },
    @{ Name = 'Edge';    Data = "$env:LOCALAPPDATA\Microsoft\Edge\User Data";           Exe = 'msedge.exe';  Scheme = 'edge' },
    @{ Name = 'Brave';   Data = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; Exe = 'brave.exe'; Scheme = 'brave' },
    @{ Name = 'Vivaldi'; Data = "$env:LOCALAPPDATA\Vivaldi\User Data";                  Exe = 'vivaldi.exe'; Scheme = 'vivaldi' },
    @{ Name = 'Opera';   Data = "$env:APPDATA\Opera Software\Opera Stable";             Exe = 'opera.exe';   Scheme = 'opera'; Single = $true; Cache = "$env:LOCALAPPDATA\Opera Software\Opera Stable" }
  )
  foreach ($b in $defs) {
    if (-not (Test-Path -LiteralPath $b.Data)) { continue }
    if ($b.Single) { $profiles = @(Get-Item -LiteralPath $b.Data) }
    else { $profiles = @(Get-ChildItem -LiteralPath $b.Data -Directory -Force -EA SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }) }
    [pscustomobject]@{
      Name = $b.Name; Data = $b.Data; Exe = $b.Exe; Scheme = $b.Scheme; Cache = $b.Cache
      Running = (Test-FileLocked (Join-Path $b.Data 'lockfile')); Profiles = $profiles
    }
  }
}

function Get-FirefoxProfiles {
  $root = "$env:APPDATA\Mozilla\Firefox\Profiles"
  if (-not (Test-Path -LiteralPath $root)) { return }
  foreach ($p in Get-ChildItem -LiteralPath $root -Directory -EA SilentlyContinue) {
    [pscustomobject]@{ Name = $p.Name; Path = $p.FullName; Cache = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\$($p.Name)"; Running = (Test-FileLocked (Join-Path $p.FullName 'parent.lock')) }
  }
}

# ---------------------------------------------------------------- startup
$SA = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$StartupSources = @(
  @{ id = 'hkcu';    label = 'Registry - you';            key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             approved = "HKCU:\$SA\Run" },
  @{ id = 'hklm';    label = 'Registry - all users';      key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             approved = "HKLM:\$SA\Run" },
  @{ id = 'hklm32';  label = 'Registry - all users (32-bit)'; key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; approved = "HKLM:\$SA\Run32" },
  @{ id = 'fold';    label = 'Startup folder - you';      folder = [Environment]::GetFolderPath('Startup');                         approved = "HKCU:\$SA\StartupFolder" },
  @{ id = 'foldall'; label = 'Startup folder - all users'; folder = [Environment]::GetFolderPath('CommonStartup');                  approved = "HKLM:\$SA\StartupFolder" }
)

$StartupRules = @(
  @('keep',     'securityhealth|windowsdefender|msascui',                                   'Windows Security tray. Keep it so you see protection alerts.'),
  @('keep',     'realtek|rtkaud|rthdvcpl|rtkngui|waves|maxxaudio|dolby|nahimic|sound research', 'Audio driver helper. Keep it or sound controls and effects can break.'),
  @('keep',     'synaptics|syntp|\belan|etdctrl|alps|precisiontouch',                       'Touchpad driver helper. Keep it for gestures and scrolling.'),
  @('keep',     'wacom|wintab|xp-pen|xppen|huion|pentablet',                                 'Drawing tablet driver. Keep it for pen pressure and buttons.'),
  @('keep',     'igfx|hotkeycmds|intel.*graphics',                                           'Intel graphics helper. Keep it for display hotkeys and settings.'),
  @('keep',     'bitwarden|1password|keepass|lastpass|dashlane|nordpass|protonpass',         'Password manager. Keep it if you want autofill ready at login.'),
  @('keep',     'malwarebytes|avast(?!.*cleanup)|\bavg\b|norton|mcafee|bitdefender|kaspersky|eset|sophos|webroot', 'Security software. Keep it unless you meant to uninstall it.'),
  @('keep',     'bluetooth|btray|btsend',                                                    'Bluetooth helper. Keep it if you use Bluetooth devices.'),
  @('disable',  'ccleaner|iobit|advanced ?systemcare|driver ?booster|wise ?care|avast ?cleanup|glary|auslogics|reimage|restoro|pc ?optimizer|segurazo|smart ?pc ?care|pc ?app ?store', 'PC "optimizer" software - the nagware this panel replaces.'),
  @('optional', 'onedrive',                                                                  'Cloud sync. Keep it if you rely on OneDrive syncing your files.'),
  @('optional', 'dropbox|googledrivefs|google ?drive|icloud|nextcloud|syncthing|megasync|pcloud', 'Cloud sync. Keep it if you want files syncing in the background.'),
  @('optional', 'logi|logitech|razer|corsair|icue|steelseries|synapse|armoury',              'Peripheral software. Keep it if you use custom buttons, macros or RGB.'),
  @('optional', 'nvidia|nvbackend|nvcpl|radeon|amd|cncmd',                                   'GPU companion app. The graphics driver works without it.'),
  @('disable',  'spotify|itunes|ituneshelper|apple ?music|tidal|deezer',                     'Music app. Starts in a second when you open it yourself.'),
  @('disable',  'discord|telegram|whatsapp|signal|messenger',                                'Chat app. Slows boot; open it when you want it.'),
  @('disable',  'teams|skype|zoom|slack|webex',                                              'Meeting/chat app. Slows boot; open it when you need it.'),
  @('disable',  'steam|epicgames|eadesktop|\borigin\b|battle\.net|ubisoft|uplay|gog ?galaxy|riot', 'Game launcher. Opens fine when you start a game.'),
  @('disable',  'adobe|acrobat|ccxprocess|creative ?cloud|agcinvoker|adobegcinvoker|adobearm|acrotray', 'Adobe background helper. Adobe apps still open and license without it.'),
  @('disable',  'microsoftedgeautolaunch|msedge.*--no-startup-window|chrome.*--no-startup-window|opera.*(launcher|autoupdate)|brave.*update', 'Browser pre-loader. Only makes the browser open a little faster.'),
  @('disable',  'cortana|xbox|gamebar|yourphone|phoneexperience',                            'Windows extra you can open on demand.'),
  @('disable',  'utorrent|bittorrent|qbittorrent|vuze',                                      'Torrent client. Uses bandwidth in the background.'),
  @('disable',  'jusched|java.*update|quicktime',                                            'Old updater. Not needed at boot.'),
  @('disable',  'update|updater',                                                            'Background updater. The app checks for updates when you open it.')
)

function Get-StartupAdvice([string]$text) {
  $t = $text.ToLower()
  foreach ($r in $StartupRules) { if ($t -match $r[1]) { return @{ verdict = $r[0]; why = $r[2] } } }
  return @{ verdict = 'optional'; why = 'Not recognised. Not essential at boot - turn it off if you do not need it running all the time.' }
}

function Get-ApprovedEnabled([string]$approved, [string]$name) {
  $v = Get-RegValue $approved $name
  if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
  return $true
}

function Get-StartupItems {
  $items = New-Object System.Collections.ArrayList
  foreach ($s in $StartupSources) {
    if ($s.key) {
      $k = Get-Item -LiteralPath $s.key -EA SilentlyContinue
      if (-not $k) { continue }
      foreach ($n in $k.GetValueNames()) {
        if (-not $n) { continue }
        $cmd = [string]$k.GetValue($n)
        $exe = Get-ExePath $cmd
        $pub = Get-Publisher $exe
        $adv = Get-StartupAdvice "$n $cmd $pub"
        [void]$items.Add([ordered]@{ source = $s.id; sourceLabel = $s.label; name = $n; command = $cmd; publisher = $pub; enabled = (Get-ApprovedEnabled $s.approved $n); verdict = $adv.verdict; why = $adv.why; taskPath = '' })
      }
    } elseif ($s.folder -and (Test-Path -LiteralPath $s.folder)) {
      foreach ($f in Get-ChildItem -LiteralPath $s.folder -File -Force -EA SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
        $cmd = $f.FullName
        if ($f.Extension -eq '.lnk') { try { $sc = $Shell.CreateShortcut($f.FullName); $cmd = ('"{0}" {1}' -f $sc.TargetPath, $sc.Arguments).Trim() } catch {} }
        $pub = Get-Publisher (Get-ExePath $cmd)
        $adv = Get-StartupAdvice "$($f.Name) $cmd $pub"
        [void]$items.Add([ordered]@{ source = $s.id; sourceLabel = $s.label; name = $f.Name; command = $cmd; publisher = $pub; enabled = (Get-ApprovedEnabled $s.approved $f.Name); verdict = $adv.verdict; why = $adv.why; taskPath = '' })
      }
    }
  }
  # Third-party scheduled tasks that fire at logon/boot (a favourite hiding spot for updaters)
  try {
    foreach ($t in Get-ScheduledTask -EA Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) {
      $trig = @($t.Triggers | ForEach-Object { $_.CimClass.CimClassName })
      if (-not ($trig -contains 'MSFT_TaskLogonTrigger' -or $trig -contains 'MSFT_TaskBootTrigger')) { continue }
      $act = @($t.Actions | Where-Object { $_.Execute } | Select-Object -First 1)
      $cmd = if ($act) { ('"{0}" {1}' -f $act[0].Execute, $act[0].Arguments).Trim() } else { '' }
      $pub = Get-Publisher (Get-ExePath $cmd)
      $adv = Get-StartupAdvice "$($t.TaskName) $cmd $pub"
      [void]$items.Add([ordered]@{ source = 'task'; sourceLabel = 'Scheduled task (at logon)'; name = $t.TaskName; command = $cmd; publisher = $pub; enabled = ("$($t.State)" -ne 'Disabled'); verdict = $adv.verdict; why = $adv.why; taskPath = $t.TaskPath })
    }
  } catch {}
  return , $items.ToArray()
}

function Set-StartupItem($b) {
  $enable = [bool]$b.enable
  if ($b.source -eq 'task') {
    if ($enable) { Enable-ScheduledTask -TaskName $b.name -TaskPath $b.taskPath -EA Stop | Out-Null }
    else { Disable-ScheduledTask -TaskName $b.name -TaskPath $b.taskPath -EA Stop | Out-Null }
    return
  }
  $src = $StartupSources | Where-Object { $_.id -eq $b.source } | Select-Object -First 1
  if (-not $src) { throw 'Unknown startup source.' }
  $bytes = New-Object byte[] 12
  if ($enable) { $bytes[0] = 2 } else { $bytes[0] = 3; [BitConverter]::GetBytes((Get-Date).ToFileTime()).CopyTo($bytes, 4) }
  Set-RegValue $src.approved $b.name $bytes 'Binary'
}

# ---------------------------------------------------------------- turbo boost
$ProtectedProcs = @('system','idle','registry','smss','csrss','wininit','winlogon','services','lsass','lsaiso','svchost','dwm','explorer','fontdrvhost','sihost','ctfmon','taskhostw','runtimebroker','searchhost','searchapp','searchui','searchindexer','startmenuexperiencehost','shellexperiencehost','textinputhost','applicationframehost','systemsettings','audiodg','msmpeng','nissrv','securityhealthservice','securityhealthsystray','securityhealthhost','smartscreen','conhost','dllhost','wudfhost','memory compression','lockapp','useroobebroker','widgets','widgetservice','powershell','pwsh','cmd','windowsterminal','openconsole','spoolsv','sgrmbroker','mpdefendercoreservice','dashost','unsecapp','wmiprvse','backgroundtaskhost','shellhost','lsm','winstore.app','msedgewebview2','dwmapi','rundll32','igfxem','rtkauduservice64','nvcontainer','nvdisplay.container','amdrsserv','atieclxx','atiesrxx')
$SuggestStop = 'onedrive|ms-teams|teams|spotify|discord|steam|epicgameslauncher|eadesktop|origin|battle\.net|zoom|skype|slack|dropbox|adobe|ccxprocess|creative cloud|acrotray|googledrivefs|icloud|itunes|update|updater|phoneexperiencehost|yourphone|cortana|gamebar|xboxapp|crashpad|telemetry'
$BrowserNames = 'chrome|msedge|firefox|brave|opera|vivaldi'

function Get-UiPids {
  try { @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -EA Stop | Where-Object { $_.CommandLine -like '*Tweakr23-ui*' } | ForEach-Object { [int]$_.ProcessId }) } catch { @() }
}

function Get-MemInfo {
  $os = Get-CimInstance Win32_OperatingSystem
  return [ordered]@{ total = [double]$os.TotalVisibleMemorySize * 1KB; free = [double]$os.FreePhysicalMemory * 1KB }
}

function Get-TurboList {
  $session = (Get-Process -Id $PID).SessionId
  $ui = Get-UiPids
  $procs = Get-Process | Where-Object { $_.SessionId -eq $session -and $_.Id -ne $PID -and ($ProtectedProcs -notcontains $_.ProcessName.ToLower()) -and ($ui -notcontains $_.Id) }
  $list = foreach ($g in ($procs | Group-Object ProcessName)) {
    $first = $g.Group[0]
    $mem = ($g.Group | Measure-Object WorkingSet64 -Sum).Sum
    $win = @($g.Group | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }).Count -gt 0
    $n = $g.Name.ToLower()
    [ordered]@{
      name = $g.Name; desc = "$($first.Description)"; count = $g.Count; memory = $mem; hasWindow = $win
      browser = ($n -match "^($BrowserNames)$"); suggested = ((-not $win) -and ($n -match $SuggestStop))
    }
  }
  return [ordered]@{ mem = (Get-MemInfo); items = @($list | Sort-Object { $_.memory } -Descending | Select-Object -First 45) }
}

function Invoke-TurboBoost($b) {
  $before = (Get-MemInfo).free
  $session = (Get-Process -Id $PID).SessionId
  $ui = Get-UiPids
  $report = @()
  foreach ($name in @($b.names)) {
    if ($name -notmatch '^[\w\.\- ]+$' -or ($ProtectedProcs -contains $name.ToLower())) { continue }
    $ps = @(Get-Process -Name $name -EA SilentlyContinue | Where-Object { $_.SessionId -eq $session -and ($ui -notcontains $_.Id) -and $_.Id -ne $PID })
    $windowed = @($ps | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    if ($windowed.Count -gt 0 -and -not $b.force) {
      foreach ($p in $windowed) { try { [void]$p.CloseMainWindow() } catch {} }
      $report += "$name - asked to close (it may show a save prompt)"
    } else {
      $ps | Stop-Process -Force -EA SilentlyContinue
      $report += "$name - stopped"
    }
  }
  Start-Sleep -Seconds 2
  $after = (Get-MemInfo).free
  return [ordered]@{ freed = [math]::Max(0, $after - $before); report = $report; mem = (Get-MemInfo) }
}

# ---------------------------------------------------------------- junk
function Get-JunkCats {
  $w = $env:windir
  $cats = New-Object System.Collections.ArrayList
  $skipped = @()

  [void]$cats.Add(@{ id = 'usertemp'; label = 'Your temp files'; desc = 'Leftovers apps forgot to delete (files older than 24h).'; safe = $true; targets = @(@{ dir = $env:TEMP; age = 24 }) })
  [void]$cats.Add(@{ id = 'wintemp'; label = 'Windows temp files'; desc = 'System temp folder (files older than 24h).'; safe = $true; targets = @(@{ dir = "$w\Temp"; age = 24 }) })
  [void]$cats.Add(@{ id = 'wu'; label = 'Windows Update downloads'; desc = 'Installers for updates that are already installed.'; safe = $true; targets = @(@{ dir = "$w\SoftwareDistribution\Download" }) })
  [void]$cats.Add(@{ id = 'do'; label = 'Delivery Optimization cache'; desc = 'Update pieces Windows keeps to share with other PCs.'; safe = $true; targets = @(@{ dir = "$w\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" }) })
  [void]$cats.Add(@{ id = 'dumps'; label = 'Crash dumps and error reports'; desc = 'Memory dumps and reports from past crashes.'; safe = $true; targets = @(
        @{ dir = "$env:LOCALAPPDATA\CrashDumps" }, @{ dir = "$w\Minidump" }, @{ glob = "$w\MEMORY.DMP" },
        @{ dir = "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" }, @{ dir = "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" },
        @{ dir = "$env:LOCALAPPDATA\Microsoft\Windows\WER" }) })
  [void]$cats.Add(@{ id = 'logs'; label = 'Old Windows setup logs'; desc = 'Servicing logs (the active one is skipped automatically).'; safe = $true; targets = @(@{ glob = "$w\Logs\CBS\*.log"; age = 72 }, @{ glob = "$w\Logs\CBS\*.cab" }) })
  [void]$cats.Add(@{ id = 'thumbs'; label = 'Thumbnail cache'; desc = 'Rebuilds itself. Folders of images load slower once afterwards. Some files stay locked by Explorer.'; safe = $false; targets = @(@{ glob = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" }) })
  [void]$cats.Add(@{ id = 'shader'; label = 'Graphics shader caches'; desc = 'Rebuilds itself. Games and 3D apps may stutter briefly the first run after.'; safe = $false; targets = @(
        @{ dir = "$env:LOCALAPPDATA\D3DSCache" }, @{ dir = "$env:LOCALAPPDATA\NVIDIA\DXCache" }, @{ dir = "$env:LOCALAPPDATA\NVIDIA\GLCache" },
        @{ dir = "$env:LOCALAPPDATA\AMD\DxCache" }, @{ dir = "$env:LOCALAPPDATA\AMD\GLCache" }) })

  $bt = @()
  foreach ($br in Get-ChromiumBrowsers) {
    if ($br.Running) { $skipped += $br.Name; continue }
    foreach ($p in $br.Profiles) {
      $base = $p.FullName
      if ($br.Cache) { $base = $br.Cache }
      foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') { $bt += @{ dir = (Join-Path $base $sub) } }
    }
    foreach ($sub in 'ShaderCache', 'GrShaderCache') { $bt += @{ dir = (Join-Path $br.Data $sub) } }
  }
  foreach ($fp in Get-FirefoxProfiles) {
    if ($fp.Running) { if ($skipped -notcontains 'Firefox') { $skipped += 'Firefox' }; continue }
    $bt += @{ dir = (Join-Path $fp.Cache 'cache2') }
  }
  $bdesc = 'Cached web files. Sites load a bit slower once. Logins and history are untouched.'
  if ($skipped.Count) { $bdesc += " Skipped (open right now): $($skipped -join ', ')." }
  [void]$cats.Add(@{ id = 'browser'; label = 'Browser caches'; desc = $bdesc; safe = $true; targets = $bt })
  [void]$cats.Add(@{ id = 'recycle'; label = 'Recycle Bin'; desc = 'Permanently empties the Recycle Bin. Check it first if unsure.'; safe = $false; targets = @(); special = 'recycle' })
  return $cats
}

function Get-JunkFiles($cat) {
  foreach ($t in $cat.targets) {
    $cut = $null; if ($t.age) { $cut = (Get-Date).AddHours(-$t.age) }
    if ($t.dir) { $files = Get-FilesSafe $t.dir } else { $files = Get-ChildItem -Path $t.glob -Force -File -EA SilentlyContinue }
    foreach ($f in $files) { if (-not $cut -or $f.LastWriteTime -lt $cut) { $f } }
  }
}

function Get-RecycleInfo {
  $size = 0; $count = 0
  try { foreach ($i in (New-Object -ComObject Shell.Application).NameSpace(10).Items()) { $size += $i.Size; $count++ } } catch {}
  return @{ size = $size; count = $count }
}

function Invoke-JunkScan {
  $out = foreach ($c in Get-JunkCats) {
    if ($c.special -eq 'recycle') { $r = Get-RecycleInfo; $size = $r.size; $count = $r.count }
    else { $size = 0; $count = 0; foreach ($f in (Get-JunkFiles $c)) { $size += $f.Length; $count++ } }
    [ordered]@{ id = $c.id; label = $c.label; desc = $c.desc; safe = $c.safe; size = [double]$size; count = $count }
  }
  return @{ items = @($out) }
}

function Invoke-JunkClean($ids) {
  $total = 0; $report = @()
  foreach ($c in Get-JunkCats) {
    if (@($ids) -notcontains $c.id) { continue }
    $freed = 0; $failed = 0
    if ($c.special -eq 'recycle') {
      $freed = (Get-RecycleInfo).size
      Clear-RecycleBin -Force -EA SilentlyContinue
    } else {
      if ($c.id -eq 'wu') { Stop-Service wuauserv, bits -Force -EA SilentlyContinue }
      if ($c.id -eq 'do' -and (Get-Command Delete-DeliveryOptimizationCache -EA SilentlyContinue)) {
        $freed = Get-DirSize $c.targets[0].dir
        try { Delete-DeliveryOptimizationCache -Force -EA Stop } catch {}
      } else {
        foreach ($f in @(Get-JunkFiles $c)) {
          try { $len = $f.Length; if ($f.IsReadOnly) { $f.IsReadOnly = $false }; $f.Delete(); $freed += $len } catch { $failed++ }
        }
        foreach ($t in $c.targets) { if ($t.dir) { Remove-EmptyDirs $t.dir } }
      }
      if ($c.id -eq 'wu') { Start-Service wuauserv, bits -EA SilentlyContinue }
    }
    $total += $freed
    $line = '{0}: freed {1:N1} MB' -f $c.label, ($freed / 1MB)
    if ($failed) { $line += " ($failed in-use files skipped)" }
    $report += $line
  }
  return [ordered]@{ freed = [double]$total; report = $report }
}

# ---------------------------------------------------------------- privacy
function Invoke-PrivacySweep($ids) {
  $ids = @($ids); $r = @()
  $exp = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
  if ($ids -contains 'recent') {
    $n = 0; Get-ChildItem "$env:APPDATA\Microsoft\Windows\Recent" -Filter *.lnk -File -Force -EA SilentlyContinue | ForEach-Object { try { $_.Delete(); $n++ } catch {} }
    $r += "Recent files list: cleared $n entries"
  }
  if ($ids -contains 'jumplists') {
    $n = 0; foreach ($d in 'AutomaticDestinations', 'CustomDestinations') { Get-ChildItem "$env:APPDATA\Microsoft\Windows\Recent\$d" -File -Force -EA SilentlyContinue | ForEach-Object { try { $_.Delete(); $n++ } catch {} } }
    $r += "Jump lists: cleared $n files"
  }
  foreach ($pair in @(@('runmru', 'RunMRU', 'Run dialog history'), @('typed', 'TypedPaths', 'Explorer address bar history'), @('search', 'WordWheelQuery', 'Explorer search history'))) {
    if ($ids -contains $pair[0]) {
      $k = "$exp\$($pair[1])"
      if (Test-Path $k) { Remove-Item $k -Recurse -Force -EA SilentlyContinue; New-Item $k -Force | Out-Null }
      $r += "$($pair[2]): cleared"
    }
  }
  if ($ids -contains 'clipboard') { cmd /c 'echo off | clip'; $r += 'Clipboard: cleared' }
  if ($ids -contains 'dns') { Clear-DnsClientCache -EA SilentlyContinue; $r += 'DNS cache: flushed' }
  if ($ids -contains 'cookies' -or $ids -contains 'history') {
    foreach ($br in Get-ChromiumBrowsers) {
      if ($br.Running) { $r += "$($br.Name): skipped - close it first"; continue }
      foreach ($p in $br.Profiles) {
        $files = @()
        if ($ids -contains 'cookies') { $files += 'Cookies', 'Cookies-journal', 'Network\Cookies', 'Network\Cookies-journal' }
        if ($ids -contains 'history') { $files += 'History', 'History-journal', 'Visited Links', 'Top Sites', 'Top Sites-journal' }
        foreach ($f in $files) { $fp = Join-Path $p.FullName $f; if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force -EA SilentlyContinue } }
      }
      $r += "$($br.Name): cleared $(if($ids -contains 'cookies'){'cookies '})$(if($ids -contains 'history'){'history'})"
    }
    if ($ids -contains 'cookies') {
      foreach ($fp in Get-FirefoxProfiles) {
        if ($fp.Running) { $r += 'Firefox: skipped - close it first'; continue }
        Remove-Item -LiteralPath (Join-Path $fp.Path 'cookies.sqlite') -Force -EA SilentlyContinue
        $r += "Firefox ($($fp.Name)): cookies cleared"
      }
    }
  }
  return @{ report = $r }
}

# Toggle definitions. "on" means the privacy-friendly / tweak-applied state.
# off = $null means "remove the value" (used for policy keys).
$Toggles = @(
  @{ id = 'adid';     group = 'privacy'; label = 'Turn off advertising ID'; desc = 'Stops apps using a per-user ID to target ads.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; names = @('Enabled'); on = 0; off = 1 },
  @{ id = 'tailored'; group = 'privacy'; label = 'Turn off tailored experiences'; desc = 'Microsoft stops using diagnostic data for tips and offers.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; names = @('TailoredExperiencesWithDiagnosticDataEnabled'); on = 0; off = 1 },
  @{ id = 'startads'; group = 'privacy'; label = 'No suggested apps in Start'; desc = 'Removes "suggestions" (ads) in Start and Settings.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; names = @('SystemPaneSuggestionsEnabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled'); on = 0; off = 1 },
  @{ id = 'silent';   group = 'privacy'; label = 'Block silent app installs'; desc = 'Stops Windows auto-installing promoted apps and games.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; names = @('SilentInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled'); on = 0; off = 1 },
  @{ id = 'lockads';  group = 'privacy'; label = 'No tips/ads on lock screen'; desc = 'Removes "fun facts" and promos from the lock screen.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; names = @('RotatingLockScreenOverlayEnabled', 'SubscribedContent-338387Enabled'); on = 0; off = 1 },
  @{ id = 'websearch'; group = 'privacy'; label = 'No web results in Start search'; desc = 'Start search only finds your apps and files, not Bing.'; path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; names = @('DisableSearchBoxSuggestions'); on = 1; off = $null; explorer = $true },
  @{ id = 'activity'; group = 'privacy'; label = 'Turn off activity history'; desc = 'Windows stops logging the apps and files you open.'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; names = @('PublishUserActivities', 'UploadUserActivities'); on = 0; off = $null },
  @{ id = 'telemetry'; group = 'privacy'; label = 'Minimum diagnostic data'; desc = 'Sends only the required diagnostic data to Microsoft.'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; names = @('AllowTelemetry'); on = 1; off = $null },
  @{ id = 'langlist'; group = 'privacy'; label = 'Hide language list from websites'; desc = 'Websites cannot read your installed languages.'; path = 'HKCU:\Control Panel\International\User Profile'; names = @('HttpAcceptLanguageOptOut'); on = 1; off = 0 },

  @{ id = 'ext';      group = 'tweak'; label = 'Show file extensions'; desc = 'See .jpg, .exe etc. Helps spot fake "photo.jpg.exe" files.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; names = @('HideFileExt'); on = 0; off = 1; explorer = $true },
  @{ id = 'hidden';   group = 'tweak'; label = 'Show hidden files'; desc = 'Shows hidden folders like AppData in Explorer.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; names = @('Hidden'); on = 1; off = 2; explorer = $true },
  @{ id = 'thispc';   group = 'tweak'; label = 'Explorer opens to This PC'; desc = 'Instead of Home / Quick access.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; names = @('LaunchTo'); on = 1; off = $null; explorer = $true },
  @{ id = 'endtask';  group = 'tweak'; label = '"End task" on taskbar right-click'; desc = 'Kill a frozen app straight from the taskbar (Windows 11).'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; names = @('TaskbarEndTask'); on = 1; off = $null },
  @{ id = 'classic';  group = 'tweak'; label = 'Classic right-click menu'; desc = 'Skip "Show more options" on Windows 11.'; special = 'classicmenu'; explorer = $true },
  @{ id = 'delay';    group = 'tweak'; label = 'No startup app delay'; desc = 'Startup apps launch right away instead of after ~10s.'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; names = @('StartupDelayInMSec'); on = 0; off = $null },
  @{ id = 'sticky';   group = 'tweak'; label = 'No Sticky Keys popup'; desc = 'Pressing Shift five times stops opening the Sticky Keys box.'; path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; names = @('Flags'); on = '506'; off = '510'; type = 'String' },
  @{ id = 'hags';     group = 'gpu'; label = 'Hardware-accelerated GPU scheduling'; desc = 'Lets the GPU manage its own memory. Can lower latency in games and creative apps. Needs a restart.'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; names = @('HwSchMode'); on = 2; off = 1 }
)
$ClassicKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'

function Get-ToggleState($t) {
  if ($t.special -eq 'classicmenu') { return (Test-Path -LiteralPath $ClassicKey) }
  foreach ($n in $t.names) { $v = Get-RegValue $t.path $n; if ($null -eq $v -or "$v" -ne "$($t.on)") { return $false } }
  return $true
}

function Get-Toggles([string]$group) {
  return @($Toggles | Where-Object { $_.group -eq $group } | ForEach-Object { [ordered]@{ id = $_.id; label = $_.label; desc = $_.desc; on = (Get-ToggleState $_); explorer = [bool]$_.explorer } })
}

function Set-Toggle($b) {
  $t = $Toggles | Where-Object { $_.id -eq $b.id } | Select-Object -First 1
  if (-not $t) { throw 'Unknown setting.' }
  $want = [bool]$b.on
  if ($t.special -eq 'classicmenu') {
    if ($want) { New-Item -Path $ClassicKey -Force | Out-Null; Set-ItemProperty -LiteralPath $ClassicKey -Name '(default)' -Value '' }
    else { Remove-Item -LiteralPath (Split-Path $ClassicKey) -Recurse -Force -EA SilentlyContinue }
  } else {
    $type = if ($t.type) { $t.type } else { 'DWord' }
    foreach ($n in $t.names) {
      if ($want) { Set-RegValue $t.path $n $t.on $type }
      elseif ($null -eq $t.off) { Remove-ItemProperty -LiteralPath $t.path -Name $n -EA SilentlyContinue }
      else { Set-RegValue $t.path $n $t.off $type }
    }
  }
  if ($t.explorer) { Restart-Explorer }
  $msg = "$($t.label): $(if($want){'on'}else{'off'})"
  if ($t.id -eq 'hags') { $msg += ' - restart Windows to apply' }
  return @{ message = $msg }
}

# ---------------------------------------------------------------- extensions
$RiskySens = @('webRequest', 'webRequestBlocking', 'cookies', 'history', 'debugger', 'nativeMessaging', 'proxy', 'management', 'clipboardRead', 'downloads', 'privacy', 'declarativeNetRequestWithHostAccess')

function Get-ExtRisk($perms) {
  $p = @($perms | ForEach-Object { "$_" })
  $all = @($p | Where-Object { $_ -match '<all_urls>|^\*://\*/|^https?://\*/|^\*://\*\.' }).Count -gt 0
  $sens = @($p | Where-Object { $RiskySens -contains $_ })
  $level = 'low'
  if ($all -and $sens.Count -gt 0) { $level = 'high' } elseif ($all -or $sens.Count -ge 2) { $level = 'medium' }
  $summary = @(); if ($all) { $summary += 'reads/changes data on all websites' }; $summary += $sens
  return @{ level = $level; summary = ($summary -join ', ') }
}

function Get-ManifestName([string]$verDir, $m) {
  $n = "$($m.name)"
  if ($n -match '^__MSG_(.+)__$') {
    $key = $Matches[1]
    $locs = @(); if ($m.default_locale) { $locs += $m.default_locale }; $locs += 'en', 'en_US'
    foreach ($l in $locs) {
      $f = Join-Path $verDir "_locales\$l\messages.json"
      if (Test-Path -LiteralPath $f) {
        try {
          $msgs = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
          foreach ($pp in $msgs.PSObject.Properties) { if ($pp.Name -ieq $key) { return $pp.Value.message } }
        } catch {}
      }
    }
  }
  return $n
}

function Get-PolicyForced {
  $forced = @{}
  foreach ($root in 'HKLM:', 'HKCU:') {
    foreach ($v in 'Google\Chrome', 'Microsoft\Edge', 'BraveSoftware\Brave') {
      $k = "$root\SOFTWARE\Policies\$v\ExtensionInstallForcelist"
      $item = Get-Item -LiteralPath $k -EA SilentlyContinue
      if (-not $item) { continue }
      foreach ($n in $item.GetValueNames()) { $id = ("$($item.GetValue($n))" -split ';')[0]; $forced[$id] = @{ key = $k; value = $n } }
    }
  }
  return $forced
}

function Get-Extensions {
  $forced = Get-PolicyForced
  $groups = @()
  foreach ($br in Get-ChromiumBrowsers) {
    $exts = @()
    foreach ($p in $br.Profiles) {
      $ed = Join-Path $p.FullName 'Extensions'
      if (-not (Test-Path -LiteralPath $ed)) { continue }
      foreach ($idDir in Get-ChildItem -LiteralPath $ed -Directory -EA SilentlyContinue | Where-Object { $_.Name -match '^[a-p]{32}$' }) {
        $ver = Get-ChildItem -LiteralPath $idDir.FullName -Directory -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $ver) { continue }
        $mf = Join-Path $ver.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try { $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($m.theme) { continue }
        $perms = @($m.permissions) + @($m.host_permissions) + @($m.content_scripts | ForEach-Object { $_.matches })
        $risk = Get-ExtRisk $perms
        $u = "$($m.update_url)"
        $store = ($u -match 'clients2\.google\.com|edge\.microsoft\.com|extension-updates\.opera\.com|vivaldi')
        $exts += [ordered]@{
          id = $idDir.Name; name = (Get-ManifestName $ver.FullName $m); version = "$($m.version)"; profile = $p.Name; profilePath = $p.FullName
          risk = $risk.level; perms = $risk.summary; sideloaded = (-not $store); policy = $forced.ContainsKey($idDir.Name)
        }
      }
    }
    $groups += [ordered]@{ browser = $br.Name; running = $br.Running; items = $exts }
  }
  $ff = @(); $ffRunning = $false
  foreach ($fp in Get-FirefoxProfiles) {
    if ($fp.Running) { $ffRunning = $true }
    $ej = Join-Path $fp.Path 'extensions.json'
    if (-not (Test-Path -LiteralPath $ej)) { continue }
    try { $data = Get-Content -LiteralPath $ej -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    foreach ($a in $data.addons) {
      if ($a.type -ne 'extension' -or $a.location -ne 'app-profile') { continue }
      $perms = @($a.userPermissions.permissions) + @($a.userPermissions.origins)
      $risk = Get-ExtRisk $perms
      $ff += [ordered]@{ id = "$($a.id)"; name = "$($a.defaultLocale.name)"; version = "$($a.version)"; profile = $fp.Name; profilePath = $fp.Path; risk = $risk.level; perms = $risk.summary; sideloaded = $false; policy = $false; active = [bool]$a.active; file = "$($a.path)" }
    }
  }
  if ($ff.Count -or (Get-FirefoxProfiles)) { $groups += [ordered]@{ browser = 'Firefox'; running = $ffRunning; items = $ff } }
  return @{ groups = $groups }
}

function Open-ExtensionPage($b) {
  if ($b.browser -eq 'Firefox') { Start-Process (Resolve-AppExe 'firefox.exe') -ArgumentList 'about:addons'; return }
  $br = Get-ChromiumBrowsers | Where-Object { $_.Name -eq $b.browser } | Select-Object -First 1
  if (-not $br) { throw 'Browser not found.' }
  $arg = "$($br.Scheme)://extensions/"
  if ($b.id -match '^[a-p]{32}$') { $arg += "?id=$($b.id)" }
  Start-Process (Resolve-AppExe $br.Exe) -ArgumentList $arg
}

function Remove-Extension($b) {
  $r = @()
  if ($b.browser -eq 'Firefox') {
    $fp = Get-FirefoxProfiles | Where-Object { $_.Path -eq $b.profilePath } | Select-Object -First 1
    if (-not $fp) { throw 'Profile not found.' }
    if ($fp.Running) { throw 'Close Firefox first.' }
    $file = "$($b.file)"
    if (-not $file.StartsWith($fp.Path, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected extension path.' }
    Remove-Item -LiteralPath $file -Recurse -Force -EA Stop
    return @{ message = "Removed from Firefox. It disappears next time Firefox starts." }
  }
  if ($b.id -notmatch '^[a-p]{32}$') { throw 'Bad extension id.' }
  $br = Get-ChromiumBrowsers | Where-Object { $_.Name -eq $b.browser } | Select-Object -First 1
  if (-not $br) { throw 'Browser not found.' }
  if ($br.Running) { throw "Close $($br.Name) completely first (check the system tray)." }
  $prof = $br.Profiles | Where-Object { $_.FullName -eq $b.profilePath } | Select-Object -First 1
  if (-not $prof) { throw 'Profile not found.' }
  $forced = Get-PolicyForced
  if ($forced.ContainsKey($b.id)) {
    Remove-ItemProperty -LiteralPath $forced[$b.id].key -Name $forced[$b.id].value -Force -EA SilentlyContinue
    $r += 'Removed the policy that force-installed it.'
  }
  foreach ($sub in "Extensions\$($b.id)", "Local Extension Settings\$($b.id)", "Sync Extension Settings\$($b.id)") {
    $pth = Join-Path $prof.FullName $sub
    if (Test-Path -LiteralPath $pth) { Remove-Item -LiteralPath $pth -Recurse -Force -EA SilentlyContinue }
  }
  $r += "Deleted its files from $($br.Name). If browser sync is on and it comes back, remove it from the extensions page too."
  return @{ message = ($r -join ' ') }
}

# ---------------------------------------------------------------- shortcuts
function Get-ShortcutRoots {
  @(
    @{ label = 'Desktop'; path = [Environment]::GetFolderPath('Desktop') },
    @{ label = 'Public desktop'; path = [Environment]::GetFolderPath('CommonDesktopDirectory') },
    @{ label = 'Start menu'; path = [Environment]::GetFolderPath('Programs') },
    @{ label = 'Start menu (all users)'; path = [Environment]::GetFolderPath('CommonPrograms') },
    @{ label = 'Taskbar pins'; path = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar" }
  ) | Where-Object { $_.path -and (Test-Path -LiteralPath $_.path) }
}

function Test-TargetExists([string]$t) {
  if (Test-Path -LiteralPath $t) { return $true }
  if ($t -like '*\Program Files\*') { if (Test-Path -LiteralPath ($t -replace '\\Program Files\\', '\Program Files (x86)\')) { return $true } }
  if ($t -like '*\Program Files (x86)\*') { if (Test-Path -LiteralPath ($t -replace '\\Program Files \(x86\)\\', '\Program Files\')) { return $true } }
  return $false
}

function Get-BrokenShortcuts {
  $out = @()
  foreach ($root in Get-ShortcutRoots) {
    foreach ($f in Get-ChildItem -LiteralPath $root.path -Filter *.lnk -Recurse -File -Force -EA SilentlyContinue) {
      try { $t = $Shell.CreateShortcut($f.FullName).TargetPath } catch { continue }
      if (-not $t) { continue }                           # store apps / installer-advertised shortcuts
      if ($t -match '^[a-zA-Z]:\\' -and -not (Test-Path -LiteralPath ($t.Substring(0, 3)))) { $why = 'drive not connected' }
      elseif (-not (Test-TargetExists $t)) { $why = 'target missing' }
      else { continue }
      $out += [ordered]@{ path = $f.FullName; name = $f.BaseName; where = $root.label; target = $t; why = $why }
    }
  }
  return @{ items = $out }
}

function Remove-Shortcuts($paths) {
  $roots = @(Get-ShortcutRoots | ForEach-Object { $_.path })
  $n = 0
  foreach ($p in @($paths)) {
    if ($p -notlike '*.lnk') { continue }
    if (-not ($roots | Where-Object { $p.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) { continue }
    try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin'); $n++ } catch {}
  }
  return @{ message = "Moved $n shortcut(s) to the Recycle Bin." }
}

# ---------------------------------------------------------------- drivers
$PnpCodes = @{ 1 = 'Not configured correctly'; 3 = 'Driver may be corrupted'; 10 = 'Device cannot start'; 12 = 'Not enough free resources'; 14 = 'Restart needed'; 18 = 'Reinstall the driver'; 19 = 'Registry entry damaged'; 21 = 'Being removed'; 22 = 'Disabled'; 24 = 'Not present or missing drivers'; 28 = 'Driver not installed'; 31 = 'Not working properly'; 32 = 'Driver service disabled'; 39 = 'Driver missing or corrupted'; 43 = 'Stopped after reporting a problem'; 48 = 'Driver blocked'; 52 = 'Driver signature cannot be verified' }

function Get-Drivers {
  $now = Get-Date
  $seen = @{}
  $list = foreach ($d in Get-CimInstance Win32_PnPSignedDriver -EA SilentlyContinue) {
    if (-not $d.DeviceName -or -not $d.DriverVersion) { continue }
    $k = "$($d.DeviceName)|$($d.DriverVersion)"; if ($seen[$k]) { continue }; $seen[$k] = 1
    $age = $null; $date = ''
    if ($d.DriverDate) { $age = [math]::Round(($now - $d.DriverDate).TotalDays / 365.25, 1); $date = $d.DriverDate.ToString('yyyy-MM-dd') }
    $prov = "$($d.DriverProviderName)"
    [ordered]@{ device = $d.DeviceName; cls = "$($d.DeviceClass)"; provider = $prov; version = $d.DriverVersion; date = $date; age = $age; inbox = ($prov -eq 'Microsoft') }
  }
  $problems = foreach ($e in Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -EA SilentlyContinue) {
    $c = [int]$e.ConfigManagerErrorCode
    if ($c -eq 45) { continue }   # device simply not plugged in
    $msg = $PnpCodes[$c]; if (-not $msg) { $msg = "Problem code $c" }
    [ordered]@{ device = "$($e.Name)"; code = $c; problem = $msg }
  }
  $gpus = @(Get-CimInstance Win32_VideoController -EA SilentlyContinue | ForEach-Object {
      $dd = ''; if ($_.DriverDate) { $dd = $_.DriverDate.ToString('yyyy-MM-dd') }
      [ordered]@{ name = "$($_.Name)"; version = "$($_.DriverVersion)"; date = $dd }
    })
  return [ordered]@{ drivers = @($list | Sort-Object { if ($_.inbox) { -1 } else { $_.age } } -Descending); problems = @($problems); gpus = $gpus; hags = (Get-Toggles 'gpu') }
}

function Find-DriverUpdates {
  try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $searcher = $s.CreateUpdateSearcher()
    $res = $searcher.Search("IsInstalled=0 and Type='Driver'")
    $out = foreach ($u in $res.Updates) {
      $dd = ''; try { $dd = ([datetime]$u.DriverVerDate).ToString('yyyy-MM-dd') } catch {}
      [ordered]@{ title = "$($u.Title)"; provider = "$($u.DriverProvider)"; cls = "$($u.DriverClass)"; date = $dd }
    }
    return @{ items = @($out) }
  } catch { throw "Windows Update search failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- hardware health
function Get-Health {
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $up = (Get-Date) - $os.LastBootUpTime
  $mods = @(Get-CimInstance Win32_PhysicalMemory -EA SilentlyContinue | ForEach-Object { [ordered]@{ size = [double]$_.Capacity; speed = $_.ConfiguredClockSpeed; maker = "$($_.Manufacturer)".Trim(); slot = "$($_.DeviceLocator)" } })
  $disks = @(Get-PhysicalDisk -EA SilentlyContinue | ForEach-Object {
      $rc = $null; try { $rc = $_ | Get-StorageReliabilityCounter -EA Stop } catch {}
      [ordered]@{ name = "$($_.FriendlyName)"; media = "$($_.MediaType)"; bus = "$($_.BusType)"; size = [double]$_.Size; health = "$($_.HealthStatus)"; status = "$($_.OperationalStatus -join ', ')"
        temp = $rc.Temperature; tempMax = $rc.TemperatureMax; wear = $rc.Wear; hours = $rc.PowerOnHours; readErr = $rc.ReadErrorsUncorrected; writeErr = $rc.WriteErrorsUncorrected }
    })
  $bat = $null
  $b = Get-CimInstance Win32_Battery -EA SilentlyContinue | Select-Object -First 1
  if ($b) {
    $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -EA SilentlyContinue | Select-Object -First 1).DesignedCapacity
    $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -EA SilentlyContinue | Select-Object -First 1).FullChargedCapacity
    $hp = $null; if ($design -and $full) { $hp = [math]::Round(100 * $full / $design) }
    $bat = [ordered]@{ charge = $b.EstimatedChargeRemaining; design = $design; full = $full; health = $hp }
  }
  $temps = @()
  try { $temps = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -EA Stop | ForEach-Object { [math]::Round($_.CurrentTemperature / 10 - 273.15) }) } catch {}
  $since = (Get-Date).AddDays(-7)
  $errs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 1000 -EA SilentlyContinue)
  $top = @($errs | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { [ordered]@{ source = $_.Name; count = $_.Count } })
  $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = (Get-Date).AddDays(-30) } -EA SilentlyContinue).Count
  $bsod = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = (Get-Date).AddDays(-30) } -EA SilentlyContinue).Count
  $gpu = @(Get-CimInstance Win32_VideoController -EA SilentlyContinue | ForEach-Object { "$($_.Name)" })
  return [ordered]@{
    os = "$($os.Caption) (build $($os.BuildNumber))"; uptimeHours = [math]::Round($up.TotalHours, 1)
    cpu = [ordered]@{ name = "$($cpu.Name)".Trim(); cores = $cpu.NumberOfCores; threads = $cpu.NumberOfLogicalProcessors; load = $cpu.LoadPercentage }
    mem = (Get-MemInfo); modules = $mods; gpus = $gpu; disks = $disks; battery = $bat; temps = $temps
    errors7d = $errs.Count; topErrors = $top; unexpectedShutdowns30d = $crashes; bluescreens30d = $bsod
  }
}

# ---------------------------------------------------------------- disk check
function Get-Volumes {
  $out = @(Get-Volume -EA SilentlyContinue | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Fixed' } | Sort-Object DriveLetter | ForEach-Object {
      [ordered]@{ letter = "$($_.DriveLetter)"; label = "$($_.FileSystemLabel)"; fs = "$($_.FileSystem)"; size = [double]$_.Size; free = [double]$_.SizeRemaining; health = "$($_.HealthStatus)" }
    })
  return @{ items = $out }
}

function Invoke-VolumeAction($b) {
  $l = "$($b.letter)"
  if ($l -notmatch '^[A-Za-z]$') { throw 'Bad drive letter.' }
  switch ($b.mode) {
    'scan'    { $r = Repair-Volume -DriveLetter $l -Scan -EA Stop }
    'spotfix' { $r = Repair-Volume -DriveLetter $l -SpotFix -EA Stop }
    'offline' { $r = Repair-Volume -DriveLetter $l -OfflineScanAndFix -EA Stop }
    default   { throw 'Unknown mode.' }
  }
  $txt = "$r"
  $nice = switch ($txt) {
    'NoErrorsFound'      { 'No errors found. This drive is healthy.' }
    'ScanNeeded'         { 'Windows wants a deeper scan. Try "Scan" again.' }
    'SpotFixNeeded'      { 'Errors found. Use "Fix now" to repair them online.' }
    'FullRepairNeeded'   { 'Errors need an offline repair. Use "Fix at restart".' }
    default              { if ($b.mode -eq 'offline') { 'Repair scheduled - it runs at the next restart.' } else { "Result: $txt" } }
  }
  return @{ result = $txt; message = $nice }
}

# ---------------------------------------------------------------- system tools
function Get-PowerPlan {
  $line = (powercfg /getactivescheme) -join ' '
  $m = [regex]::Match($line, '\(([^)]+)\)')
  if ($m.Success) { return $m.Groups[1].Value } else { return $line }
}

function Invoke-SystemAction($b) {
  switch ($b.id) {
    'restorepoint' {
      $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
      Enable-ComputerRestore -Drive "$env:SystemDrive\" -EA SilentlyContinue
      Set-RegValue $k 'SystemRestorePointCreationFrequency' 0
      try { Checkpoint-Computer -Description ("Tweakr23 {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -EA Stop }
      finally { Remove-ItemProperty -LiteralPath $k -Name 'SystemRestorePointCreationFrequency' -EA SilentlyContinue }
      return 'Restore point created. You can roll back from "Open System Restore".'
    }
    'openrestore'   { Start-Process rstrui.exe; return 'System Restore opened.' }
    'power-balanced'{ powercfg /setactive SCHEME_BALANCED | Out-Null; return 'Power plan: Balanced' }
    'power-high'    { powercfg /setactive SCHEME_MIN | Out-Null; return 'Power plan: High performance' }
    'power-ultimate' {
      $g = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
      $existing = [regex]::Match(((powercfg /list) -join "`n"), '([0-9a-f\-]{36})\s+\(Ultimate')
      if ($existing.Success) { $id = $existing.Groups[1].Value }
      else { $id = [regex]::Match(((powercfg -duplicatescheme $g) -join ' '), '[0-9a-f\-]{36}').Value }
      if (-not $id) { throw 'Ultimate Performance is not available on this edition of Windows.' }
      powercfg /setactive $id | Out-Null
      return 'Power plan: Ultimate Performance (best on desktops - uses more power).'
    }
    'optimize' {
      Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', "`$Host.UI.RawUI.WindowTitle='Tweakr23 - Optimize drives'; Get-Volume | Where-Object { `$_.DriveLetter -and `$_.DriveType -eq 'Fixed' } | ForEach-Object { Write-Host ('Optimizing ' + `$_.DriveLetter + ':') -ForegroundColor Cyan; Optimize-Volume -DriveLetter `$_.DriveLetter -Verbose }; Write-Host 'Done. You can close this window.' -ForegroundColor Green"
      return 'Optimizing drives in a separate window (TRIM for SSDs, defrag for hard drives).'
    }
    'repair'   { Start-Window 'Tweakr23 - Repair system files' 'DISM /Online /Cleanup-Image /RestoreHealth & sfc /scannow & echo. & echo Done. You can close this window.'; return 'System file repair running in a separate window. Takes 10-30 minutes.' }
    'winsxs'   { Start-Window 'Tweakr23 - Component cleanup' 'DISM /Online /Cleanup-Image /StartComponentCleanup & echo. & echo Done. You can close this window.'; return 'Cleaning old Windows component versions in a separate window.' }
    'explorer' { Restart-Explorer; return 'Explorer restarted (taskbar and desktop reloaded).' }
    'iconcache' {
      $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
      Set-RegValue $wl 'AutoRestartShell' 0
      Get-Process explorer -EA SilentlyContinue | Stop-Process -Force
      Start-Sleep -Milliseconds 1200
      Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -EA SilentlyContinue
      Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -Force -EA SilentlyContinue
      Set-RegValue $wl 'AutoRestartShell' 1
      Start-Process explorer.exe
      return 'Icon cache rebuilt. Blank or wrong icons should be fixed.'
    }
    'dns'      { Clear-DnsClientCache; return 'DNS cache flushed.' }
    'netreset' { netsh winsock reset | Out-Null; netsh int ip reset | Out-Null; ipconfig /flushdns | Out-Null; return 'Network stack reset. Restart Windows to finish.' }
    'cleanmgr' { Start-Process cleanmgr.exe; return 'Windows Disk Cleanup opened (use "Clean up system files" for old Windows versions).' }
    'regbackup' {
      $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Tweakr23 backups'
      New-Item $dir -ItemType Directory -Force | Out-Null
      $f = Join-Path $dir ("HKCU-{0}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
      reg export HKCU "$f" /y | Out-Null
      return "Your user registry was backed up to $f"
    }
    'batteryreport' {
      $f = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'battery-report.html'
      powercfg /batteryreport /output "$f" | Out-Null
      Start-Process $f
      return "Battery report saved to $f"
    }
    'wu-drivers' { Start-Process 'ms-settings:windowsupdate-optionalupdates'; return 'Opened Windows Update > Optional updates (driver updates live here).' }
    'devmgr'     { Start-Process devmgmt.msc; return 'Device Manager opened.' }
    default { throw 'Unknown action.' }
  }
}

# ---------------------------------------------------------------- dashboard / quick fix
function Get-Dashboard {
  $os = Get-CimInstance Win32_OperatingSystem
  $c = Get-Volume -DriveLetter ($env:SystemDrive.Substring(0, 1)) -EA SilentlyContinue
  $st = Get-StartupItems
  $prob = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0 AND ConfigManagerErrorCode <> 45' -EA SilentlyContinue).Count
  return [ordered]@{
    os = "$($os.Caption)"; build = "$($os.BuildNumber)"; pc = $env:COMPUTERNAME
    uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    mem = (Get-MemInfo); diskSize = [double]$c.Size; diskFree = [double]$c.SizeRemaining
    startupOn = @($st | Where-Object { $_.enabled }).Count
    startupSuggest = @($st | Where-Object { $_.enabled -and $_.verdict -eq 'disable' }).Count
    problemDevices = $prob; power = (Get-PowerPlan)
  }
}

function Invoke-QuickFix {
  $r = @()
  $j = Invoke-JunkClean @('usertemp', 'wintemp', 'wu', 'dumps', 'logs', 'browser')
  $r += $j.report
  Clear-DnsClientCache -EA SilentlyContinue; $r += 'DNS cache flushed'
  $bs = @((Get-BrokenShortcuts).items).Count
  $r += "Broken shortcuts found: $bs (review them in Shortcut Fix)"
  $all = Get-StartupItems
  $st = @($all | Where-Object { $_.enabled -and $_.verdict -eq 'disable' }).Count
  $r += "Startup apps worth turning off: $st (review them in Startup)"
  return [ordered]@{ freed = $j.freed; report = $r }
}

# ---------------------------------------------------------------- routes
$Routes = @{
  'GET /api/ping'            = { @{ ok = $true } }
  'GET /api/mem'             = { Get-MemInfo }
  'GET /api/dashboard'       = { Get-Dashboard }
  'POST /api/quickfix'       = { Invoke-QuickFix }
  'GET /api/startup'         = { @{ items = (Get-StartupItems) } }
  'POST /api/startup/set'    = { param($b) Set-StartupItem $b; @{ ok = $true } }
  'GET /api/turbo'           = { Get-TurboList }
  'POST /api/turbo/boost'    = { param($b) Invoke-TurboBoost $b }
  'GET /api/junk/scan'       = { Invoke-JunkScan }
  'POST /api/junk/clean'     = { param($b) Invoke-JunkClean $b.ids }
  'GET /api/privacy'         = { @{ toggles = (Get-Toggles 'privacy') } }
  'POST /api/privacy/sweep'  = { param($b) Invoke-PrivacySweep $b.ids }
  'GET /api/tweaks'          = { @{ toggles = (Get-Toggles 'tweak'); power = (Get-PowerPlan) } }
  'POST /api/toggle'         = { param($b) Set-Toggle $b }
  'GET /api/extensions'      = { Get-Extensions }
  'POST /api/extensions/open'   = { param($b) Open-ExtensionPage $b; @{ ok = $true } }
  'POST /api/extensions/remove' = { param($b) Remove-Extension $b }
  'GET /api/shortcuts'       = { Get-BrokenShortcuts }
  'POST /api/shortcuts/remove' = { param($b) Remove-Shortcuts $b.paths }
  'GET /api/drivers'         = { Get-Drivers }
  'GET /api/drivers/wu'      = { Find-DriverUpdates }
  'GET /api/health'          = { Get-Health }
  'GET /api/volumes'         = { Get-Volumes }
  'POST /api/volumes/action' = { param($b) Invoke-VolumeAction $b }
  'POST /api/system'         = { param($b) @{ message = (Invoke-SystemAction $b) } }
  'POST /api/open'           = { param($b) if ("$($b.url)" -match '^https://[\w\.\-/\?=&%#]+$') { Start-Process $b.url }; @{ ok = $true } }
  'POST /api/quit'           = { $script:Quit = $true; @{ ok = $true } }
}

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type, [int]$code = 200) {
  $res = $ctx.Response
  $res.StatusCode = $code
  $res.ContentType = $type
  $res.Headers.Add('Cache-Control', 'no-store')
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}
function Send-Json($ctx, $obj, [int]$code = 200) {
  $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
  Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $code
}

# ---------------------------------------------------------------- server
$uiPath = Join-Path $Root 'ui.html'
if (-not (Test-Path -LiteralPath $uiPath)) { Write-Host 'ui.html is missing - keep it next to Tweakr23.ps1.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }

$listener = New-Object System.Net.HttpListener
$Port = $null
for ($i = 0; $i -lt 10 -and -not $Port; $i++) {
  $try = Get-Random -Minimum 49200 -Maximum 64900
  try { $listener.Prefixes.Clear(); $listener.Prefixes.Add("http://localhost:$try/"); $listener.Start(); $Port = $try } catch { $listener = New-Object System.Net.HttpListener }
}
if (-not $Port) { Write-Host 'Could not open a local port.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }

$Url = "http://localhost:$Port/?t=$Token"
Write-Host ''
Write-Host '  TWEAKR23  ' -ForegroundColor Black -BackgroundColor Cyan
Write-Host '  Panel is running. Close this window (or press Quit in the panel) to stop.' -ForegroundColor Cyan
Write-Host ''

# Open the panel in its own app window, with a private browser profile so it
# never locks your real Edge/Chrome profile (needed for cache cleaning).
$uiProfile = Join-Path $env:TEMP 'Tweakr23-ui'
$appArgs = @("--app=$Url", "--user-data-dir=`"$uiProfile`"", '--window-size=1320,880', '--no-first-run', '--no-default-browser-check', '--disable-sync')
$edge = Resolve-AppExe 'msedge.exe'; $chrome = Resolve-AppExe 'chrome.exe'
if (Test-Path -LiteralPath $edge -EA SilentlyContinue) { Start-Process $edge -ArgumentList $appArgs }
elseif (Test-Path -LiteralPath $chrome -EA SilentlyContinue) { Start-Process $chrome -ArgumentList $appArgs }
else { Start-Process $Url }

$script:Quit = $false
try {
  while ($listener.IsListening -and -not $script:Quit) {
    $async = $listener.BeginGetContext($null, $null)
    $idle = $false
    while (-not $async.AsyncWaitHandle.WaitOne(1000)) {
      if (((Get-Date) - $script:LastPing).TotalSeconds -gt $IdleExitSeconds) { $idle = $true; break }
    }
    if ($idle) { Out-Line 'Panel closed - shutting down.' 'DarkGray'; break }
    $ctx = $listener.EndGetContext($async)
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    try {
      if ($path -eq '/') {
        if ($req.QueryString['t'] -ne $Token) { Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes('Forbidden')) 'text/plain' 403; continue }
        $html = [IO.File]::ReadAllText($uiPath, [Text.Encoding]::UTF8).Replace('__TOKEN__', $Token)
        Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
        $script:LastPing = Get-Date
        continue
      }
      if ($req.Headers['X-Token'] -ne $Token) { Send-Json $ctx @{ error = 'Forbidden' } 403; continue }
      $script:LastPing = Get-Date
      $key = "$($req.HttpMethod) $path"
      $handler = $Routes[$key]
      if (-not $handler) { Send-Json $ctx @{ error = "No route $key" } 404; continue }
      $body = $null
      if ($req.HasEntityBody) {
        $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd(); $reader.Close()
        if ($raw) { $body = $raw | ConvertFrom-Json }
      }
      if ($path -ne '/api/ping') { Out-Line $key 'DarkCyan' }
      $result = & $handler $body
      Send-Json $ctx $result
    } catch {
      Out-Line "ERROR $path : $($_.Exception.Message)" 'Red'
      try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch {}
    }
  }
} finally {
  $listener.Stop(); $listener.Close()
}
