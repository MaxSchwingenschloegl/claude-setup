# Tests for the plugin fingerprint in plugins.ps1. Run: powershell -NoProfile -File scripts\plugins.test.ps1
# Exit code 0 when every case passes. The two cases with a real byte-code cache need Python on PATH.

$ErrorActionPreference = 'Stop'
if (-not $env:CLAUDE_SETUP_CONFIG) {
    $env:CLAUDE_SETUP_CONFIG = [Environment]::GetEnvironmentVariable('CLAUDE_SETUP_CONFIG', 'User')
}
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\plugins.ps1"

$script:run = 0
$script:failed = 0
function Check([string]$Name, [bool]$Ok) {
    $script:run++
    if ($Ok) { Write-Host "ok   $Name" } else { $script:failed++; Write-Host "FAIL $Name" -ForegroundColor Red }
}

# A .pyc header: magic, flags (0: checked by the source's time stamp and size), 8 more bytes, code
function New-Pyc([string]$Path, [int]$Flags) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    $bytes = [byte[]](@(0x55, 0x0d, 0x0d, 0x0a) + [BitConverter]::GetBytes([int32]$Flags) + @(1, 2, 3, 4, 5, 6, 7, 8) + @(0xe3, 0, 0, 0))
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Write-Text([string]$Path, [string]$Text, [Text.Encoding]$Encoding = (New-Object Text.UTF8Encoding $false)) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Encoding)
}

# Each case adds one file, checks the fingerprint and removes the file (and a folder it made) again
function Check-Added([string]$Name, [string]$File, [scriptblock]$Write, [bool]$Counts) {
    & $Write $File
    $same = (Get-PluginHash $plugin) -eq $base
    Remove-Item -LiteralPath $File
    if ((Split-Path -Leaf (Split-Path $File)) -eq '.orphaned_at') { Remove-Item -LiteralPath (Split-Path $File) }
    Check $Name ($same -ne $Counts)
}

