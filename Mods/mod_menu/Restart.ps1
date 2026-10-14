param([Parameter(Mandatory=$true)][string]$Win64,
      [Parameter(Mandatory=$true)][string]$Receipt)
$ErrorActionPreference = 'Stop'
$restartRoot = [IO.Path]::GetFullPath($Win64).TrimEnd('\','/')
$receiptPath = [IO.Path]::GetFullPath($Receipt)
$configRoot = Join-Path $restartRoot 'Configs'
if ([IO.Path]::GetDirectoryName($receiptPath) -ne $configRoot -or
    [IO.Path]::GetFileName($receiptPath) -notmatch '^ModMenu\.restart-\d+-\d+$') { exit 2 }
# Publish complete status files through same-directory rename.
function Publish-Status([string]$Suffix, [string]$Message) {
    $target = $receiptPath + $Suffix
    $temporary = $target + '.pending'
    [IO.File]::WriteAllText($temporary, $Message)
    [IO.File]::Move($temporary, $target)
}
$restartLock = $null
$process = $null
function Get-LiveGameProcesses {
    foreach ($candidate in Get-Process | Where-Object { $_.ProcessName -match 'Goobies|Shooter' }) {
        $exited=$candidate.HasExited
        if ($exited -isnot [bool]) { throw 'Cannot establish candidate process liveness.' }
        if ($exited) { $candidate.Dispose() }
        else { $candidate }
    }
}
try {
    $restartLock = [IO.File]::Open((Join-Path $configRoot 'ModMenu.restart.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $executable = Join-Path $restartRoot 'Shooter-Win64-Shipping.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Game executable missing.' }
    # CIM is denied in some normal-user environments. Retain a native process
    # handle and verify its executable directly instead of depending on WMI.
    $candidates = @(Get-LiveGameProcesses)
    if ($candidates.Count -ne 1 -or $candidates[0].Path -ne $executable) {
        throw 'Restart requires exactly one Goobies process, belonging to this Win64 directory.'
    }
    $running = $candidates[0]
    $process = $running
    $null = $process.Handle
    if ($process.MainModule.FileName -ne $executable -or
        $process.HasExited) {
        throw 'Process identity changed during restart preparation.'
    }
    # Supported restart path: direct shipping, Win64 cwd, no arguments.
    # Do not block preparation on WMI or redirect through Steam/the wrapper.
    $arguments = ''
    Publish-Status '.identity' ('PID='+$process.Id+'; path='+$process.MainModule.FileName+'; start='+$process.StartTime.ToUniversalTime().ToString('o')+'; restart arguments=none; prepared='+[DateTime]::UtcNow.ToString('o'))
    Publish-Status '.ready' 'READY'
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not (Test-Path -LiteralPath ($receiptPath+'.commit'))) {
        if ((Test-Path -LiteralPath ($receiptPath+'.cancel')) -or [DateTime]::UtcNow -gt $deadline) { throw 'Restart canceled or confirmation expired.' }
        Start-Sleep -Milliseconds 100
    }
    $committed = 0L
    if (-not [long]::TryParse([IO.File]::ReadAllText($receiptPath+'.commit'),[ref]$committed)) { throw 'Invalid restart commit.' }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $committed
    if ($age -lt 0 -or $age -gt 5) { throw 'Restart commit expired.' }
    if (Test-Path -LiteralPath ($receiptPath+'.cancel')) { throw 'Restart canceled.' }
    Publish-Status '.armed' 'ARMED'
    $deadline = [DateTime]::UtcNow.AddSeconds(5-$age)
    while (-not $process.HasExited) {
        if ((Test-Path -LiteralPath ($receiptPath+'.cancel')) -or [DateTime]::UtcNow -gt $deadline) { throw 'Game did not exit promptly; restart canceled.' }
        Start-Sleep -Milliseconds 100
    }
    if ((Test-Path -LiteralPath ($receiptPath+'.cancel')) -or [DateTime]::UtcNow -gt $deadline) { throw 'Restart canceled or expired.' }
    Publish-Status '.exited' ('Verified process exit: PID='+$process.Id+'; exit='+$process.ExitTime.ToUniversalTime().ToString('o')+'; code='+$process.ExitCode)
    $process.Dispose(); $process=$null
    $replacement = @(Get-LiveGameProcesses)
    $identities=@($replacement | ForEach-Object { @{pid=$_.Id;path=$_.Path;start=$_.StartTime.ToUniversalTime().ToString('o');exited=$_.HasExited} })
    Publish-Status '.remaining' (ConvertTo-Json -InputObject $identities -Compress)
    if ($replacement.Count -ne 0) { throw 'Another instance exists; restart canceled.' }
    $startOptions = @{ FilePath=$executable; WorkingDirectory=$restartRoot; PassThru=$true; WindowStyle='Normal' }
    if ($arguments) { $startOptions.ArgumentList = $arguments }
    if ((Test-Path -LiteralPath ($receiptPath+'.cancel')) -or [DateTime]::UtcNow -gt $deadline) { throw 'Restart canceled or expired before launch.' }
    $launched = Start-Process @startOptions
    if (-not $launched -or $launched.WaitForExit(1000)) { throw 'Replacement failed to remain running.' }
    Publish-Status '.started' ('Process launched: '+$launched.Id+'; in-game readiness is unverified.')
} catch {
    try { Publish-Status '.error' ('Restart failed: '+$_.Exception.Message) } catch { }
} finally {
    if ($restartLock) { $restartLock.Dispose() }
    if ($process) { $process.Dispose() }
}
