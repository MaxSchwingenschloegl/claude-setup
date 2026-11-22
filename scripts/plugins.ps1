# Shared by install.ps1, scripts/vet-plugins.ps1 and scripts/check-setup.ps1: where a plugin's files are, a fingerprint of
# their content, and what the configuration's vetting.json says about them. Needs common.ps1.

# A skillspector score above this needs an approval recorded in vetting.json
$PluginScoreLimit = 50

# Reads a JSON file of Claude Code; a missing or unreadable file counts as empty, so a damaged
# cache cannot stop the run halfway
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json }
    catch { Write-Warning "Could not read ${Path}: $($_.Exception.Message)"; return $null }
}

# The plugins installed for all projects, as name -> folder; with -AnyScope also those a
# project installed for itself, the user record first and otherwise the first record whose
# folder still exists. Claude Code records the path through whichever account installed it;
# skillspector refuses a path below a link, so the folder is given through the hub.
function Get-UserPlugins([switch]$AnyScope) {
    $result = @{}
    $installed = (Read-JsonFile "$($ClaudeLayout.Hub)\plugins\installed_plugins.json").plugins
    if (-not $installed) { return $result }
    foreach ($property in $installed.PSObject.Properties) {
        $records = @($property.Value | Where-Object { $_.scope -eq 'user' })
        if ($AnyScope) { $records += @($property.Value | Where-Object { $_.scope -ne 'user' }) }
        $found = $null
        foreach ($record in $records) {
            $path = $record.installPath
            if (-not $path) { continue }
            $at = $path.IndexOf('\plugins\cache\', [StringComparison]::OrdinalIgnoreCase)
            if ($at -ge 0) { $path = $ClaudeLayout.Hub + $path.Substring($at) }
            $candidate = [pscustomobject]@{ Folder = $path; Version = $record.version; Commit = $record.gitCommitSha }
            if (-not $found) { $found = $candidate }
            if (-not $AnyScope -or (Test-Path -LiteralPath $path)) { $found = $candidate; break }
        }
        if ($found) { $result[$property.Name] = $found }
    }
    return $result
}

# The plugins the configuration's settings.json enables. Plugins synced from claude.ai are left
# out: they come with the account, not from a marketplace.
function Get-EnabledPlugins {
    $list = (Read-JsonFile "$($ClaudeLayout.Config)\settings.json").enabledPlugins
    @(if ($list) { $list.PSObject.Properties | Where-Object { $_.Value -and $_.Name -notlike '*@synced' } | ForEach-Object Name })
}

# A plugin's entry in the local copy of its marketplace, with the folder of that copy (through
# the hub, like the install paths). Empty when the marketplace or the entry is not known here.
$MarketplaceCache = @{}
function Get-MarketplaceEntry([string]$Name) {
    $plugin, $market = $Name -split '@', 2
    $known = Read-JsonFile "$($ClaudeLayout.Hub)\plugins\known_marketplaces.json"
    $location = if ($known -and $market) { $known.$market.installLocation }
    if (-not $location) { return $null }
    $at = $location.IndexOf('\plugins\marketplaces\', [StringComparison]::OrdinalIgnoreCase)
    if ($at -ge 0) { $location = $ClaudeLayout.Hub + $location.Substring($at) }
    if (-not $MarketplaceCache.Contains($location)) {
        $MarketplaceCache[$location] = (Read-CaseSensitiveJson "$location\.claude-plugin\marketplace.json")['plugins']
    }
    $entry = @($MarketplaceCache[$location] | Where-Object { $_['name'] -eq $plugin })[0]
    if (-not $entry) { return $null }
    return [pscustomobject]@{ Location = $location; Entry = $entry }
}

# Where a plugin that is not installed yet would be installed from: a folder in the local copy
# of its marketplace, or a pinned commit of a remote repository (Unpinned when it names none).
# Empty when its marketplace is not known here.
function Get-PluginSource([string]$Name) {
    $found = Get-MarketplaceEntry $Name
    if (-not $found) { return $null }
    $source = $found.Entry['source']
    if ($source -is [string]) {
        $folder = [IO.Path]::GetFullPath((Join-Path $found.Location $source))
        if (Test-Path -LiteralPath $folder) { return [pscustomobject]@{ Folder = $folder; Commit = $null; Unpinned = $false } }
        return $null
    }
    $sha = if ($source) { $source['sha'] }
    return [pscustomobject]@{ Folder = $null; Commit = $sha; Unpinned = -not $sha }
}

# Entry fields that load or run something. With "strict": false a plugin's hooks, servers and
# commands live there instead of in its folder, so they belong to its fingerprint.
$MarketplaceComponentFields = 'commands', 'agents', 'skills', 'hooks', 'mcpServers', 'lspServers', 'outputStyles'

# The PATH a program gets that no shell with your profile started (VS Code started from the
# Start menu, for one): the machine's and the user's PATH from the registry, in that order (.NET
# expands a REG_EXPAND_SZ value, a REG_SZ one stays as it is, as Windows keeps it). A Node
# version manager that adds its folder in the profile (fnm env) is missing there, and so are the
# programs installed under it. A program that was already running keeps the PATH it started with
# until it is quit.
# shortcut: .NET fills a REG_EXPAND_SZ entry from this window's variables, not the logon's, so a
# variable the profile sets or changes and a PATH entry uses (%NVM_SYMLINK%) is read with this
# window's value; Get-Command uses this window's PATHEXT, and also takes an extensionless file
# Windows cannot start. Upgrade by reading the raw values and filling them from the logon
# environment when a case shows up.
function Get-StartPath {
    $parts = foreach ($scope in 'Machine', 'User') { [Environment]::GetEnvironmentVariable('Path', $scope) -split ';' }
    @($parts | Where-Object { $_ }) -join ';'
}

# True when program $Name is found on $Path (folders separated by ;), as a process started with
# that PATH finds it (PATHEXT included); the name is taken literally, not as a wildcard
function Test-CommandOnPath([string]$Name, [string]$Path) {
    $saved = $env:Path
    try {
        $env:Path = $Path
        [bool](Get-Command -Name ([WildcardPattern]::Escape($Name)) -CommandType Application -ErrorAction SilentlyContinue)
    } finally { $env:Path = $saved }
}

# Where language-server program $Name is: 'start' when a program started without your profile
# finds it on $StartPath, 'window' when only this window finds it (its profile added the folder,
# as fnm env does), 'missing' when neither does
function Get-ServerReach([string]$Name, [string]$StartPath) {
    if (Test-CommandOnPath $Name $StartPath) { return 'start' }
    if (Get-Command -Name ([WildcardPattern]::Escape($Name)) -CommandType Application -ErrorAction SilentlyContinue) { return 'window' }
    return 'missing'
}

# The programs a plugin's language servers start: declared in its marketplace entry
# ("strict": false) or, when its folder is given, in its plugin.json or .lsp.json. lspServers
# may be an object of servers, a path to a file holding one, or an array of both.
# ${CLAUDE_PLUGIN_ROOT} is replaced by the folder. A declaration it cannot read is reported
# instead of read as "no servers": the plugin then does nothing, and Claude Code names the
# missing program only when the server is to start, at the first file of its kind.
function Get-LspCommands([string]$Name, [string]$Folder) {
    $servers = [Collections.ArrayList]::new()
    $collect = {
        param($Value, [string]$Origin)
        if ($null -eq $Value) { return }
        if ($Value -is [string]) {
            if (-not $Folder) { Write-Warning "${Name}: lspServers in $Origin points to $Value, but the plugin's folder is unknown here."; return }
            $path = Join-Path $Folder $Value
            if (-not (Test-Path -LiteralPath $path)) { Write-Warning "${Name}: lspServers in $Origin points to $Value, which does not exist."; return }
            & $collect (Read-CaseSensitiveJson $path) $Value
        } elseif ($Value -is [Collections.IDictionary]) {
            foreach ($server in $Value.Values) { [void]$servers.Add($server) }
        } elseif ($Value -is [Collections.IEnumerable]) {
            foreach ($item in $Value) { & $collect $item $Origin }
        } else { Write-Warning "${Name}: lspServers in $Origin has a shape this check does not know." }
    }
    $found = Get-MarketplaceEntry $Name
    if ($found) { & $collect $found.Entry['lspServers'] 'its marketplace entry' }
    if ($Folder) {
        & $collect (Read-CaseSensitiveJson "$Folder\.claude-plugin\plugin.json")['lspServers'] 'plugin.json'
        $file = Read-CaseSensitiveJson "$Folder\.lsp.json"
        if ($file.Count) { & $collect $file '.lsp.json' }
    }
    @(foreach ($server in $servers) {
        if ($server -is [Collections.IDictionary] -and $server['command']) {
            $command = [string]$server['command']
            if ($Folder) { $command = $command.Replace('${CLAUDE_PLUGIN_ROOT}', $Folder) }
            $command
        }
    }) | Sort-Object -Unique
}

# JSON with sorted keys, so the same entry always gives the same text
function ConvertTo-CanonicalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys); [Array]::Sort($keys, [StringComparer]::Ordinal)
        return '{' + (@(foreach ($key in $keys) { (ConvertTo-CanonicalJson $key) + ':' + (ConvertTo-CanonicalJson $Value[$key]) }) -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) { return '[' + (@(foreach ($item in $Value) { ConvertTo-CanonicalJson $item }) -join ',') + ']' }
    return ([IFormattable]$Value).ToString($null, [Globalization.CultureInfo]::InvariantCulture)
}

