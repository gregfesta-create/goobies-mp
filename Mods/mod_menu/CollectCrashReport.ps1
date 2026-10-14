<#
.SYNOPSIS
    Collects Goobies crash information into one zip, then sends it (when allowed) or leaves it in your Downloads folder.
.DESCRIPTION
    Read-only on the game folder; needs no admin rights. Copies UE4SS logs, mod configuration, Goobies MP
    logs and settings (last 5 MB of each appended log), the newest achievement-guard log, the newest crash
    folder's context and (if small enough) the newest crash dump. Text files are sanitized: user name,
    profile folder (long and 8.3 form), computer name, Steam IDs (also steam:<id> and masked forms), lobby
    IDs, IP and e-mail addresses, network host names, webhook URLs and the account fields in
    CrashContext.runtime-xml are replaced. Dump files (.dmp) are binary and cannot be sanitized;
    use -NoDump to leave them out. On failure it writes Goobies_crash_report_FAILED.txt explaining
    how to retry. Without -NoExplorer it then shows the zip and opens the GitHub issue page (-IssueUrl).

    Nothing is uploaded unless a Discord webhook file exists (report_webhook.txt next to this script, or
    -WebhookFile) AND you answer Y to the question it asks. The webhook address is never printed or saved
    in the report. With a webhook file the zip is built in %TEMP% and deleted once Discord has it; a report
    that is not sent (No, or an upload problem) is moved to -OutDir (default: Downloads) and the GitHub page opens.
    With -Gui (used by "Report a problem.bat", which runs this hidden) the question is a Yes/No popup and
    a sent report ends with a notice that closes by itself; there is no console window to read.

    -AutoCrash (Mod Menu starts it hidden a few seconds after the game starts) reports a crash of THIS game copy by
    itself and exits silently when there is nothing to do: it needs a valid webhook file; it looks for crash folders
    (-CrashesRoot) that are newer than the marker in %LOCALAPPDATA%\Goobies_report\seen.txt, not yet seen, and whose
    CrashContext RootDir/BaseDir is this game copy; every one it finds is marked seen and only the newest is reported,
    at most 3 a day (auto_sent.txt next to the marker). Consent is %LOCALAPPDATA%\Goobies_report\consent.txt:
    ask (default: one Yes/No popup; Yes saves auto and sends, No saves off), auto (send, then a short notice) or off;
    CrashReports=ask|auto|off in this copy's Configs\ModMenu.ini overrides it. The first run only sets the marker.
    GOOBIES_REPORT_SEEN / GOOBIES_REPORT_CONSENT override the two files (tests only).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File CollectCrashReport.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File CollectCrashReport.ps1 -GameDir "D:\SteamLibrary\steamapps\common\Goobies" -NoDump
#>
[CmdletBinding()]
param(
    [string]$GameDir,        # Goobies folder (common\Goobies, or Goobies_DX11 / Goobies_Vulkan inside it); auto-detected if omitted
    [string]$OutDir,         # where an unsent zip goes; default is your Downloads folder
    [string]$CrashesRoot,    # default %LOCALAPPDATA%\Shooter\Saved\Crashes
    [string]$SteamRoot,      # Steam folder; default from the registry (HKCU\Software\Valve\Steam)
    [switch]$NoDump,         # never include a .dmp file
    [switch]$NoExplorer,     # do not open Explorer, the issue page (or Notepad on failure) at the end
    [string]$IssueUrl = 'https://github.com/gregfesta-create/goobies-mod-menu/issues/new?template=crash_report.yml',
    [string]$WebhookFile,    # Discord webhook file; default report_webhook.txt next to this script
    [long]$UploadLimitBytes = 10MB,  # largest zip sent to Discord (non-boosted servers); a bigger one is re-zipped without the dump
    [switch]$Gui,            # ask and report with popups (the .bat runs this script with no visible window)
    [switch]$AutoCrash       # automatic crash report of this game copy (Mod Menu runs it hidden at game start)
)
$ErrorActionPreference = 'Stop'
$Version = '1.5.0'
$MaxDumpBytes = 20MB
$MaxLogBytes = 5MB
$DefaultIssueUrl = 'https://github.com/gregfesta-create/goobies-mod-menu/issues/new?template=crash_report.yml'
$WebhookPattern = '^https://(discord\.com|discordapp\.com)/api/webhooks/\d+/[\w-]+$'

function Test-GameRoot([string]$Dir) {
    return $Dir -and (Test-Path -LiteralPath (Join-Path $Dir 'Shooter\Binaries\Win64') -PathType Container)
}

# A folder may be a game root itself or hold several (Steam ships Goobies_DX11\ and Goobies_Vulkan\).
# With several, prefer the newest UE4SS.log, then one with a Mods folder, then DX11.
$script:GameChoice = $null
function Select-GameRoot([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $cands = @(@($Dir) + @(Get-ChildItem -LiteralPath $Dir -Directory | ForEach-Object { $_.FullName }) |
               Where-Object { Test-GameRoot $_ })
    if ($cands.Count -le 1) { return $cands | Select-Object -First 1 }
    $ranked = $cands | ForEach-Object {
        $w = Join-Path $_ 'Shooter\Binaries\Win64'
        $log = Get-Item -LiteralPath (Join-Path $w 'UE4SS.log') -ErrorAction SilentlyContinue
        [pscustomobject]@{ Dir = $_; Log = $(if ($log) { $log.LastWriteTimeUtc } else { [datetime]::MinValue })
                           Mods = [int](Test-Path -LiteralPath (Join-Path $w 'Mods')); Dx = [int]((Split-Path -Leaf $_) -match 'DX11') }
    } | Sort-Object Log, Mods, Dx -Descending
    $best = $ranked[0]
    $why = if ($best.Log -ne [datetime]::MinValue) { 'newest UE4SS.log' } elseif ($best.Mods) { 'has a Mods folder' } else { 'DX11 default' }
    $script:GameChoice = "Found several Goobies installs: $(($cands | ForEach-Object { Split-Path -Leaf $_ }) -join ', '). " +
                         "Using $(Split-Path -Leaf $best.Dir) ($why); pass -GameDir to pick another."
    return $best.Dir
}

# Steam: SteamPath (registry, or -SteamRoot) plus every library listed in libraryfolders.vdf.
function Find-SteamGame {
    $steam = $SteamRoot
    if (-not $steam) {
        try { $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath).SteamPath } catch { return $null }
    }
    if (-not $steam) { return $null }
    $steam = [IO.Path]::GetFullPath($steam)   # registry value uses forward slashes
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
            $libs += $m.Groups[1].Value -replace '\\\\', '\'
        }
    }
    foreach ($lib in $libs | Select-Object -Unique) {
        $found = Select-GameRoot (Join-Path $lib 'steamapps\common\Goobies')
        if ($found) { return $found }
    }
    return $null
}

