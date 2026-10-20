# Shared by install.ps1 and shell/claude-accounts.ps1: reads the configuration's accounts.json
# and defines which items are linked where, so the installer and the startup check always agree.
# The configuration folder is named by the user environment variable CLAUDE_SETUP_CONFIG, which
# install.ps1 sets.

$__root = Split-Path -Parent $PSScriptRoot
$__configDir = $env:CLAUDE_SETUP_CONFIG
if (-not $__configDir -or -not (Test-Path -LiteralPath (Join-Path $__configDir 'accounts.json'))) {
    throw "No configuration found (CLAUDE_SETUP_CONFIG = '$__configDir'). Run $__root\install.ps1 -ConfigDir <folder>."
}
$__configDir = [IO.Path]::GetFullPath($__configDir).TrimEnd('\')
$__config = Get-Content -Raw -Encoding UTF8 (Join-Path $__configDir 'accounts.json') | ConvertFrom-Json
foreach ($__name in @($__config.accounts)) {
    if ($__name -cnotmatch '^[a-z0-9][a-z0-9-]*\z') {
        throw "accounts.json: invalid account name '$__name' (allowed: a-z, 0-9, -)"
    }
}
if (@($__config.accounts) -notcontains $__config.default) {
    throw "accounts.json: default account '$($__config.default)' is not listed in accounts"
}

$ClaudeLayout = @{
    Root         = $__root
    Config       = $__configDir
    Hub          = Join-Path $env:USERPROFILE '.claude'
    Accounts     = @($__config.accounts)
    Default      = $__config.default
    # Further plugin marketplaces, as folders relative to the configuration
    Marketplaces = @(@($__config.marketplaces) | Where-Object { $_ } |
                     ForEach-Object { [IO.Path]::GetFullPath((Join-Path $__configDir $_)).TrimEnd('\') })
    # Files that link straight into the configuration, from the hub and from every account.
    # Claude Code saves settings.json by replacing the file at the end of one link: a direct
    # link keeps working and the change lands in the configuration, a chain of two would break.
    ConfigFiles  = @('CLAUDE.md', 'settings.json')
    # Hub folders that link into the configuration
    ConfigDirs   = @('commands', 'rules', 'agents', 'output-styles')
    # Hub folders that link into this repo: the secret guard and the status line
    ToolDirs     = @('hooks', 'statusline')
    # Account items that link to the hub; everything else in an account folder is its own
    # (login, caches, sessions, skills synced from claude.ai)
    AccountFiles = @('history.jsonl')
    AccountDirs  = @('commands', 'hooks', 'rules', 'agents', 'output-styles', 'plugins', 'projects', 'paste-cache')
    # Skills every session needs: each folder in the configuration's skills/ is linked into every
    # account's skills folder. Skills only some projects need are plugins (plugins/ here).
    GlobalSkills = @(Get-ChildItem (Join-Path $__configDir 'skills') -Directory -ErrorAction SilentlyContinue |
                     ForEach-Object Name)
}
Remove-Variable __root, __configDir, __config, __name -ErrorAction SilentlyContinue

function Get-ClaudeAccountDir([string]$Account) {
    Join-Path $env:USERPROFILE ".claude-$Account"
}

function Get-ClaudeFullPath([string]$Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

# The folder a hub folder links to: the configuration or this repo
function Get-ClaudeHubTarget([string]$Name) {
    if ($ClaudeLayout.ToolDirs -contains $Name) { Join-Path $ClaudeLayout.Root $Name }
    else { Join-Path $ClaudeLayout.Config $Name }
}

# True when $Path is a symlink or junction that points to $Target.
function Test-ClaudeLink([string]$Path, [string]$Target) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -notin 'SymbolicLink', 'Junction') { return $false }
    $actual = @($item.Target)[0]
    if (-not $actual) { return $false }
    if (-not [IO.Path]::IsPathRooted($actual)) { $actual = Join-Path (Split-Path -Parent $Path) $actual }
    return (Get-ClaudeFullPath $actual) -eq (Get-ClaudeFullPath $Target)
}
