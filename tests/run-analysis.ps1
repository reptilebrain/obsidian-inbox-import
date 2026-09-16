# Run from either supported PowerShell runtime after installing PSScriptAnalyzer.
$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
$repoRoot = Split-Path $PSScriptRoot -Parent

# Analyze tracked files only. Never load the ignored machine-local configuration.
$files = @(git -C $repoRoot ls-files -- '*.ps1' '*.psm1' '*.psd1')
if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) {
    throw 'Cannot enumerate tracked PowerShell files for analysis.'
}
$findings = @(foreach ($file in $files) {
    Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $file) -Settings @{
        IncludeDefaultRules = $true
        Severity = @('Error', 'Warning')
    } -ErrorAction Stop
})
if ($findings.Count -gt 0) {
    $findings | Format-Table ScriptName, Line, Severity, RuleName, Message -AutoSize -Wrap
    throw "PSScriptAnalyzer reported $($findings.Count) errors or warnings."
}
Write-Output "PSScriptAnalyzer 1.25.0: no errors or warnings in $($files.Count) tracked files."