# The script's own folder (or a parent of it), when it sits inside or beside a Goobies install.
function Find-ParentGame {
    $dir = $PSScriptRoot
    while ($dir) {
        $found = Select-GameRoot $dir
        if ($found) { return $found }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Format-Span([TimeSpan]$Span) {
    $s = $Span.Duration()
    if ($s.TotalDays -ge 1) { return '{0}d {1}h' -f [math]::Floor($s.TotalDays), $s.Hours }
    if ($s.TotalHours -ge 1) { return '{0}h {1}m' -f $s.Hours, $s.Minutes }
    return '{0}m' -f [math]::Floor($s.TotalMinutes)
}

# Read a text file even while the game still has it open for writing. Honour a BOM; otherwise
# decode as strict UTF-8 and fall back to the ANSI code page, so non-ASCII names in a cp1252 file still match.
# With -TailBytes, a longer file keeps only its last TailBytes, starting at a whole line, behind a note.
function Read-Shared([string]$Path, [long]$TailBytes = 0) {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $skip = 0
        if ($TailBytes -gt 0 -and $fs.Length -gt $TailBytes) { $skip = $fs.Length - $TailBytes; [void]$fs.Seek($skip, 'Begin') }
        $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); $b = $ms.ToArray()
    } finally { $fs.Dispose() }
    if ($skip -gt 0) {   # drop the partial first line (also avoids a split UTF-8 character)
        $nl = [Array]::IndexOf($b, [byte]10)
        $cut = if ($nl -ge 0) { $nl + 1 } else { 0 }
        $rest = New-Object byte[] ($b.Length - $cut)
        [Array]::Copy($b, $cut, $rest, 0, $rest.Length)
        $b = $rest
        $note = "[CollectCrashReport: first {0:N0} bytes left out; this log keeps only its last {1:N0} MB]`r`n" -f ($skip + $cut), ($TailBytes / 1MB)
        return $note + (Convert-Bytes $b)
    }
    return Convert-Bytes $b
}

function Convert-Bytes([byte[]]$b) {
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
    try { return (New-Object Text.UTF8Encoding($false, $true)).GetString($b) } catch { return [Text.Encoding]::Default.GetString($b) }
}

