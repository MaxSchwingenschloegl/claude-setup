<#
.SYNOPSIS
    Checks this machine's Claude Code setup and lists what needs a look. Changes nothing.
.DESCRIPTION
    Run it now and then on each machine, and after a `git worktree remove` that failed:
    - Links: the hub's and every account's links point where install.ps1 puts them.
    - Repositories: this repo, the configuration and the marketplaces it names are on their
      default branch, neither behind nor ahead of origin, and hold no uncommitted changes
      (Claude Code writes settings.json itself on /config and plugin switches, so those changes
      land in the configuration unseen).
    - Plugins: every enabled plugin is installed and has a matching scan in vetting.json, and
      nothing is installed for all projects without being enabled. Also listed, for information:
      the plugins enabled, and those installed for single project folders, with folders that
      are gone and the home folder marked (README, "Things to know").
    - Worktrees: registered worktrees whose folder is gone (`git worktree prune` removes the
      entry), and folders a failed `git worktree remove` left behind ("Directory not empty",
      locked node_modules): a folder next to the repositories, or in the .claude\worktrees of a
      repository or worktree, that is no repository and no worktree git knows.
    Run it from the checkout install.ps1 linked: from a worktree it checks that worktree instead
    (and says so). It changes nothing but what `git fetch` writes.
    Exit code 1 when something needs a look, 0 when nothing does.
.PARAMETER ReposDir
    The folder that holds your repositories and the worktrees next to them. Default: the folder
    this repo is in.
.PARAMETER NoFetch
    Compare with what was fetched last instead of fetching from origin first.
#>
param(
    [string]$ReposDir,
    [switch]$NoFetch
)

$ErrorActionPreference = 'Stop'
if (-not $env:CLAUDE_SETUP_CONFIG) {
    $env:CLAUDE_SETUP_CONFIG = [Environment]::GetEnvironmentVariable('CLAUDE_SETUP_CONFIG', 'User')
}
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\plugins.ps1"
$L = $ClaudeLayout
if (-not $ReposDir) {
    $ReposDir = Split-Path -Parent $L.Root
} elseif (-not (Test-Path -LiteralPath $ReposDir -PathType Container)) {
    throw "-ReposDir: $ReposDir is no folder."
}
# Convert-Path reads a relative folder from the current location, as you typed it
$ReposDir = Get-ClaudeFullPath (Convert-Path -LiteralPath $ReposDir)

$findings = 0
function Report([string]$Text) {
    $script:findings++
    Write-Warning $Text
}
function Note([string]$Text) { Write-Host $Text -ForegroundColor Cyan }

# git's output; its errors are dropped and leave $LASTEXITCODE set, so a repository git cannot
# read is reported instead of stopping the check. git writes UTF-8, which Windows PowerShell
# would read in the console's code page (a path with an umlaut would then match nothing), and
# without optional locks `git status` leaves the index as it is.
function Invoke-Git([string]$Repo) {
    $ErrorActionPreference = 'Continue'
    $encoding = [Console]::OutputEncoding
    $locks = $env:GIT_OPTIONAL_LOCKS
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $env:GIT_OPTIONAL_LOCKS = '0'
        & git -C $Repo @args 2> $null
    } finally {
        [Console]::OutputEncoding = $encoding
        $env:GIT_OPTIONAL_LOCKS = $locks
    }
}

if (Test-Path -LiteralPath (Join-Path $L.Root '.git') -PathType Leaf) {
    Note "This runs from the worktree $($L.Root), so it checks that worktree and the links to it, not the checkout install.ps1 linked. Run it from that checkout."
}

# 1. Links
$broken = @($L.Accounts | ForEach-Object { Get-ClaudeBrokenLinks $_ } | Sort-Object -Unique)
if ($broken.Count) {
    Report "Not linked as expected: $($broken -join ', '). Run $($L.Root)\install.ps1; it keeps a backup of every file it replaces."
}

# 2. The repositories of the setup
foreach ($repo in @(@($L.Root, $L.Config) + $L.Marketplaces | Select-Object -Unique)) {
    $name = Split-Path -Leaf $repo
    $before = $findings
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) {
        Report "The marketplace $repo, named in accounts.json, is missing."
        continue
    }
    if (-not (Test-Path -LiteralPath "$repo\.git")) { Note "$repo is no git repository; not checked."; continue }
    if (-not $NoFetch) {
        Invoke-Git $repo fetch --quiet origin | Out-Null
        if ($LASTEXITCODE) { Report "${name}: git fetch origin failed; compared with what was fetched last." }
    }
    # The default branch from origin/HEAD, which a clone sets; without it, main or master
    $default = Invoke-Git $repo symbolic-ref --quiet --short refs/remotes/origin/HEAD
    if ($default) {
        $default = $default -replace '^origin/'
    } else {
        $default = @('main', 'master') | Where-Object {
            Invoke-Git $repo rev-parse --verify --quiet "refs/remotes/origin/$_" | Out-Null
            -not $LASTEXITCODE
        } | Select-Object -First 1
        if (-not $default) {
            Report "${name}: no default branch known for origin (no origin/HEAD, origin/main or origin/master); git -C $repo remote set-head origin -a sets it."
            continue
        }
    }
    $branch = Invoke-Git $repo symbolic-ref --quiet --short HEAD
    if ($branch -ne $default) {
        Report "${name}: on $(if ($branch) { "the branch $branch" } else { 'a detached HEAD' }), not on $default."
    }
    $counts = Invoke-Git $repo rev-list --left-right --count "HEAD...origin/$default"
    if ($LASTEXITCODE -or -not $counts) {
        Report "${name}: cannot compare with origin/$default."
    } else {
        $ahead, $behind = [int[]]($counts -split '\s+')
        if ($behind) { Report "${name}: $behind commit(s) behind origin/$default; git -C $repo pull --ff-only." }
        if ($ahead) { Report "${name}: $ahead commit(s) not on origin/$default." }
    }
    $dirty = @(Invoke-Git $repo status --porcelain)
    if ($dirty.Count) {
        $shown = ($dirty | Select-Object -First 10 | ForEach-Object { $_.Trim() }) -join '; '
        Report "${name}: $($dirty.Count) uncommitted change(s): $shown$(if ($dirty.Count -gt 10) { '; ...' })"
    }
    if ($findings -eq $before) { Note "${name}: on $default, level with origin/$default, nothing uncommitted." }
}

