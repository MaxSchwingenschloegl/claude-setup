<#
.SYNOPSIS
    Sets up Claude Code with several accounts that share one configuration folder.
.DESCRIPTION
    The configuration (accounts, settings, rules, global skills) lives in a folder of your own,
    ideally a private git repository; this repo holds the tools. The first run with a folder
    that does not exist yet creates it from a template and stops, so you can edit it first.

    Safe to run again at any time: it only changes what is not set up yet and repairs links
    that have turned into plain files. Nothing is deleted that is not empty or identical to
    what replaces it: folder contents are moved into the hub, and whatever cannot be merged is
    kept as <name>.backup-<time> next to it. Creating file symlinks needs Windows Developer
    Mode (Settings > System > For developers) or an elevated PowerShell.
.PARAMETER ConfigDir
    Your configuration folder. Needed on the first run; later runs remember it (user environment
    variable CLAUDE_SETUP_CONFIG).
.PARAMETER Template
    The template a new configuration folder starts from: recommended (default) or minimal.
.PARAMETER DryRun
    Show what would change without changing anything.
.PARAMETER InstallPlugins
    Also install the plugins settings.json enables but this machine does not have yet, as far as
    the configuration's vetting.json holds a skillspector scan of exactly what the marketplace
    would install (scripts\vet-plugins.ps1). Without it they are only listed, so nothing that
    runs code is installed before you looked at it.
.PARAMETER Uninstall
    Undo the setup: every link becomes a plain copy of what it pointed to, the profile block,
    the environment variables and the marketplace registrations go. Logins, transcripts and the
    configuration folder stay.
#>
param(
    [string]$ConfigDir,
    [ValidateSet('recommended', 'minimal')][string]$Template = 'recommended',
    [switch]$DryRun,
    [switch]$InstallPlugins,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# The configuration folder: given, or remembered from an earlier run
$remembered = [Environment]::GetEnvironmentVariable('CLAUDE_SETUP_CONFIG', 'User')
$explicit = [bool]$ConfigDir
if (-not $ConfigDir) { $ConfigDir = $remembered }
if (-not $ConfigDir) {
    throw "Name your configuration folder: .\install.ps1 -ConfigDir <folder>. A folder that does not exist yet is created from a template (-Template recommended or minimal)."
}
$ConfigDir = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($ConfigDir)) { $ConfigDir } else { Join-Path (Get-Location) $ConfigDir })).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $ConfigDir 'accounts.json'))) {
    if (-not $explicit) {
        throw "The remembered configuration $ConfigDir is gone or has no accounts.json. Name it again: .\install.ps1 -ConfigDir <folder>."
    }
    if ($Uninstall) { throw "$ConfigDir is no configuration folder (no accounts.json)." }
    if ((Test-Path -LiteralPath $ConfigDir) -and (Get-ChildItem -LiteralPath $ConfigDir -Force | Where-Object Name -ne '.git' | Select-Object -First 1)) {
        throw "$ConfigDir has files but no accounts.json. Use an empty or new folder for a new configuration."
    }
    if ($DryRun) {
        Write-Host "would create $ConfigDir from the template '$Template'" -ForegroundColor Yellow
        return
    }
    New-Item -ItemType Directory -Force $ConfigDir | Out-Null
    foreach ($entry in Get-ChildItem -LiteralPath "$PSScriptRoot\templates\$Template" -Force) {
        Copy-Item -LiteralPath $entry.FullName -Destination $ConfigDir -Recurse -Force
    }
    [Environment]::SetEnvironmentVariable('CLAUDE_SETUP_CONFIG', $ConfigDir, 'User')
    Write-Host "Created $ConfigDir from the template '$Template'." -ForegroundColor Green
    Write-Host 'Before installing: set your account names in accounts.json, read CLAUDE.md, rules/ and settings.json'
    Write-Host '(README, "Choose your configuration"), ideally make the folder a private git repository. Then:'
    Write-Host '  .\install.ps1 -DryRun     # shows what would change' -ForegroundColor Cyan
    Write-Host '  .\install.ps1' -ForegroundColor Cyan
    return
}
$env:CLAUDE_SETUP_CONFIG = $ConfigDir
. "$PSScriptRoot\scripts\common.ps1"
. "$PSScriptRoot\scripts\plugins.ps1"
$L = $ClaudeLayout
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$changes = 0
$utf8 = New-Object Text.UTF8Encoding $false