# A marketplace manifest may hold keys that differ only in case (".c" and ".C" for the C and
# C++ language servers), which ConvertFrom-Json refuses; read it as dictionaries instead
function Read-CaseSensitiveJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) { return $text | ConvertFrom-Json -AsHashtable }
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        return $serializer.DeserializeObject($text)
    } catch { Write-Warning "Could not read ${Path}: $($_.Exception.Message)"; return @{} }
}

# Fingerprint of a plugin folder: every file's path and content. Claude Code's lock files
# (.in_use/<process id>) and its mark .orphaned_at (the time in milliseconds, in the top folder,
# written when it no longer needs a version) are left out and CRLF counts as LF, so neither a
# running session nor a checkout with other line endings changes it, and a marketplace update that
# left the plugin alone keeps it. A lone carriage return still counts: some parsers read it as a
# line break. Python's byte-code cache counts like every other file: Python checks a time-stamp
# .pyc only against its source's time stamp and size, never its content, and runs a .pyc that
# stands where its source would be without any source, so a .pyc left out would be code nobody
# scanned (README, "Vetting plugins", on PYTHONDONTWRITEBYTECODE).
# The fields of the marketplace entry $Name that load or run something count too.
function Get-PluginHash([string]$Path, [string]$Name) {
    $root = (Get-ClaudeFullPath $Path) + '\'
    $latin1 = [Text.Encoding]::GetEncoding(28591)   # maps every byte to one character and back
    $sha = [Security.Cryptography.SHA256]::Create()
    $lines = [string[]]@(foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force) {
        $relative = $file.FullName.Substring($root.Length).Replace('\', '/')
        # [0-9], not \d, which in .NET also takes other scripts' digits; \z, not $, which also
        # matches before a final line break. A lock file holds a few bytes of JSON.
        if ($relative -cmatch '^\.in_use/[0-9]{1,10}\z' -and $file.Length -le 4096) { continue }
        if ($relative -ceq '.orphaned_at' -and $file.Length -le 20 -and
            [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($file.FullName)) -cmatch '^[0-9]{1,20}\z') { continue }
        $raw = [IO.File]::ReadAllBytes($file.FullName)
        $bytes = $latin1.GetBytes($latin1.GetString($raw).Replace("`r`n", "`n"))
        "$relative $([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', ''))"
    })
    $entry = if ($Name) { (Get-MarketplaceEntry $Name).Entry }
    $components = [ordered]@{}
    foreach ($field in $MarketplaceComponentFields) { if ($entry -and $entry.ContainsKey($field)) { $components[$field] = $entry[$field] } }
    if ($components.Count) {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-CanonicalJson $components))
        $lines = [string[]]($lines + ":marketplace-entry $([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', ''))")
    }
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines -join "`n"))
    return [BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
}

