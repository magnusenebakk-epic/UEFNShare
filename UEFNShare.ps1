# UEFNShare - share, install, duplicate and package UEFN projects.
# Single-file, zero-dependency, Windows PowerShell 5.1 compatible.
# Run:  irm <raw-url>/UEFNShare.ps1 | iex     or     UEFNShare.cmd

#region Constants

$script:ToolVersion       = '1.0.0'
$script:DefaultCatalogUrl = 'https://raw.githubusercontent.com/magnusenebakk-epic/UEFNShare/main/index.json'
$script:SettingsPath      = Join-Path $env:APPDATA 'UEFNShare\settings.json'
$script:UefnIniPath       = Join-Path $env:LOCALAPPDATA 'UnrealEditorFortnite\Saved\Config\WindowsEditor\EditorPerProjectUserSettings.ini'
$script:VkProjectsIniDir  = Join-Path $env:LOCALAPPDATA 'UnrealEditorFortnite\Saved\Config\WindowsEditor\VK_Projects'
$script:LauncherDat       = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
$script:VerseSentinelRoot = '/invaliddomain'
$script:StagingDirs       = New-Object System.Collections.ArrayList

# TLS 1.2 for PS 5.1 talking to GitHub
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch { }

#endregion

#region UI helpers

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Ok   { param([string]$Text) Write-Host "[OK] $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "[!]  $Text" -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host "[X]  $Text" -ForegroundColor Red }
function Write-Info { param([string]$Text) Write-Host "     $Text" -ForegroundColor Gray }

function Read-Prompt {
    # Core prompt primitive: Enter accepts the default. Strips surrounding quotes (Explorer copy-as-path).
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Default = '',
        [switch]$AllowEmpty
    )
    while ($true) {
        if ($Default -ne '') {
            Write-Host "$Message [$Default]: " -ForegroundColor White -NoNewline
        } else {
            Write-Host "${Message}: " -ForegroundColor White -NoNewline
        }
        $resp = Read-Host
        if ($null -eq $resp) { $resp = '' }
        $resp = $resp.Trim().Trim('"')
        if ($resp -eq '') {
            if ($Default -ne '') { return $Default }
            if ($AllowEmpty)     { return '' }
            Write-Warn 'A value is required.'
            continue
        }
        return $resp
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)][string]$Message,
        [bool]$Default = $true
    )
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        Write-Host "$Message $hint " -ForegroundColor White -NoNewline
        $resp = Read-Host
        if ($null -eq $resp -or $resp.Trim() -eq '') { return $Default }
        switch -Regex ($resp.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Warn 'Please answer y or n.' }
        }
    }
}

function Read-MenuChoice {
    # Numbered menu. Returns 0-based index, or -1 when Back/Quit is chosen.
    param(
        [string]$Title = '',
        [Parameter(Mandatory)][string[]]$Options,
        [string]$BackLabel = 'Back',
        [string]$DefaultChoice = ''
    )
    if ($Title -ne '') { Write-Head $Title }
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Options[$i])
    }
    Write-Host ("  [B] {0}" -f $BackLabel)
    while ($true) {
        if ($DefaultChoice -ne '') {
            Write-Host "Choice [$DefaultChoice]: " -ForegroundColor White -NoNewline
        } else {
            Write-Host 'Choice: ' -ForegroundColor White -NoNewline
        }
        $resp = Read-Host
        if (($null -eq $resp -or $resp.Trim() -eq '') -and $DefaultChoice -ne '') { $resp = $DefaultChoice }
        $resp = $resp.Trim()
        if ($resp -match '^(b|q)$') { return -1 }
        $n = 0
        if ([int]::TryParse($resp, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return ($n - 1) }
        Write-Warn ("Enter a number between 1 and {0}, or B to go back." -f $Options.Count)
    }
}

#endregion

#region Settings

function Get-UefnShareSettings {
    $defaults = [pscustomobject]@{
        settingsVersion      = 1
        catalogUrl           = $script:DefaultCatalogUrl
        projectsPathOverride = ''
    }
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $defaults }
    try {
        $loaded = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
        foreach ($p in @('catalogUrl', 'projectsPathOverride')) {
            $prop = $loaded.PSObject.Properties[$p]
            if ($null -ne $prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
                $defaults.$p = "$($prop.Value)"
            }
        }
    } catch {
        Write-Warn "Settings file was unreadable and has been ignored ($script:SettingsPath)."
    }
    return $defaults
}

function Save-UefnShareSettings {
    param([Parameter(Mandatory)]$Settings)
    $dir = Split-Path -Parent $script:SettingsPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Settings | ConvertTo-Json -Depth 5
    Write-TextFileNoBom -Path $script:SettingsPath -Text $json
}

#endregion

#region File IO helpers

function Read-TextFileRaw {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Write-TextFileNoBom {
    # PS 5.1's Set-Content -Encoding UTF8 writes a BOM; UEFN files are BOM-less UTF-8.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-FolderSizeMB {
    param([Parameter(Mandatory)][string]$Path, [string[]]$ExcludeTopLevel = @())
    $total = 0
    Get-ChildItem -LiteralPath $Path -Force | Where-Object { $ExcludeTopLevel -notcontains $_.Name } | ForEach-Object {
        if ($_.PSIsContainer) {
            $sum = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if ($sum) { $total += $sum }
        } else {
            $total += $_.Length
        }
    }
    return [math]::Round($total / 1MB, 1)
}

#endregion

#region Environment detection

function Get-IniSectionValue {
    # Dependency-free ini read: first value of Key inside [Section].
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $inSection = $false
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -eq $Section)
            continue
        }
        if ($inSection -and $trimmed.StartsWith("$Key=")) {
            return $trimmed.Substring($Key.Length + 1)
        }
    }
    return $null
}

function ConvertFrom-IniArray {
    # Parses ini array syntax: ()  or  ("a","b")  or  (a,b)
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $inner = $Value.Trim().TrimStart('(').TrimEnd(')')
    if ($inner.Trim() -eq '') { return @() }
    return @($inner.Split(',') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })
}

