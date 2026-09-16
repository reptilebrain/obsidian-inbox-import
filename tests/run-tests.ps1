# Standalone integration tests: run with powershell -File or pwsh -File.
# Only temporary copies execute. Never copy the machine-local configuration.
$Root = Join-Path ([IO.Path]::GetTempPath()) ('obsidian-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Root)
Write-Output "Isolated test root: $Root"
$ErrorActionPreference = 'Stop'
$original = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'move-txt-to-obsidian-inbox.ps1'))
$oldLocal = $env:LOCALAPPDATA
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Case {
    # This internal fixture always creates disposable test data. WhatIf would leave
    # the fixture incomplete; it is not a user-facing filesystem operation.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal fixture creates only isolated temporary test data; partial setup would invalidate tests.')]
    param ([string]$Name)
    $script:case = Join-Path $Root ($engineName + '-' + $Name)
    $script:desktop = Join-Path $case 'Desktop'
    $script:documents = Join-Path $case 'Documents'
    $script:vault = Join-Path $case 'Vault'
    $env:LOCALAPPDATA = Join-Path $case 'LocalAppData'
    foreach ($p in @($desktop,$documents,$vault)) { [void][IO.Directory]::CreateDirectory($p) }
    $script:copy = Join-Path $case 'test-copy.ps1'
    $desktopLiteral = "'" + $desktop.Replace("'", "''") + "'"
    $documentsLiteral = "'" + $documents.Replace("'", "''") + "'"
    $script:code = $original.Replace("[Environment]::GetFolderPath('Desktop')", $desktopLiteral).Replace("[Environment]::GetFolderPath('MyDocuments')", $documentsLiteral)
    Write-TestCopy
}
function Write-TestCopy {
    # Fail closed if a future edit leaves a real Windows source lookup in the copy.
    Assert ($original.Contains("[Environment]::GetFolderPath('Desktop')")) 'Desktop test seam changed'
    Assert ($original.Contains("[Environment]::GetFolderPath('MyDocuments')")) 'Documents test seam changed'
    Assert (-not ($code -match 'GetFolderPath')) 'Unmocked Windows source lookup; refusing to execute'
    [IO.File]::WriteAllText($copy,$code)
}
function Invoke-Case([string[]]$Options = @()) {
    $script:output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copy -VaultPath $vault @Options 2>&1)
    $script:status = $LASTEXITCODE
}
function Get-TreeSnapshot {
    Get-ChildItem -LiteralPath $case -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $hash = if ($_.PSIsContainer) { 'directory' } else { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        '{0}|{1}' -f $_.FullName, $hash
    }
}
function Write-TestFile([string]$Path, [bool]$Old = $true) {
    [IO.File]::WriteAllBytes($Path, [byte[]](0,255,254,13,10,195,165,0,65))
    if ($Old) {
        [IO.File]::SetCreationTimeUtc($Path,[DateTime]::UtcNow.AddHours(-3))
        [IO.File]::SetLastWriteTimeUtc($Path,[DateTime]::UtcNow.AddHours(-3))
    }
}
try {
# Use the same runtime as the caller, so each CI matrix job tests one version.
$runtime = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
foreach ($engine in @((Join-Path $PSHOME $runtime))) {
    Write-Output "Runtime: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    $engineName = [IO.Path]::GetFileNameWithoutExtension($engine)
    foreach ($mode in @('local-default','local-override','local-empty','local-broken','local-dry')) {
        New-Case $mode
        Write-TestFile (Join-Path $desktop 'note.txt')
        $localConfig = Join-Path $case 'obsidian-inbox-import.local.ps1'
        if ($mode -eq 'local-broken') {
            [IO.File]::WriteAllText($localConfig, 'throw ''Simulated configuration failure''')
        } elseif ($mode -eq 'local-empty') {
            [IO.File]::WriteAllText($localConfig, '$DefaultVaultPath = ''   ''')
        } else {
            $configured = $vault
            if ($mode -eq 'local-override') { $configured = Join-Path $case 'UnusedDefault' }
            [IO.File]::WriteAllText($localConfig, ('$DefaultVaultPath = ''' + $configured + ''''))
        }
        $options = @()
        if ($mode -eq 'local-override') { $options = @('-VaultPath',$vault) }
        if ($mode -eq 'local-dry') { $options = @('-DryRun') }
        $output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copy @options 2>&1)
        $status = $LASTEXITCODE
        if ($mode -in @('local-empty','local-broken')) {
            Assert ($status -eq 1 -and -not (Test-Path $env:LOCALAPPDATA) -and -not (Test-Path (Join-Path $vault '00_Inbox'))) "Local configuration failure: $output"
        } elseif ($mode -eq 'local-dry') {
            Assert ($status -eq 0 -and ($output -join "`n") -match 'Planned=1' -and -not (Test-Path $env:LOCALAPPDATA) -and -not (Test-Path (Join-Path $vault '00_Inbox'))) "Local dry run: $output"
        } else {
            Assert ($status -eq 0 -and (Test-Path (Join-Path $vault '00_Inbox\note.md'))) "Local config import: $output"
        }
    }
    Write-Output "$engineName PASS local config loading, explicit override, empty/broken config, dry run"

    New-Case 'configured-default'
    Write-TestFile (Join-Path $desktop 'note.txt')
    $code = $code.Replace('$DefaultVaultPath = ''''', ('$DefaultVaultPath = ''' + $vault + ''''))
    Write-TestCopy
    $output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copy 2>&1)
    $status = $LASTEXITCODE
    Assert ($status -eq 0 -and (Test-Path (Join-Path $vault '00_Inbox\note.md'))) "Configured default: $output"
    Write-Output "$engineName PASS configured default imports isolated fixture without VaultPath"

    New-Case 'explicit-override'
    $unused = Join-Path $case 'UnusedDefault'
    [void][IO.Directory]::CreateDirectory($unused)
    Write-TestFile (Join-Path $desktop 'note.txt')
    $code = $code.Replace('$DefaultVaultPath = ''''', ('$DefaultVaultPath = ''' + $unused + ''''))
    Write-TestCopy
    Invoke-Case
    Assert ($status -eq 0 -and (Test-Path (Join-Path $vault '00_Inbox\note.md')) -and -not (Test-Path (Join-Path $unused '00_Inbox'))) "Explicit override: $output"
    Write-Output "$engineName PASS explicit VaultPath overrides configured default"

    $invalidCases = @(
        @{ Name='empty-default'; Default=''; Explicit=$false; Value='' },
        @{ Name='whitespace-default'; Default='   '; Explicit=$false; Value='' },
        @{ Name='empty-argument'; Default='D:\Notes\My Vault'; Explicit=$true; Value='' },
        @{ Name='whitespace-argument'; Default='D:\Notes\My Vault'; Explicit=$true; Value='   ' },
        @{ Name='relative'; Default=''; Explicit=$true; Value='Notes\Vault' },
        @{ Name='drive-relative'; Default=''; Explicit=$true; Value='D:Vault' },
        @{ Name='root-relative'; Default=''; Explicit=$true; Value='\Notes\Vault' },
        @{ Name='unc-server-only'; Default=''; Explicit=$true; Value='\\server' },
        @{ Name='unc-empty-share'; Default=''; Explicit=$true; Value='\\server\' },
        @{ Name='relative-default'; Default='Notes\Vault'; Explicit=$false; Value='' }
    )
    foreach ($item in $invalidCases) {
        New-Case $item.Name
        $code = $code.Replace('$DefaultVaultPath = ''''', ('$DefaultVaultPath = ''' + $item.Default + ''''))
        Assert ($original.Contains("[Environment]::GetFolderPath('Desktop')")) 'Desktop test seam changed'
    Write-TestCopy
        # A PowerShell launcher preserves explicit empty strings in both runtimes.
        $launcher = Join-Path $case 'launch.ps1'
        $invocation = '& ''' + $copy + ''''
        if ($item.Explicit) { $invocation += ' -VaultPath ''' + $item.Value + '''' }
        [IO.File]::WriteAllText($launcher, ($invocation + "`nexit `$LASTEXITCODE"))
        $before = @(Get-TreeSnapshot)
        $output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $launcher 2>&1)
        $status = $LASTEXITCODE
        $after = @(Get-TreeSnapshot)
        Assert ($status -eq 1 -and ($output -join "`n") -match 'Configuration error:') "Invalid config $($item.Name): $output"
        Assert (-not (Compare-Object $before $after)) "Invalid config side effects: $($item.Name)"
    }
    Write-Output "$engineName PASS 10 invalid/empty configurations, explicit empty preserved, no side effects or prompts"

    # Stop immediately after the actual format validation, before any filesystem access.
    $formatPaths = @('D:\Notes\My Vault', 'D:\', '\\server\share\My Vault', '\\server\share')
    foreach ($formatPath in $formatPaths) {
        New-Case ('format-' + [Guid]::NewGuid().ToString('N'))
        $code = $code.Replace('$script:hadErrors = $false', 'Write-Output ''FORMAT ACCEPTED''; exit 0' + "`n" + '$script:hadErrors = $false')
        Assert ($original.Contains("[Environment]::GetFolderPath('Desktop')")) 'Desktop test seam changed'
    Write-TestCopy
        $output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copy -VaultPath $formatPath 2>&1)
        $status = $LASTEXITCODE
        Assert ($status -eq 0 -and ($output -join "`n") -match 'FORMAT ACCEPTED') "Format rejected: $formatPath $output"
        Assert (-not (Test-Path $env:LOCALAPPDATA)) 'Format test created log'
    }
    Write-Output "$engineName PASS drive and UNC format acceptance (early-exit double, no network resource tested)"

    New-Case 'mandatory'
    $ErrorActionPreference = 'Continue'
    $output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $copy -DryRun 2>&1)
    $ErrorActionPreference = 'Stop'
    $status = $LASTEXITCODE
    Assert ($status -eq 1) "Missing mandatory parameter: $output"
    Assert (-not (Test-Path $env:LOCALAPPDATA)) 'Mandatory parameter produced log'
    Write-Output "$engineName PASS empty configuration, exit 1 without prompting"

    foreach ($dryMode in @($true,$false)) {
        New-Case "inbox-file-$dryMode"
        Write-TestFile (Join-Path $vault '00_Inbox')
        Write-TestFile (Join-Path $desktop 'note.txt')
        if ($dryMode) { Invoke-Case @('-DryRun') } else { Invoke-Case }
        Assert ($status -eq 1 -and ($output -join "`n") -match 'Inbox exists but is not a directory') "Inbox type: $output"
        Assert (Test-Path (Join-Path $desktop 'note.txt')) 'Inbox type moved source'
        if ($dryMode) { Assert (-not (Test-Path $env:LOCALAPPDATA)) 'Dry inbox type wrote log' }
    }
    Write-Output "$engineName PASS inbox file rejected in dry and real run"

    New-Case 'vault-disappears'
    Write-TestFile (Join-Path $desktop 'a.txt')
    Write-TestFile (Join-Path $desktop 'b.txt')
    Write-TestFile (Join-Path $documents 'c.txt')
    $hook = '[IO.Directory]::Move($vault.FullName, ($vault.FullName + ''-gone''))'
    $code = $code.Replace('        foreach ($file in $files) {', "        $hook`n        foreach (`$file in `$files) {")
    Write-TestCopy
    Invoke-Case
    Assert ($status -eq 1 -and -not (Test-Path $vault)) "Disappearing vault recreated: $output"
    Assert (($output -join "`n") -match 'Import aborted; vault root unavailable') 'Missing abort message'
    Assert (@($output | Where-Object { "$_" -match 'Import aborted;' }).Count -eq 1) 'Failed to abort remaining import'
    Assert (@(Get-ChildItem $desktop,$documents -Filter '*.txt').Count -eq 3) 'Sources changed after vault loss'
    Write-Output "$engineName PASS vault loss after enumeration aborts all sources (injected rename)"

    foreach ($age in @(60,0)) {
        New-Case "stale-metadata-$age"
        Write-TestFile (Join-Path $desktop 'a.txt')
        $hook = 'foreach ($cached in $files) { $null = $cached.LastWriteTimeUtc; [IO.File]::SetLastWriteTimeUtc($cached.FullName, [DateTime]::UtcNow) }'
        $code = $code.Replace('        foreach ($file in $files) {', "        $hook`n        foreach (`$file in `$files) {")
        Assert ($original.Contains("[Environment]::GetFolderPath('Desktop')")) 'Desktop test seam changed'
    Write-TestCopy
        Invoke-Case @('-MinAgeMinutes',"$age")
        Assert ($status -eq 0) "Stale metadata: $output"
        if ($age -eq 60) {
            Assert (($output -join "`n") -match 'Skipped=1' -and (Test-Path (Join-Path $desktop 'a.txt'))) 'Stale metadata was used'
        } else { Assert (($output -join "`n") -match 'Moved=1') 'Zero did not disable age check' }
    }
    Write-Output "$engineName PASS modified after enumeration refreshes metadata; zero still disables age check (injected timestamp change)"

    New-Case 'source-disappears'
    Write-TestFile (Join-Path $desktop 'a.txt')
    Write-TestFile (Join-Path $desktop 'b.txt')
    $hook = 'if ($files.Count -gt 0) { [IO.File]::Move($files[0].FullName, ($files[0].FullName + ''.gone'')) }'
    $code = $code.Replace('        foreach ($file in $files) {', "        $hook`n        foreach (`$file in `$files) {")
    Write-TestCopy
    Invoke-Case
    Assert ($status -eq 1 -and ($output -join "`n") -match 'Source file no longer exists' -and ($output -join "`n") -match 'Moved=1') "Source refresh: $output"
    Write-Output "$engineName PASS source disappears after enumeration, later file proceeds (injected rename)"

    New-Case 'incomplete-move'
    Write-TestFile (Join-Path $desktop 'a.txt')
    Write-TestFile (Join-Path $desktop 'b.txt')
    $code = $code.Replace('[IO.File]::Move($file.FullName, $target)', '[IO.File]::Copy($file.FullName, $target)')
    Write-TestCopy
    Invoke-Case
    Assert ($status -eq 1 -and ($output -join "`n") -match 'Moved=0') "Incomplete move counted: $output"
    Assert (@(Get-ChildItem $desktop -Filter '*.txt').Count -eq 2) 'Remaining source deleted'
    Assert (@(Get-ChildItem (Join-Path $vault '00_Inbox') -Filter '*.md').Count -eq 2) 'Later move was not attempted'
    $logs = Get-ChildItem $env:LOCALAPPDATA -Recurse -Filter 'obsidian-*.log' | Get-Content
    Assert (-not (($logs -join "`n") -match '\sOK\s')) 'Incomplete move logged success'
    Assert (-not (($output -join "`n") -match '(?m)^MOVED ')) 'Incomplete move announced success'
    Write-Output "$engineName PASS incomplete move exit 1, no success/count, sources retained, continues (File.Copy double)"

    New-Case 'missing-destination'
    Write-TestFile (Join-Path $desktop 'a.txt')
    $code = $code.Replace('[IO.File]::Move($file.FullName, $target)', '[IO.File]::Move($file.FullName, ($file.FullName + ''.elsewhere''))')
    Write-TestCopy
    Invoke-Case
    Assert ($status -eq 1 -and ($output -join "`n") -match 'Moved=0') "Missing destination: $output"
    Write-Output "$engineName PASS missing destination exit 1 (redirected move double)"

    New-Case 'directory-destination'
    Write-TestFile (Join-Path $desktop 'a.txt')
    $code = $code.Replace('[IO.File]::Move($file.FullName, $target)', '[IO.File]::Move($file.FullName, ($file.FullName + ''.elsewhere'')); [void][IO.Directory]::CreateDirectory($target)')
    Write-TestCopy
    Invoke-Case
    Assert ($status -eq 1 -and ($output -join "`n") -match 'Moved=0') "Directory destination: $output"
    Write-Output "$engineName PASS directory destination exit 1 (move double)"

    New-Case 'dry'
    Write-TestFile (Join-Path $desktop 'note.txt')
    Write-TestFile (Join-Path $documents 'note.txt')
    $before = @(Get-TreeSnapshot)
    Invoke-Case @('-DryRun')
    $after = @(Get-TreeSnapshot)
    Assert ($status -eq 0) "dry exit: $output"
    Assert (-not (Compare-Object $before $after)) 'Dry run changed tree'
    Assert (($output -join "`n") -match 'note - import .*?-1.md') 'Dry conflict missing'
    Assert (($output -join "`n") -match 'Planned=2') 'Dry count'
    Write-Output "$engineName PASS dry run, no created files/directories, cross-source conflict"

    New-Case 'age'
    Write-TestFile (Join-Path $desktop 'creation.txt')
    [IO.File]::SetCreationTimeUtc((Join-Path $desktop 'creation.txt'),[DateTime]::UtcNow)
    Write-TestFile (Join-Path $desktop 'modified.txt')
    [IO.File]::SetLastWriteTimeUtc((Join-Path $desktop 'modified.txt'),[DateTime]::UtcNow)
    Invoke-Case
    Assert ($status -eq 0 -and ($output -join "`n") -match 'Skipped=2') "age: $output"
    Assert (-not (Test-Path (Join-Path $vault '00_Inbox'))) 'Premature inbox'
    Invoke-Case @('-MinAgeMinutes','0')
    Assert ($status -eq 0 -and ($output -join "`n") -match 'Moved=2') "age disabled: $output"
    Assert (@(Get-ChildItem $env:LOCALAPPDATA -Recurse -Filter 'obsidian-*.log').Count -eq 2) 'Separate logs'
    Write-Output "$engineName PASS creation/write age, age disabled, deferred inbox, separate logs"

    New-Case 'import'
    $inbox = Join-Path $vault '00_Inbox'
    [void][IO.Directory]::CreateDirectory($inbox)
    Write-TestFile (Join-Path $inbox 'note.md')
    Write-TestFile (Join-Path $inbox 'note - import 20260915-120658-1.md')
    $code = $code.Replace("`$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'", "`$stamp = '20260915-120658'")
    Write-TestCopy
    Write-TestFile (Join-Path $desktop 'note.txt')
    Write-TestFile (Join-Path $documents 'note.txt')
    [void][IO.Directory]::CreateDirectory((Join-Path $desktop 'sub'))
    Write-TestFile (Join-Path $desktop 'sub\nested.txt')
    Write-TestFile (Join-Path $desktop 'keep.csv')
    $hash = (Get-FileHash (Join-Path $desktop 'note.txt')).Hash
    $existingTime = [IO.File]::GetLastWriteTimeUtc((Join-Path $inbox 'note.md'))
    Invoke-Case @('-DryRun')
    Assert ($status -eq 0 -and ($output -join "`n") -match '120658-2.md' -and ($output -join "`n") -match '120658-3.md') 'Dry existing candidates'
    Invoke-Case
    Assert ($status -eq 0) "import: $output"
    foreach ($n in @(2,3)) {
        Assert ((Get-FileHash (Join-Path $inbox "note - import 20260915-120658-$n.md")).Hash -eq $hash) 'Bytes changed'
    }
    Assert ([IO.File]::GetLastWriteTimeUtc((Join-Path $inbox 'note.md')) -eq $existingTime) 'Existing file changed'
    Assert ((Test-Path (Join-Path $desktop 'sub\nested.txt')) -and (Test-Path (Join-Path $desktop 'keep.csv'))) 'Scope violation'
    Assert (-not (Test-Path (Join-Path $desktop 'note.txt'))) 'Source not moved'
    Write-Output "$engineName PASS candidate numbering, existing file preserved, byte hashes, top-level txt only"

    New-Case 'missing'
    $vault = Join-Path $case 'DoesNotExist'
    Invoke-Case
    Assert ($status -eq 1 -and -not (Test-Path $vault)) 'Missing vault not rejected'
    Write-Output "$engineName PASS missing vault exit 1, root not created"

    New-Case 'empty'
    Invoke-Case
    Assert ($status -eq 0 -and -not (Test-Path (Join-Path $vault '00_Inbox')) ) 'Empty run'
    Write-Output "$engineName PASS empty run exit 0 without inbox"

    New-Case 'file-error'
    Write-TestFile (Join-Path $desktop 'a-locked.txt')
    Write-TestFile (Join-Path $desktop 'z-good.txt')
    $lock = [IO.File]::Open((Join-Path $desktop 'a-locked.txt'), 'Open', 'Read', 'None')
    try { Invoke-Case } finally { $lock.Dispose() }
    Assert ($status -eq 1 -and (Test-Path (Join-Path $vault '00_Inbox\z-good.md')) -and (Test-Path (Join-Path $desktop 'a-locked.txt'))) "Per-file error: $output"
    Write-Output "$engineName PASS failed move continues, source retained, exit 1"

    New-Case 'log-init-error'
    [IO.File]::WriteAllText($env:LOCALAPPDATA,'block directory')
    Write-TestFile (Join-Path $desktop 'a.txt')
    Write-TestFile (Join-Path $desktop 'b.txt')
    Invoke-Case
    Assert ($status -eq 1 -and ($output -join "`n") -match 'Moved=2') "Log initialization error: $output"
    Assert (@($output | Where-Object { "$_" -match 'Log initialization failed' }).Count -eq 1) 'Repeated log initialization error'
    Write-Output "$engineName PASS log initialization failure continues once, exit 1"

    New-Case 'log-write-error'
    Write-TestFile (Join-Path $desktop 'a.txt')
    Write-TestFile (Join-Path $desktop 'b.txt')
    $code = $code.Replace('$script:logEnabled = $true', '$script:logEnabled = $true' + "`n" + '        $heldLog = [IO.File]::Open($script:logPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)')
    Write-TestCopy
    Invoke-Case
    Assert ($status -eq 1 -and ($output -join "`n") -match 'Moved=2') "Log write error: $output"
    Assert (@($output | Where-Object { "$_" -match 'Log write failed' }).Count -eq 1) 'Repeated log write error'
    Write-Output "$engineName PASS log write failure disables logging, continues, exit 1"
}
} finally { $env:LOCALAPPDATA = $oldLocal }
Write-Output 'All integration tests passed.'
exit 0