function Write-Step([string]$Message) {
    if ($DryRun) { Write-Host "would $Message" -ForegroundColor Yellow } else { Write-Host $Message }
    $script:changes++
}

# cmd's mklink honours Developer Mode; New-Item in Windows PowerShell 5.1 needs elevation
function New-FileSymlink([string]$Path, [string]$Target) {
    $ErrorActionPreference = 'Continue'   # in 5.1, stderr of cmd would otherwise end the script
    $output = cmd /c mklink "$Path" "$Target" 2>&1
    if ($LASTEXITCODE) { throw "mklink could not create ${Path}: $output" }
}

function Test-SymlinkPrivilege {
    $probe = Join-Path $env:TEMP "claude-setup-probe-$([guid]::NewGuid())"
    try { New-FileSymlink $probe "$PSScriptRoot\install.ps1"; return $true }
    catch { return $false }
    finally { if (Test-Path -LiteralPath $probe) { [IO.File]::Delete($probe) } }
}

# Appends the lines of a history.jsonl that an account has started on its own to the shared one.
function Merge-History([string]$From, [string]$To) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path $To) { foreach ($line in [IO.File]::ReadAllLines($To, $utf8)) { [void]$seen.Add($line) } }
    $new = @([IO.File]::ReadAllLines($From, $utf8) | Where-Object { $_.Trim() -and -not $seen.Contains($_) })
    if (-not $new.Count) { return 0 }
    # A last line without a newline would otherwise be glued to the first appended one
    $prefix = ''
    if ((Test-Path $To) -and (Get-Item $To).Length -gt 0) {
        $stream = [IO.File]::OpenRead($To)
        try { [void]$stream.Seek(-1, [IO.SeekOrigin]::End); if ($stream.ReadByte() -ne 10) { $prefix = "`n" } }
        finally { $stream.Close() }
    }
    [IO.File]::AppendAllText($To, $prefix + ($new -join "`n") + "`n", $utf8)
    return $new.Count
}

# Moves what an account has collected in a folder of its own into the hub. Entries the hub
# already has stay where they are and end up in the backup.
function Merge-Folder([string]$From, [string]$To) {
    $moved = 0
    foreach ($entry in @(Get-ChildItem -LiteralPath $From -Force)) {
        $dest = Join-Path $To $entry.Name
        if (-not (Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue)) {
            Move-Item -LiteralPath $entry.FullName -Destination $dest
            $moved++
        }
    }
    return $moved
}

# True when a plain file is a changed copy of the repo file rather than an unrelated one: it
# holds at least half of the repo file's lines. A settings.json that Claude Code rewrote keeps
# almost all of them; the default file Claude Code creates on a new machine keeps almost none,
# and taking that one into the repo would wipe the configuration.
function Test-SameLineage([string]$Path, [string]$Target) {
    $mine = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in [IO.File]::ReadAllLines($Path)) { if ($line.Trim()) { [void]$mine.Add($line.Trim()) } }
    $repo = @([IO.File]::ReadAllLines($Target) | Where-Object { $_.Trim() })
    if (-not $repo.Count) { return $false }
    $shared = @($repo | Where-Object { $mine.Contains($_.Trim()) }).Count
    return ($shared * 2) -ge $repo.Count
}

function Test-EmptyFolder([string]$Path) {
    -not (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)
}

