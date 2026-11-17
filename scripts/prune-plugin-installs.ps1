<#
.SYNOPSIS
    Removes the plugin records Claude Code keeps for project folders that are gone, and for the
    home folder, from the hub's plugins\installed_plugins.json.
.DESCRIPTION
    A plugin installed with project or local scope is recorded with the project's folder. When
    the folder is deleted (a worktree removed, a project moved), the record stays, and
    check-setup.ps1 lists it as "[folder gone]". A session started in the home folder records
    every enabled plugin a second time for that folder (README, "Things to know"), including
    plugins that were switched off later and would load again in the next session there.
    `claude plugin uninstall --scope project` cannot help with either: it needs the folder, and
    in the home folder the project settings it edits are your settings.json.

    This script removes exactly those records and nothing else: records with scope user, and
    records of folders that exist (other than the home folder), stay as they are. The plugin
    files in plugins\cache stay too; Claude Code removes files no record uses. Before writing it
    keeps a copy as installed_plugins.json.backup-<time> next to the file.

    Close every Claude Code session first: a running session can write its own view of the file
    back. The script refuses to write while a claude process runs.
.PARAMETER DryRun
    List what would be removed, change nothing.
.PARAMETER KeepHome
    Keep the records of the home folder; remove only those of folders that are gone.
.PARAMETER Path
    Another installed_plugins.json, for a test on a copy. The check for running sessions
    applies only to the hub's own file.
#>
param(
    [switch]$DryRun,
    [switch]$KeepHome,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
if (-not $env:CLAUDE_SETUP_CONFIG) {
    $env:CLAUDE_SETUP_CONFIG = [Environment]::GetEnvironmentVariable('CLAUDE_SETUP_CONFIG', 'User')
}
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\plugins.ps1"
$hubFile = "$($ClaudeLayout.Hub)\plugins\installed_plugins.json"
$file = if ($Path) { Get-ClaudeFullPath $Path } else { $hubFile }
if (-not (Test-Path -LiteralPath $file)) { Write-Host "No $file; nothing to prune."; exit 0 }

$data = Get-Content -Raw -Encoding UTF8 -LiteralPath $file | ConvertFrom-Json
if (-not $data.plugins) { Write-Host "No plugin records in $file; nothing to prune."; exit 0 }
$homeFolder = Get-ClaudeFullPath $env:USERPROFILE

# Why a record goes, or $null when it stays
function Get-PruneReason($Record) {
    if ($Record.scope -eq 'user' -or -not $Record.projectPath) { return $null }
    $folder = Get-ClaudeFullPath $Record.projectPath
    if ($folder -eq $homeFolder) { if ($KeepHome) { return $null } else { return 'home folder' } }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return 'folder gone' }
    return $null
}

$removed = @()
$emptied = @()
foreach ($property in @($data.plugins.PSObject.Properties)) {
    $kept = @()
    foreach ($record in @($property.Value)) {
        $reason = Get-PruneReason $record
        if ($reason) { $removed += [pscustomobject]@{ Plugin = $property.Name; Folder = $record.projectPath; Why = $reason } }
        else { $kept += $record }
    }
    if ($kept.Count -eq 0) { $emptied += $property.Name }
    else { $data.plugins.($property.Name) = $kept }
}

if (-not $removed.Count) { Write-Host 'Nothing to prune: every project record points to an existing folder other than the home folder.'; exit 0 }
$removed | Sort-Object Folder, Plugin | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
if ($DryRun) { Write-Host "Dry run: $($removed.Count) record(s) would be removed from $file."; exit 0 }

if ($file -eq (Get-ClaudeFullPath $hubFile) -and (Get-Process -Name claude -ErrorAction SilentlyContinue)) {
    Write-Warning 'A Claude Code session is running and could write its own view of the file back. Close every session (and VS Code), then run this again.'
    exit 1
}
foreach ($name in $emptied) { $data.plugins.PSObject.Properties.Remove($name) }
$backup = "$file.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $file -Destination $backup
# Without a byte-order mark, which Set-Content -Encoding UTF8 in Windows PowerShell would write
[IO.File]::WriteAllText($file, ($data | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
Write-Host "Removed $($removed.Count) record(s) from $file; the old file is $backup." -ForegroundColor Green