function Get-ProjectsRoot {
    # Precedence: settings override -> UEFN ini -> Documents\Fortnite Projects.
    $settings = Get-UefnShareSettings
    if ($settings.projectsPathOverride -ne '') { return $settings.projectsPathOverride }
    $iniVal = Get-IniSectionValue -Path $script:UefnIniPath `
        -Section '/Script/ValkyrieEditor.ValkyrieEditorConfig' -Key 'LastCreatedProjectLocation'
    if ($iniVal) { return ($iniVal -replace '/', '\') }
    return Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Fortnite Projects'
}

function Get-AllProjectRoots {
    # Primary root plus any AdditionalProjectPaths UEFN is configured to scan.
    $roots = @(Get-ProjectsRoot)
    $extra = Get-IniSectionValue -Path $script:UefnIniPath `
        -Section '/Script/ValkyrieEditor.ValkyrieEditorConfig' -Key 'AdditionalProjectPaths'
    foreach ($p in (ConvertFrom-IniArray $extra)) {
        $norm = $p -replace '/', '\'
        if ($roots -notcontains $norm) { $roots += $norm }
    }
    return @($roots | Where-Object { Test-Path -LiteralPath $_ })
}

function Test-UefnRunning {
    return [bool](Get-Process -Name 'UnrealEditorFortnite*' -ErrorAction SilentlyContinue)
}

function Get-InstalledUefnVersion {
    # Reads e.g. "++Fortnite+Release-41.30-CL-56430492" from the Epic launcher manifest.
    if (-not (Test-Path -LiteralPath $script:LauncherDat)) { return $null }
    try {
        $raw = Read-TextFileRaw $script:LauncherDat
        if ($raw -match '\+\+Fortnite\+Release-([\d.]+)-CL-(\d+)') {
            return [pscustomobject]@{ Version = $Matches[1]; CL = $Matches[2] }
        }
    } catch { }
    return $null
}

function Test-VersionCompatible {
    # $true = ok, $false = installed UEFN is older than required, $null = could not compare.
    param([string]$Required, [string]$Installed)
    if (-not $Required -or -not $Installed) { return $null }
    try {
        return ([version]$Installed -ge [version]$Required)
    } catch {
        if ($Required -eq $Installed) { return $true }
        return $null
    }
}

#endregion

#region Project model

function Get-ProjectInfo {
    param([Parameter(Mandatory)][string]$FolderPath)
    if (-not (Test-Path -LiteralPath $FolderPath)) { throw "Folder not found: $FolderPath" }

    $projFiles = @(Get-ChildItem -LiteralPath $FolderPath -Filter '*.uefnproject' -File -ErrorAction SilentlyContinue)
    if ($projFiles.Count -eq 0) { throw "Not a UEFN project: no .uefnproject file found in '$FolderPath'." }
    if ($projFiles.Count -gt 1) { throw "Multiple .uefnproject files found in '$FolderPath': $($projFiles.Name -join ', ')" }

    $plugFiles = @(Get-ChildItem -LiteralPath $FolderPath -Filter '*.uplugin' -File -ErrorAction SilentlyContinue)
    if ($plugFiles.Count -eq 0) { throw "Not a UEFN project: no .uplugin file found in '$FolderPath'." }
    if ($plugFiles.Count -gt 1) { throw "Multiple .uplugin files found in '$FolderPath': $($plugFiles.Name -join ', ')" }

    $json = Get-Content -LiteralPath $projFiles[0].FullName -Raw | ConvertFrom-Json

    $modules = @{}
    if ($json.bindings -and $json.bindings.modules) {
        foreach ($p in $json.bindings.modules.PSObject.Properties) { $modules[$p.Name] = $p.Value }
    }

    $pluginName = [System.IO.Path]::GetFileNameWithoutExtension($plugFiles[0].Name)

    # The uplugin filename is authoritative; warn if the .uefnproject disagrees.
    $declaredPlugin = $null
    if ($json.plugins -and @($json.plugins).Count -gt 0) { $declaredPlugin = @($json.plugins)[0].name }
    if ($declaredPlugin -and $declaredPlugin -ne $pluginName) {
        Write-Warn "Plugin name mismatch: uplugin file is '$pluginName' but .uefnproject declares '$declaredPlugin'. Using '$pluginName'."
    }
    if ($modules.Count -gt 0 -and -not $modules.ContainsKey($pluginName) -and $declaredPlugin -and -not $modules.ContainsKey($declaredPlugin)) {
        Write-Warn "No module entry matches the plugin name '$pluginName' in .uefnproject bindings."
    }

    $versePath = ''
    if ($json.bindings -and $null -ne $json.bindings.projectVersePath) { $versePath = "$($json.bindings.projectVersePath)" }
    $projectId = ''
    if ($json.bindings -and $null -ne $json.bindings.projectId) { $projectId = "$($json.bindings.projectId)" }

    return [pscustomobject]@{
        Name                              = [System.IO.Path]::GetFileNameWithoutExtension($projFiles[0].Name)
        FolderPath                        = $FolderPath
        UefnProjectFile                   = $projFiles[0].FullName
        UpluginFile                       = $plugFiles[0].FullName
        PluginName                        = $pluginName
        Title                             = "$($json.title)"
        Description                       = "$($json.description)"
        ProjectId                         = $projectId
        Modules                           = $modules
        ProjectVersePath                  = $versePath
        CompatibilityVersion              = "$($json.compatibilityVersion)"
        RequiredRedirectorStartingVersion = "$($json.requiredRedirectorStartingVersion)"
        IsBound                           = ($versePath -ne '')
    }
}

function Get-LocalProjects {
    # One-level scan of all UEFN scan roots for project folders.
    $results = @()
    foreach ($root in (Get-AllProjectRoots)) {
        foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $pf = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.uefnproject' -File -ErrorAction SilentlyContinue)
            if ($pf.Count -ne 1) { continue }
            try { $info = Get-ProjectInfo -FolderPath $dir.FullName } catch { continue }
            $results += [pscustomobject]@{
                Info    = $info
                Root    = $root
                ShareMB = Get-FolderSizeMB -Path $dir.FullName -ExcludeTopLevel @('.lore', '.git')
            }
        }
    }
    return $results
}