# vetting.json in the configuration, as name -> entry (empty when there is none)
function Read-PluginVetting {
    $result = [ordered]@{}
    $data = Read-JsonFile "$($ClaudeLayout.Config)\vetting.json"
    if ($data -and $data.plugins) {
        foreach ($property in $data.plugins.PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    return $result
}

# What vetting.json says about a plugin with the content $Hash or, for a remote one not
# installed yet, the commit $Commit:
#   ok          scanned with this content, score within the limit or approved
#   unvetted    no scan recorded
#   changed     the content differs from what was scanned
#   unapproved  score above the limit and no approval recorded
#   incomplete  the scan did not cover every file and no approval recorded
# An approval is a date (yyyy-MM-dd); anything else, "false" included, is none.
function Get-PluginVerdict($Entry, [string]$Hash, [string]$Commit) {
    if (-not $Entry) { return 'unvetted' }
    if ($Hash) { if ($Entry.hash -ne $Hash) { return 'changed' } }
    elseif (-not $Commit -or $Entry.commit -ne $Commit) { return 'changed' }
    if ($Entry.approved -is [datetime] -or "$($Entry.approved)" -match '^\d{4}-\d{2}-\d{2}$') { return 'ok' }
    if ([double]$Entry.score -gt $PluginScoreLimit) { return 'unapproved' }
    if ($null -eq $Entry.score -or ($Entry.analysis -and $Entry.analysis -ne 'complete')) { return 'incomplete' }
    return 'ok'
}

# Each verdict in words
$PluginVerdictText = @{
    ok = 'scanned'; unvetted = 'not scanned'; changed = 'changed since the scan'
    unapproved = "score above $PluginScoreLimit, not approved"; incomplete = 'scan incomplete, not approved'
    unknown = 'marketplace not on this machine'; unpinned = 'remote source without a pinned commit'
    unreadable = 'files could not be read'
}

# The verdict for a plugin folder, with $Vetting from Read-PluginVetting; a file that cannot be
# read counts as not vetted
function Get-FolderVerdict($Vetting, [string]$Plugin, [string]$Folder) {
    try { return Get-PluginVerdict $Vetting[$Plugin] (Get-PluginHash $Folder $Plugin) }
    catch { Write-Warning "Could not read the files of ${Plugin}: $($_.Exception.Message)"; return 'unreadable' }
}