$root = Join-Path ([IO.Path]::GetTempPath()) "plugins-test-$PID"
if (Test-Path $root) { Remove-Item -Recurse -Force $root }
try {
    $plugin = Join-Path $root 'plugin'
    New-Item -ItemType Directory -Force "$plugin\hooks" | Out-Null
    Set-Content -LiteralPath "$plugin\hooks\tool.py" -Value 'VALUE = 1' -Encoding ASCII
    Set-Content -LiteralPath "$plugin\hooks\hooks.json" -Value '{}' -Encoding ASCII
    $base = Get-PluginHash $plugin
    $lock = '{"pid":35992,"procStartFt":134077416119453125,"acquiredAt":1794951526481}'
    $arabic = "$([char]0x0661)$([char]0x0662)"
    $wide = "$([char]0xFF11)$([char]0xFF12)"

    # Claude Code's own files stay out
    Check-Added 'a lock file .in_use/<process id> leaves the fingerprint as it was' "$plugin\.in_use\35992" { param($f) Write-Text $f $lock } $false
    Check-Added "Claude Code's .orphaned_at mark (a time stamp) leaves it as it was" "$plugin\.orphaned_at" { param($f) Write-Text $f '1794951526481' } $false
    Check-Added 'an .orphaned_at of 20 digits leaves it as it was' "$plugin\.orphaned_at" { param($f) Write-Text $f ('1' * 20) } $false

    # ... and nothing that only looks like them
    Check-Added 'a file in .in_use that is no process id changes it' "$plugin\.in_use\x1" { param($f) Write-Text $f '' } $true
    Check-Added 'a file in .in_use named with Arabic-Indic digits changes it' "$plugin\.in_use\$arabic" { param($f) Write-Text $f '' } $true
    Check-Added 'a file in .in_use named with full-width digits changes it' "$plugin\.in_use\$wide" { param($f) Write-Text $f '' } $true
    Check-Added 'a lock file larger than 4 KB changes it' "$plugin\.in_use\35992" { param($f) Write-Text $f ('x' * 4097) } $true
    Check-Added 'an .orphaned_at with a final line break changes it' "$plugin\.orphaned_at" { param($f) Write-Text $f "1794951526481`n" } $true
    Check-Added 'an .orphaned_at with more than a time stamp changes it' "$plugin\.orphaned_at" { param($f) Write-Text $f "1794951526481`nimport os" } $true
    Check-Added 'an .orphaned_at of more than 20 digits changes it' "$plugin\.orphaned_at" { param($f) Write-Text $f ('1' * 21) } $true
    Check-Added 'an empty .orphaned_at changes it' "$plugin\.orphaned_at" { param($f) Write-Text $f '' } $true
    Check-Added 'an .orphaned_at with a byte-order mark changes it' "$plugin\.orphaned_at" { param($f) Write-Text $f '1794951526481' (New-Object Text.UTF8Encoding $true) } $true
    Check-Added 'an .orphaned_at in UTF-16 changes it' "$plugin\.orphaned_at" { param($f) Write-Text $f '17949515' ([Text.Encoding]::Unicode) } $true
    Check-Added 'an .orphaned_at of Arabic-Indic digits changes it' "$plugin\.orphaned_at" { param($f) Write-Text $f $arabic } $true
    Check-Added 'a file in a folder named .orphaned_at changes it' "$plugin\.orphaned_at\1794951526481" { param($f) Write-Text $f '1794951526481' } $true
    Check-Added 'an .orphaned_at below the top folder changes it' "$plugin\hooks\.orphaned_at" { param($f) Write-Text $f '1794951526481' } $true

    # Python's byte-code cache counts, whatever its header says and wherever it stands
    Check-Added 'a time-stamp .pyc in __pycache__ changes it' "$plugin\hooks\__pycache__\tool.cpython-312.pyc" { param($f) New-Pyc $f 0 } $true
    Check-Added 'an unchecked hash-based .pyc changes it' "$plugin\hooks\__pycache__\tool.cpython-311.pyc" { param($f) New-Pyc $f 1 } $true
    Check-Added 'a .pyc where a source would be, which Python runs without one, changes it' "$plugin\hooks\run.pyc" { param($f) New-Pyc $f 0 } $true

    Check 'back to the base after the removals' ((Get-PluginHash $plugin) -eq $base)
    Set-Content -LiteralPath "$plugin\hooks\tool.py" -Value 'VALUE = 2' -Encoding ASCII
    Check 'a changed source file changes it' ((Get-PluginHash $plugin) -ne $base)
    Set-Content -LiteralPath "$plugin\hooks\tool.py" -Value 'VALUE = 1' -Encoding ASCII

    # The reason for PYTHONDONTWRITEBYTECODE: an import writes a cache, and that cache counts.
    # Get-Command can find the WindowsApps stub that only opens the Store: run it once to be sure.
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) { & $python.Source -c 'import sys' 2>$null; if ($LASTEXITCODE -ne 0) { $python = $null } }
    if ($python) {
        foreach ($case in @(@{ Set = $true }, @{ Set = $false })) {
            $real = Join-Path $root "real-$($case.Set)"
            New-Item -ItemType Directory -Force "$real\hooks" | Out-Null
            Set-Content -LiteralPath "$real\hooks\tool.py" -Value 'VALUE = 1' -Encoding ASCII
            $before = Get-PluginHash $real
            $saved = $env:PYTHONDONTWRITEBYTECODE
            $savedPrefix = $env:PYTHONPYCACHEPREFIX   # would move the cache out of the folder
            try {
                Remove-Item Env:PYTHONPYCACHEPREFIX -ErrorAction SilentlyContinue
                if ($case.Set) { $env:PYTHONDONTWRITEBYTECODE = '1' } else { Remove-Item Env:PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue }
                & $python.Source -c "import sys; sys.path.insert(0, sys.argv[1]); import tool; assert tool.VALUE == 1" "$real\hooks"
                $exit = $LASTEXITCODE
            } finally { $env:PYTHONDONTWRITEBYTECODE = $saved; $env:PYTHONPYCACHEPREFIX = $savedPrefix }
            $written = @(Get-ChildItem -LiteralPath "$real\hooks" -Recurse -Filter *.pyc -ErrorAction SilentlyContinue).Count
            $same = (Get-PluginHash $real) -eq $before
            if ($case.Set) {
                Check "with PYTHONDONTWRITEBYTECODE=1 the import ran (exit $exit), wrote no cache ($written .pyc) and the fingerprint stayed" ($exit -eq 0 -and $written -eq 0 -and $same)
            } else {
                Check "without it the import ran (exit $exit), wrote a cache ($written .pyc) and the fingerprint changed" ($exit -eq 0 -and $written -ge 1 -and -not $same)
            }
        }
    } else {
        Write-Host 'skip the two cases with a real byte-code cache: no working python on PATH' -ForegroundColor Yellow
    }
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host "$script:run run, $script:failed failed"
if ($script:failed) { exit 1 }