# Makes $Path a link to $Target. A wrong link is replaced. A plain file or folder is dropped
# when it is empty or identical to the target; folder contents and history lines are merged
# into the target first, and whatever is left is kept as a backup. With -Adopt, a plain file
# that is newer than the target is taken into the target: Claude Code saves settings.json by
# replacing the file, which turns a link into a plain file that holds the latest change.
#
# -NoMerge keeps a folder's contents out of the target: for targets inside this repo, so files a
# machine already had never end up in a commit by accident.
function Set-Link([string]$Path, [string]$Target, [string]$Kind, [switch]$Adopt, [switch]$NoMerge) {
    if (Test-ClaudeLink $Path $Target) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.LinkType -in 'SymbolicLink', 'Junction') {
            Write-Step "remove link $Path (pointed to $(@($item.Target)[0]))"
            if (-not $DryRun) { if ($item.PSIsContainer) { [IO.Directory]::Delete($Path) } else { [IO.File]::Delete($Path) } }
        } elseif ($item.PSIsContainer) {
            $empty = Test-EmptyFolder $Path
            if (-not $empty -and -not $NoMerge) {
                Write-Step "move the contents of $Path into $Target"
                if (-not $DryRun) { Write-Host "  $(Merge-Folder $Path $Target) entries moved" }
                if (-not $DryRun) { $empty = Test-EmptyFolder $Path }
            }
            if ($empty) {
                Write-Step "remove empty folder $Path"
                if (-not $DryRun) { [IO.Directory]::Delete($Path) }
            } else {
                $what = if ($NoMerge) { 'its contents stay out of the repo' } else { "entries $Target already has" }
                Write-Step "keep $Path as $($item.Name).backup-$stamp ($what)"
                if (-not $DryRun) { Rename-Item -LiteralPath $Path -NewName "$($item.Name).backup-$stamp" }
            }
        } elseif ((Test-Path $Target) -and (Get-FileHash -LiteralPath $Path).Hash -eq (Get-FileHash -LiteralPath $Target).Hash) {
            Write-Step "remove $Path (same content as $Target)"
            if (-not $DryRun) { [IO.File]::Delete($Path) }
        } elseif ($Adopt -and (Test-Path $Target) -and $item.LastWriteTimeUtc -gt (Get-Item -LiteralPath $Target).LastWriteTimeUtc -and
                  (Test-SameLineage $Path $Target)) {
            Write-Step "take the newer $Path into $Target (review it with git diff)"
            if (-not $DryRun) {
                Copy-Item -LiteralPath $Target "$Target.backup-$stamp"   # uncommitted edits in the repo copy
                Copy-Item -LiteralPath $Path $Target -Force
                [IO.File]::Delete($Path)
            }
        } else {
            if ($item.Name -eq 'history.jsonl') {
                Write-Step "merge $Path into $Target"
                if (-not $DryRun) { Write-Host "  $(Merge-History $Path $Target) new lines" }
            }
            Write-Step "back up $Path as $($item.Name).backup-$stamp"
            if (-not $DryRun) { Rename-Item -LiteralPath $Path -NewName "$($item.Name).backup-$stamp" }
        }
    }
    Write-Step "link $Path -> $Target"
    if (-not $DryRun) {
        if ($Kind -eq 'SymbolicLink') { New-FileSymlink $Path $Target }
        else { New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null }
    }
}

# Profiles without a byte order mark may be UTF-8 or the ANSI code page
function Read-TextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return $utf8.GetString($bytes, 3, $bytes.Length - 3)
    }
    try { return (New-Object Text.UTF8Encoding $false, $true).GetString($bytes) }
    catch { return [Text.Encoding]::Default.GetString($bytes) }
}

$begin = '# >>> claude-setup >>>'
$end = '# <<< claude-setup <<<'
$blockPattern = "(?s)$([regex]::Escape($begin)).*?$([regex]::Escape($end))\r?\n?"

# Adds or updates the claude-setup block in a profile, or removes it when $Block is empty.
# A profile that holds nothing but the block is removed together with it.
function Set-ProfileBlock([string]$Path, [string]$Block) {
    $current = Read-TextFile $Path
    $rest = [regex]::Replace($current, $blockPattern, '')
    if ($Block) {
        $updated = if ($current -match $blockPattern) {
            [regex]::Replace($current, $blockPattern, [Text.RegularExpressions.MatchEvaluator] { "$Block`r`n" })
        } elseif ($current.Trim()) { $current.TrimEnd() + "`r`n`r`n$Block`r`n" } else { "$Block`r`n" }
    } else {
        $updated = $rest
    }
    if ($rest -match 'CLAUDE_CONFIG_DIR') {
        Write-Warning "$Path still sets CLAUDE_CONFIG_DIR outside the claude-setup block. Remove the old account functions there."
    }
    if ($updated -eq $current) { return }
    if ($updated.Trim()) {
        Write-Step "$(if ($Block) { 'update' } else { 'remove the claude-setup block from' }) $Path"
    } else {
        Write-Step "remove $Path (it held only the claude-setup block)"
    }
    if ($DryRun) { return }
    if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path "$Path.backup-$stamp" }
    if ($updated.Trim()) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
        [IO.File]::WriteAllText($Path, $updated, (New-Object Text.UTF8Encoding $true))
    } else {
        [IO.File]::Delete($Path)
    }
}

Write-Host "Claude setup from $($L.Root) with the configuration $($L.Config)$(if ($DryRun) { ' (dry run, nothing is changed)' })"