#endregion

#region JSON surgery (targeted, format-preserving)

function ConvertTo-JsonStringLiteral {
    # Escapes a value for injection between JSON quotes.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '\' { [void]$sb.Append('\\') }
            '"' { [void]$sb.Append('\"') }
            default {
                if ([int]$ch -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    return $sb.ToString()
}

function Set-JsonScalar {
    # Replaces the string value of a uniquely-keyed scalar without reformatting the file.
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewValue
    )
    $pattern = '("' + [regex]::Escape($Key) + '"\s*:\s*")((?:[^"\\]|\\.)*)(")'
    $rx = New-Object regex($pattern)
    $count = $rx.Matches($Text).Count
    if ($count -ne 1) {
        throw "Expected exactly 1 occurrence of JSON key '$Key' but found $count. The file format may have changed; aborting to avoid corruption."
    }
    $lit = ConvertTo-JsonStringLiteral $NewValue
    $evaluator = { param($m) $m.Groups[1].Value + $lit + $m.Groups[3].Value }.GetNewClosure()
    return $rx.Replace($Text, $evaluator)
}

function Set-JsonGuidValue {
    # Replaces a GUID-shaped value under the given key. The GUID-shape constraint guarantees we
    # hit the bindings entry and never a same-named key holding a non-GUID value.
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$NewGuid
    )
    $guidShape = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $pattern = '("' + [regex]::Escape($Key) + '"\s*:\s*")(' + $guidShape + ')(")'
    $rx = New-Object regex($pattern)
    $count = $rx.Matches($Text).Count
    if ($count -ne 1) {
        throw "Expected exactly 1 GUID value under key '$Key' but found $count. Aborting to avoid corruption."
    }
    $evaluator = { param($m) $m.Groups[1].Value + $NewGuid + $m.Groups[3].Value }.GetNewClosure()
    return $rx.Replace($Text, $evaluator)
}

function New-ProjectGuid {
    # Fresh GUID; avoids the (cosmically unlikely) collision with an existing local UEFN sidecar.
    do {
        $g = [guid]::NewGuid().ToString()
    } while ((Test-Path -LiteralPath $script:VkProjectsIniDir) -and
             (Test-Path -LiteralPath (Join-Path $script:VkProjectsIniDir "$g.ini")))
    return $g
}

function Update-UefnProjectFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$NewTitle,
        [string[]]$ModuleNames = @(),
        $NewDescription = $null  # untyped: [string] would coerce $null to '' and blank descriptions
    )
    $text = Read-TextFileRaw $Path
    $text = Set-JsonGuidValue -Text $text -Key 'projectId' -NewGuid (New-ProjectGuid)
    foreach ($m in $ModuleNames) {
        $text = Set-JsonGuidValue -Text $text -Key $m -NewGuid ([guid]::NewGuid().ToString())
    }
    $text = Set-JsonScalar -Text $text -Key 'projectVersePath' -NewValue ''
    $text = Set-JsonScalar -Text $text -Key 'title' -NewValue $NewTitle
    if ($null -ne $NewDescription) {
        $text = Set-JsonScalar -Text $text -Key 'description' -NewValue ([string]$NewDescription)
    }
    Write-TextFileNoBom -Path $Path -Text $text
}

function Update-UpluginFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PluginName
    )
    $text = Read-TextFileRaw $Path
    $text = Set-JsonScalar -Text $text -Key 'VersePath' -NewValue "$script:VerseSentinelRoot/$PluginName"
    Write-TextFileNoBom -Path $Path -Text $text
}

function Test-SanitizedProject {
    # Post-write validation; sanitize always runs on a staging copy, so a throw here aborts cleanly.
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [Parameter(Mandatory)]$Pre
    )
    $post = Get-ProjectInfo -FolderPath $FolderPath
    if ($post.ProjectVersePath -ne '') { throw 'Sanitize validation failed: projectVersePath was not cleared.' }
    if ($post.ProjectId -eq $Pre.ProjectId) { throw 'Sanitize validation failed: projectId was not regenerated.' }
    foreach ($name in $Pre.Modules.Keys) {
        if ($post.Modules[$name] -eq $Pre.Modules[$name]) {
            throw "Sanitize validation failed: module GUID for '$name' was not regenerated."
        }
    }
    $plugJson = Get-Content -LiteralPath $post.UpluginFile -Raw | ConvertFrom-Json
    if ("$($plugJson.VersePath)" -ne "$script:VerseSentinelRoot/$($post.PluginName)") {
        throw 'Sanitize validation failed: uplugin VersePath is not the unbound sentinel.'
    }
    if ($post.PluginName -ne $Pre.PluginName) { throw 'Sanitize validation failed: plugin name changed.' }
    return $post
}

#endregion

#region Verse source rewrite

function Update-VerseSources {
    # Rewrites the project's own account-qualified Verse path in .verse text sources to the
    # unbound sentinel. Binary assets are never touched; UEFN's redirector fixes those on open.
    param(
        [Parameter(Mandatory)][string]$ContentDir,
        [AllowEmptyString()][string]$OldVersePath,
        [Parameter(Mandatory)][string]$PluginName
    )
    if (-not (Test-Path -LiteralPath $ContentDir)) { return 0 }
    $sentinel = "$script:VerseSentinelRoot/$PluginName"
    $changed = 0
    foreach ($file in (Get-ChildItem -LiteralPath $ContentDir -Recurse -Filter '*.verse' -File -ErrorAction SilentlyContinue)) {
        $text = Read-TextFileRaw $file.FullName
        $new = $text
        if ($OldVersePath -ne '' -and $OldVersePath -ne $sentinel) {
            $new = $new.Replace($OldVersePath, $sentinel)
        }
        # Residue catch: any account-qualified reference to THIS project (never other creators' libraries).
        $residue = '/[\w.+-]+@fortnite\.com/' + [regex]::Escape($PluginName)
        $new = [regex]::Replace($new, $residue, $sentinel)
        if ($new -ne $text) {
            Write-TextFileNoBom -Path $file.FullName -Text $new
            $changed++
        }
    }
    return $changed
}

