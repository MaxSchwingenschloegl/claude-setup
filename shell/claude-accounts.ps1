# Claude Code with several accounts and one shared configuration.
# Dot-sourced from profile.ps1 (install.ps1 adds the line). Defines claude-<account> for every
# account and code-<account> for every account except the default one, and checks the default
# account's links on every shell start. Plain `claude` uses the default account through the
# user environment variable CLAUDE_CONFIG_DIR.

try { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\common.ps1') }
catch { Write-Warning "Claude setup: $($_.Exception.Message)"; return }

# Warns when a link has turned into a plain file (a tool that saves by replacing the file does
# that), because the accounts would then drift apart without notice.
function Test-ClaudeAccount([string]$Account) {
    $L = $ClaudeLayout
    $broken = @()
    $dir = Get-ClaudeAccountDir $Account
    foreach ($name in $L.ConfigFiles) {
        foreach ($base in $L.Hub, $dir) {
            if (-not (Test-ClaudeLink "$base\$name" "$($L.Config)\$name")) { $broken += "$base\$name" }
        }
    }
    foreach ($name in $L.ConfigDirs + $L.ToolDirs) {
        if (-not (Test-ClaudeLink "$($L.Hub)\$name" (Get-ClaudeHubTarget $name))) { $broken += "$($L.Hub)\$name" }
    }
    foreach ($name in $L.GlobalSkills) {
        if (-not (Test-ClaudeLink "$dir\skills\$name" "$($L.Config)\skills\$name")) { $broken += "$dir\skills\$name" }
    }
    foreach ($name in $L.AccountFiles + $L.AccountDirs) {
        if (-not (Test-ClaudeLink "$dir\$name" "$($L.Hub)\$name")) { $broken += "$dir\$name" }
    }
    if ($broken.Count) {
        Write-Warning ("Claude setup: not linked as expected: $($broken -join ', '). " +
                       "Run $($L.Root)\install.ps1; it keeps a backup of every file it replaces.")
    }
}

# The check runs inside try as well, so Ctrl+C or an error there cannot leave the shell on
# another account
function Invoke-ClaudeAs([string]$Account, [object[]]$Arguments) {
    $previous = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = Get-ClaudeAccountDir $Account
        Test-ClaudeAccount $Account
        claude @Arguments
    } finally { $env:CLAUDE_CONFIG_DIR = $previous }
}

# VS Code with another account than the default: its own window with its own profile
function Start-CodeAs([string]$Account, [object[]]$Arguments) {
    $previous = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = Get-ClaudeAccountDir $Account
        Test-ClaudeAccount $Account
        code --user-data-dir "$env:USERPROFILE\.vscode-$Account" @Arguments
    } finally { $env:CLAUDE_CONFIG_DIR = $previous }
}

foreach ($account in $ClaudeLayout.Accounts) {
    Set-Item "function:global:claude-$account" ([scriptblock]::Create("Invoke-ClaudeAs '$account' `$args"))
    if ($account -ne $ClaudeLayout.Default) {
        Set-Item "function:global:code-$account" ([scriptblock]::Create("Start-CodeAs '$account' `$args"))
    }
}
Remove-Variable account -ErrorAction SilentlyContinue

Test-ClaudeAccount $ClaudeLayout.Default
