<#
.SYNOPSIS
    Scans the plugins your configuration enables with skillspector and records the results in
    the configuration's vetting.json.
.DESCRIPTION
    Covers every plugin settings.json enables and every plugin installed for all projects. An
    installed plugin is scanned where it is installed; one that is not installed yet is scanned
    in the local copy of its marketplace, before it ever runs. A plugin whose files have not
    changed since its recorded scan is not scanned again, even when its version label has
    (plugins without a version of their own take the marketplace's commit as one).

    A score above 50 needs an exception: read every finding in the report, and if each one is
    harmless, add "approved" (the date) and "reasons" to the plugin's entry in vetting.json.
    install.ps1 warns about plugins without a matching scan, and -InstallPlugins installs only
    plugins whose scan matches what the marketplace would install.

    Every LLM call of skillspector's semantic analysis goes through the local claude CLI
    (SKILLSPECTOR_PROVIDER=claude_cli, unless you set another provider) and counts against
    your plan.
.PARAMETER Plugin
    Only these plugins, as name@marketplace or just the name.
.PARAMETER Force
    Scan again even when the files have not changed since the recorded scan.
.PARAMETER ConfigDir
    Your configuration folder; by default the one install.ps1 remembered.
#>
param(
    [string[]]$Plugin,
    [switch]$Force,
    [string]$ConfigDir
)

$ErrorActionPreference = 'Stop'
if ($ConfigDir) { $env:CLAUDE_SETUP_CONFIG = [IO.Path]::GetFullPath($ConfigDir) }
elseif (-not $env:CLAUDE_SETUP_CONFIG) { $env:CLAUDE_SETUP_CONFIG = [Environment]::GetEnvironmentVariable('CLAUDE_SETUP_CONFIG', 'User') }
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\plugins.ps1"
$L = $ClaudeLayout

if (-not (Get-Command skillspector -ErrorAction SilentlyContinue)) {
    throw 'skillspector is not installed: winget install astral-sh.uv, then uv tool install git+https://github.com/NVIDIA/skillspector.git'
}
if (-not $env:SKILLSPECTOR_PROVIDER) { $env:SKILLSPECTOR_PROVIDER = 'claude_cli' }

$fields = 'version', 'commit', 'hash', 'scanned', 'skillspector', 'provider', 'score', 'recommendation',
          'issues', 'analysis', 'semantic', 'approved', 'reasons'

# Writes vetting.json by hand: ConvertTo-Json in Windows PowerShell indents unevenly and escapes
# quotes and angle brackets, which makes the reasons hard to read and to review in a diff. Lists
# and objects you add to an entry yourself are kept, written on one line.
function ConvertTo-JsonText($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    # Windows PowerShell reads 13.5 as decimal, PowerShell 7 as double
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return ([IFormattable]$Value).ToString($null, [Globalization.CultureInfo]::InvariantCulture)
    }
    # PowerShell 7 reads "2026-10-20" as a date
    if ($Value -is [datetime]) { $Value = $Value.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        return '{ ' + (@(foreach ($p in $Value.PSObject.Properties) { "$(ConvertTo-JsonText $p.Name): $(ConvertTo-JsonText $p.Value)" }) -join ', ') + ' }'
    }
    if ($Value -isnot [string] -and $Value -is [Collections.IEnumerable]) {
        return '[' + (@(foreach ($item in $Value) { ConvertTo-JsonText $item }) -join ', ') + ']'
    }
    $text = ([string]$Value).Replace('\', '\\').Replace('"', '\"')
    $text = [regex]::Replace($text, '[\x00-\x1f]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
    return '"' + $text + '"'
}

function Save-Vetting($Entries) {
    $blocks = foreach ($name in @($Entries.Keys | Sort-Object)) {
        $entry = $Entries[$name]
        $names = @($fields | Where-Object { $null -ne $entry.$_ }) +
                 @($entry.PSObject.Properties.Name | Where-Object { $fields -notcontains $_ })
        $lines = foreach ($field in $names) { "      $(ConvertTo-JsonText $field): $(ConvertTo-JsonText $entry.$field)" }
        "    $(ConvertTo-JsonText $name): {`n$($lines -join ",`n")`n    }"
    }
    $json = "{`n  `"plugins`": {`n$($blocks -join ",`n")`n  }`n}`n"
    [IO.File]::WriteAllText("$($L.Config)\vetting.json", $json, (New-Object Text.UTF8Encoding $false))
}

# Turns a skillspector JSON report into the fields of a vetting.json entry
function Read-Report([string]$Path) {
    $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    $counts = foreach ($severity in 'CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'INFO') {
        $n = @($report.issues | Where-Object severity -eq $severity).Count
        if ($n) { "$n $($severity.ToLowerInvariant())" }
    }
    $semantic = @($report.analysis_completeness.analyzer_statuses | Where-Object { $_.analyzer_id -like 'semantic_*' })
    $done = @($semantic | Where-Object status -eq 'completed').Count
    $applicable = @($semantic | Where-Object status -ne 'not_applicable').Count
    $semanticText = if (-not $applicable) { 'not applicable' }
                    elseif ($done -eq $applicable) { 'completed' }
                    else { "$done of $applicable completed" }
    $completeness = $report.analysis_completeness
    [pscustomobject]@{
        skillspector   = $report.metadata.skillspector_version
        score          = [double]$report.risk_assessment.score
        recommendation = $report.risk_assessment.recommendation
        issues         = if ($counts) { $counts -join ', ' } else { 'none' }
        analysis       = if ($completeness.status -eq 'complete') { 'complete' }
                         else { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}, {1:0.#} % covered',
                                                 $completeness.status, [double]$completeness.coverage_percent) }
        semantic       = $semanticText
        complete       = $completeness.status -eq 'complete'
    }
}

$vetting = Read-PluginVetting
$userPlugins = Get-UserPlugins
$names = @(@(Get-EnabledPlugins) + @($userPlugins.Keys) | Sort-Object -Unique)
if ($Plugin) {
    $Plugin = @($Plugin -split ',' | ForEach-Object Trim | Where-Object { $_ })   # -File passes a,b as one string
    $names = @($names | Where-Object { $Plugin -contains $_ -or $Plugin -contains ($_ -split '@')[0] })
    $unknown = @($Plugin | Where-Object { $p = $_; -not ($names | Where-Object { $_ -eq $p -or ($_ -split '@')[0] -eq $p }) })
    if ($unknown.Count) { Write-Warning "Neither enabled nor installed for all projects: $($unknown -join ', ')" }
}
$reports = Join-Path $env:TEMP 'claude-setup-vetting'
New-Item -ItemType Directory -Force $reports | Out-Null
$today = Get-Date -Format 'yyyy-MM-dd'
$changed = $false
$rows = @()

foreach ($name in $names) {
    $old = $vetting[$name]
    $install = $userPlugins[$name]
    if ($install -and (Test-Path -LiteralPath $install.Folder)) {
        $folder = $install.Folder; $version = $install.Version; $commit = $install.Commit
    } else {
        $source = Get-PluginSource $name
        if (-not $source -or -not $source.Folder) {
            # Starting a session to fetch a marketplace would load the very plugins not scanned yet
            $why = if ($source) { 'it comes from a remote repository. Install it with claude plugin install, then run this again before you start a session' }
                   else { 'its marketplace is not on this machine. Add it with claude plugin marketplace add <owner/repo> (settings.json, extraKnownMarketplaces, names it), then run this again' }
            Write-Warning "${name}: not installed and not scanned; $why."
            continue
        }
        $folder = $source.Folder; $version = 'not installed'; $commit = $null
    }
    try { $hash = Get-PluginHash $folder $name }
    catch { Write-Warning "Could not read the files of ${name}: $($_.Exception.Message)"; continue }

    if ($old -and $old.hash -eq $hash -and -not $Force) {
        # Same files as scanned: only the version label may have moved on
        if ($install -and ($old.version -ne $version -or $old.commit -ne $commit)) {
            $old | Add-Member -NotePropertyName version -NotePropertyValue $version -Force
            $old | Add-Member -NotePropertyName commit -NotePropertyValue $commit -Force
            $changed = $true
        }
        $rows += [pscustomobject]@{ Plugin = $name; Version = $version; Score = $old.score; Verdict = Get-PluginVerdict $old $hash; Note = "unchanged since $($old.scanned)" }
        continue
    }

    Write-Host "Scanning $name ($version) ..."
    $file = Join-Path $reports "$(($name -split '@')[0])-$($version -replace '[^\w.-]', '_').json"
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    $ErrorActionPreference = 'Continue'   # skillspector logs warnings on stderr
    $output = skillspector scan $folder --format json --output $file 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    # Exit code 2 with a report means an incomplete run, which is recorded as such
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Warning "skillspector could not scan ${name} (exit code $exitCode): $(@($output | Where-Object { $_ -notmatch 'WARNING \[skillspector' }) -join ' ')"
        continue
    }
    try { $result = Read-Report $file }
    catch { Write-Warning "Could not read the report of ${name} (${file}): $($_.Exception.Message)"; continue }
    if (-not $result.complete) {
        Write-Warning ("${name}: the scan is incomplete ($($result.analysis)). A large plugin can run out of skillspector's " +
                       'time limit, SKILLSPECTOR_MAX_WORKFLOW_SECONDS (600 by default); raise it and scan again with -Force.')
    }

    $entry = [pscustomobject]@{
        version = $version; commit = $commit; hash = $hash; scanned = $today
        skillspector = $result.skillspector; provider = $env:SKILLSPECTOR_PROVIDER
        score = $result.score; recommendation = $result.recommendation; issues = $result.issues
        analysis = $result.analysis; semantic = $result.semantic
    }
    # Own notes survive a new scan; an approval only holds for the files it was given for
    if ($old) {
        foreach ($property in $old.PSObject.Properties | Where-Object { $fields -notcontains $_.Name }) {
            $entry | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
        if ($old.approved -and $old.hash -eq $hash) {
            $entry | Add-Member -NotePropertyName approved -NotePropertyValue $old.approved
            $entry | Add-Member -NotePropertyName reasons -NotePropertyValue $old.reasons
        } elseif ($old.approved) {
            Write-Warning "${name}: the approval of $($old.approved) was given for other files; read the new findings and approve again if they hold."
        }
    }
    $vetting[$name] = $entry
    Save-Vetting $vetting   # at once: a later failure or Ctrl-C must not cost the scans made so far
    $changed = $true
    $rows += [pscustomobject]@{ Plugin = $name; Version = $version; Score = $entry.score; Verdict = Get-PluginVerdict $entry $hash; Note = "$($entry.issues); report $file" }
}

if ($changed) {
    Save-Vetting $vetting
    Write-Host "Updated $($L.Config)\vetting.json; review it with git diff and commit it." -ForegroundColor Green
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$open = @($rows | Where-Object { $_.Verdict -in 'unapproved', 'incomplete' })
if ($open.Count) {
    Write-Host "Score above $PluginScoreLimit or scan incomplete, without an approval: $($open.Plugin -join ', ')." -ForegroundColor Yellow
    Write-Host '  Read every finding in the report. If each is harmless, add "approved" (the date) and "reasons" to the' -ForegroundColor Yellow
    Write-Host '  entry in vetting.json; otherwise disable the plugin in settings.json and uninstall it.' -ForegroundColor Yellow
}