#endregion

#region Sanitizer

function Clear-ReadOnlyFlags {
    param([Parameter(Mandatory)][string]$Path)
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.IsReadOnly) { $_.IsReadOnly = $false }
    }
}

function Remove-PathIfExists {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return $true
    }
    return $false
}

function Invoke-ProjectSanitize {
    # The shared transform: makes a staged project copy identity-free ("as-new"), exactly the
    # state UEFN itself produces for a never-bound project. Always operates on a staging copy.
    param(
        [Parameter(Mandatory)][string]$StagingPath,
        [Parameter(Mandatory)][string]$NewTitle,
        [Parameter(Mandatory)][ValidateSet('Install', 'Export', 'Duplicate')][string]$Mode,
        $NewDescription = $null  # untyped on purpose; see Update-UefnProjectFile
    )
    $pre = Get-ProjectInfo -FolderPath $StagingPath

    Clear-ReadOnlyFlags -Path $StagingPath

    # Original owner's revision-control DB / repos / regenerated files: always removed.
    foreach ($d in @('.lore', '.urc', '.svn', '__MACOSX')) {
        if (Remove-PathIfExists (Join-Path $StagingPath $d)) { Write-Info "Removed $d\" }
    }
    if ($Mode -ne 'Duplicate') {
        if (Remove-PathIfExists (Join-Path $StagingPath '.git')) { Write-Info 'Removed .git\' }
        $dev = Join-Path $StagingPath 'Content\Developers'
        if (Remove-PathIfExists $dev) { Write-Info 'Removed Content\Developers\' }
    }
    Get-ChildItem -LiteralPath $StagingPath -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; Write-Info "Removed $($_.Name) (UEFN regenerates it)" }
    Get-ChildItem -LiteralPath $StagingPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('Thumbs.db', 'desktop.ini') } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    # Stray files at the project root (anything outside the known UEFN layout).
    $whitelist = @(
        "$($pre.Name).uefnproject", "$($pre.PluginName).uplugin",
        'Content', 'Resources', 'References', '.loreignore', '.urcignore'
    )
    $strays = @(Get-ChildItem -LiteralPath $StagingPath -Force -ErrorAction SilentlyContinue |
        Where-Object { $whitelist -notcontains $_.Name })
    if ($strays.Count -gt 0) {
        switch ($Mode) {
            'Export' {
                Write-Info 'Files not part of the standard UEFN project layout:'
                foreach ($s in $strays) {
                    if (Read-YesNo "  Remove '$($s.Name)' from the package?" -Default $true) {
                        Remove-Item -LiteralPath $s.FullName -Recurse -Force
                    }
                }
            }
            'Install' {
                Write-Warn ("Keeping unrecognized items from the package: {0}" -f ($strays.Name -join ', '))
            }
            'Duplicate' { }  # the user's own files; keep silently
        }
    }

    Update-UefnProjectFile -Path $pre.UefnProjectFile -NewTitle $NewTitle `
        -ModuleNames @($pre.Modules.Keys) -NewDescription $NewDescription
    Update-UpluginFile -Path $pre.UpluginFile -PluginName $pre.PluginName
    $verseChanged = Update-VerseSources -ContentDir (Join-Path $StagingPath 'Content') `
        -OldVersePath $pre.ProjectVersePath -PluginName $pre.PluginName
    if ($verseChanged -gt 0) { Write-Info "Rewrote Verse paths in $verseChanged .verse file(s)" }

    return Test-SanitizedProject -FolderPath $StagingPath -Pre $pre
}

#endregion

#region Staging and zip

function New-StagingDir {
    # Deliberately short path: PS 5.1 zip/copy APIs hit MAX_PATH easily.
    $base = Join-Path $env:TEMP 'uefnshare'
    do {
        $dir = Join-Path $base ('{0:x4}' -f (Get-Random -Maximum 65536))
    } while (Test-Path -LiteralPath $dir)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [void]$script:StagingDirs.Add($dir)
    return $dir
}

function Remove-AllStagingDirs {
    foreach ($dir in @($script:StagingDirs)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:StagingDirs.Clear()
}

function Copy-ProjectToStaging {
    # Filtered top-level copy; skipping .lore/.git at copy time avoids copying GBs just to delete them.
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$StagingDir,
        [string[]]$ExcludeTopLevel = @()
    )
    $projRoot = Join-Path $StagingDir (Split-Path $SourceDir -Leaf)
    New-Item -ItemType Directory -Path $projRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $SourceDir -Force | Where-Object { $ExcludeTopLevel -notcontains $_.Name } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $projRoot -Recurse -Force }
    return $projRoot
}

function Resolve-StagedProjectRoot {
    # Finds the project root inside an extracted zip regardless of zip shape
    # (nested folder, bare contents, junk siblings like __MACOSX).
    param([Parameter(Mandatory)][string]$SearchDir)
    $found = @(Get-ChildItem -LiteralPath $SearchDir -Recurse -Filter '*.uefnproject' -File -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { throw 'No .uefnproject file found in the archive - this is not a UEFN project package.' }
    $sorted = $found | Sort-Object { $_.FullName.Split([System.IO.Path]::DirectorySeparatorChar).Count }
    $minDepth = $sorted[0].FullName.Split([System.IO.Path]::DirectorySeparatorChar).Count
    $atMin = @($sorted | Where-Object { $_.FullName.Split([System.IO.Path]::DirectorySeparatorChar).Count -eq $minDepth })
    if ($atMin.Count -gt 1) {
        throw "Multiple projects found in the archive: $($atMin.FullName -join ', '). Package one project per zip."
    }
    return (Split-Path -Parent $atMin[0].FullName)
}

function Expand-ProjectZip {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$StagingDir
    )
    Unblock-File -LiteralPath $ZipPath -ErrorAction SilentlyContinue
    Write-Info 'Extracting archive...'
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $StagingDir -Force
    return Resolve-StagedProjectRoot -SearchDir $StagingDir
}

