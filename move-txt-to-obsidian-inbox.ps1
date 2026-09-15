# Move loose text files into an existing Obsidian vault without changing their bytes.
[CmdletBinding()]
param (
    # Configure the existing vault root here, or pass -VaultPath when invoking the script.
    [ValidateNotNullOrEmpty()]
    [string]$VaultPath = 'C:\Users\perra\OneDrive\Dokument\The Vault',
    [switch]$DryRun,
    # Zero disables both creation-time and last-write-time checks.
    [ValidateRange(0, 2147483647)]
    [int]$MinAgeMinutes = 60
)

$ErrorActionPreference = 'Stop'
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
    $cutoff = [DateTime]::UtcNow.AddMinutes(-[double]$MinAgeMinutes)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # Reserve planned targets as well, so dry runs handle duplicate source names.
    $reserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sources = @(
        [Environment]::GetFolderPath('Desktop')
        [Environment]::GetFolderPath('MyDocuments')
    ) | Select-Object -Unique

    foreach ($source in $sources) {
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
                # Create the inbox only when an eligible file is about to be moved.
                [void][IO.Directory]::CreateDirectory($inbox)
                # File.Move never overwrites, even if a target appears after the check.
                # A concurrent conflict is reported per file and leaves the source intact.
                [IO.File]::Move($file.FullName, $target)
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