# 3. Plugins
$vetting = Read-PluginVetting
$enabled = @(Get-EnabledPlugins | Sort-Object)
$userPlugins = Get-UserPlugins
$states = foreach ($plugin in $enabled) {
    if (-not $userPlugins.Contains($plugin)) {
        Report "Enabled in settings.json but not installed on this machine: $plugin. install.ps1 lists it and, once scanned, -InstallPlugins installs it."
        "$plugin (not installed)"
        continue
    }
    $folder = $userPlugins[$plugin].Folder
    if (-not (Test-Path -LiteralPath $folder)) {
        Report "The files of $plugin are missing ($folder); reinstall it."
        "$plugin (files missing)"
        continue
    }
    $verdict = Get-FolderVerdict $vetting $plugin $folder
    if ($verdict -ne 'ok') {
        Report "Enabled plugin $plugin, $($PluginVerdictText[$verdict]): scan it with scripts\vet-plugins.ps1 before the next session (README, `"Vetting plugins`")."
    }
    "$plugin ($($PluginVerdictText[$verdict]))"
}
Note "Enabled plugins: $(if ($states) { $states -join ', ' } else { 'none' })"
$idle = @($userPlugins.Keys | Where-Object { $enabled -notcontains $_ -and $_ -notlike '*@synced' } | Sort-Object)
if ($idle.Count) {
    Report "Installed for all projects but not enabled in settings.json: $($idle -join ', '). Enable them there or run: claude plugin uninstall <name>"
}
$records = (Read-JsonFile "$($L.Hub)\plugins\installed_plugins.json").plugins
$byProject = [ordered]@{}
if ($records) {
    foreach ($property in $records.PSObject.Properties) {
        foreach ($record in @($property.Value | Where-Object { $_.scope -ne 'user' -and $_.projectPath })) {
            $key = "$($record.projectPath) ($($record.scope))"
            if (-not $byProject.Contains($key)) { $byProject[$key] = @() }
            $byProject[$key] += $property.Name -replace '@.*'
        }
    }
}
foreach ($key in $byProject.Keys | Sort-Object) {
    $path = $key -replace ' \((project|local)\)$'
    $mark = if ((Get-ClaudeFullPath $path) -eq (Get-ClaudeFullPath $env:USERPROFILE)) { ' [home folder: a session started there; README, "Things to know"]' }
            elseif (-not (Test-Path -LiteralPath $path)) { ' [folder gone]' }
    Note "Installed for $key$mark`: $(($byProject[$key] | Sort-Object) -join ', ')"
}

# 4. Worktrees
$before = $findings
$repoDirs = @(Get-ChildItem -LiteralPath $ReposDir -Directory -Force |
              Where-Object { -not $_.LinkType -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container) })
$registered = @{}
$present = @()
foreach ($repo in $repoDirs) {
    $path = $null
    foreach ($line in @(Invoke-Git $repo.FullName worktree list --porcelain)) {
        if ($line -like 'worktree *') {
            $path = Get-ClaudeFullPath $line.Substring(9)
            $registered[$path.ToLowerInvariant()] = $true
            if (Test-Path -LiteralPath $path -PathType Container) { $present += $path }
        } elseif ($line -like 'prunable*') {
            Report "$($repo.Name): the registered worktree $path is gone; git -C $($repo.FullName) worktree prune removes the entry."
        }
    }
}
# Next to the repositories, and in the .claude\worktrees of each repository and worktree (a
# session in a worktree puts its own worktrees there)
$candidates = @(Get-ChildItem -LiteralPath $ReposDir -Directory -Force | Where-Object { $_.Name -notlike '.*' })
foreach ($path in $present) {
    $candidates += @(Get-ChildItem -LiteralPath (Join-Path $path '.claude\worktrees') -Directory -Force -ErrorAction SilentlyContinue)
}
foreach ($folder in $candidates) {
    if ($folder.LinkType -or $registered.Contains($folder.FullName.ToLowerInvariant())) { continue }
    $dotGit = Join-Path $folder.FullName '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) { continue }
    if (Test-Path -LiteralPath $dotGit -PathType Leaf) {
        # A worktree of a repository elsewhere still points to its entry there
        $line = Get-Content -LiteralPath $dotGit -TotalCount 1 -Encoding UTF8
        if ($line -match '^gitdir:\s*(.+)$' -and (Test-Path -LiteralPath $matches[1].Trim())) { continue }
    }
    Report "$($folder.FullName) is no repository and no worktree git knows: probably what a failed git worktree remove left behind. Make sure it holds nothing you need, then delete it."
}
$worktrees = $registered.Count - $repoDirs.Count
if ($findings -eq $before) {
    Note "Worktrees: $($repoDirs.Count) repositories in $ReposDir with $worktrees further worktree(s), all present, $($candidates.Count) folder(s) looked at, nothing left behind."
}

if ($findings) {
    Write-Host "$findings thing(s) need a look." -ForegroundColor Yellow
    exit 1
}
Write-Host 'Everything checked is in order.' -ForegroundColor Green
exit 0