function New-ProjectZip {
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)][string]$ZipPath
    )
    $outDir = Split-Path -Parent $ZipPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    try {
        Compress-Archive -Path $ProjectDir -DestinationPath $ZipPath -CompressionLevel Optimal -ErrorAction Stop
    } catch {
        # PS 5.1 Compress-Archive fails on files >= 4 GB; fall back to .NET (still zero-dependency).
        Write-Warn "Compress-Archive failed ($($_.Exception.Message)); using .NET zip fallback."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $ProjectDir, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    }
}

#endregion

#region Network

function Get-Catalog {
    param([Parameter(Mandatory)][string]$Url)
    $catalog = $null
    try {
        if ($Url -match '^[A-Za-z]:' -or $Url.StartsWith('\\')) {
            $catalog = Get-Content -LiteralPath $Url -Raw | ConvertFrom-Json
        } elseif ($Url -match '^file://') {
            $catalog = Get-Content -LiteralPath ([uri]$Url).LocalPath -Raw | ConvertFrom-Json
        } else {
            $catalog = Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 30
            if ($catalog -is [string]) { $catalog = $catalog | ConvertFrom-Json }
        }
    } catch {
        throw "Could not fetch the catalog from '$Url' ($($_.Exception.Message)). Check the catalog URL in Settings."
    }
    if ($null -eq $catalog.PSObject.Properties['schemaVersion'] -or $catalog.schemaVersion -ne 1) {
        throw "The catalog at '$Url' has an unsupported or missing schemaVersion (expected 1)."
    }
    if ($null -eq $catalog.PSObject.Properties['projects']) {
        throw "The catalog at '$Url' has no 'projects' array."
    }
    return $catalog
}

function Save-FileWithProgress {
    # Streamed download with progress. Plain Invoke-WebRequest on PS 5.1 is either crawling-slow
    # (progress on) or silent (progress off); a raw WebRequest stream copy is both fast and visible.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    $response = $null; $inStream = $null; $outStream = $null
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        if ($request -is [System.Net.HttpWebRequest]) {
            $request.UserAgent = "UEFNShare/$script:ToolVersion"
            $request.AllowAutoRedirect = $true
        }
        $response = $request.GetResponse()
        $total = $response.ContentLength
        $inStream = $response.GetResponseStream()
        $outStream = [System.IO.File]::Create($OutFile)
        $buffer = New-Object byte[] (1MB)
        $done = [long]0
        $lastReport = [long]0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $read)
            $done += $read
            if (($done - $lastReport) -ge 2MB) {
                $lastReport = $done
                $mbDone = [math]::Round($done / 1MB, 1)
                $speed = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round(($done / 1MB) / $sw.Elapsed.TotalSeconds, 1) } else { 0 }
                if ($total -gt 0) {
                    $pct = [math]::Min(100, [math]::Round($done * 100 / $total))
                    Write-Progress -Activity 'Downloading' -Status ("{0} / {1} MB  ({2} MB/s)" -f $mbDone, [math]::Round($total / 1MB, 1), $speed) -PercentComplete $pct
                } else {
                    Write-Progress -Activity 'Downloading' -Status ("{0} MB  ({1} MB/s)" -f $mbDone, $speed)
                }
            }
        }
        Write-Progress -Activity 'Downloading' -Completed
    } catch {
        if ($outStream) { $outStream.Dispose(); $outStream = $null }
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        throw "Download failed: $($_.Exception.Message)"
    } finally {
        if ($outStream) { $outStream.Dispose() }
        if ($inStream)  { $inStream.Dispose() }
        if ($response)  { $response.Dispose() }
    }
}

function Test-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected
    )
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($actual -ieq $Expected)
}

#endregion

#region Flows

function Show-ProjectSummary {
    param([Parameter(Mandatory)]$Info)
    Write-Info ("Project: {0}  (title: '{1}')" -f $Info.Name, $Info.Title)
    Write-Info ("Plugin:  {0}   Modules: {1}" -f $Info.PluginName, $Info.Modules.Count)
    if ($Info.IsBound) { Write-Info ("Currently bound to: {0}" -f $Info.ProjectVersePath) }
    else { Write-Info 'Currently unbound (pristine).' }
    if ($Info.CompatibilityVersion) { Write-Info ("Requires UEFN {0}+" -f $Info.CompatibilityVersion) }
}

function Get-UniqueFolderName {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$BaseName
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Root $BaseName))) { return $BaseName }
    $i = 2
    while (Test-Path -LiteralPath (Join-Path $Root ("{0} ({1})" -f $BaseName, $i))) { $i++ }
    return ("{0} ({1})" -f $BaseName, $i)
}

