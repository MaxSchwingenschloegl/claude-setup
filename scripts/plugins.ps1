# Shared by install.ps1 and scripts/vet-plugins.ps1: where a plugin's files are, a fingerprint of
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

# The plugins installed for all projects, as name -> folder. Claude Code records the path
# through whichever account installed it; skillspector refuses a path below a link, so the
# folder is given through the hub.
function Get-UserPlugins {
    $result = @{}
    $installed = (Read-JsonFile "$($ClaudeLayout.Hub)\plugins\installed_plugins.json").plugins
    if (-not $installed) { return $result }
    foreach ($property in $installed.PSObject.Properties) {
        $record = @($property.Value | Where-Object scope -eq 'user')[0]
        if (-not $record) { continue }
        $path = $record.installPath
        $at = $path.IndexOf('\plugins\cache\', [StringComparison]::OrdinalIgnoreCase)
        if ($at -ge 0) { $path = $ClaudeLayout.Hub + $path.Substring($at) }
        $result[$property.Name] = [pscustomobject]@{
            Folder = $path; Version = $record.version; Commit = $record.gitCommitSha
        }
    }
    return $result
}

# The plugins the configuration's settings.json enables. Plugins synced from claude.ai are left
# out: they come with the account, not from a marketplace.
function Get-EnabledPlugins {
    $list = (Read-JsonFile "$($ClaudeLayout.Config)\settings.json").enabledPlugins
    @(if ($list) { $list.PSObject.Properties | Where-Object { $_.Value -and $_.Name -notlike '*@synced' } | ForEach-Object Name })
}

# Where a plugin that is not installed yet would be installed from: a folder in the local copy
# of its marketplace, or a commit of a remote repository. Empty when neither is known here.
function Get-PluginSource([string]$Name) {
    $plugin, $market = $Name -split '@', 2
    $known = Read-JsonFile "$($ClaudeLayout.Hub)\plugins\known_marketplaces.json"
    $location = if ($known -and $market) { $known.$market.installLocation }
    if (-not $location) { return $null }
    $entry = @((Read-CaseSensitiveJson "$location\.claude-plugin\marketplace.json")['plugins'] |
               Where-Object { $_['name'] -eq $plugin })[0]
    if (-not $entry) { return $null }
    $source = $entry['source']
    if ($source -is [string]) {
        $folder = [IO.Path]::GetFullPath((Join-Path $location $source))
        if (Test-Path -LiteralPath $folder) { return [pscustomobject]@{ Folder = $folder; Commit = $null } }
        return $null
    }
    if ($source -and $source['sha']) { return [pscustomobject]@{ Folder = $null; Commit = $source['sha'] } }
    return $null
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

# Fingerprint of a plugin folder: every file's path and content. Claude Code's lock folder
# .in_use and carriage returns are left out, so neither a running session nor a checkout with
# other line endings changes it, and a marketplace update that left the plugin alone keeps it.
function Get-PluginHash([string]$Path) {
    $root = (Get-ClaudeFullPath $Path) + '\'
    $latin1 = [Text.Encoding]::GetEncoding(28591)   # maps every byte to one character and back
    $sha = [Security.Cryptography.SHA256]::Create()
    $lines = [string[]]@(foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force) {
        $relative = $file.FullName.Substring($root.Length).Replace('\', '/')
        if ($relative -match '^(\.in_use|\.git)/') { continue }
        $bytes = $latin1.GetBytes($latin1.GetString([IO.File]::ReadAllBytes($file.FullName)).Replace("`r", ''))
        "$relative $([BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', ''))"
    })
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
function Get-PluginVerdict($Entry, [string]$Hash, [string]$Commit) {
    if (-not $Entry) { return 'unvetted' }
    if ($Hash) { if ($Entry.hash -ne $Hash) { return 'changed' } }
    elseif (-not $Commit -or $Entry.commit -ne $Commit) { return 'changed' }
    if ([int]$Entry.score -gt $PluginScoreLimit -and -not $Entry.approved) { return 'unapproved' }
    return 'ok'
}
