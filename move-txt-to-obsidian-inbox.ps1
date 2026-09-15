# Move loose text files into an existing Obsidian vault without changing their bytes.
[CmdletBinding()]
param (
    # Override the default vault setting below for this invocation.
    [string]$VaultPath,
    [switch]$DryRun,
    # Zero disables both creation-time and last-write-time checks.
    [ValidateRange(0, 2147483647)]
    [int]$MinAgeMinutes = 60
)

# Set your existing Obsidian vault folder in obsidian-inbox-import.local.ps1
# beside this script: $DefaultVaultPath = 'D:\Notes\My Vault'
# That optional local file is ignored by Git and overrides the setting below.
# Example: 'D:\Notes\My Vault'
# An explicit -VaultPath argument overrides this setting.
$DefaultVaultPath = ''

$ErrorActionPreference = 'Stop'

# Check whether the argument was supplied, so an explicit empty value never falls back.
if (-not $PSBoundParameters.ContainsKey('VaultPath')) {
    try {
        $localConfigPath = Join-Path $PSScriptRoot 'obsidian-inbox-import.local.ps1'
        if (Test-Path -LiteralPath $localConfigPath -ErrorAction Stop) {
            if (-not (Test-Path -LiteralPath $localConfigPath -PathType Leaf -ErrorAction Stop)) {
                throw 'The local configuration must be a PowerShell file.'
            }
            . $localConfigPath
        }
    }
    catch {
        Write-Warning "Configuration error: cannot load local configuration: $($_.Exception.Message)" -WarningAction Continue
        exit 1
    }
    $VaultPath = $DefaultVaultPath
}
if ([string]::IsNullOrWhiteSpace($VaultPath)) {
    Write-Warning 'Configuration error: set $DefaultVaultPath in obsidian-inbox-import.local.ps1 or pass a non-empty -VaultPath.' -WarningAction Continue
    exit 1
}

# IsPathRooted also accepts drive-relative paths. Require a drive root or a UNC
# server and share explicitly; this works in Windows PowerShell 5.1 as well.
$isDrivePath = $VaultPath -match '^[A-Za-z]:[\\/]'
$isUncPath = $VaultPath -match '^\\\\[^\\/:*?"<>|\s]+\\[^\\/:*?"<>|\s][^\\/:*?"<>|]*(?:\\|$)'
if (-not ($isDrivePath -or $isUncPath)) {
    Write-Warning 'Configuration error: VaultPath must be a fully qualified Windows path, such as D:\Notes\My Vault or \\server\share\My Vault.' -WarningAction Continue
    exit 1
}
try {
    # Validate path syntax without accessing the filesystem or creating a log.
    $null = [IO.Path]::GetFullPath($VaultPath)
}
catch {
    Write-Warning "Configuration error: invalid VaultPath: $($_.Exception.Message)" -WarningAction Continue
    exit 1
}

$script:hadErrors = $false
$script:logEnabled = $false
$script:logPath = $null

function Write-RunLog {
    param ([string]$Message)
    if (-not $script:logEnabled) { return }
    try {
        Add-Content -LiteralPath $script:logPath -Value "$(Get-Date -Format o) $Message" -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Disable logging after the first failure, but continue processing files.
        $script:logEnabled = $false
        $script:hadErrors = $true
        Write-Warning "Log write failed: $($_.Exception.Message)" -WarningAction Continue
    }
}

function Report-RunError {
    param ([string]$Message)
    $script:hadErrors = $true
    Write-Warning $Message -WarningAction Continue
    Write-RunLog "ERROR $Message"
}