function Install-ProjectFromStaging {
    # Shared tail of Browse, Local-install and Duplicate: prompt, sanitize, copy into the projects root.
    param(
        [Parameter(Mandatory)][string]$StagedRoot,
        [ValidateSet('Install', 'Duplicate')][string]$Mode = 'Install',
        [string]$DefaultTitle = '',
        [string]$PresetTitle = '',
        [string]$PresetFolderName = '',
        [string]$DefaultRoot = ''
    )
    $info = Get-ProjectInfo -FolderPath $StagedRoot
    Write-Head 'Install project'
    Show-ProjectSummary -Info $info

    # UEFN version gate
    $installed = Get-InstalledUefnVersion
    if ($installed) {
        $compat = Test-VersionCompatible -Required $info.CompatibilityVersion -Installed $installed.Version
        if ($compat -eq $false) {
            Write-Warn ("This project requires UEFN {0} but you have {1}. It may fail to open until UEFN updates." -f $info.CompatibilityVersion, $installed.Version)
            if (-not (Read-YesNo 'Continue anyway?' -Default $false)) { return }
        }
    } else {
        Write-Warn 'Could not detect an installed UEFN version - skipping the compatibility check.'
    }
    if (Test-UefnRunning) {
        Write-Warn 'UEFN is currently running. Installing is safe, but the Project Browser needs a refresh (or UEFN restart) to show the new project.'
    }

    # Title
    $title = $PresetTitle
    if ($title -eq '') {
        $def = if ($DefaultTitle -ne '') { $DefaultTitle } else { $info.Title }
        if ($def -eq '') { $def = $info.Name }
        $title = Read-Prompt 'Project title' -Default $def
    }

    # Destination root
    $rootDefault = if ($DefaultRoot -ne '') { $DefaultRoot } else { Get-ProjectsRoot }
    $root = Read-Prompt 'Install into projects folder' -Default $rootDefault
    if (-not (Test-Path -LiteralPath $root)) {
        if (Read-YesNo "Folder '$root' does not exist. Create it?" -Default $true) {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
        } else { return }
    }

    # Folder name (collision loop). The uplugin filename is part of the project's identity and
    # is never renamed; folder + .uefnproject filename + title are free to change.
    $folderName = $PresetFolderName
    while ($true) {
        if ($folderName -eq '') {
            $folderName = Read-Prompt 'Install as folder name' -Default (Get-UniqueFolderName -Root $root -BaseName $info.Name)
        }
        if ($folderName -match '[\\/:*?"<>|]') {
            Write-Warn 'Folder name contains invalid characters.'
            $folderName = ''
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $root $folderName)) {
            Write-Warn "A folder named '$folderName' already exists in '$root'."
            $folderName = ''
            continue
        }
        break
    }

    # Sanitize on the staging copy, then rename the .uefnproject to match the folder.
    Write-Info 'Resetting project identity (new GUIDs, unbound Verse path)...'
    $info = Invoke-ProjectSanitize -StagingPath $StagedRoot -NewTitle $title -Mode $Mode
    if ($folderName -ne $info.Name) {
        Rename-Item -LiteralPath $info.UefnProjectFile -NewName "$folderName.uefnproject"
    }

    # Free-space sanity check
    try {
        $needMB = Get-FolderSizeMB -Path $StagedRoot
        $qualifier = (Split-Path -Qualifier ([System.IO.Path]::GetFullPath($root))).TrimEnd(':')
        $freeMB = [math]::Round((Get-PSDrive -Name $qualifier).Free / 1MB, 1)
        if ($freeMB -lt ($needMB * 1.2)) {
            Write-Warn ("Low disk space: project needs ~{0} MB, drive {1}: has {2} MB free." -f $needMB, $qualifier, $freeMB)
            if (-not (Read-YesNo 'Continue anyway?' -Default $false)) { return }
        }
    } catch { }

    # Copy into place (staging may be on another volume; Copy-Item is volume-safe).
    $dest = Join-Path $root $folderName
    Write-Info "Copying to $dest ..."
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Get-ChildItem -LiteralPath $StagedRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
    }
    Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Ok "Installed '$title' to $dest"
    Write-Info 'Open UEFN and refresh the Project Browser to see it.'
    Write-Info 'On first open, UEFN will bind the project to YOUR account automatically and show'
    Write-Info 'the standard Verse code trust prompt - that prompt is expected and is your'
    Write-Info 'security checkpoint for code someone else wrote.'
}

function Invoke-BrowseCatalogFlow {
    $settings = Get-UefnShareSettings
    Write-Head 'Browse catalog'
    Write-Info "Fetching catalog from $($settings.catalogUrl) ..."
    $catalog = Get-Catalog -Url $settings.catalogUrl

    $catName = if ($catalog.PSObject.Properties['name'] -and $catalog.name) { $catalog.name } else { 'Catalog' }
    $entries = @($catalog.projects)
    if ($entries.Count -eq 0) {
        Write-Warn 'The catalog has no projects yet.'
        return
    }

    $installed = Get-InstalledUefnVersion
    $labels = foreach ($e in $entries) {
        $bits = @()
        if ($e.PSObject.Properties['author'] -and $e.author) { $bits += "by $($e.author)" }
        if ($e.PSObject.Properties['version'] -and $e.version) { $bits += "v$($e.version)" }
        if ($e.PSObject.Properties['sizeMB'] -and $e.sizeMB) { $bits += "$($e.sizeMB) MB" }
        $compatNote = ''
        if ($e.PSObject.Properties['uefnCompatibilityVersion'] -and $e.uefnCompatibilityVersion) {
            $bits += "UEFN $($e.uefnCompatibilityVersion)"
            if ($installed -and (Test-VersionCompatible -Required $e.uefnCompatibilityVersion -Installed $installed.Version) -eq $false) {
                $compatNote = '  [!] needs newer UEFN'
            }
        }
        $meta = if ($bits.Count -gt 0) { ' - ' + ($bits -join ', ') } else { '' }
        "$($e.title)$meta$compatNote"
    }

    $pick = Read-MenuChoice -Title $catName -Options @($labels)
    if ($pick -lt 0) { return }
    $entry = $entries[$pick]

    Write-Host ''
    Write-Host $entry.title -ForegroundColor White
    if ($entry.PSObject.Properties['description'] -and $entry.description) { Write-Info $entry.description }
    if ($entry.PSObject.Properties['readmeUrl'] -and $entry.readmeUrl) { Write-Info "Readme: $($entry.readmeUrl)" }
    if ($entry.PSObject.Properties['screenshotUrl'] -and $entry.screenshotUrl) { Write-Info "Screenshot: $($entry.screenshotUrl)" }

    $sizeNote = if ($entry.PSObject.Properties['sizeMB'] -and $entry.sizeMB) { " ($($entry.sizeMB) MB)" } else { '' }
    if (-not (Read-YesNo "Download '$($entry.title)'$sizeNote?" -Default $true)) { return }

    $staging = New-StagingDir
    $zipPath = Join-Path $staging 'pkg.zip'
    Save-FileWithProgress -Url $entry.downloadUrl -OutFile $zipPath
    Write-Ok 'Download complete.'

    if ($entry.PSObject.Properties['sha256'] -and $entry.sha256) {
        if (-not (Test-FileSha256 -Path $zipPath -Expected $entry.sha256)) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            throw 'SHA-256 checksum mismatch - the download is corrupt or was tampered with. Aborting.'
        }
        Write-Ok 'Checksum verified.'
    }

    $extractDir = New-StagingDir
    $stagedRoot = Expand-ProjectZip -ZipPath $zipPath -StagingDir $extractDir
    Install-ProjectFromStaging -StagedRoot $stagedRoot -DefaultTitle "$($entry.title)"
}