# Redaction rules, built once: profile paths (long and 8.3, either slash) first, then names.
$profiles = @($env:USERPROFILE)
try { $profiles += (New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:USERPROFILE).ShortPath } catch { }
$profiles = @($profiles | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') } | Select-Object -Unique)
$Redactions = New-Object System.Collections.Generic.List[object]
foreach ($p in $profiles) {
    $rx = (($p -split '[\\/]+' | ForEach-Object { [regex]::Escape($_) }) -join '[\\/]+') + '(?![A-Za-z0-9])'
    $Redactions.Add(@("(?i)$rx", '<userprofile>'))
}
$names = @(@($env:USERNAME) + @($profiles | ForEach-Object { Split-Path -Leaf $_ }) | Where-Object { $_.Length -ge 2 } |
           Sort-Object Length -Descending | Select-Object -Unique)
foreach ($n in $names) { $Redactions.Add(@(('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($n) + '(?![A-Za-z0-9])'), '<user>')) }
if ($env:COMPUTERNAME) { $Redactions.Add(@(('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($env:COMPUTERNAME) + '(?![A-Za-z0-9])'), '<pc>')) }
$octet = '(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
foreach ($rule in @(
        @('(?s)<(UserName|LoginId|EpicAccountId|MachineId|UserActivityHint)>.*?</\1>', '<$1></$1>'),
        # Goobies MP identity keys: steam:<SteamID64> and the masked log form steam:7656...5678 / steam:7656<ellipsis>5678.
        @("(?i)(?<![A-Za-z0-9])steam:\d[\d.$([char]0x2026)]*", 'steam:<steamid>'),
        @('(?<!\d)7656119\d{10}(?!\d)', '<steamid>'),
        @('(?i)https?://(?:[a-z0-9-]+\.)*(?:discord\.com|discordapp\.com)/api/webhooks/\S+', '<webhook>'),
        @('(?<!\d)109775\d{12}(?!\d)', '<lobby>'),
        # Bounded e-mail parts keep this linear on very long tokens.
        @('(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,24}', '<email>'),
        # Four octets only (1.1.3 stays), and not version numbers such as "version 4.27.2.0", "v4.27.2.0", "UE4.27.2.0".
        @("(?<!\d)(?<!\d\.)(?<!(?i:\bv|\bver|\bversion|\bue)[\s:=]*)(?:$octet\.){3}$octet(?!\.?\d)", '<ip>'),
        @('(?<![\w:\\])\\\\[A-Za-z0-9][A-Za-z0-9._$-]*\\', '\\<host>\'))) { $Redactions.Add($rule) }

function Protect-Text([string]$Text) {
    foreach ($r in $Redactions) { $Text = [regex]::Replace($Text, $r[0], $r[1]) }
    return $Text
}

$included = New-Object System.Collections.Generic.List[string]
$modVersions = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]
function Add-TextFile([string]$Source, [string]$Rel, [long]$TailBytes = 0) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    try {
        $dest = Join-Path $stage $Rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        [IO.File]::WriteAllText($dest, (Protect-Text (Read-Shared $Source $TailBytes)), (New-Object Text.UTF8Encoding($false)))
        $included.Add($Rel)
    } catch { $skipped.Add("$Rel ($($_.Exception.Message))") }   # e.g. locked by another program
}

# Never prompt: on failure leave a text file next to where the zip would go and open it.
function Write-Failure([string]$Reason) {
    # Sanitized like the report (people paste this file into issues); a script under the profile
    # folder keeps a working command by spelling the profile as $env:USERPROFILE.
    $cmd = (Protect-Text ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -GameDir "<your Goobies folder>"' -f $PSCommandPath)).Replace('<userprofile>', '$env:USERPROFILE')
    $text = @('CollectCrashReport.ps1 could not create a crash report.', '', "Reason: $(Protect-Text $Reason)", '', 'How to retry:',
        '1. Find your Goobies folder: in Steam, right-click Goobies > Manage > Browse local files.',
        '2. Open PowerShell in the folder that holds CollectCrashReport.ps1: Shift+right-click an empty spot in it',
        '   and choose "Open PowerShell window here" (Windows 11: right-click > "Open in Terminal").',
        '3. Run this command, with <your Goobies folder> replaced by the folder from step 1:', '', "   $cmd", '',
        'If Windows blocks the script: right-click it > Properties > Unblock, or run Unblock-File on it.') -join "`r`n"
    Write-Output $text
    $dir = $OutDir
    try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { $dir = $env:TEMP }
    $file = Join-Path $dir 'Goobies_crash_report_FAILED.txt'
    [IO.File]::WriteAllText($file, $text)
    Write-Output ''
    Write-Output "Details saved to: $file"
    if (-not $NoExplorer) { Start-Process notepad.exe -ArgumentList "`"$file`"" }
}

# ---- optional Discord upload ---------------------------------------------------------------------
# The webhook address is a secret (anyone holding it can post): it is never printed, logged or zipped.
# State: none (no file), invalid (file holds something else), ok (Url is a Discord webhook).
function Read-Webhook {
    $file = if ($WebhookFile) { $WebhookFile } else { Join-Path $PSScriptRoot 'report_webhook.txt' }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return [pscustomobject]@{ State = 'none'; Url = $null } }
    $line = $null
    try {
        $line = @((Read-Shared $file) -split "`r?`n" | ForEach-Object { $_.Trim() } |
                  Where-Object { $_ -and -not $_.StartsWith('#') }) | Select-Object -First 1
    } catch { }
    # ECMAScript: \d and \w are ASCII only.
    if ($line -and [regex]::IsMatch($line, $WebhookPattern, 'IgnoreCase, ECMAScript')) { return [pscustomobject]@{ State = 'ok'; Url = $line } }
    return [pscustomobject]@{ State = 'invalid'; Url = $null }
}

function Hide-Webhook([string]$Text, [string]$Url) {
    if ($Url) {
        $parts = $Url.Split('/')
        foreach ($s in @($Url) + @($parts[-1], $parts[-2])) { if ($s) { $Text = $Text.Replace($s, '<webhook>') } }
    }
    return Protect-Text $Text
}

# One multipart POST (payload_json + files[0]). Returns Ok/Status/Body; throws on network errors.
# GOOBIES_REPORT_UPLOAD_MOCK (tests only) replaces the network send: ok | fail | textchannel;
# the request body is written to GOOBIES_REPORT_UPLOAD_MOCK_OUT.
function Send-Webhook([string]$Url, [string]$ZipFile, [string]$Message, [string]$ThreadName) {
    Add-Type -AssemblyName System.Net.Http
    $payload = [ordered]@{ content = $Message }
    if ($ThreadName) { $payload.thread_name = $ThreadName }   # a forum channel needs a post title
    $payload.allowed_mentions = @{ parse = @() }               # never ping anyone
    $form = New-Object System.Net.Http.MultipartFormDataContent
    try {
        $jsonPart = New-Object System.Net.Http.StringContent((ConvertTo-Json $payload -Compress -Depth 4), [Text.Encoding]::UTF8, 'application/json')
        $cd = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue('form-data'); $cd.Name = '"payload_json"'
        $jsonPart.Headers.ContentDisposition = $cd
        $form.Add($jsonPart)
        $filePart = New-Object System.Net.Http.ByteArrayContent(, [IO.File]::ReadAllBytes($ZipFile))
        $filePart.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/zip')
        $cd = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue('form-data')
        $cd.Name = '"files[0]"'; $cd.FileName = '"' + [IO.Path]::GetFileName($ZipFile) + '"'
        $filePart.Headers.ContentDisposition = $cd
        $form.Add($filePart)
        $mock = $env:GOOBIES_REPORT_UPLOAD_MOCK
        if ($mock) {
            if ($env:GOOBIES_REPORT_UPLOAD_MOCK_OUT) {
                [IO.File]::WriteAllBytes($env:GOOBIES_REPORT_UPLOAD_MOCK_OUT, $form.ReadAsByteArrayAsync().GetAwaiter().GetResult())
            }
            if ($mock -eq 'ok' -or ($mock -eq 'textchannel' -and -not $ThreadName)) { return [pscustomobject]@{ Ok = $true; Status = 204; Body = '' } }
            if ($mock -eq 'textchannel') {
                return [pscustomobject]@{ Ok = $false; Status = 400; Body = '{"message": "Webhooks can only create threads in forum channels", "code": 220003}' }
            }
            throw "mock network failure while posting to $Url"
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        try {
            $resp = $client.PostAsync($Url, $form).GetAwaiter().GetResult()
            $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return [pscustomobject]@{ Ok = $resp.IsSuccessStatusCode; Status = [int]$resp.StatusCode; Body = [string]$body }
        } catch {
            $base = $_.Exception.GetBaseException()
            if ($base -is [Threading.Tasks.TaskCanceledException]) { throw 'Discord did not answer within 60 seconds.' }
            throw $base.Message
        } finally { $client.Dispose() }
    } finally { $form.Dispose() }
}

# Step log of the newest run (no window, so this is how a silent run is diagnosed): one sanitized line per step in
# %LOCALAPPDATA%\Goobies_report\last_run.txt (GOOBIES_REPORT_RUNLOG overrides; tests only). Never throws.
function Write-RunLog([string]$Line, [switch]$New) {
    try {
        $file = if ($env:GOOBIES_REPORT_RUNLOG) { $env:GOOBIES_REPORT_RUNLOG } else { Join-Path $env:LOCALAPPDATA 'Goobies_report\last_run.txt' }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        $text = '{0} {1}{2}' -f (Get-Date).ToString('HH:mm:ss.fff'), (Protect-Text $Line), "`r`n"
        if ($New) { [IO.File]::WriteAllText($file, $text) } else { [IO.File]::AppendAllText($file, $text) }
    } catch { }
}

# -Gui popups: -Ask shows Yes/No (default No) and returns $true for Yes; otherwise an information notice
# that closes after -Seconds (0 = waits for OK). GOOBIES_REPORT_GUI_MOCK (tests only) answers instead of
# showing a window (yes|no) and appends each popup's text to GOOBIES_REPORT_GUI_MOCK_OUT.
function Show-Popup([string]$Text, [switch]$Ask, [int]$Seconds = 0) {
    if ($env:GOOBIES_REPORT_GUI_MOCK) {
        if ($env:GOOBIES_REPORT_GUI_MOCK_OUT) { [IO.File]::AppendAllText($env:GOOBIES_REPORT_GUI_MOCK_OUT, "$Text`n----`n") }
        return ($Ask -and $env:GOOBIES_REPORT_GUI_MOCK -eq 'yes')
    }
    $title = 'Goobies - Report a problem'
    try {
        if ($Ask) {
            # Windows Script Host popup: the WinForms MessageBox returned No at once (15 ms) when the .bat started
            # this script from Explorer. 4 Yes/No, 32 question icon, 256 No is the default, 0x40000 always on top;
            # no answer within 10 minutes counts as No. Returns 6 for Yes, 7 for No, -1 on timeout.
            $code = (New-Object -ComObject WScript.Shell).Popup($Text, 600, $title, 4 + 32 + 256 + 0x40000)
            Write-RunLog "popup answer code=$code"
            return ($code -eq 6)
        }
        # 0x40 information icon, 0x40000 always on top.
        [void](New-Object -ComObject WScript.Shell).Popup($Text, $Seconds, $title, 0x40040)
    } catch { Write-RunLog "popup error: $($_.Exception.Message)" }
    return $false
}

# ---- -AutoCrash state: consent, seen-crash marker, daily count -----------------------------------------
$AutoDailyLimit = 3
$AutoSeenKeep = 200
$AutoAskText = "Goobies crashed last time. Send crash reports to the Goobies developers automatically from now on?`n`n" +
               "Yes = send this one and future ones automatically. No = don't send."
function Get-StateFile([string]$EnvName, [string]$Leaf) {
    $v = [Environment]::GetEnvironmentVariable($EnvName)
    if ($v) { return $v }
    return Join-Path $env:LOCALAPPDATA "Goobies_report\$Leaf"
}
function Write-StateText([string]$File, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $File) | Out-Null
    [IO.File]::WriteAllText($File, $Text)
}
# ask | auto | off. This copy's Configs\ModMenu.ini (CrashReports=auto|off) is the Mod Menu setting and wins; it is saved.
function Read-Consent([string]$Win64) {
    $file = Get-StateFile 'GOOBIES_REPORT_CONSENT' 'consent.txt'
    $ini = Join-Path $Win64 'Configs\ModMenu.ini'
    if (Test-Path -LiteralPath $ini -PathType Leaf) {
        try {
            $m = [regex]::Match((Read-Shared $ini), '(?im)^\s*CrashReports\s*=\s*(auto|off)\s*$')
            if ($m.Success) {
                $v = $m.Groups[1].Value.ToLower()
                $old = if (Test-Path -LiteralPath $file) { ([IO.File]::ReadAllText($file)).Trim().ToLower() } else { '' }
                if ($old -ne $v) { Write-StateText $file "$v`r`n" }
                return $v
            }
        } catch { }
    }
    try {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $v = ([IO.File]::ReadAllText($file)).Trim().ToLower()
            if ($v -in 'ask', 'auto', 'off') { return $v }
        }
    } catch { }
    return 'ask'
}
function Save-Consent([string]$Value) { Write-StateText (Get-StateFile 'GOOBIES_REPORT_CONSENT' 'consent.txt') "$Value`r`n" }
# seen.txt: "since=<UTC time>" (no older crash is ever reported) and one handled crash folder name per line.
function Read-Seen {
    $file = Get-StateFile 'GOOBIES_REPORT_SEEN' 'seen.txt'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $lines = @([IO.File]::ReadAllLines($file) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $since = $null
    if ($lines.Count -and $lines[0] -match '^since=(.+)$') {
        try { $since = [datetime]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime() } catch { }
    }
    if (-not $since) { return $null }
    return [pscustomobject]@{ Since = $since; Names = @($lines | Select-Object -Skip 1) }
}
function Save-Seen([datetime]$Since, [string[]]$Names) {
    $keep = @($Names | Where-Object { $_ } | Select-Object -Unique | Select-Object -Last $AutoSeenKeep)
    Write-StateText (Get-StateFile 'GOOBIES_REPORT_SEEN' 'seen.txt') (((@('since=' + $Since.ToUniversalTime().ToString('o')) + $keep) -join "`r`n") + "`r`n")
}
# The game folder a crash came from (CrashContext RootDir, else BaseDir minus Shooter\Binaries\Win64), or $null.
function Get-CrashGameDir([string]$CrashDir) {
    $ctx = Join-Path $CrashDir 'CrashContext.runtime-xml'
    if (-not (Test-Path -LiteralPath $ctx -PathType Leaf)) { return $null }
    try { $raw = Read-Shared $ctx } catch { return $null }
    foreach ($tag in 'RootDir', 'BaseDir') {
        $m = [regex]::Match($raw, "<$tag>([^<]+)</$tag>")
        if (-not $m.Success) { continue }
        try { $dir = [IO.Path]::GetFullPath($m.Groups[1].Value).TrimEnd('\') } catch { continue }
        if ($tag -eq 'BaseDir') { $dir = $dir -replace '(?i)\\Shooter\\Binaries\\Win64$', '' }
        return $dir
    }
    return $null
}
# True when the crash folder's CrashContext RootDir/BaseDir is $Root (or inside it).
function Test-CrashOfCopy([string]$CrashDir, [string]$Root) {
    $dir = Get-CrashGameDir $CrashDir
    return [bool]($dir -and ($dir -ieq $Root -or $dir.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)))
}
# Decides whether to report now. Returns the crash folder to report, or $null (nothing to do; the reason is logged).
function Invoke-AutoPreflight([string]$Root, [string]$Win64, [string]$Crashes) {
    if ((Read-Webhook).State -ne 'ok') { Write-RunLog 'auto: no webhook'; return $null }
    $consent = Read-Consent $Win64
    if ($consent -eq 'off') { Write-RunLog 'auto: consent off'; return $null }
    $seen = Read-Seen
    if (-not $seen) { Save-Seen (Get-Date).ToUniversalTime() @(); Write-RunLog 'auto: first run, marker set'; return $null }
    $new = @()
    if (Test-Path -LiteralPath $Crashes -PathType Container) {
        $new = @(Get-ChildItem -LiteralPath $Crashes -Directory |
                 Where-Object { $_.LastWriteTimeUtc -gt $seen.Since -and $seen.Names -notcontains $_.Name -and (Test-CrashOfCopy $_.FullName $Root) } |
                 Sort-Object LastWriteTimeUtc -Descending)
    }
    if (-not $new.Count) { Write-RunLog 'auto: no new crash'; return $null }
    Save-Seen $seen.Since (@($seen.Names) + @($new | ForEach-Object { $_.Name }))
    Write-RunLog "auto: new crashes=$($new.Count) consent=$consent"
    $daily = Join-Path (Split-Path -Parent (Get-StateFile 'GOOBIES_REPORT_SEEN' 'seen.txt')) 'auto_sent.txt'
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $days = @(if (Test-Path -LiteralPath $daily) { [IO.File]::ReadAllLines($daily) | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    if (@($days | Where-Object { $_ -eq $today }).Count -ge $AutoDailyLimit) { Write-RunLog 'auto: daily limit reached'; return $null }
    if ($consent -eq 'ask') {
        Write-RunLog 'auto: asked (popup)'
        if (-not (Show-Popup $AutoAskText -Ask)) { Save-Consent 'off'; Write-RunLog 'auto: answer=no, consent off'; return $null }
        Save-Consent 'auto'; Write-RunLog 'auto: answer=yes, consent auto'
    }
    Write-StateText $daily (((@($days | Select-Object -Last 20) + $today) -join "`r`n") + "`r`n")
    return $new[0]
}
# "active (gmp_host.log written 3m before the crash)" when a GoobiesMP log was written in the 5 minutes before it.
function Get-MultiplayerNote($Crash, [string]$MpDir) {
    if (-not $Crash -or -not $MpDir -or -not (Test-Path -LiteralPath $MpDir -PathType Container)) { return 'not active' }
    $t = $Crash.LastWriteTime
    $log = Get-ChildItem -LiteralPath $MpDir -File | Where-Object { $_.Name -match '^gmp(_[^\\/]*)?\.log$' -and
             $_.LastWriteTime -ge $t.AddMinutes(-5) -and $_.LastWriteTime -le $t.AddMinutes(1) } |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { return 'not active' }
    return 'active ({0} written {1} before the crash)' -f $log.Name, (Format-Span ($t - $log.LastWriteTime))
}

# 'in your Downloads folder' or 'in <folder>' for where the zip ends up (a staged zip: where it is moved if kept).
function Get-ZipWhere {
    $zipDir = if ($uploadStage) { $OutDir } else { Split-Path -Parent $zipPath }
    $downloads = Get-DownloadsFolder
    if ($downloads -and $zipDir.TrimEnd('\') -ieq $downloads.TrimEnd('\')) { return 'in your Downloads folder' }
    return "in $zipDir"
}

# The Downloads known folder (it may be moved to another drive); $null when Windows cannot say.
function Get-DownloadsFolder {
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { return $p }
    } catch { }
    $p = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path -LiteralPath $p -PathType Container) { return $p }
    return $null
}

# Asks first (default No); sends the zip, or a copy without the dump when it is over the limit.
# Returns $true only when Discord accepted the report.
function Send-Report([string]$Url) {
    $answer = $null
    if ($AutoCrash) {
        $answer = 'y'; Write-RunLog 'auto: sending (consent given)'
    } elseif ($Gui) {
        $q = "A problem report was made (game logs, mod settings and the newest crash dump; your name and IDs are removed).`n`nSend it to the Goobies MP developers?"
        Write-RunLog 'asked (popup)'
        if (Show-Popup $q -Ask) { $answer = 'y' }
    } else {
        Write-Output ''
        Write-RunLog 'asked (console)'
        Write-Host -NoNewline 'Send this report to the Goobies MP developers? (Y/N) '
        try { $answer = [Console]::In.ReadLine() } catch { }
        Write-Output ''
    }
    $yes = $answer -match '^\s*y(es)?\s*$'
    Write-RunLog ('answer=' + $(if ($yes) { 'yes' } else { 'no' }))
    if (-not $yes) { Write-Output 'Not sent.'; return }
    $script:tried = $true

    $file = $zipPath; $tmpDir = $null
    $dumpState = if ($dumpEntry) { 'included' } else { 'not included' }
    $dumpNoteText = $null
    try {
        $size = (Get-Item -LiteralPath $file).Length
        if ($size -gt $UploadLimitBytes -and $dumpEntry) {
            $tmpDir = Join-Path $env:TEMP "Goobies_report_upload_$PID"
            New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
            $file = Join-Path $tmpDir (Split-Path -Leaf $zipPath)
            $src = [IO.Compression.ZipFile]::OpenRead($zipPath)
            $dst = [IO.Compression.ZipFile]::Open($file, 'Create')
            try {
                foreach ($e in $src.Entries) {
                    if ($e.FullName -eq $dumpEntry) { continue }
                    $in = $e.Open(); $out = $dst.CreateEntry($e.FullName).Open()
                    try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
                }
            } finally { $dst.Dispose(); $src.Dispose() }
            $dumpNoteText = "The crash dump was too large for Discord and was left out; the full zip is $(Get-ZipWhere)."
            $script:keepFull = $true
            Write-Output $dumpNoteText
            $dumpState = 'left out (too large for Discord)'
            $size = (Get-Item -LiteralPath $file).Length
        }
        if ($size -gt $UploadLimitBytes) {
            Write-Output ('Not sent: the report is too big for Discord ({0:N1} MB).' -f ($size / 1MB))
            return
        }
        $now = Get-Date
        $versions = @($modVersions | Where-Object { $_ -like 'GoobiesMP *' } | ForEach-Object { 'Goobies MP' + $_.Substring(9) }) +
                    @($modVersions | Where-Object { $_ -notlike 'GoobiesMP *' })
        $mods = if ($versions.Count) { $versions -join ', ' } else { 'none found' }
        $kind = if ($AutoCrash) { 'Automatic crash report' } else { 'Goobies crash report' }
        $autoLines = @()
        if ($AutoCrash -and $crash) {
            $autoLines = @("Crash: $($crash.Name) at $($crash.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))", "Multiplayer: $(Get-MultiplayerNote $crash $mpDir)")
        }
        $message = Protect-Text (@("$kind (CollectCrashReport $Version)",
            "Report time: $($now.ToString('yyyy-MM-dd HH:mm:ss zzz'))", "Mods: $mods") + $autoLines + @("Crash dump: $dumpState") + @($dumpNoteText | Where-Object { $_ }) -join "`n")
        if ($message.Length -gt 1900) { $message = $message.Substring(0, 1900) }
        $threadKind = if ($AutoCrash) { 'Automatic crash report' } else { 'Crash report' }
        $thread = Protect-Text ("$threadKind $($now.ToString('yyyy-MM-dd HH:mm')) - $mods")
        if ($thread.Length -gt 100) { $thread = $thread.Substring(0, 97) + '...' }

        Write-Output 'Sending...'
        $r = Send-Webhook $Url $file $message $thread
        # A text channel (not a forum) may refuse a post title; send once more without it.
        if (-not $r.Ok -and $r.Status -eq 400 -and $r.Body -match '220003|thread_name|forum') { $r = Send-Webhook $Url $file $message '' }
        if (-not $r.Ok) {
            $detail = if ($r.Body.Length -gt 200) { $r.Body.Substring(0, 200) } else { $r.Body }
            throw "Discord answered $($r.Status). $detail"
        }
        Write-RunLog "sent status=$($r.Status)"
        Write-Output 'Sent. Thank you - the Goobies MP developers have your report.'
        $script:sent = $true
    } catch {
        Write-RunLog "send failed: $(Hide-Webhook $_.Exception.Message $Url)"
        Write-Output "Could not send the report: $(Hide-Webhook $_.Exception.Message $Url)"
    } finally {
        if ($tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-RunLog "start version=$Version gui=$Gui auto=$AutoCrash pid=$PID" -New
# -AutoCrash runs hidden: popups only, never a folder, a page or Notepad.
if ($AutoCrash) { $Gui = [switch]$true; $NoExplorer = [switch]$true }
if (-not $OutDir) { $OutDir = Get-DownloadsFolder }
if (-not $OutDir) { $OutDir = $env:USERPROFILE }
$uploadStage = $null; $keepFull = $false
# Upload staging folders left by an interrupted run (older than a day) are removed; only this script's own prefix.
Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'Goobies_report_*' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
# Start-Process opens whatever it is given, so only a web address is accepted for the issue page.
if ($IssueUrl -notmatch '^https://[^\s"]+$') {
    Write-Output 'Note: -IssueUrl must start with https:// - using the default GitHub page.'
    $IssueUrl = $DefaultIssueUrl
}
$dumpEntry = $null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stage = Join-Path $env:TEMP "Goobies_crash_report_$stamp`_$PID"
$zipPath = $null; $zipDone = $false
try {
    # ---- 1. locate the game ------------------------------------------------------------------
    if ($GameDir) {
        $found = Select-GameRoot $GameDir
        if (-not $found) { throw "Goobies was not found at '$GameDir' (expected a Shooter\Binaries\Win64 folder in it or in a Goobies_DX11 / Goobies_Vulkan folder inside it)." }
        $GameDir = $found
    } else {
        # A copy of this script inside a game folder (it ships in Win64\Mods\mod_menu) reports that copy;
        # otherwise the Steam install.
        $GameDir = Find-ParentGame
        if (-not $GameDir) { $GameDir = Find-SteamGame }
        if (-not $GameDir) { throw 'The Goobies install was not found automatically (checked your Steam libraries and the folders around this script).' }
    }
    $GameDir = (Resolve-Path -LiteralPath $GameDir).Path.TrimEnd('\')
    if ($script:GameChoice) { Write-Output $script:GameChoice }
    Write-Output "Game folder: $GameDir"
    $win64 = Join-Path $GameDir 'Shooter\Binaries\Win64'
    if (-not $CrashesRoot) { $CrashesRoot = Join-Path $env:LOCALAPPDATA 'Shooter\Saved\Crashes' }
    $autoCrashDir = $null
    if ($AutoCrash) {
        $autoCrashDir = Invoke-AutoPreflight $GameDir $win64 $CrashesRoot
        if (-not $autoCrashDir) { Write-RunLog 'end auto: nothing to do'; exit 0 }
    }
    # The crash to report: -AutoCrash's pick, else the newest crash folder.
    $crash = $autoCrashDir
    if (-not $crash -and (Test-Path -LiteralPath $CrashesRoot)) {
        $crash = Get-ChildItem -LiteralPath $CrashesRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    # A crash of another game copy that exists on this PC: report that copy's logs and configs, not the detected one's.
    $collectedNote = $null
    if ($crash) {
        $crashGame = Get-CrashGameDir $crash.FullName
        if ($crashGame -and -not ($crashGame -ieq $GameDir -or $crashGame.StartsWith($GameDir + '\', [StringComparison]::OrdinalIgnoreCase)) -and
            (Test-GameRoot $crashGame)) {
            $collectedNote = "Logs and configs collected from the copy the crash came from: $crashGame (the detected copy was $GameDir)."
            Write-Output $collectedNote
            Write-RunLog 'collecting from the crashed copy'
            $GameDir = (Resolve-Path -LiteralPath $crashGame).Path.TrimEnd('\')
            $win64 = Join-Path $GameDir 'Shooter\Binaries\Win64'
        }
    }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    # ---- 2. logs and configuration ---------------------------------------------------------
    Get-ChildItem -LiteralPath $win64 -File -Filter 'UE4SS*.log*' | ForEach-Object { Add-TextFile $_.FullName $_.Name }
    Add-TextFile (Join-Path $win64 'UE4SS-settings.ini') 'UE4SS-settings.ini'
    Add-TextFile (Join-Path $win64 'Configs\ModList.ini') 'ModList.ini'
    $mods = Join-Path $win64 'Mods'
    Add-TextFile (Join-Path $mods 'mods.txt') 'mods.txt'
    $folderLines = @()
    if (Test-Path -LiteralPath $mods) {
        foreach ($d in Get-ChildItem -LiteralPath $mods -Directory | Sort-Object Name) {
            $state = if (Test-Path -LiteralPath (Join-Path $d.FullName 'enabled.txt')) { 'enabled.txt' } else { '-' }
            $folderLines += ('{0,-32} {1}' -f $d.Name, $state)
            $ini = Join-Path $d.FullName 'mod_menu.ini'
            Add-TextFile $ini "mods\$($d.Name)\mod_menu.ini"
            try {
                $v = [regex]::Match((Read-Shared $ini), '(?im)^\s*Version\s*=\s*([^\r\n;#]{1,40})')
                if ($v.Success) { $modVersions.Add(('{0} {1}' -f $d.Name, $v.Groups[1].Value.Trim())) }
            } catch { }   # no or unreadable mod_menu.ini: no version to report
        }
    }
    [IO.File]::WriteAllText((Join-Path $stage 'mod_folders.txt'), (Protect-Text ($folderLines -join "`r`n")))
    $included.Add('mod_folders.txt')

    # ---- 2b. Goobies MP: role logs (appended across launches, so only the tail), settings, the
    #          authority manifest (never the DLL) and the newest achievement-guard log --------------
    $mpDir = Join-Path $mods 'GoobiesMP'
    if (Test-Path -LiteralPath $mpDir -PathType Container) {
        Get-ChildItem -LiteralPath $mpDir -File | Where-Object { $_.Name -match '^gmp(_[^\\/]*)?\.log$' } | Sort-Object Name |
            ForEach-Object { Add-TextFile $_.FullName "mods\GoobiesMP\$($_.Name)" $MaxLogBytes }
    }
    Add-TextFile (Join-Path $win64 'Configs\GoobiesMP.ini') 'GoobiesMP.ini'
    Add-TextFile (Join-Path $mods 'GoobiesMPAuthority\manifest.json') 'mods\GoobiesMPAuthority\manifest.json'
    $guardDir = Join-Path $GameDir 'Shooter\Plugins\SteamCorePro\SteamCorePro\Source\ThirdParty\SteamLibrary\redistributable_bin\win64'
    if (Test-Path -LiteralPath $guardDir -PathType Container) {
        $guard = Get-ChildItem -LiteralPath $guardDir -File -Filter 'mod_menu_guard_*.log' |
                 Where-Object { $_.Name -match '^mod_menu_guard_\d+_\d+\.log$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($guard) { Add-TextFile $guard.FullName "guard\$($guard.Name)" $MaxLogBytes }
    }

    # ---- 3. newest crash folder and newest dump ----------------------------------------------
    $dumps = @(Get-ChildItem -LiteralPath $win64 -File -Filter 'crash_*.dmp')
    $ctxRaw = ''
    if ($crash) {
        $ctxPath = Join-Path $crash.FullName 'CrashContext.runtime-xml'
        if (Test-Path -LiteralPath $ctxPath) { try { $ctxRaw = Read-Shared $ctxPath } catch { } }
        Add-TextFile $ctxPath 'crash\CrashContext.runtime-xml'
        Add-TextFile (Join-Path $crash.FullName 'CrashReportClient.ini') 'crash\CrashReportClient.ini'
        $dumps += @(Get-ChildItem -LiteralPath $crash.FullName -File -Filter 'UEMinidump.dmp')
    }
    $dump = $dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $dump) { $dumpNote = 'No crash dump found.' }
    elseif ($NoDump) { $dumpNote = "Dump $($dump.Name) left out because -NoDump was used." }
    elseif ($dump.Length -gt $MaxDumpBytes) {
        $dumpNote = 'Dump {0} left out: {1:N1} MB is over the 20 MB limit.' -f $dump.Name, ($dump.Length / 1MB)
    } else {
        try {
            $crashDir = New-Item -ItemType Directory -Force -Path (Join-Path $stage 'crash')
            Copy-Item -LiteralPath $dump.FullName -Destination $crashDir.FullName -Force
            $included.Add("crash\$($dump.Name)")
            $dumpEntry = "crash/$($dump.Name)"
            $dumpNote = "Dump $($dump.Name) included (binary, not sanitized; rerun with -NoDump to omit)."
        } catch {   # e.g. still locked by the crashing game or the crash reporter
            $skipped.Add("crash\$($dump.Name) ($($_.Exception.Message))")
            $dumpNote = "Dump $($dump.Name) could not be read; see Skipped below."
        }
    }

    # ---- 4. summary, with warnings when the crash may not match this install or session -------
    $exes = @(Get-ChildItem -LiteralPath $GameDir -File -Filter 'Goobies*.exe' | ForEach-Object { $_.Name })
    $warnings = @()
    $crashTime = 'none found'
    if ($crash) {
        $crashTime = '{0} ({1}), {2} ago' -f $crash.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $crash.Name,
                     (Format-Span ((Get-Date) - $crash.LastWriteTime))
        $log = Get-Item -LiteralPath (Join-Path $win64 'UE4SS.log') -ErrorAction SilentlyContinue
        if ($log) {   # UE4SS.log is rewritten on every launch, so it marks the latest game session
            $delta = $crash.LastWriteTime - $log.LastWriteTime
            $crashTime += '; {0} {1} UE4SS.log ({2})' -f (Format-Span $delta), $(if ($delta.Ticks -lt 0) { 'before' } else { 'after' }),
                          $log.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            if ($delta.TotalMinutes -lt -10) { $warnings += 'this crash is older than the latest game session - may not be the crash you are reporting.' }
            if ($delta.TotalMinutes -gt 10) { $warnings += 'this crash happened after the last logged session - the log may be from a different run.' }
        }
        $m = [regex]::Match($ctxRaw, '<(?:RootDir|BaseDir)>([^<]+)</')
        if ($m.Success) {
            try { $ctxDir = [IO.Path]::GetFullPath($m.Groups[1].Value).TrimEnd('\') } catch { $ctxDir = $m.Groups[1].Value }
            if (-not ($ctxDir -ieq $GameDir -or $ctxDir.StartsWith($GameDir + '\', [StringComparison]::OrdinalIgnoreCase))) {
                $warnings += "this crash came from a different Goobies copy: $ctxDir"
            }
        }
    }
    foreach ($w in $warnings) { Write-Output "Note: $(Protect-Text $w)" }
    $fileLines = foreach ($rel in $included) { '  {0}  {1:N0} bytes' -f $rel, (Get-Item -LiteralPath (Join-Path $stage $rel)).Length }
    $summary = @(
        "CollectCrashReport.ps1 version $Version",
        "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
        "Windows: $([Environment]::OSVersion.VersionString)",
        "Game folder: $GameDir",
        "Game executables: $(if ($exes) { $exes -join ', ' } else { 'none found' })",
        "Newest crash folder: $crashTime",
        "Mod versions: $(if ($modVersions.Count) { $modVersions -join ', ' } else { 'none found' })"
    ) + @($collectedNote | Where-Object { $_ }) + @($warnings | ForEach-Object { "WARNING: $_" }) + @($dumpNote, 'Included files:') + $fileLines +
        @($skipped | ForEach-Object { "Skipped (could not read): $_" })
    [IO.File]::WriteAllText((Join-Path $stage 'summary.txt'), (Protect-Text ($summary -join "`r`n")))

    # ---- 5. zip with forward-slash entry names (portable across unzip tools) --------------------
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path
    # With a usable webhook the zip is built in %TEMP%: deleted once sent, moved to $OutDir if kept.
    $hook = Read-Webhook
    Write-RunLog "webhook=$($hook.State)"
    $zipDir = $OutDir
    if ($hook.State -eq 'ok') {
        $uploadStage = Join-Path $env:TEMP "Goobies_report_$PID"
        New-Item -ItemType Directory -Force -Path $uploadStage | Out-Null
        $zipDir = $uploadStage
    }
    $zipPath = Join-Path $zipDir "Goobies_crash_report_$stamp.zip"
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File) {
            $entry = $f.FullName.Substring($stage.Length + 1) -replace '\\', '/'
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entry)
        }
    } finally { $zip.Dispose() }
    $zipDone = $true
} catch {
    if ($zipPath -and -not $zipDone -and (Test-Path -LiteralPath $zipPath -PathType Leaf)) { Remove-Item -LiteralPath $zipPath -Force }
    if ($uploadStage) { Remove-Item -LiteralPath $uploadStage -Recurse -Force -ErrorAction SilentlyContinue }
    Write-RunLog "failed: $($_.Exception.Message)"
    if (-not $AutoCrash) { Write-Failure $_.Exception.Message }   # an automatic run stays silent
    exit 1
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath (Join-Path $OutDir 'Goobies_crash_report_FAILED.txt') -Force -ErrorAction SilentlyContinue
Write-Output "Crash report written to: $zipPath"

# ---- 6. optional upload (only with a webhook file and a Y answer), else the GitHub page ----------
$script:sent = $false
$script:tried = $false
if ($hook.State -eq 'invalid') {
    Write-Output 'Note: the address in the webhook file is not a Discord webhook address, so nothing is sent.'
} elseif ($hook.State -eq 'ok') {
    Send-Report $hook.Url
}
$hookState = $hook.State
$hook = $null

# A staged zip is deleted once Discord has all of it; otherwise it is moved to $OutDir.
$removed = $false
if ($uploadStage) {
    try {
        if ($sent -and -not $keepFull) {
            Remove-Item -LiteralPath $zipPath -Force; $removed = $true
        } else {
            $dest = Join-Path $OutDir (Split-Path -Leaf $zipPath)
            Move-Item -LiteralPath $zipPath -Destination $dest -Force; $zipPath = $dest
        }
    } catch { Write-Output "Note: could not tidy up the report file: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $uploadStage -Recurse -Force -ErrorAction SilentlyContinue
    $uploadStage = $null
}

$zipName = Split-Path -Leaf $zipPath
Write-RunLog "end sent=$sent removed=$removed zip=$(if ($removed) { '-' } else { $zipPath })"
$where = Get-ZipWhere
Write-Output ''
if ($sent) {
    if ($removed) {
        Write-Output 'The report file was removed from this PC (the developers have it).'
        if ($AutoCrash) { Show-Popup "Goobies crashed last time; a crash report was sent automatically. Thank you!`n`nThis message closes by itself." -Seconds 5 | Out-Null }
        elseif ($Gui) { Show-Popup "Report sent. Thank you!`n`nThis message closes by itself." -Seconds 5 | Out-Null }
    } else {
        Write-Output "The full report (with the crash dump) is $where`: $zipName"
        $first = if ($AutoCrash) { 'A crash report was sent automatically. Thank you!' } else { 'Report sent. Thank you!' }
        if ($Gui) { Show-Popup "$first`n`nThe crash dump was too big to send; the full report is $where`. This message closes by itself." -Seconds 5 | Out-Null }
    }
} else {
    Write-Output "Issue page: $IssueUrl"
    # -Gui never opens a folder; the issue page opens only when there is no other way to send (no webhook file).
    $openPage = -not $NoExplorer -and -not ($Gui -and $hookState -eq 'ok')
    if (-not $NoExplorer -and -not $Gui) { Start-Process explorer.exe -ArgumentList "/select,`"$zipPath`"" }
    if ($openPage) {
        try { Start-Process $IssueUrl } catch { Write-Output 'Could not open the browser; open the issue page above yourself.' }
        Write-Output "Your report is $where`: $zipName. Drag it into the page that just opened."
    } else {
        Write-Output "Your report is $where`: $zipName. Drag it into a new issue on the page above."
    }
    if ($Gui) {
        $text = if ($tried) { "The report could not be sent automatically.`n`nIt was saved $where`:`n$zipName" }
                elseif ($hookState -eq 'ok') { "Not sent.`n`nThe report was saved $where`:`n$zipName" }
                else { "The report was saved $where`:`n$zipName`n`nThe page that just opened shows how to send it." }
        Show-Popup $text -Seconds 20 | Out-Null
    }
}
exit 0