# Every real invocation gets its own log, including runs with no eligible files.
if (-not $DryRun) {
    try {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not set.' }
        $logDirectory = Join-Path $env:LOCALAPPDATA 'DesktopCleanup\Logs'
        [void][IO.Directory]::CreateDirectory($logDirectory)
        $logName = 'obsidian-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), ([Guid]::NewGuid().ToString('N'))
        $script:logPath = Join-Path $logDirectory $logName
        $logStream = [IO.File]::Open($script:logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $logStream.Dispose()
        $script:logEnabled = $true
        Write-RunLog "START Vault=$VaultPath MinAgeMinutes=$MinAgeMinutes"
    }
    catch { Report-RunError "Log initialization failed: $($_.Exception.Message)" }
}

$moved = 0
$planned = 0
$skipped = 0
try {
    # Resolve and validate the root before creating anything inside the vault.
    $vault = Get-Item -LiteralPath $VaultPath -Force -ErrorAction Stop
    if (-not $vault.PSIsContainer -or $vault.PSProvider.Name -ne 'FileSystem') {
        throw "Vault root is not a filesystem directory: $VaultPath"
    }
    $inbox = Join-Path $vault.FullName '00_Inbox'
    if ((Test-Path -LiteralPath $inbox -ErrorAction Stop) -and
        -not (Test-Path -LiteralPath $inbox -PathType Container -ErrorAction Stop)) {
        throw "Inbox exists but is not a directory: $inbox"
    }
    $cutoff = [DateTime]::UtcNow.AddMinutes(-[double]$MinAgeMinutes)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # Reserve planned targets as well, so dry runs handle duplicate source names.
    $reserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sources = @(
        [Environment]::GetFolderPath('Desktop')
        [Environment]::GetFolderPath('MyDocuments')
    ) | Select-Object -Unique

    :ImportSources foreach ($source in $sources) {
        try {
            if ([string]::IsNullOrWhiteSpace($source)) { throw 'Windows returned an empty source path.' }
            # No recursion and no ReparsePoint exclusion: local OneDrive files are allowed.
            $files = @(Get-ChildItem -LiteralPath $source -File -Force -Filter '*.txt' -ErrorAction Stop |
                Where-Object { $_.Extension -ieq '.txt' } | Sort-Object Name)
        }
        catch {
            Report-RunError "Cannot list source '$source': $($_.Exception.Message)"
            continue
        }
        foreach ($file in $files) {
            try {
                # Enumeration caches metadata; refresh before testing existence or age.
                $file.Refresh()
                if (-not $file.Exists) { throw 'Source file no longer exists.' }
                if ($MinAgeMinutes -gt 0 -and
                    ($file.CreationTimeUtc -ge $cutoff -or $file.LastWriteTimeUtc -ge $cutoff)) {
                    $skipped++
                    Write-Output "SKIP (too recent) $($file.FullName)"
                    Write-RunLog "SKIP (too recent) $($file.FullName)"
                    continue
                }
                $base = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                $target = Join-Path $inbox ($base + '.md')
                $number = 0
                while ($reserved.Contains($target) -or (Test-Path -LiteralPath $target -ErrorAction Stop)) {
                    $number++
                    $target = Join-Path $inbox ("$base - import $stamp-$number.md")
                }
                if ($DryRun) {
                    [void]$reserved.Add($target)
                    $planned++
                    Write-Output "DRY RUN $($file.FullName) -> $target"
                    continue
                }
                # Abort all remaining imports if the validated vault has disappeared.
                # This check narrows, but cannot eliminate, the race before creation.
                try {
                    $currentVault = Get-Item -LiteralPath $vault.FullName -Force -ErrorAction Stop
                    if (-not $currentVault.PSIsContainer -or $currentVault.PSProvider.Name -ne 'FileSystem') {
                        throw "Vault root is no longer a filesystem directory: $($vault.FullName)"
                    }
                }
                catch {
                    Report-RunError "Import aborted; vault root unavailable: $($_.Exception.Message)"
                    break ImportSources
                }
                # Create the inbox only when an eligible file is about to be moved.
                [void][IO.Directory]::CreateDirectory($inbox)
                # File.Move never overwrites, even if a target appears after the check.
                # A concurrent conflict is reported per file and leaves the source intact.
                [IO.File]::Move($file.FullName, $target)
                # A cross-volume move may leave the source behind. Report it without
                # deleting the remaining source or claiming a successful import.
                $destination = Get-Item -LiteralPath $target -Force -ErrorAction Stop
                if ($destination.PSIsContainer -or $destination.PSProvider.Name -ne 'FileSystem' -or
                    (Test-Path -LiteralPath $file.FullName -ErrorAction Stop)) {
                    throw "Move verification failed; destination must be a file and source must be absent: $target"
                }
                [void]$reserved.Add($target)
                $moved++
                Write-Output "MOVED $($file.FullName) -> $target"
                Write-RunLog "OK $($file.FullName) -> $target"
            }
            catch { Report-RunError "Cannot move '$($file.FullName)': $($_.Exception.Message)" }
        }
    }
}
catch { Report-RunError "Run failed: $($_.Exception.Message)" }

$summary = "Moved=$moved Planned=$planned Skipped=$skipped"
Write-Output $summary
Write-RunLog "END $summary"
if ($script:hadErrors) { exit 1 }
exit 0