function Invoke-LocalInstallFlow {
    Write-Head 'Install from local zip or folder'
    $path = Read-Prompt 'Path to the project zip or folder'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Err "Path not found: $path"
        return
    }
    $staging = New-StagingDir
    $stagedRoot = $null
    $item = Get-Item -LiteralPath $path
    if ($item.PSIsContainer) {
        Write-Info 'Copying project to a working area (the source will not be modified)...'
        $srcRoot = Resolve-StagedProjectRoot -SearchDir $item.FullName
        $stagedRoot = Copy-ProjectToStaging -SourceDir $srcRoot -StagingDir $staging -ExcludeTopLevel @('.lore', '.urc')
    } elseif ($item.Extension -ieq '.zip') {
        $stagedRoot = Expand-ProjectZip -ZipPath $item.FullName -StagingDir $staging
    } else {
        Write-Err 'The path must be a folder or a .zip file.'
        return
    }
    Install-ProjectFromStaging -StagedRoot $stagedRoot
}

function Select-LocalProject {
    param([string]$Title = 'Select a project')
    $projects = @(Get-LocalProjects)
    if ($projects.Count -eq 0) {
        Write-Warn "No UEFN projects found under: $((Get-AllProjectRoots) -join '; ')"
        return $null
    }
    $labels = foreach ($p in $projects) {
        $bound = if ($p.Info.IsBound) { $p.Info.ProjectVersePath } else { 'unbound' }
        "{0}  (title: '{1}', {2}, {3} MB)" -f $p.Info.Name, $p.Info.Title, $bound, $p.ShareMB
    }
    $pick = Read-MenuChoice -Title $Title -Options @($labels)
    if ($pick -lt 0) { return $null }
    return $projects[$pick]
}