# Replaces a link by a plain copy of what it points to; for -Uninstall
function Convert-LinkToCopy([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -notin 'SymbolicLink', 'Junction') { return }
    $target = @($item.Target)[0]
    Write-Step "replace the link $Path by a copy of $target"
    if ($DryRun) { return }
    if ($item.PSIsContainer) { [IO.Directory]::Delete($Path) } else { [IO.File]::Delete($Path) }
    if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination $Path -Recurse }
}

if ($Uninstall) {
    # Links that point into the configuration or this repo become copies; the account folders'
    # links to the hub stay, the hub is plain folders again afterwards
    foreach ($name in $L.ConfigFiles + $L.ConfigDirs + $L.ToolDirs) { Convert-LinkToCopy "$($L.Hub)\$name" }
    foreach ($account in $L.Accounts) {
        $dir = Get-ClaudeAccountDir $account
        foreach ($name in $L.ConfigFiles) { Convert-LinkToCopy "$dir\$name" }
        foreach ($name in $L.GlobalSkills) { Convert-LinkToCopy "$dir\skills\$name" }
    }
    $documents = [Environment]::GetFolderPath('MyDocuments')
    foreach ($folder in "$documents\WindowsPowerShell", "$documents\PowerShell") {
        $file = "$folder\profile.ps1"
        if ((Test-Path $file) -and ([IO.File]::ReadAllText($file) -match '# >>> claude-setup >>>')) {
            Write-Step "remove the claude-setup block from $file"
            if (-not $DryRun) {
                $text = [regex]::Replace([IO.File]::ReadAllText($file), '(?s)# >>> claude-setup >>>.*?# <<< claude-setup <<<\r?\n?', '')
                if ($text.Trim()) { [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $true)) } else { [IO.File]::Delete($file) }
            }
        }
    }
    foreach ($variable in 'CLAUDE_SETUP_CONFIG', 'CLAUDE_CONFIG_DIR') {
        if ([Environment]::GetEnvironmentVariable($variable, 'User')) {
            Write-Step "delete the user environment variable $variable"
            if (-not $DryRun) { [Environment]::SetEnvironmentVariable($variable, $null, 'User') }
        }
    }
    $hooksPath = (Get-ClaudeFullPath "$($L.Root)\.githooks") -replace '\\', '/'
    foreach ($folder in @($L.Root, $L.Config) + $L.Marketplaces) {
        if ((Test-Path "$folder\.git") -and (Get-Command git -ErrorAction SilentlyContinue)) {
            $current = git -C $folder config core.hooksPath
            if ($current -eq $hooksPath -or $current -eq '.githooks') {
                Write-Step "switch off the secret scan hook for $folder"
                if (-not $DryRun) { git -C $folder config --unset core.hooksPath }
            }
        }
        $manifest = Read-JsonFile "$folder\.claude-plugin\marketplace.json"
        if ($manifest -and (Get-Command claude -ErrorAction SilentlyContinue)) {
            Write-Step "remove the plugin marketplace $($manifest.name)"
            if (-not $DryRun) {
                $ErrorActionPreference = 'Continue'
                claude plugin marketplace remove $manifest.name 2>&1 | Out-Null
                $ErrorActionPreference = 'Stop'
            }
        }
    }
    if ($DryRun) { return }
    Write-Host ('Uninstalled. Plain claude now uses ~/.claude again, which has no login: run claude and /login. ' +
                'The account folders ~/.claude-<name> keep their logins; delete the ones you no longer need. ' +
                'Files kept as *.backup-* next to their original are yours to restore or delete.') -ForegroundColor Green
    return
}

# Check up front, so a missing privilege stops the run before anything has changed
$missingSymlinks = @($L.ConfigFiles | Where-Object { -not (Test-ClaudeLink "$($L.Hub)\$_" "$($L.Config)\$_") })
foreach ($account in $L.Accounts) {
    $dir = Get-ClaudeAccountDir $account
    $missingSymlinks += @($L.ConfigFiles | Where-Object { -not (Test-ClaudeLink "$dir\$_" "$($L.Config)\$_") })
    $missingSymlinks += @($L.AccountFiles | Where-Object { -not (Test-ClaudeLink "$dir\$_" "$($L.Hub)\$_") })
}
if ($missingSymlinks.Count -and -not (Test-SymlinkPrivilege)) {
    $message = 'Creating file symlinks needs Windows Developer Mode (Settings > System > For developers) or an elevated PowerShell.'
    if ($DryRun) { Write-Warning $message } else { throw "$message Nothing was changed." }
}