function Invoke-DuplicateFlow {
    $sel = Select-LocalProject -Title 'Duplicate one of my projects'
    if ($null -eq $sel) { return }
    $info = $sel.Info

    if (Test-UefnRunning) {
        Write-Warn 'UEFN is running. If this project is open in the editor, files may be copied mid-write.'
        if (-not (Read-YesNo 'Continue?' -Default $false)) { return }
    }

    $newFolder = Read-Prompt 'New folder name' -Default (Get-UniqueFolderName -Root $sel.Root -BaseName ($info.Name + '2'))
    $newTitle  = Read-Prompt 'New project title' -Default ($info.Title + ' Copy')

    # .lore is ALWAYS excluded: a copied revision-control DB shares the projectId/identity,
    # which is exactly what would make UEFN treat the copy as the same project.
    $exclude = @('.lore', '.urc')
    if (Test-Path -LiteralPath (Join-Path $info.FolderPath '.git')) {
        if (-not (Read-YesNo 'This project has a .git repo. Copy it into the duplicate?' -Default $false)) {
            $exclude += '.git'
        }
    } else {
        $exclude += '.git'
    }

    Write-Info 'Copying project (excluding revision-control history)...'
    $staging = New-StagingDir
    $stagedRoot = Copy-ProjectToStaging -SourceDir $info.FolderPath -StagingDir $staging -ExcludeTopLevel $exclude

    Install-ProjectFromStaging -StagedRoot $stagedRoot -Mode Duplicate `
        -PresetTitle $newTitle -PresetFolderName $newFolder -DefaultRoot $sel.Root
}

function Invoke-ExportFlow {
    $sel = Select-LocalProject -Title 'Export a project for sharing'
    if ($null -eq $sel) { return }
    $info = $sel.Info

    if (Test-UefnRunning) {
        Write-Warn 'UEFN is running. For a clean export, close UEFN so no files are mid-write.'
        if (-not (Read-YesNo 'Continue anyway?' -Default $false)) { return }
    }

    $pkgTitle = Read-Prompt 'Package title' -Default ($(if ($info.Title) { $info.Title } else { $info.Name }))
    $authorDefault = ''
    if ($info.ProjectVersePath -match '^/([^/@]+)@') { $authorDefault = $Matches[1] }
    $author  = Read-Prompt 'Author name' -Default $authorDefault -AllowEmpty
    $version = Read-Prompt 'Version' -Default '1.0.0'
    $desc    = (Read-Prompt 'Description' -Default $info.Description -AllowEmpty).Trim()

    Write-Info 'Copying project to a working area (excluding .lore/.git history)...'
    $staging = New-StagingDir
    $stagedRoot = Copy-ProjectToStaging -SourceDir $info.FolderPath -StagingDir $staging -ExcludeTopLevel @('.lore', '.urc', '.git')

    Write-Info 'Stripping identity (the package will install as-new for anyone)...'
    $post = Invoke-ProjectSanitize -StagingPath $stagedRoot -NewTitle $pkgTitle -Mode Export -NewDescription $desc

    $distDefault = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'dist' } else { [Environment]::GetFolderPath('Desktop') }
    $zipDefault  = Join-Path $distDefault ("{0}-{1}.zip" -f $post.Name, $version)
    $zipPath     = Read-Prompt 'Output zip path' -Default $zipDefault

    Write-Info 'Creating zip...'
    New-ProjectZip -ProjectDir $stagedRoot -ZipPath $zipPath
    $zipItem = Get-Item -LiteralPath $zipPath
    $sha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sizeMB = [math]::Round($zipItem.Length / 1MB, 1)

    $id = ($post.Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    $entry = [ordered]@{
        id                       = $id
        name                     = $post.Name
        title                    = $pkgTitle
        description              = $desc
        author                   = $author
        version                  = $version
        uefnCompatibilityVersion = $post.CompatibilityVersion
        sizeMB                   = $sizeMB
        sha256                   = $sha
        downloadUrl              = "https://github.com/magnusenebakk-epic/UEFNShare/releases/download/<tag>/$($zipItem.Name)"
    }
    $entryJson = [pscustomobject]$entry | ConvertTo-Json -Depth 5

    Write-Host ''
    Write-Ok "Packaged: $zipPath ($sizeMB MB)"
    Write-Host ''
    Write-Host 'Catalog entry (paste into the "projects" array of your index.json):' -ForegroundColor White
    Write-Host $entryJson
    try {
        if (Read-YesNo 'Copy the catalog entry to the clipboard?' -Default $true) {
            $entryJson | Set-Clipboard
            Write-Ok 'Copied.'
        }
    } catch { }
    Write-Host ''
    Write-Info 'Next steps: 1) upload the zip to a GitHub Release,  2) fix downloadUrl in the'
    Write-Info 'entry above,  3) paste the entry into index.json and push it.'
}

function Invoke-SettingsFlow {
    while ($true) {
        $settings = Get-UefnShareSettings
        $autoRoot = Get-ProjectsRoot
        $overrideLabel = if ($settings.projectsPathOverride -ne '') { $settings.projectsPathOverride } else { "(auto: $autoRoot)" }
        $pick = Read-MenuChoice -Title 'Settings' -Options @(
            "Catalog URL: $($settings.catalogUrl)",
            "Projects folder override: $overrideLabel",
            'Reset to defaults'
        )
        switch ($pick) {
            -1 { return }
            0 {
                $settings.catalogUrl = Read-Prompt 'Catalog URL' -Default $settings.catalogUrl
                Save-UefnShareSettings $settings
                Write-Ok 'Saved.'
            }
            1 {
                Write-Info "Enter a folder path, or 'auto' to use the UEFN-detected location."
                $val = Read-Prompt 'Projects folder override' -Default ($(if ($settings.projectsPathOverride) { $settings.projectsPathOverride } else { 'auto' }))
                $settings.projectsPathOverride = if ($val -ieq 'auto') { '' } else { $val }
                Save-UefnShareSettings $settings
                Write-Ok 'Saved.'
            }
            2 {
                $settings.catalogUrl = $script:DefaultCatalogUrl
                $settings.projectsPathOverride = ''
                Save-UefnShareSettings $settings
                Write-Ok 'Settings reset.'
            }
        }
    }
}

function Show-Help {
    Write-Head 'Help'
    Write-Host @"
UEFNShare installs, duplicates and packages UEFN projects.

Why this exists: a UEFN project carries identifiers that tie it to its creator's
Epic account (project/module GUIDs, the account Verse path, and the revision-
control database). Simply copying a project to another machine leaves it bound
to the original creator. This tool resets all of that to the exact state UEFN
uses for a brand-new, never-opened project - so on first open, UEFN binds the
project to YOUR account and it behaves as if you created it.

  Browse catalog     Lists projects from a catalog URL (Settings). Downloads
                     the zip, verifies its checksum when provided, and installs.
  Install local      Installs from a zip or folder someone sent you. The source
                     is never modified.
  Duplicate          Copies one of your own projects as a fresh, independent
                     project (new GUIDs, unbound - UEFN re-binds it on open).
  Export             Packages one of your projects into a shareable zip with all
                     of your identity stripped, and emits a catalog entry.

What install/export changes: fresh project + module GUIDs, Verse path reset to
the unbound state, account-qualified 'using' paths in .verse files rewritten,
.lore revision-control history and editor-generated files removed. Binary
assets are never modified - UEFN's own redirector fixes those on first open.

What it never touches: UEFN's central config, your trusted-projects list, and
your Epic/revision-control login tokens. When you first open an installed
project, UEFN shows its Verse code trust prompt - review it; that is the
security boundary for running code somebody else wrote.

Hosting your own catalog: serve an index.json (schemaVersion 1) with a
'projects' array from any static host (GitHub raw works), point Settings >
Catalog URL at it. Each entry needs id, name, title, version, downloadUrl;
author, description, sizeMB, sha256, uefnCompatibilityVersion are recommended.
"@
}

function Show-Banner {
    $installed = Get-InstalledUefnVersion
    $uefnLabel = if ($installed) { "UEFN detected: $($installed.Version) (CL $($installed.CL))" } else { 'UEFN install not detected' }
    Write-Host ''
    Write-Host ("UEFNShare v{0}" -f $script:ToolVersion) -ForegroundColor Cyan -NoNewline
    Write-Host ("    {0}" -f $uefnLabel) -ForegroundColor Gray
    Write-Host ("Projects folder: {0}" -f (Get-ProjectsRoot)) -ForegroundColor Gray
}

function Main {
    Show-Banner
    while ($true) {
        $pick = Read-MenuChoice -Title 'Main menu' -Options @(
            'Browse catalog and install',
            'Install from local zip or folder',
            'Duplicate one of my projects',
            'Export one of my projects for sharing',
            'Settings',
            'Help'
        ) -BackLabel 'Quit' -DefaultChoice '1'
        try {
            switch ($pick) {
                -1 { Remove-AllStagingDirs; return }
                0  { Invoke-BrowseCatalogFlow }
                1  { Invoke-LocalInstallFlow }
                2  { Invoke-DuplicateFlow }
                3  { Invoke-ExportFlow }
                4  { Invoke-SettingsFlow }
                5  { Show-Help }
            }
        } catch {
            Write-Err $_.Exception.Message
        } finally {
            Remove-AllStagingDirs
        }
    }
}

#endregion

# Entry point. Set UEFNSHARE_NO_MAIN=1 to dot-source the functions without running the menu (tests).
if (-not $env:UEFNSHARE_NO_MAIN) {
    Main
}