# 0. Taking over what Claude Code already had on this machine, so nothing is lost silently
$defaultDir = Get-ClaudeAccountDir $L.Default
if (-not (Test-Path $defaultDir) -and -not $DryRun) { New-Item -ItemType Directory $defaultDir | Out-Null }
#    The login in ~/.claude moves to the default account, so you stay signed in there
if ((Test-Path "$($L.Hub)\.credentials.json") -and -not (Test-Path "$defaultDir\.credentials.json")) {
    Write-Step "move the existing login from $($L.Hub) to the default account $($L.Default)"
    if (-not $DryRun) { Move-Item -LiteralPath "$($L.Hub)\.credentials.json" "$defaultDir\.credentials.json" }
}
#    ~/.claude.json holds MCP servers, trusted projects and onboarding state; with
#    CLAUDE_CONFIG_DIR set, Claude Code reads it from the account folder instead
$homeState = Join-Path $env:USERPROFILE '.claude.json'
if ((Test-Path $homeState) -and -not (Test-Path "$defaultDir\.claude.json")) {
    Write-Step "copy $homeState (MCP servers, trusted projects) to the default account $($L.Default)"
    if (-not $DryRun) { Copy-Item -LiteralPath $homeState "$defaultDir\.claude.json" }
}
#    Personal skills in ~/.claude/skills move into the configuration's skills folder. A linked
#    skills folder belongs to another tool (npx skills links ~/.agents/skills there): its skills
#    stay where they are and are only named, as taking them over unasked would skip the scan.
$hubSkills = Join-Path $L.Hub 'skills'
$hubSkillsItem = Get-Item -LiteralPath $hubSkills -Force -ErrorAction SilentlyContinue
$hubOnly = @(if ($hubSkillsItem) {
    Get-ChildItem -LiteralPath $hubSkills -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path "$($_.FullName)\SKILL.md") -and -not (Test-Path "$($L.Config)\skills\$($_.Name)") }
})
if ($hubSkillsItem.LinkType -and $hubOnly.Count) {
    Write-Warning ("$hubSkills links to $(@($hubSkillsItem.Target)[0]), so its skills are not taken over and no account sees them: " +
                   "$($hubOnly.Name -join ', '). Copy the ones you want into $($L.Config)\skills after scanning them with skillspector.")
} elseif (-not $hubSkillsItem.LinkType) {
    foreach ($skill in $hubOnly) {
        Write-Step "move your skill $($skill.Name) from $hubSkills into $($L.Config)\skills"
        if (-not $DryRun) {
            New-Item -ItemType Directory -Force "$($L.Config)\skills" | Out-Null
            Move-Item -LiteralPath $skill.FullName "$($L.Config)\skills\$($skill.Name)"
            $L.GlobalSkills += $skill.Name
        }
    }
}

# 1. Hub ~/.claude: CLAUDE.md, settings.json, commands, rules, agents and output styles come
#    from the configuration, hooks and statusline from this repo
if (-not (Test-Path $L.Hub)) {
    Write-Step "create $($L.Hub)"
    if (-not $DryRun) { New-Item -ItemType Directory $L.Hub | Out-Null }
}
foreach ($name in $L.ConfigFiles) { Set-Link "$($L.Hub)\$name" "$($L.Config)\$name" 'SymbolicLink' -Adopt }
foreach ($name in $L.ConfigDirs + $L.ToolDirs) {
    $target = Get-ClaudeHubTarget $name
    if (-not (Test-Path $target)) {
        Write-Step "create $target"
        if (-not $DryRun) { New-Item -ItemType Directory $target | Out-Null }
    }
    # What a machine already has in commands, rules, agents or output styles is yours and moves
    # into your configuration (review it with git status there); the tool folders stay clean
    if ($L.ToolDirs -contains $name) { Set-Link "$($L.Hub)\$name" $target 'Junction' -NoMerge }
    else { Set-Link "$($L.Hub)\$name" $target 'Junction' }
}
foreach ($name in $L.AccountDirs | Where-Object { ($L.ConfigDirs + $L.ToolDirs) -notcontains $_ }) {
    if (-not (Test-Path "$($L.Hub)\$name")) {
        Write-Step "create $($L.Hub)\$name"
        if (-not $DryRun) { New-Item -ItemType Directory "$($L.Hub)\$name" | Out-Null }
    }
}
if (-not (Test-Path "$($L.Hub)\history.jsonl")) {
    Write-Step "create $($L.Hub)\history.jsonl"
    if (-not $DryRun) { New-Item -ItemType File "$($L.Hub)\history.jsonl" | Out-Null }
}
if (Test-Path "$($L.Hub)\.credentials.json") {
    Write-Warning "$($L.Hub) holds a login (.credentials.json). The hub is meant to have none: sign in per account instead and delete that file once every account works."
}

# 2. Accounts ~/.claude-<name>: own login; CLAUDE.md and settings.json link straight into the
#    configuration, everything else that is shared links to the hub
foreach ($account in $L.Accounts) {
    $dir = Get-ClaudeAccountDir $account
    if (-not (Test-Path $dir)) {
        Write-Step "create $dir"
        if (-not $DryRun) { New-Item -ItemType Directory $dir | Out-Null }
    }
    foreach ($name in $L.ConfigFiles) { Set-Link "$dir\$name" "$($L.Config)\$name" 'SymbolicLink' -Adopt }
    foreach ($name in $L.AccountFiles) { Set-Link "$dir\$name" "$($L.Hub)\$name" 'SymbolicLink' }
    foreach ($name in $L.AccountDirs) { Set-Link "$dir\$name" "$($L.Hub)\$name" 'Junction' }

    # Global skills: one junction per folder in the configuration's skills/, none for a removed one
    $skillsDir = Join-Path $dir 'skills'
    if ($L.GlobalSkills.Count -and -not (Test-Path $skillsDir)) {
        Write-Step "create $skillsDir"
        if (-not $DryRun) { New-Item -ItemType Directory $skillsDir | Out-Null }
    }
    foreach ($name in $L.GlobalSkills) { Set-Link "$skillsDir\$name" "$($L.Config)\skills\$name" 'Junction' }
    $skillSource = (Get-ClaudeFullPath "$($L.Config)\skills") + '\'
    $oldSource = if ($remembered -and (Get-ClaudeFullPath $remembered) -ne $L.Config) { (Get-ClaudeFullPath "$remembered\skills") + '\' }
    foreach ($link in @(Get-ChildItem $skillsDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object LinkType -eq 'Junction')) {
        $target = @($link.Target)[0]
        if (-not $target) { continue }
        $gone = $target.StartsWith($skillSource, [StringComparison]::OrdinalIgnoreCase) -and $L.GlobalSkills -notcontains $link.Name
        $previous = $oldSource -and $target.StartsWith($oldSource, [StringComparison]::OrdinalIgnoreCase)
        if ($gone -or $previous -or -not (Test-Path -LiteralPath $target)) {
            Write-Step "remove skill link $($link.FullName) (not in the configuration, or its target is gone)"
            if (-not $DryRun) { [IO.Directory]::Delete($link.FullName) }
        }
    }
}

# 3. Plain `claude` (and the VS Code extension) use the default account
$defaultDir = Get-ClaudeAccountDir $L.Default
if ([Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User') -ne $defaultDir) {
    Write-Step "set user environment variable CLAUDE_CONFIG_DIR = $defaultDir"
    if (-not $DryRun) { [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $defaultDir, 'User') }
}
# ... and the account functions find the configuration through CLAUDE_SETUP_CONFIG
if ([Environment]::GetEnvironmentVariable('CLAUDE_SETUP_CONFIG', 'User') -ne $L.Config) {
    Write-Step "set user environment variable CLAUDE_SETUP_CONFIG = $($L.Config)"
    if (-not $DryRun) { [Environment]::SetEnvironmentVariable('CLAUDE_SETUP_CONFIG', $L.Config, 'User') }
}

# 4. PowerShell loads the account functions from profile.ps1, the profile for all hosts, so the
#    console, the VS Code terminal and the VS Code PowerShell extension get them alike, in
#    Windows PowerShell and in PowerShell 7. The guard keeps new shells quiet if the repo moves.
$documents = [Environment]::GetFolderPath('MyDocuments')
$profileFolders = @("$documents\WindowsPowerShell")
if ((Get-Command pwsh -ErrorAction SilentlyContinue) -or (Test-Path "$documents\PowerShell")) {
    $profileFolders += "$documents\PowerShell"
}
# Typographic single quotes end a PowerShell string as well; written as code points, because
# Windows PowerShell reads a file without a byte order mark in the ANSI code page
$quotes = "['" + [char]0x2018 + [char]0x2019 + [char]0x201A + [char]0x201B + "]"
$module = "$($L.Root)\shell\claude-accounts.ps1" -replace $quotes, "''"
$block = "$begin`r`nif (Test-Path -LiteralPath '$module') { . '$module' }`r`n$end"
foreach ($folder in $profileFolders) {
    Set-ProfileBlock "$folder\profile.ps1" $block
    Set-ProfileBlock "$folder\Microsoft.PowerShell_profile.ps1" ''   # earlier versions put it here
}

# A fresh Windows only runs signed scripts or none at all, which keeps profile.ps1 from loading.
# The process scope is skipped: it may be Bypass just for this run.
$policy = 'Restricted'
foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
    $value = Get-ExecutionPolicy -Scope $scope
    if ($value -ne 'Undefined') { $policy = $value; break }
}
if ($policy -in 'Restricted', 'AllSigned') {
    Write-Warning "PowerShell runs no unsigned scripts here ($policy), so profile.ps1 cannot load the account functions. Allow them for your user: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}

# 5. This repo, the configuration and your own marketplaces: scan every commit for secrets.
#    A repository that already has hooks of its own (husky and the like) keeps them.
$hooksPath = (Get-ClaudeFullPath "$($L.Root)\.githooks") -replace '\\', '/'
if (Get-Command git -ErrorAction SilentlyContinue) {
    foreach ($repo in @($L.Root, $L.Config) + $L.Marketplaces) {
        if (-not (Test-Path "$repo\.git")) { continue }
        $current = git -C $repo config core.hooksPath
        if ($current -eq $hooksPath) { continue }
        $ours = -not $current -or $current -eq '.githooks' -or $current -match '/\.githooks$'
        if (-not $ours) {
            Write-Warning "$repo uses its own git hooks ($current); the secret scan is not added there."
            continue
        }
        Write-Step "enable the secret scan hook for $repo"
        if (-not $DryRun) { git -C $repo config core.hooksPath $hooksPath }
    }
}

# 6. Plugin marketplaces: this repo (the skill groups in plugins/) and those the configuration
#    names. Each is registered per machine and declared in its own folder's
#    .claude/settings.local.json (not committed), so settings.json never holds a path of one
#    machine. Enable a group per project with: claude plugin install <group>@<marketplace> --scope local
$known = Read-JsonFile "$($L.Hub)\plugins\known_marketplaces.json"
foreach ($folder in @($L.Root) + $L.Marketplaces) {
    $manifest = Read-JsonFile "$folder\.claude-plugin\marketplace.json"
    if (-not $manifest) { Write-Warning "No plugin marketplace in $folder (.claude-plugin\marketplace.json)."; continue }
    $name = $manifest.name
    $registered = if ($known) { $known.$name }
    $registeredPath = if ($registered) { $registered.source.path }
    if ($registeredPath -and (Get-ClaudeFullPath $registeredPath) -eq (Get-ClaudeFullPath $folder)) { continue }
    Write-Step "register $folder as the plugin marketplace $name"
    if ($DryRun) { continue }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Warning 'Claude Code is not installed yet. Install it, then run install.ps1 again to register the skill groups.'
        break
    }
    $ErrorActionPreference = 'Continue'
    Push-Location $folder
    try {
        if ($registered) { claude plugin marketplace remove $name 2>&1 | Out-Null }
        $output = claude plugin marketplace add $folder --scope local 2>&1
        if ($LASTEXITCODE) { Write-Warning "Could not register the marketplace ${name}: $output" }
    } finally { Pop-Location; $ErrorActionPreference = 'Stop' }
}

# Earlier versions shared claude.ai skills from one account into the others as junctions into
# that account's skills\synced folder; the skill groups replace that
foreach ($account in $L.Accounts) {
    $skills = Join-Path (Get-ClaudeAccountDir $account) 'skills'
    foreach ($link in @(Get-ChildItem $skills -Directory -ErrorAction SilentlyContinue | Where-Object LinkType -eq 'Junction')) {
        if (@($link.Target)[0] -match '\\\.claude-([^\\]+)\\skills\\synced\\' -and $matches[1] -ne $account) {
            Write-Step "remove shared skill link $($link.FullName)"
            if (-not $DryRun) { [IO.Directory]::Delete($link.FullName) }
        }
    }
}

# 7. Plugins: what is installed for all projects is also enabled in the configuration's settings.json.
#    Plugins a project installs and enables for itself are its own business.
#    Every enabled plugin should have a skillspector scan of exactly its files in the
#    configuration's vetting.json (scripts\vet-plugins.ps1). Plugins enabled but not installed
#    yet are listed; -InstallPlugins installs those whose scan matches what the marketplace holds.
#    Not by default: a plugin runs code, and what gets installed is your decision, after a look.
$verdictText = @{
    ok = 'scanned'; unvetted = 'not scanned'; changed = 'changed since the scan'
    unapproved = "score above $PluginScoreLimit, not approved"; unknown = 'marketplace not on this machine'
}
$enabled = Get-EnabledPlugins
$vetting = Read-PluginVetting
$userPlugins = Get-UserPlugins
$idle = @($userPlugins.Keys | Where-Object { $enabled -notcontains $_ -and $_ -notlike '*@synced' })
if ($idle.Count) {
    Write-Warning "Installed for all projects but not enabled in settings.json: $($idle -join ', '). Enable them there or run: claude plugin uninstall <name>"
}
$installable = @(); $blocked = @(); $notInstalled = @()
foreach ($plugin in @($enabled | Where-Object { -not $userPlugins.Contains($_) })) {
    $source = Get-PluginSource $plugin
    $verdict = if (-not $source) { 'unknown' }
               elseif ($source.Folder) { Get-PluginVerdict $vetting[$plugin] (Get-PluginHash $source.Folder) }
               else { Get-PluginVerdict $vetting[$plugin] $null $source.Commit }
    if ($verdict -eq 'ok') { $installable += $plugin } else { $blocked += "$plugin ($($verdictText[$verdict]))" }
    $notInstalled += "$plugin ($($verdictText[$verdict]))"
}
if ($notInstalled.Count -and -not $InstallPlugins) {
    Write-Host "Enabled in settings.json but not installed: $($notInstalled -join ', ')." -ForegroundColor Cyan
    Write-Host '  Scan them with scripts\vet-plugins.ps1 and look at the result; .\install.ps1 -InstallPlugins then installs the scanned ones.' -ForegroundColor Cyan
    $installable = @()
} elseif ($blocked.Count) {
    Write-Warning "Not installed, no matching scan in vetting.json: $($blocked -join ', '). Run scripts\vet-plugins.ps1 first."
}
foreach ($plugin in $installable) {
    Write-Step "install the plugin $plugin, enabled in settings.json and scanned"
    if ($DryRun) { continue }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Write-Warning 'Claude Code is not installed yet; run install.ps1 again afterwards.'; break }
    $ErrorActionPreference = 'Continue'
    $output = claude plugin install $plugin --scope user 2>&1
    if ($LASTEXITCODE) { Write-Warning "Could not install ${plugin}: $output" }
    $ErrorActionPreference = 'Stop'
}
# Installed plugins, the ones just installed included: the marketplace may have moved on
# between the scan and the install
if ($installable.Count -and -not $DryRun) { $userPlugins = Get-UserPlugins }
$open = [ordered]@{ unvetted = @(); changed = @(); unapproved = @() }
foreach ($plugin in @($enabled | Where-Object { $userPlugins.Contains($_) })) {
    $folder = $userPlugins[$plugin].Folder
    if (-not (Test-Path -LiteralPath $folder)) { Write-Warning "The files of $plugin are missing ($folder); reinstall it."; continue }
    $verdict = Get-PluginVerdict $vetting[$plugin] (Get-PluginHash $folder)
    if ($verdict -ne 'ok') { $open[$verdict] += $plugin }
}
foreach ($verdict in @($open.Keys)) {
    if ($open[$verdict].Count) {
        Write-Warning "Enabled plugins, $($verdictText[$verdict]): $($open[$verdict] -join ', '). Run scripts\vet-plugins.ps1 (README, ""Vetting plugins"")."
    }
}

if (-not $changes) {
    Write-Host 'Everything is set up.' -ForegroundColor Green
} elseif (-not $DryRun) {
    Write-Host 'Done. Open a new PowerShell window to load the account functions.' -ForegroundColor Green
}
$noLogin = @($L.Accounts | Where-Object { -not (Test-Path "$(Get-ClaudeAccountDir $_)\.credentials.json") })
foreach ($account in $noLogin) {
    Write-Host "Not signed in yet: $account. Run claude-$account and then /login." -ForegroundColor Cyan
}
