# UEFNKit - share, install, duplicate and package UEFN projects.
# Single-file, zero-dependency, Windows PowerShell 5.1 compatible.
# Run:  irm <raw-url>/UEFNKit.ps1 | iex     or     UEFNKit.cmd
# Headless/automation:  powershell -ExecutionPolicy Bypass -File UEFNKit.ps1 <command> [options]
# (see AGENTS.md or 'UEFNKit.ps1 help' for the command reference)
param(
    [Parameter(Position = 0)][string]$Command = '',
    [string]$Path = '',          # install: source zip or folder
    [string]$Project = '',       # duplicate/variants/export/remove: project name or folder path
    [string]$Name = '',          # install/duplicate: name for the new project
    [string]$Title = '',         # display title override
    [string]$Id = '',            # install/catalog-remove: catalog entry id
    [string]$Version = '',       # export: package version (default 1.0.0)
    [string]$Author = '',        # export: author override
    [string]$Description = '',   # export: description override
    [string]$OutDir = '',        # export: output folder for the zip
    [string]$ProjectsRoot = '',  # install/duplicate: target projects folder override
    [string]$CatalogUrl = '',    # catalog/install: catalog URL override
    [switch]$Yes,                # required consent for destructive/overwriting commands
    [switch]$Json,               # machine-readable result output
    [switch]$Publish,            # export: publish to the catalog (owner machine with gh)
    [switch]$DeleteRelease       # catalog-remove: also delete the entry's GitHub release
)

#region Constants

$script:ToolVersion       = '2.4.0'
$script:DefaultCatalogUrl = 'https://raw.githubusercontent.com/magnusenebakk-epic/UEFNKit/main/index.json'
$script:SettingsPath      = Join-Path $env:APPDATA 'UEFNKit\settings.json'
# Pre-rename locations (the tool used to be called UEFNShare); read as fallback.
$script:LegacySettingsPath      = Join-Path $env:APPDATA 'UEFNShare\settings.json'
$script:LegacyDefaultCatalogUrl = 'https://raw.githubusercontent.com/magnusenebakk-epic/UEFNShare/main/index.json'
$script:UefnIniPath       = Join-Path $env:LOCALAPPDATA 'UnrealEditorFortnite\Saved\Config\WindowsEditor\EditorPerProjectUserSettings.ini'
$script:VkProjectsIniDir  = Join-Path $env:LOCALAPPDATA 'UnrealEditorFortnite\Saved\Config\WindowsEditor\VK_Projects'
$script:LauncherDat       = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
$script:UefnLogPath       = Join-Path $env:LOCALAPPDATA 'UnrealEditorFortnite\Saved\Logs\UnrealEditorFortnite.log'
$script:VerseSentinelRoot = '/invaliddomain'
$script:StagingDirs       = New-Object System.Collections.ArrayList
$script:RawScriptUrl      = 'https://raw.githubusercontent.com/magnusenebakk-epic/UEFNKit/main/UEFNKit.ps1'

# Box-drawing characters built from code points: the script file stays pure ASCII, which
# PowerShell 5.1 requires for BOM-less files.
$script:BoxH  = [string][char]0x2500
$script:BoxV  = [string][char]0x2502
$script:BoxTL = [string][char]0x250C
$script:BoxTR = [string][char]0x2510
$script:BoxBL = [string][char]0x2514
$script:BoxBR = [string][char]0x2518

# Headless mode: prompts auto-resolve to their defaults (logged), menus are errors.
$script:NonInteractive = $false

# TLS 1.2 for PS 5.1 talking to GitHub
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch { }

#endregion

#region UI helpers

function Write-Head {
    param([string]$Text)
    Write-Host ''
    if (Test-InteractiveConsole) {
        $width = [Math]::Min(64, [Math]::Max(24, [Console]::WindowWidth - 2))
        $tail = [Math]::Max(2, $width - $Text.Length - 6)
        Write-Host (($script:BoxH * 2) + ' ') -ForegroundColor DarkCyan -NoNewline
        Write-Host $Text -ForegroundColor Cyan -NoNewline
        Write-Host (' ' + ($script:BoxH * $tail)) -ForegroundColor DarkCyan
    } else {
        Write-Host "=== $Text ===" -ForegroundColor Cyan
    }
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
    if ($script:NonInteractive) {
        if ($Default -ne '') { Write-Info "(auto) ${Message}: $Default"; return $Default }
        if ($AllowEmpty) { return '' }
        throw "Headless mode has no value for '$Message' - pass it as a parameter."
    }
    while ($true) {
        if ($Default -ne '') {
            Write-Host $Message -ForegroundColor White -NoNewline
            Write-Host " [Enter = $Default]" -ForegroundColor DarkGray -NoNewline
            Write-Host ': ' -ForegroundColor White -NoNewline
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
    if ($script:NonInteractive) {
        $ans = if ($Default) { 'yes' } else { 'no' }
        Write-Info "(auto) ${Message}: $ans"
        return $Default
    }
    if (Test-InteractiveConsole) {
        $width = [Math]::Max(20, [Console]::WindowWidth - 1)
        # Long questions get their own line so the single-line redraw never wraps.
        $prompt = $Message
        if (($prompt.Length + 36) -gt $width) {
            Write-Host $Message -ForegroundColor White
            $prompt = 'Confirm'
        }
        $top = [Console]::CursorTop
        $cursorWasVisible = $true
        try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }
        $sel = $Default
        $confirmed = $false
        try {
            while (-not $confirmed) {
                [Console]::SetCursorPosition(0, $top)
                Write-Host ($prompt + '  ') -ForegroundColor White -NoNewline
                if ($sel) {
                    Write-Host ' Yes ' -ForegroundColor Black -BackgroundColor Green -NoNewline
                    Write-Host '  ' -NoNewline
                    Write-Host ' No ' -ForegroundColor DarkGray -NoNewline
                } else {
                    Write-Host ' Yes ' -ForegroundColor DarkGray -NoNewline
                    Write-Host '  ' -NoNewline
                    Write-Host ' No ' -ForegroundColor Black -BackgroundColor Red -NoNewline
                }
                Write-Host '   y/n, arrows, Enter' -ForegroundColor DarkGray -NoNewline
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'LeftArrow'  { $sel = $true }
                    'RightArrow' { $sel = $false }
                    'UpArrow'    { $sel = -not $sel }
                    'DownArrow'  { $sel = -not $sel }
                    'Y'          { $sel = $true;  $confirmed = $true }
                    'N'          { $sel = $false; $confirmed = $true }
                    'Enter'      { $confirmed = $true }
                    'Escape'     { $sel = $false; $confirmed = $true }
                }
            }
        } finally {
            try { [Console]::CursorVisible = $cursorWasVisible } catch { }
        }
        [Console]::SetCursorPosition(0, $top)
        Write-Host (' ' * $width) -NoNewline
        [Console]::SetCursorPosition(0, $top)
        Write-Host ($prompt + '  ') -ForegroundColor White -NoNewline
        if ($sel) { Write-Host 'Yes' -ForegroundColor Green } else { Write-Host 'No' -ForegroundColor Red }
        return $sel
    }

    # Typed fallback for redirected input/output.
    $hint = if ($Default) { '[y/n, Enter = yes]' } else { '[y/n, Enter = no]' }
    while ($true) {
        Write-Host $Message -ForegroundColor White -NoNewline
        Write-Host " $hint" -ForegroundColor DarkGray -NoNewline
        Write-Host ': ' -ForegroundColor White -NoNewline
        $resp = Read-Host
        if ($null -eq $resp -or $resp.Trim() -eq '') { return $Default }
        switch -Regex ($resp.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Warn 'Please answer y or n.' }
        }
    }
}

function Test-InteractiveConsole {
    # Arrow-key menus need a real console host with unredirected keyboard AND screen
    # (in-place redrawing uses SetCursorPosition, which throws on redirected output).
    try {
        return ($Host.Name -eq 'ConsoleHost') -and
               -not [Console]::IsInputRedirected -and
               -not [Console]::IsOutputRedirected
    } catch { return $false }
}

function Read-MenuChoice {
    # Menu picker: arrow keys + Enter in a real console (number keys jump directly); falls
    # back to typed numbers when input is redirected. Returns the 0-based option index, or
    # -1 when Back/Quit is chosen.
    param(
        [string]$Title = '',
        [Parameter(Mandatory)][string[]]$Options,
        [string[]]$Descriptions = @(),  # optional, parallel to Options; shown for the highlighted item
        [string]$BackLabel = 'Back',
        [string]$DefaultChoice = ''
    )
    if ($script:NonInteractive) {
        throw "Headless mode cannot present the '$Title' menu - use a CLI command instead (see 'UEFNKit.ps1 help')."
    }
    if ($Title -ne '') { Write-Head $Title }

    if (-not (Test-InteractiveConsole)) {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $Options[$i])
        }
        Write-Host ("  [B] {0}" -f $BackLabel)
        while ($true) {
            if ($DefaultChoice -ne '') {
                Write-Host "Choice [Enter = $DefaultChoice]: " -ForegroundColor White -NoNewline
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

    # Interactive mode: Back/Quit is the last selectable item.
    $items = @($Options) + @($BackLabel)
    $backIndex = $items.Count - 1
    $sel = 0
    $n0 = 0
    if ($DefaultChoice -ne '' -and [int]::TryParse($DefaultChoice, [ref]$n0) -and $n0 -ge 1 -and $n0 -le $Options.Count) {
        $sel = $n0 - 1
    }

    # Lines longer than the console width would wrap and break in-place redrawing.
    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    $view = [Math]::Min($items.Count, [Math]::Max(4, [Console]::WindowHeight - 7))
    $offset = [Math]::Max(0, [Math]::Min($sel, $items.Count - $view))
    $hasDescs = ($Descriptions.Count -gt 0)
    $totalLines = $view + 1 + $(if ($hasDescs) { 1 } else { 0 })

    # Reserve the lines first so the top row is stable even if the buffer scrolls.
    for ($i = 0; $i -lt $totalLines; $i++) { Write-Host '' }
    $top = [Console]::CursorTop - $totalLines

    $cursorWasVisible = $true
    try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }
    try {
        while ($true) {
            if ($sel -lt $offset) { $offset = $sel }
            if ($sel -ge ($offset + $view)) { $offset = $sel - $view + 1 }

            [Console]::SetCursorPosition(0, $top)
            for ($row = 0; $row -lt $view; $row++) {
                $i = $offset + $row
                $num = if ($i -eq $backIndex) { ' B' } else { '{0,2}' -f ($i + 1) }
                $line = "$num. $($items[$i])"
                if ($line.Length -gt ($width - 5)) { $line = $line.Substring(0, $width - 8) + '...' }
                if ($i -eq $sel) {
                    Write-Host ('> ' + $line).PadRight($width) -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host ('  ' + $line).PadRight($width)
                }
            }
            if ($hasDescs) {
                $desc = if ($sel -lt $Descriptions.Count -and $null -ne $Descriptions[$sel]) { "$($Descriptions[$sel])" } else { '' }
                if ($desc.Length -gt ($width - 5)) { $desc = $desc.Substring(0, $width - 8) + '...' }
                Write-Host ('    ' + $desc).PadRight($width) -ForegroundColor DarkGray
            }
            $scrollNote = if ($items.Count -gt $view) { " ($($sel + 1)/$($items.Count))" } else { '' }
            $hint = "  Up/Down move, Enter select, Esc = $BackLabel$scrollNote"
            if ($hint.Length -gt $width) { $hint = $hint.Substring(0, $width) }
            # No trailing newline on the last reserved row, or the buffer scrolls each redraw.
            Write-Host $hint.PadRight($width) -ForegroundColor DarkGray -NoNewline

            $key = [Console]::ReadKey($true)
            $confirmed = $false
            switch ($key.Key) {
                'UpArrow'   { $sel = ($sel - 1 + $items.Count) % $items.Count }
                'DownArrow' { $sel = ($sel + 1) % $items.Count }
                'Home'      { $sel = 0 }
                'End'       { $sel = $items.Count - 1 }
                'Enter'     { $confirmed = $true }
                'Escape'    { $sel = $backIndex; $confirmed = $true }
                'B'         { $sel = $backIndex; $confirmed = $true }
                'Q'         { $sel = $backIndex; $confirmed = $true }
                default {
                    $ch = $key.KeyChar
                    if ($ch -ge '1' -and $ch -le '9') {
                        $n = [int]$ch - [int][char]'0'
                        if ($n -le $Options.Count) { $sel = $n - 1; $confirmed = $true }
                    }
                }
            }
            if ($confirmed) { break }
        }

        # Blank the desc/hint lines and leave a one-line record of the choice.
        [Console]::SetCursorPosition(0, $top + $view)
        if ($hasDescs) { Write-Host (' ' * $width) }
        Write-Host (' ' * $width) -NoNewline
        [Console]::SetCursorPosition(0, $top + $view)
        Write-Host 'Selected: ' -ForegroundColor DarkGray -NoNewline
        Write-Host $items[$sel] -ForegroundColor Cyan
    } finally {
        try { [Console]::CursorVisible = $cursorWasVisible } catch { }
    }

    if ($sel -eq $backIndex) { return -1 }
    return $sel
}

#endregion

#region Settings

function Get-UefnKitSettings {
    $defaults = [pscustomobject]@{
        settingsVersion      = 1
        catalogUrl           = $script:DefaultCatalogUrl
        projectsPathOverride = ''
    }
    $readPath = $script:SettingsPath
    if (-not (Test-Path -LiteralPath $readPath)) {
        if (Test-Path -LiteralPath $script:LegacySettingsPath) { $readPath = $script:LegacySettingsPath }
        else { return $defaults }
    }
    try {
        $loaded = Get-Content -LiteralPath $readPath -Raw | ConvertFrom-Json
        foreach ($p in @('catalogUrl', 'projectsPathOverride')) {
            $prop = $loaded.PSObject.Properties[$p]
            if ($null -ne $prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
                $defaults.$p = "$($prop.Value)"
            }
        }
        # A legacy settings file pointing at the old default catalog means "default".
        if ($defaults.catalogUrl -eq $script:LegacyDefaultCatalogUrl) {
            $defaults.catalogUrl = $script:DefaultCatalogUrl
        }
    } catch {
        Write-Warn "Settings file was unreadable and has been ignored ($readPath)."
    }
    return $defaults
}

function Save-UefnKitSettings {
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
    $settings = Get-UefnKitSettings
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
    # Best-effort detection from two sources, keeping the newest:
    #  - the launcher manifest's Fortnite_Studio (= UEFN) entry - NOT the first Fortnite
    #    artifact in the file, which can be the game client or a stale sidecar
    #  - UEFN's own log, i.e. the build that actually last ran on this machine
    # Non-launcher/internal UEFN builds may be invisible to both, so callers must treat
    # this as advisory (warn, never block).
    $rxVer = '\+\+Fortnite\+Release-([\d.]+)-CL-(\d+)'
    $candidates = @()

    if (Test-Path -LiteralPath $script:LauncherDat) {
        try {
            $dat = Get-Content -LiteralPath $script:LauncherDat -Raw | ConvertFrom-Json
            $entries = @($dat.InstallationList)
            $picks = @($entries | Where-Object { $_.AppName -eq 'Fortnite_Studio' })
            if ($picks.Count -eq 0) { $picks = $entries }
            foreach ($e in $picks) {
                if ("$($e.AppVersion)" -match $rxVer) {
                    $candidates += [pscustomobject]@{ Version = $Matches[1]; CL = $Matches[2]; Source = 'Epic launcher manifest' }
                }
            }
        } catch { }
    }
    if (Test-Path -LiteralPath $script:UefnLogPath) {
        try {
            # The LogInit build banner sits near the top; don't read multi-MB logs fully.
            foreach ($line in (Get-Content -LiteralPath $script:UefnLogPath -TotalCount 3000 -ErrorAction Stop)) {
                if ($line -match ('LogInit: Build: ' + $rxVer)) {
                    $candidates += [pscustomobject]@{ Version = $Matches[1]; CL = $Matches[2]; Source = 'UEFN log (last run)' }
                    break
                }
            }
        } catch { }
    }

    if ($candidates.Count -eq 0) { return $null }
    $best = $candidates[0]
    foreach ($c in $candidates) {
        $cmp = Test-VersionCompatible -Required $best.Version -Installed $c.Version
        if ($cmp -eq $true -and $c.Version -ne $best.Version) { $best = $c }
    }
    return $best
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
            # No size scan here: recursively measuring every project makes the picker crawl.
            $results += [pscustomobject]@{
                Info = $info
                Root = $root
            }
        }
    }
    # Variant detection: a project whose projectId appears in another project's
    # variants.lock.json is a generated variant of that root. The lock is the single
    # source of truth - no marker files inside variants, nothing to go stale.
    $ownerByProjectId = @{}
    foreach ($p in $results) {
        $lockPath = Join-Path $p.Info.FolderPath 'variants.lock.json'
        if (-not (Test-Path -LiteralPath $lockPath)) { continue }
        try {
            $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
            if ($lock.PSObject.Properties['variants']) {
                foreach ($vp in $lock.variants.PSObject.Properties) {
                    $vid = "$($vp.Value.projectId)"
                    if ($vid -ne '') { $ownerByProjectId[$vid] = $p.Info.Name }
                }
            }
        } catch { }
    }
    foreach ($p in $results) {
        $variantOf = ''
        if ($ownerByProjectId.ContainsKey($p.Info.ProjectId) -and $ownerByProjectId[$p.Info.ProjectId] -ne $p.Info.Name) {
            $variantOf = $ownerByProjectId[$p.Info.ProjectId]
        }
        $p | Add-Member -NotePropertyName VariantOf -NotePropertyValue $variantOf
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

function Set-JsonRawValue {
    # Replaces a non-string scalar (number or bool) under a uniquely-keyed field.
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$NewRaw
    )
    $pattern = '("' + [regex]::Escape($Key) + '"\s*:\s*)(-?\d+(?:\.\d+)?|true|false)'
    $rx = New-Object regex($pattern)
    $count = $rx.Matches($Text).Count
    if ($count -ne 1) {
        throw "Expected exactly 1 occurrence of JSON key '$Key' but found $count. Aborting to avoid corruption."
    }
    $evaluator = { param($m) $m.Groups[1].Value + $NewRaw }.GetNewClosure()
    return $rx.Replace($Text, $evaluator)
}

function ConvertTo-PrettyJson {
    # Minimal tab-indented JSON writer for tool-owned files (manifest, lock). Invariant
    # culture for numbers; handles hashtables (ordered), PSCustomObjects, arrays, scalars.
    param($Value, [int]$IndentLevel = 0)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $ind = "`t" * $IndentLevel
    $indIn = "`t" * ($IndentLevel + 1)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return '"' + (ConvertTo-JsonStringLiteral $Value) + '"' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or
        $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return $Value.ToString($inv)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Keys.Count -eq 0) { return '{}' }
        $parts = foreach ($k in $Value.Keys) {
            $indIn + '"' + (ConvertTo-JsonStringLiteral ([string]$k)) + '": ' + (ConvertTo-PrettyJson $Value[$k] ($IndentLevel + 1))
        }
        return "{`r`n" + ($parts -join ",`r`n") + "`r`n$ind}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) { $indIn + (ConvertTo-PrettyJson $item ($IndentLevel + 1)) }
        return "[`r`n" + ($parts -join ",`r`n") + "`r`n$ind]"
    }
    if ($Value -is [psobject]) {
        $props = @($Value.PSObject.Properties)
        if ($props.Count -eq 0) { return '{}' }
        $parts = foreach ($p in $props) {
            $indIn + '"' + (ConvertTo-JsonStringLiteral $p.Name) + '": ' + (ConvertTo-PrettyJson $p.Value ($IndentLevel + 1))
        }
        return "{`r`n" + ($parts -join ",`r`n") + "`r`n$ind}"
    }
    return '"' + (ConvertTo-JsonStringLiteral ([string]$Value)) + '"'
}

function Write-JsonPretty {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-TextFileNoBom -Path $Path -Text ((ConvertTo-PrettyJson $Value) + "`r`n")
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
        $NewDescription = $null,  # untyped: [string] would coerce $null to '' and blank descriptions
        [string]$ProjectId = '',            # keep a specific id (variant regen); '' = fresh
        [hashtable]$ModuleGuidMap = $null,  # module name -> guid to keep; missing names get fresh
        [string]$ProjectVersePath = ''      # preserved binding for variant regen; '' = unbound
    )
    $text = Read-TextFileRaw $Path
    $newId = if ($ProjectId -ne '') { $ProjectId } else { New-ProjectGuid }
    $text = Set-JsonGuidValue -Text $text -Key 'projectId' -NewGuid $newId
    foreach ($m in $ModuleNames) {
        $g = if ($ModuleGuidMap -and $ModuleGuidMap.ContainsKey($m) -and "$($ModuleGuidMap[$m])" -ne '') {
            "$($ModuleGuidMap[$m])"
        } else {
            [guid]::NewGuid().ToString()
        }
        $text = Set-JsonGuidValue -Text $text -Key $m -NewGuid $g
    }
    $text = Set-JsonScalar -Text $text -Key 'projectVersePath' -NewValue $ProjectVersePath
    $text = Set-JsonScalar -Text $text -Key 'title' -NewValue $NewTitle
    if ($null -ne $NewDescription) {
        $text = Set-JsonScalar -Text $text -Key 'description' -NewValue ([string]$NewDescription)
    }
    Write-TextFileNoBom -Path $Path -Text $text
}

function Update-UpluginFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$NewVersePath
    )
    $text = Read-TextFileRaw $Path
    $text = Set-JsonScalar -Text $text -Key 'VersePath' -NewValue $NewVersePath
    Write-TextFileNoBom -Path $Path -Text $text
}

function Test-SanitizedProject {
    # Post-write validation; sanitize always runs on a staging copy, so a throw here aborts cleanly.
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [Parameter(Mandatory)]$Pre,
        [Parameter(Mandatory)][string]$ExpectedVersePath
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
    if ("$($plugJson.VersePath)" -ne $ExpectedVersePath) {
        throw "Sanitize validation failed: uplugin VersePath is '$($plugJson.VersePath)', expected '$ExpectedVersePath'."
    }
    if ($post.PluginName -ne $Pre.PluginName) { throw 'Sanitize validation failed: plugin name changed.' }
    return $post
}

#endregion

#region Verse source rewrite

function Update-VerseSources {
    # Rewrites the project's own Verse path prefix in .verse text sources. While unbound,
    # UEFN mounts a project's Verse modules at /invaliddomain/<ProjectName> - the PROJECT
    # name (folder/.uefnproject basename), NOT the plugin name - so every rewritten using
    # must target exactly that, and a rename must re-run this. Binary assets are never
    # touched; UEFN's redirector fixes those on open.
    param(
        [Parameter(Mandatory)][string]$ContentDir,
        [string[]]$OldVersePaths = @(),
        [string[]]$OldProjectNames = @(),
        [Parameter(Mandatory)][string]$NewVersePath
    )
    if (-not (Test-Path -LiteralPath $ContentDir)) { return 0 }
    $changed = 0
    foreach ($file in (Get-ChildItem -LiteralPath $ContentDir -Recurse -Filter '*.verse' -File -ErrorAction SilentlyContinue)) {
        $text = Read-TextFileRaw $file.FullName
        $new = $text
        foreach ($old in $OldVersePaths) {
            if ($old -ne '' -and $old -ne $NewVersePath) { $new = $new.Replace($old, $NewVersePath) }
        }
        # Residue catch: any account-qualified reference to THIS project (never other creators' libraries).
        foreach ($oldName in $OldProjectNames) {
            $residue = '/[\w.+-]+@fortnite\.com/' + [regex]::Escape($oldName)
            $new = [regex]::Replace($new, $residue, $NewVersePath)
        }
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
        $NewDescription = $null,  # untyped on purpose; see Update-UefnProjectFile
        [string]$NewProjectName = ''  # final .uefnproject/folder name; drives the Verse path
    )
    $pre = Get-ProjectInfo -FolderPath $StagingPath
    if ($NewProjectName -eq '') { $NewProjectName = $pre.Name }
    $sentinel = "$script:VerseSentinelRoot/$NewProjectName"

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
    Update-UpluginFile -Path $pre.UpluginFile -NewVersePath $sentinel
    # Old prefixes: the bound account path (if any) plus the staged name's sentinel, which
    # covers reinstalling an already-exported package under a different name.
    $oldPaths = @("$script:VerseSentinelRoot/$($pre.Name)")
    if ($pre.ProjectVersePath -ne '') { $oldPaths = @($pre.ProjectVersePath) + $oldPaths }
    $verseChanged = Update-VerseSources -ContentDir (Join-Path $StagingPath 'Content') `
        -OldVersePaths $oldPaths -OldProjectNames @($pre.Name) -NewVersePath $sentinel
    if ($verseChanged -gt 0) { Write-Info "Rewrote Verse paths in $verseChanged .verse file(s) to $sentinel" }

    return Test-SanitizedProject -FolderPath $StagingPath -Pre $pre -ExpectedVersePath $sentinel
}

#endregion

#region Staging and zip

function New-StagingDir {
    # Deliberately short path: PS 5.1 zip/copy APIs hit MAX_PATH easily.
    $base = Join-Path $env:TEMP 'uefnkit'
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
            $request.UserAgent = "UEFNKit/$script:ToolVersion"
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

#region Variants

# dataSets.matchmaking keys the tool may patch, with their JSON kind. 'version' is
# deliberately absent: the key name is not unique inside the .uefnproject.
$script:MatchmakingKeys = @{
    maxPlayers = 'num'; maxTeamCount = 'num'; maxTeamSize = 'num'; maxSocialPartySize = 'num'
    minPlayers = 'num'; overtimePlayerTarget = 'num'; queueMainDuration = 'num'; queueOvertimeDuration = 'num'
    allowJoinInProgress = 'bool'; allowSquadFillOption = 'bool'; useSkillBasedMatchmaking = 'bool'; splitscreenDisabled = 'bool'
    islandQueuePrivacy = 'str'; ratingType = 'str'
}

function Get-VariantsManifest {
    # Loads and validates <root>\variants.json. Returns @{ Defaults; Variants } where each
    # variant is normalized to Suffix/Name/Title/Matchmaking/VerseConfig.
    param([Parameter(Mandatory)]$RootInfo)
    $path = Join-Path $RootInfo.FolderPath 'variants.json'
    $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $defaults = if ($json.PSObject.Properties['defaults']) { $json.defaults } else { $null }
    if ($null -eq $json.PSObject.Properties['variants'] -or @($json.variants).Count -eq 0) {
        throw "variants.json has no 'variants' array (or it is empty)."
    }
    $seen = @()
    $variants = foreach ($v in @($json.variants)) {
        $suffix = "$($v.suffix)"
        if ($suffix -notmatch '^[A-Za-z0-9_]+$') { throw "Variant suffix '$suffix' is invalid (letters, digits, underscore only)." }
        $name = if ($v.PSObject.Properties['name'] -and "$($v.name)" -ne '') { "$($v.name)" } else { "$($RootInfo.Name)$suffix" }
        if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw "Variant project name '$name' is invalid (must start with a letter; letters, digits, underscore only)." }
        if ($name -eq $RootInfo.Name) { throw "Variant '$suffix' resolves to the root project's own name." }
        if ($seen -contains $name) { throw "Two variants resolve to the same project name '$name'." }
        $seen += $name
        $mm = if ($v.PSObject.Properties['matchmaking']) { $v.matchmaking } else { $null }
        if ($mm) {
            foreach ($p in $mm.PSObject.Properties) {
                if (-not $script:MatchmakingKeys.ContainsKey($p.Name)) {
                    throw "Variant '$suffix': unknown matchmaking key '$($p.Name)'. Allowed: $(($script:MatchmakingKeys.Keys | Sort-Object) -join ', ')"
                }
            }
        }
        $vc = if ($v.PSObject.Properties['verseConfig']) { $v.verseConfig } else { $null }
        if ($vc) {
            foreach ($p in $vc.PSObject.Properties) {
                if ($p.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Variant '$suffix': verseConfig key '$($p.Name)' is not a valid Verse identifier." }
            }
        }
        [pscustomobject]@{
            Suffix = $suffix; Name = $name
            Title = if ($v.PSObject.Properties['title'] -and "$($v.title)" -ne '') { "$($v.title)" } else { $name }
            Matchmaking = $mm; VerseConfig = $vc
        }
    }
    return @{ Defaults = $defaults; Variants = @($variants) }
}

function Merge-VerseConfig {
    # defaults first, per-variant overrides on top; order preserved for stable output.
    param($Defaults, $Overrides)
    $merged = [ordered]@{}
    foreach ($src in @($Defaults, $Overrides)) {
        if ($null -eq $src) { continue }
        foreach ($p in $src.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    }
    return $merged
}

function ConvertTo-VerseLiteral {
    # Maps a JSON value to a Verse type + literal. Verse strings interpolate {}, so braces
    # must be escaped alongside the usual characters.
    param($Value)
    if ($Value -is [bool]) {
        return @{ Type = 'logic'; Literal = $(if ($Value) { 'true' } else { 'false' }) }
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16]) {
        return @{ Type = 'int'; Literal = $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        $lit = $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        if ($lit -notmatch '[.eE]') { $lit += '.0' }
        return @{ Type = 'float'; Literal = $lit }
    }
    $s = "$Value"
    $escaped = $s.Replace('\', '\\').Replace('"', '\"').Replace('{', '\{').Replace('}', '\}')
    return @{ Type = 'string'; Literal = '"' + $escaped + '"' }
}

function Write-VariantConfigVerse {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )
    if ($Values.Keys.Count -eq 0) { return }
    $lines = @(
        '# Generated by UEFNKit from variants.json. Do not edit by hand -'
        "# rerun 'Generate variants' on the root project instead."
        'VariantConfig<public> := module:'
    )
    foreach ($k in $Values.Keys) {
        $lit = ConvertTo-VerseLiteral $Values[$k]
        $lines += "    $k<public>:$($lit.Type) = $($lit.Literal)"
    }
    Write-TextFileNoBom -Path $Path -Text (($lines -join "`r`n") + "`r`n")
}

function Update-MatchmakingSettings {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Settings
    )
    $text = Read-TextFileRaw $Path
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($p in $Settings.PSObject.Properties) {
        switch ($script:MatchmakingKeys[$p.Name]) {
            'str' { $text = Set-JsonScalar -Text $text -Key $p.Name -NewValue "$($p.Value)" }
            'bool' { $text = Set-JsonRawValue -Text $text -Key $p.Name -NewRaw $(if ($p.Value) { 'true' } else { 'false' }) }
            default { $text = Set-JsonRawValue -Text $text -Key $p.Name -NewRaw ([double]$p.Value).ToString($inv) }
        }
    }
    Write-TextFileNoBom -Path $Path -Text $text
}

function Invoke-VariantGeneration {
    # Generates/updates each manifest variant next to the root. Overwrites preserve the
    # variant's identity (projectId, module GUIDs, Verse binding, .lore history) so an
    # already-published variant keeps its link to the published island across updates.
    param([Parameter(Mandatory)]$RootInfo, [Parameter(Mandatory)]$Manifest)
    $parentDir = Split-Path -Parent $RootInfo.FolderPath
    $lockPath = Join-Path $RootInfo.FolderPath 'variants.lock.json'
    $lock = $null
    if (Test-Path -LiteralPath $lockPath) {
        try { $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json } catch { }
    }
    $lockOut = [ordered]@{}
    $done = 0

    # Root gets the pure-defaults config so it stays compilable and playable.
    if ($Manifest.Defaults -and @($Manifest.Defaults.PSObject.Properties).Count -gt 0) {
        Write-VariantConfigVerse -Path (Join-Path $RootInfo.FolderPath 'Content\VariantConfig.verse') `
            -Values (Merge-VerseConfig $Manifest.Defaults $null)
        Write-Info 'Root Content\VariantConfig.verse refreshed from defaults.'
    }

    foreach ($v in $Manifest.Variants) {
        try {
            $dest = Join-Path $parentDir $v.Name
            $existing = $null
            if (Test-Path -LiteralPath $dest) {
                $pf = @(Get-ChildItem -LiteralPath $dest -Filter '*.uefnproject' -File -ErrorAction SilentlyContinue)
                if ($pf.Count -eq 0) {
                    Write-Err "Skipping '$($v.Name)': a folder with that name exists but is not a UEFN project - not touching it."
                    continue
                }
                $existing = Get-ProjectInfo -FolderPath $dest
                Write-Warn "Variant project '$($v.Name)' already exists."
                Write-Info 'Overwriting replaces its content with the root''s (manual content changes in the variant are lost).'
                Write-Info 'Its identity - projectId, Verse binding, revision-control history - is preserved.'
                if (-not (Read-YesNo "Overwrite '$($v.Name)'?" -Default $true)) {
                    Write-Info "Skipped '$($v.Name)'."
                    if ($existing) { $lockOut[$v.Suffix] = [ordered]@{ name = $v.Name; projectId = $existing.ProjectId; modules = $existing.Modules } }
                    continue
                }
            }

            # Identity: existing project on disk wins; else the lock (recreates a deleted
            # variant with its published identity); else fresh.
            $keepId = ''; $keepModules = $null; $keepVersePath = ''
            if ($existing) {
                $keepId = $existing.ProjectId
                $keepModules = $existing.Modules
                $keepVersePath = $existing.ProjectVersePath
            } elseif ($lock -and $lock.PSObject.Properties['variants'] -and $lock.variants.PSObject.Properties[$v.Suffix]) {
                $le = $lock.variants.($v.Suffix)
                $keepId = "$($le.projectId)"
                $keepModules = @{}
                foreach ($p in $le.modules.PSObject.Properties) { $keepModules[$p.Name] = "$($p.Value)" }
                Write-Info "Recreating '$($v.Name)' with its previous identity from variants.lock.json."
            }
            $variantVersePath = if ($keepVersePath -ne '') { $keepVersePath } else { "$script:VerseSentinelRoot/$($v.Name)" }

            # Stage a copy of the root (manifest/lock and RC/history never propagate).
            $staging = New-StagingDir
            $stagedRoot = Copy-ProjectToStaging -SourceDir $RootInfo.FolderPath -StagingDir $staging `
                -ExcludeTopLevel @('.lore', '.urc', '.git', 'variants.json', 'variants.lock.json')
            Get-ChildItem -LiteralPath $stagedRoot -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force

            $upf = Join-Path $stagedRoot "$($RootInfo.Name).uefnproject"
            Update-UefnProjectFile -Path $upf -NewTitle $v.Title -ModuleNames @($RootInfo.Modules.Keys) `
                -ProjectId $keepId -ModuleGuidMap $keepModules -ProjectVersePath $keepVersePath
            if ($v.Matchmaking) { Update-MatchmakingSettings -Path $upf -Settings $v.Matchmaking }
            Rename-Item -LiteralPath $upf -NewName "$($v.Name).uefnproject"

            Update-UpluginFile -Path (Join-Path $stagedRoot "$($RootInfo.PluginName).uplugin") -NewVersePath $variantVersePath

            $oldPaths = @("$script:VerseSentinelRoot/$($RootInfo.Name)")
            if ($RootInfo.ProjectVersePath -ne '') { $oldPaths = @($RootInfo.ProjectVersePath) + $oldPaths }
            $null = Update-VerseSources -ContentDir (Join-Path $stagedRoot 'Content') `
                -OldVersePaths $oldPaths -OldProjectNames @($RootInfo.Name) -NewVersePath $variantVersePath

            $cfg = Merge-VerseConfig $Manifest.Defaults $v.VerseConfig
            if ($cfg.Keys.Count -gt 0) {
                Write-VariantConfigVerse -Path (Join-Path $stagedRoot 'Content\VariantConfig.verse') -Values $cfg
            }

            # Swap into place: everything is replaced EXCEPT the variant's own RC history.
            if ($existing) {
                Clear-ReadOnlyFlags -Path $dest
                Get-ChildItem -LiteralPath $dest -Force |
                    Where-Object { $_.Name -notin @('.lore', '.urc', '.git') } |
                    Remove-Item -Recurse -Force -ErrorAction Stop
            } else {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            Get-ChildItem -LiteralPath $stagedRoot -Force | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
            }
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

            $newInfo = Get-ProjectInfo -FolderPath $dest
            $lockOut[$v.Suffix] = [ordered]@{ name = $v.Name; projectId = $newInfo.ProjectId; modules = $newInfo.Modules }
            $bindNote = if ($keepVersePath -ne '') { 'kept binding ' + $keepVersePath } elseif ($keepId -ne '') { 'kept identity' } else { 'new identity' }
            Write-Ok ("Variant '{0}' {1} ({2})" -f $v.Name, $(if ($existing) { 'updated' } else { 'created' }), $bindNote)
            $done++
        } catch {
            Write-Err "Variant '$($v.Name)' failed: $($_.Exception.Message)"
        }
    }
    Write-JsonPretty -Path $lockPath -Value ([ordered]@{ variants = $lockOut })
    return $done
}

function Read-IntPrompt {
    param([Parameter(Mandatory)][string]$Message, [int]$Default)
    while ($true) {
        $s = Read-Prompt $Message -Default "$Default"
        $n = 0
        if ([int]::TryParse($s, [ref]$n)) { return $n }
        Write-Warn 'Enter a whole number.'
    }
}

function New-VariantsManifestInteractive {
    # Prompt-driven creation of variants.json so nobody has to hand-write JSON.
    param([Parameter(Mandatory)]$RootInfo)
    $variants = @()
    while ($true) {
        Write-Head ("Variant {0}" -f ($variants.Count + 1))
        $suffix = ''
        while ($true) {
            $suffix = Read-Prompt ("Variant suffix (e.g. 4v4 - project will be named $($RootInfo.Name)<suffix>)")
            if ($suffix -match '^[A-Za-z0-9_]+$') { break }
            Write-Warn 'Letters, digits and underscores only.'
        }
        $title = Read-Prompt 'Variant title' -Default "$($RootInfo.Title) $suffix"
        $sizeDefault = 4; $playersDefault = 8
        if ($suffix -match '^(\d+)[vV](\d+)$') {
            $sizeDefault = [Math]::Max([int]$Matches[1], [int]$Matches[2])
            $playersDefault = [int]$Matches[1] + [int]$Matches[2]
        }
        $teamSize = Read-IntPrompt 'Max team size' $sizeDefault
        $teamCount = Read-IntPrompt 'Team count' 2
        $maxPlayers = Read-IntPrompt 'Max players' $playersDefault
        $vc = [ordered]@{}
        Write-Info 'Verse config values become constants in the generated VariantConfig module.'
        while ($true) {
            $pair = Read-Prompt 'Verse config Name=Value (Enter to finish)' -AllowEmpty
            if ($pair -eq '') { break }
            $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { Write-Warn 'Use Name=Value.'; continue }
            $k = $pair.Substring(0, $eq).Trim()
            $raw = $pair.Substring($eq + 1).Trim()
            if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Write-Warn 'Name must be a valid Verse identifier.'; continue }
            $iv = 0; $dv = [double]0
            if ($raw -match '^(true|false)$') { $vc[$k] = ($raw -ieq 'true') }
            elseif ([int]::TryParse($raw, [ref]$iv)) { $vc[$k] = $iv }
            elseif ([double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dv)) { $vc[$k] = $dv }
            else { $vc[$k] = $raw }
        }
        $variants += [ordered]@{
            suffix = $suffix
            title = $title
            matchmaking = [ordered]@{ maxTeamSize = $teamSize; maxTeamCount = $teamCount; maxPlayers = $maxPlayers }
            verseConfig = $vc
        }
        if (-not (Read-YesNo 'Add another variant?' -Default $false)) { break }
    }
    $manifest = [ordered]@{ defaults = [ordered]@{}; variants = $variants }
    Write-JsonPretty -Path (Join-Path $RootInfo.FolderPath 'variants.json') -Value $manifest
    Write-Ok "Wrote variants.json with $($variants.Count) variant(s). Edit it by hand anytime; 'defaults' holds shared Verse config values."
}

function Invoke-VariantsFlow {
    $sel = Select-LocalProject -Title 'Generate variants of a project (pick the ROOT)' -ExcludeVariants
    if ($null -eq $sel) { return }
    $info = $sel.Info

    if (-not (Test-Path -LiteralPath (Join-Path $info.FolderPath 'variants.json'))) {
        Write-Info "'$($info.Name)' has no variants.json yet."
        if (-not (Read-YesNo 'Create one now?' -Default $true)) { return }
        New-VariantsManifestInteractive -RootInfo $info
    }
    $manifest = Get-VariantsManifest -RootInfo $info

    Write-Head "Variants of '$($info.Name)'"
    foreach ($v in $manifest.Variants) {
        $state = if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $info.FolderPath) $v.Name)) { 'update existing' } else { 'create new' }
        Write-Info ("  {0}  (title: '{1}', {2})" -f $v.Name, $v.Title, $state)
    }
    if (Test-UefnRunning) {
        Write-Warn 'UEFN is running. Close it first - overwriting a project that is open in the editor will fail or leave it in a mixed state.'
        if (-not (Read-YesNo 'Continue anyway?' -Default $false)) { return }
    }
    if (-not (Read-YesNo ("Generate {0} variant(s) next to the root?" -f @($manifest.Variants).Count) -Default $true)) { return }

    $done = Invoke-VariantGeneration -RootInfo $info -Manifest $manifest
    Write-Host ''
    Write-Ok "$done variant(s) generated/updated."
    Write-Info 'Open each variant in UEFN to verify, then publish updates per variant as usual.'
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
    # Suffix style Name2/Name3: the name becomes a Verse path component, so no spaces/parens.
    if (-not (Test-Path -LiteralPath (Join-Path $Root $BaseName))) { return $BaseName }
    $i = 2
    while (Test-Path -LiteralPath (Join-Path $Root ("{0}{1}" -f $BaseName, $i))) { $i++ }
    return ("{0}{1}" -f $BaseName, $i)
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
            # Detection is advisory: internal/non-launcher UEFN builds are invisible to it.
            Write-Warn ("This project was saved with UEFN {0}. The newest UEFN detected on this machine is {1} (source: {2})." -f $info.CompatibilityVersion, $installed.Version, $installed.Source)
            Write-Info ("If your UEFN really is older than {0} the project may fail to open until UEFN updates; if the detection is wrong, just continue." -f $info.CompatibilityVersion)
            if (-not (Read-YesNo 'Continue?' -Default $true)) { return }
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
        if ($folderName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            Write-Warn 'Project names must start with a letter and use only letters, digits and underscores (the name becomes part of the Verse module path).'
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
    # The folder name is passed in because the unbound Verse path is /invaliddomain/<Name>.
    Write-Info 'Resetting project identity (new GUIDs, unbound Verse path)...'
    $info = Invoke-ProjectSanitize -StagingPath $StagedRoot -NewTitle $title -Mode $Mode -NewProjectName $folderName
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
    $settings = Get-UefnKitSettings
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

    $descs = foreach ($e in $entries) {
        if ($e.PSObject.Properties['description'] -and $e.description) { "$($e.description)" } else { '' }
    }
    $pick = Read-MenuChoice -Title $catName -Options @($labels) -Descriptions @($descs)
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
    param(
        [string]$Title = 'Select a project',
        [switch]$ExcludeVariants  # for flows that only make sense on a root project
    )
    $all = @(Get-LocalProjects)
    $projects = $all
    $hidden = @()
    if ($ExcludeVariants) {
        $projects = @($all | Where-Object { $_.VariantOf -eq '' })
        $hidden = @($all | Where-Object { $_.VariantOf -ne '' })
    }
    if ($projects.Count -eq 0) {
        Write-Warn "No UEFN projects found under: $((Get-AllProjectRoots) -join '; ')"
        return $null
    }
    if ($Title -ne '') { Write-Head $Title }
    if ($hidden.Count -gt 0) {
        Write-Info ("({0} generated variant(s) hidden: {1} - pick their root instead)" -f $hidden.Count, (@($hidden | ForEach-Object { $_.Info.Name }) -join ', '))
    }
    $labels = foreach ($p in $projects) {
        $bound = if ($p.Info.IsBound) { $p.Info.ProjectVersePath } else { 'unbound' }
        $tag = if ($p.VariantOf -ne '') { ", variant of $($p.VariantOf)" } else { '' }
        "{0}  (title: '{1}', {2}{3})" -f $p.Info.Name, $p.Info.Title, $bound, $tag
    }
    $descs = @($projects | ForEach-Object { $_.Info.FolderPath })
    $pick = Read-MenuChoice -Options @($labels) -Descriptions $descs
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

    $newFolder = Read-Prompt 'New folder name' -Default (Get-UniqueFolderName -Root $sel.Root -BaseName $info.Name)
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

function Get-PublisherRepoRoot {
    # Publisher mode: the script runs from a checkout that holds the catalog (index.json +
    # .git). Consumers running via 'irm | iex' have no $PSScriptRoot and never see this.
    if (-not $PSScriptRoot) { return $null }
    if ((Test-Path -LiteralPath (Join-Path $PSScriptRoot 'index.json')) -and
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.git'))) {
        return $PSScriptRoot
    }
    return $null
}

function Test-PublisherEnvironment {
    if ($null -eq (Get-PublisherRepoRoot)) { return $false }
    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { return $false }
    & gh auth status *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-RepoSlug {
    # owner/name from the repo's origin remote; $null when there is no usable remote.
    param([Parameter(Mandatory)][string]$Repo)
    $remote = (& git -C $Repo remote get-url origin 2>$null | Select-Object -First 1)
    if (-not $remote) { return $null }
    $slug = $remote.Trim() -replace '^https://github\.com/', '' -replace '^git@github\.com:', '' -replace '\.git$', ''
    if ($slug -match '^[^/]+/[^/]+$') { return $slug }
    return $null
}

function Get-ManagedCatalogInfo {
    # Catalog management is offered ONLY when the tool can prove the configured catalog is
    # the one in the repo it runs from: the catalog URL's GitHub slug equals the local
    # repo's origin slug, or the URL is a direct path to this repo's index.json.
    $repo = Get-PublisherRepoRoot
    if ($null -eq $repo) { return $null }
    $slug = Get-RepoSlug -Repo $repo
    if ($null -eq $slug) { return $null }
    $indexPath = Join-Path $repo 'index.json'
    $url = (Get-UefnKitSettings).catalogUrl
    $owned = $false
    if ($url -match '^https://raw\.githubusercontent\.com/([^/]+/[^/]+)/(?:refs/heads/)?[^/]+/index\.json$') {
        $owned = ($Matches[1] -ieq $slug)
    } elseif ($url -match '^[A-Za-z]:' -or $url -match '^file://') {
        $p = if ($url -match '^file://') { ([uri]$url).LocalPath } else { $url }
        try { $owned = ([System.IO.Path]::GetFullPath($p) -ieq [System.IO.Path]::GetFullPath($indexPath)) } catch { }
    }
    if (-not $owned) { return $null }
    return @{ Repo = $repo; Slug = $slug; IndexPath = $indexPath }
}

function Write-CatalogJson {
    # Serializes the catalog in the same tab-indented, human-editable style as the repo's
    # index.json. ConvertTo-Json is avoided: it reformats, \uXXXX-escapes, and writes
    # locale-dependent-looking output that makes hand edits unpleasant.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Name = '',
        [string]$Description = '',
        [array]$Projects = @()
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $keys = @('id', 'name', 'title', 'description', 'author', 'version',
              'uefnCompatibilityVersion', 'sizeMB', 'sha256', 'downloadUrl',
              'tags', 'screenshotUrl', 'readmeUrl')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`r`n")
    [void]$sb.Append("`t""schemaVersion"": 1,`r`n")
    [void]$sb.Append("`t""name"": ""$(ConvertTo-JsonStringLiteral $Name)"",`r`n")
    [void]$sb.Append("`t""description"": ""$(ConvertTo-JsonStringLiteral $Description)"",`r`n")
    [void]$sb.Append("`t""updated"": ""$(Get-Date -Format 'yyyy-MM-dd')"",`r`n")
    [void]$sb.Append("`t""projects"": [")
    for ($i = 0; $i -lt $Projects.Count; $i++) {
        $p = $Projects[$i]
        $lines = @()
        foreach ($key in $keys) {
            $prop = $p.PSObject.Properties[$key]
            if ($null -eq $prop -or $null -eq $prop.Value) { continue }
            $v = $prop.Value
            if ($v -is [string]) {
                $lines += "`t`t`t""$key"": ""$(ConvertTo-JsonStringLiteral $v)"""
            } elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
                # Invariant culture: a comma decimal separator would corrupt the JSON.
                $lines += "`t`t`t""$key"": $($v.ToString($inv))"
            } elseif ($v -is [array]) {
                $items = @($v | ForEach-Object { '"' + (ConvertTo-JsonStringLiteral ([string]$_)) + '"' })
                $lines += "`t`t`t""$key"": [$($items -join ', ')]"
            }
        }
        [void]$sb.Append("`r`n`t`t{`r`n")
        [void]$sb.Append(($lines -join ",`r`n"))
        [void]$sb.Append("`r`n`t`t}")
        if ($i -lt ($Projects.Count - 1)) { [void]$sb.Append(',') }
    }
    if ($Projects.Count -gt 0) { [void]$sb.Append("`r`n`t") }
    [void]$sb.Append("]`r`n}`r`n")
    Write-TextFileNoBom -Path $Path -Text $sb.ToString()
}

function Invoke-CatalogPublish {
    # One-command publish: GitHub release with the zip, index.json update, commit, push.
    # Returns $true on success; any failure returns $false so the caller can fall back to
    # the manual instructions.
    param(
        [Parameter(Mandatory)]$Entry,   # pscustomobject catalog entry
        [Parameter(Mandatory)][string]$ZipPath
    )
    $repo = Get-PublisherRepoRoot
    try {
        $slug = Get-RepoSlug -Repo $repo
        if (-not $slug) { Write-Err 'No usable git remote named origin in the catalog repo.'; return $false }
        $tag = "$($Entry.id)-$($Entry.version)"

        & gh release view $tag -R $slug *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Err "A release tagged '$tag' already exists on $slug. Bump the version and re-export."
            return $false
        }

        Write-Info "Creating release '$tag' on $slug and uploading $(Split-Path $ZipPath -Leaf)..."
        $notes = if ("$($Entry.description)" -ne '') { "$($Entry.description)" } else { 'Published with UEFNKit.' }
        & gh release create $tag $ZipPath -R $slug --title "$($Entry.title) $($Entry.version)" --notes $notes
        if ($LASTEXITCODE -ne 0) { Write-Err 'gh release create failed.'; return $false }
        $Entry.downloadUrl = "https://github.com/$slug/releases/download/$tag/$(Split-Path $ZipPath -Leaf)"

        # Sync BEFORE touching index.json: pull-with-rebase needs a clean tree, and reading
        # the catalog after the pull merges the entry against the latest remote state.
        & git -C $repo pull --rebase --autostash --quiet origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'Could not sync with the remote first - continuing with the local index.json.'
        }

        $indexPath = Join-Path $repo 'index.json'
        $catalog = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
        $kept = @(@($catalog.projects) | Where-Object { "$($_.id)" -ne "$($Entry.id)" })
        $replaced = (@($catalog.projects).Count -ne $kept.Count)
        Write-CatalogJson -Path $indexPath -Name "$($catalog.name)" -Description "$($catalog.description)" `
            -Projects ($kept + @($Entry))

        & git -C $repo add index.json
        & git -C $repo commit --quiet -m "Add $($Entry.name) v$($Entry.version) to catalog"
        if ($LASTEXITCODE -ne 0) { Write-Err 'git commit failed - index.json was updated but not committed.'; return $false }
        & git -C $repo push --quiet origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Err 'git push failed. The catalog change is committed locally - push it manually.'
            return $false
        }

        Write-Ok "Release: $($Entry.downloadUrl)"
        $note = if ($replaced) { ' (replaced the previous version of this entry)' } else { '' }
        Write-Ok "Catalog updated and pushed$note. Visible in Browse within ~5 minutes."
        return $true
    } catch {
        Write-Err "Publish failed: $($_.Exception.Message)"
        return $false
    }
}

function Show-ExportLint {
    # Pre-flight shareability report, run on the SOURCE project so file:line references
    # point at the publisher's real files.
    param([Parameter(Mandatory)]$Info)
    Write-Head 'Pre-flight report'
    $shareMB = Get-FolderSizeMB -Path $Info.FolderPath -ExcludeTopLevel @('.lore', '.git')
    $compat = if ($Info.CompatibilityVersion) { $Info.CompatibilityVersion } else { 'unknown' }
    Write-Info ("Recipients need UEFN {0}+.  Package content: ~{1} MB before compression." -f $compat, $shareMB)

    $selfRefs = @()
    $externalRefs = @()
    $contentDir = Join-Path $Info.FolderPath 'Content'
    if (Test-Path -LiteralPath $contentDir) {
        $found = Get-ChildItem -LiteralPath $contentDir -Recurse -Filter '*.verse' -File -ErrorAction SilentlyContinue |
            Select-String -Pattern '/[\w.+-]+@fortnite\.com/[A-Za-z0-9_]+' -AllMatches
        foreach ($hit in $found) {
            $rel = $hit.Path.Substring($Info.FolderPath.Length + 1)
            foreach ($m in $hit.Matches) {
                $projSegment = ($m.Value -split '/')[2]
                $line = "{0}:{1}  {2}" -f $rel, $hit.LineNumber, $m.Value
                if ($projSegment -in @($Info.Name, $Info.PluginName)) { $selfRefs += $line }
                else { $externalRefs += $line }
            }
        }
    }
    if ($selfRefs.Count -gt 0) {
        Write-Warn ("{0} absolute reference(s) to this project's own Verse path (rewritten automatically on export; consider relative 'using' forms in your source):" -f $selfRefs.Count)
        foreach ($r in ($selfRefs | Select-Object -Unique)) { Write-Info "  $r" }
    }
    if ($externalRefs.Count -gt 0) {
        Write-Warn ("{0} reference(s) to OTHER creators' Verse modules - NOT rewritten, and they may not resolve on a recipient's machine:" -f $externalRefs.Count)
        foreach ($r in ($externalRefs | Select-Object -Unique)) { Write-Info "  $r" }
    }
    $urefs = @(Get-ChildItem -LiteralPath (Join-Path $Info.FolderPath 'References') -Filter '*.uref' -File -ErrorAction SilentlyContinue)
    if ($urefs.Count -gt 0) {
        Write-Warn ("{0} Fab/marketplace asset reference(s) - recipients may need the matching entitlements or assets can show up missing:" -f $urefs.Count)
        foreach ($u in $urefs) { Write-Info "  $($u.BaseName)" }
    }
    if ($selfRefs.Count -eq 0 -and $externalRefs.Count -eq 0 -and $urefs.Count -eq 0) {
        Write-Ok 'No shareability issues found.'
    }
}

function Invoke-ExportFlow {
    $sel = Select-LocalProject -Title 'Export a project for sharing'
    if ($null -eq $sel) { return }
    $info = $sel.Info

    if ($sel.VariantOf -ne '') {
        Write-Warn "'$($info.Name)' is a generated variant of '$($sel.VariantOf)'. You usually want to export the root."
        if (-not (Read-YesNo 'Export this variant anyway?' -Default $false)) { return }
    }

    Show-ExportLint -Info $info

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
        downloadUrl              = "https://github.com/magnusenebakk-epic/UEFNKit/releases/download/<tag>/$($zipItem.Name)"
    }
    $entryObj = [pscustomobject]$entry

    Write-Host ''
    Write-Ok "Packaged: $zipPath ($sizeMB MB)"

    # Publisher machine (catalog repo + authenticated gh): offer to finish the job here.
    if (Test-PublisherEnvironment) {
        Write-Host ''
        if (Read-YesNo 'Publish now? (creates the GitHub release, updates index.json, pushes)' -Default $true) {
            if (Invoke-CatalogPublish -Entry $entryObj -ZipPath $zipPath) { return }
            Write-Warn 'Automatic publish did not complete - falling back to the manual steps below.'
        }
    }

    $entryJson = $entryObj | ConvertTo-Json -Depth 5
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

function Get-ProjectSidecarPaths {
    # Editor-generated per-project state OUTSIDE the project folder. UEFN recreates all of
    # this lazily on open; removing it with the project prevents stale-state buildup.
    param([Parameter(Mandatory)]$Info)
    $ua = Join-Path $env:LOCALAPPDATA 'UnrealEditorFortnite'
    $paths = @(
        (Join-Path $ua "Saved\Config\WindowsEditor\VK_Projects\$($Info.ProjectId).ini"),
        (Join-Path $ua "Saved\VK_Projects\$($Info.ProjectId)"),
        (Join-Path $ua "Saved\VerseProject\$($Info.Name)"),
        (Join-Path $ua "Saved\VerseProject\$($Info.Name).code-workspace"),
        (Join-Path $ua "Saved\VerseSnapshot\$($Info.Name)"),
        (Join-Path $ua "Saved\SourceControl\UncontrolledChangelists_$($Info.Name).json")
    )
    # Autosaves are keyed by NAME or PLUGIN name, and installed/duplicated copies share the
    # original's plugin name - never touch an autosave key another local project also uses.
    $otherKeys = @()
    foreach ($p in @(Get-LocalProjects)) {
        if ($p.Info.FolderPath -ne $Info.FolderPath) {
            $otherKeys += @($p.Info.Name, $p.Info.PluginName)
        }
    }
    foreach ($key in @($Info.Name, $Info.PluginName)) {
        if ($otherKeys -notcontains $key) {
            $paths += Join-Path $ua "Saved\Autosaves\$key"
        }
    }
    foreach ($guid in $Info.Modules.Values) {
        $paths += Join-Path $ua "Intermediate\ValkyrieUploadTemp\$guid"
    }
    return @($paths | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
}

function Invoke-RemoveFlow {
    $sel = Select-LocalProject -Title 'Remove an installed project'
    if ($null -eq $sel) { return }
    $info = $sel.Info

    Write-Head "Remove '$($info.Name)'"
    $sizeMB = Get-FolderSizeMB -Path $info.FolderPath
    Write-Info ("Project folder: {0}  ({1} MB)" -f $info.FolderPath, $sizeMB)
    if ((Test-Path -LiteralPath (Join-Path $info.FolderPath '.lore')) -or
        (Test-Path -LiteralPath (Join-Path $info.FolderPath '.git'))) {
        Write-Warn 'This project contains revision-control history (.lore/.git) - removing it deletes that local history too.'
    }
    $sidecars = @(Get-ProjectSidecarPaths -Info $info)
    if ($sidecars.Count -gt 0) {
        Write-Info 'Editor-generated state that will also be cleaned up:'
        foreach ($s in $sidecars) { Write-Info "  $s" }
    } else {
        Write-Info 'No editor-generated sidecar state found for this project.'
    }
    if (Test-UefnRunning) {
        Write-Warn 'UEFN is running. Close it first: open files block deletion, and UEFN may recreate some state on shutdown.'
        if (-not (Read-YesNo 'Continue anyway?' -Default $false)) { return }
    }

    Write-Warn 'This permanently deletes the project from this machine. There is no undo.'
    $typed = Read-Prompt "Type the project name ($($info.Name)) to confirm"
    if ($typed -ne $info.Name) {
        Write-Err 'Name did not match - nothing was deleted.'
        return
    }
    if (-not (Read-YesNo 'Delete the project and the sidecar state listed above?' -Default $false)) { return }

    try {
        Clear-ReadOnlyFlags -Path $info.FolderPath
        Remove-Item -LiteralPath $info.FolderPath -Recurse -Force -ErrorAction Stop
        Write-Ok "Deleted $($info.FolderPath)"
    } catch {
        Write-Err "Could not delete the project folder: $($_.Exception.Message)"
        Write-Info 'If UEFN (or VS Code) has the project open, close it and try again. Sidecar state was left untouched.'
        return
    }
    foreach ($s in $sidecars) {
        try {
            Remove-Item -LiteralPath $s -Recurse -Force -ErrorAction Stop
            Write-Ok "Removed $s"
        } catch {
            Write-Warn "Could not remove $s ($($_.Exception.Message))"
        }
    }
    Write-Info 'UEFN forgets the project on its next Project Browser refresh; no other registration exists.'
}

function Invoke-CatalogEntryDelete {
    # Removes one entry from the repo's index.json, commits and pushes.
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EntryId
    )
    try {
        & git -C $Repo pull --rebase --autostash --quiet origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'Could not sync with the remote first - continuing with the local index.json.'
        }
        $indexPath = Join-Path $Repo 'index.json'
        $catalog = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
        $kept = @(@($catalog.projects) | Where-Object { "$($_.id)" -ne $EntryId })
        if (@($catalog.projects).Count -eq $kept.Count) {
            Write-Warn "No entry with id '$EntryId' found (already removed?)."
            return $false
        }
        $removed = @($catalog.projects) | Where-Object { "$($_.id)" -eq $EntryId } | Select-Object -First 1
        Write-CatalogJson -Path $indexPath -Name "$($catalog.name)" -Description "$($catalog.description)" -Projects $kept
        & git -C $Repo add index.json
        & git -C $Repo commit --quiet -m "Remove $($removed.name) from catalog"
        if ($LASTEXITCODE -ne 0) { Write-Err 'git commit failed.'; return $false }
        & git -C $Repo push --quiet origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Err 'git push failed. The change is committed locally - push it manually.'
            return $false
        }
        Write-Ok "Removed '$($removed.title)' from the catalog and pushed."
        return $true
    } catch {
        Write-Err "Delete failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-CatalogManageFlow {
    while ($true) {
        $mc = Get-ManagedCatalogInfo
        if ($null -eq $mc) {
            Write-Warn 'Catalog management is unavailable: the configured catalog URL is not the catalog in this repo.'
            return
        }
        $catalog = $null
        try { $catalog = Get-Content -LiteralPath $mc.IndexPath -Raw | ConvertFrom-Json } catch {
            Write-Err "Could not read $($mc.IndexPath): $($_.Exception.Message)"
            return
        }
        $entries = @($catalog.projects)
        Write-Head "Manage catalog ($($mc.Slug)) - delete an entry"
        if ($entries.Count -eq 0) {
            Write-Info 'The catalog has no entries.'
            return
        }
        $labels = foreach ($e in $entries) { "{0}  (id: {1}, v{2})" -f $e.title, $e.id, $e.version }
        $pick = Read-MenuChoice -Options @($labels)
        if ($pick -lt 0) { return }
        $entry = $entries[$pick]
        if (-not (Read-YesNo "Delete '$($entry.title)' (id: $($entry.id)) from the catalog?" -Default $false)) { continue }
        if (-not (Invoke-CatalogEntryDelete -Repo $mc.Repo -EntryId "$($entry.id)")) { continue }

        # Optional: also drop the release the entry pointed at (only on OUR repo).
        $tag = $null
        if ("$($entry.downloadUrl)" -match ('^https://github\.com/' + [regex]::Escape($mc.Slug) + '/releases/download/([^/]+)/')) {
            $tag = $Matches[1]
        }
        if ($tag) {
            $ghReady = $false
            if (Get-Command gh -ErrorAction SilentlyContinue) {
                & gh auth status *> $null
                $ghReady = ($LASTEXITCODE -eq 0)
            }
            if ($ghReady) {
                if (Read-YesNo "Also delete the GitHub release '$tag' and its zip? (existing download links stop working)" -Default $false) {
                    & gh release delete $tag -R $mc.Slug --yes --cleanup-tag
                    if ($LASTEXITCODE -eq 0) { Write-Ok "Release '$tag' deleted." } else { Write-Err 'gh release delete failed.' }
                }
            } else {
                Write-Info "The release '$tag' still exists on GitHub; delete it there if you want the zip gone (gh is not signed in here)."
            }
        }
    }
}

function Invoke-SettingsFlow {
    while ($true) {
        $settings = Get-UefnKitSettings
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
                Save-UefnKitSettings $settings
                Write-Ok 'Saved.'
            }
            1 {
                Write-Info "Enter a folder path, or 'auto' to use the UEFN-detected location."
                $val = Read-Prompt 'Projects folder override' -Default ($(if ($settings.projectsPathOverride) { $settings.projectsPathOverride } else { 'auto' }))
                $settings.projectsPathOverride = if ($val -ieq 'auto') { '' } else { $val }
                Save-UefnKitSettings $settings
                Write-Ok 'Saved.'
            }
            2 {
                $settings.catalogUrl = $script:DefaultCatalogUrl
                $settings.projectsPathOverride = ''
                Save-UefnKitSettings $settings
                Write-Ok 'Settings reset.'
            }
        }
    }
}

function Show-Help {
    Write-Head 'Help'
    Write-Host @"
UEFNKit installs, duplicates and packages UEFN projects.

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
  Variants           Generates variations of a root project from a variants.json
                     manifest: per-variant island matchmaking
                     settings, a generated VariantConfig Verse module of constants,
                     fresh identity on first creation. Re-running syncs the root's
                     content into existing variants after a confirmation - their
                     projectId, Verse binding and revision-control history are
                     preserved so published islands keep their update link.
  Export             Packages one of your projects into a shareable zip with all
                     of your identity stripped, and emits a catalog entry.
  Manage my catalog  Only appears for catalog owners (the configured catalog URL
                     matches the repo this tool runs from). Deletes catalog
                     entries - commits and pushes index.json - and optionally
                     deletes the entry's GitHub release via gh.
  Remove             Deletes an installed project AND the editor-generated state
                     UEFN keeps for it outside the project folder (per-project
                     config, Verse workspace/snapshot, autosaves). Asks you to
                     type the project name before deleting - there is no undo.

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

function Test-ToolUpdateAvailable {
    # Only relevant when running a downloaded copy from disk; 'irm | iex' users are always
    # current. Best-effort with a short timeout - never blocks or errors the startup.
    if (-not $PSScriptRoot) { return }
    try {
        $raw = Invoke-RestMethod -Uri $script:RawScriptUrl -UseBasicParsing -TimeoutSec 3
        if ("$raw" -match "ToolVersion\s+=\s+'([\d.]+)'") {
            $remote = [version]$Matches[1]
            if ($remote -gt [version]$script:ToolVersion) {
                Write-Warn "UEFNKit $remote is available (you are running $script:ToolVersion). Update with 'git pull' in the tool's folder, or re-download it."
            }
        }
    } catch { }
}

function Show-Banner {
    $installed = Get-InstalledUefnVersion
    $lines = @()
    $lines += @{ Text = "UEFNKit v$script:ToolVersion"; Color = 'Cyan' }
    if ($installed) {
        $lines += @{ Text = "UEFN $($installed.Version) (CL $($installed.CL), $($installed.Source))"; Color = 'Gray' }
    } else {
        $lines += @{ Text = 'UEFN install not detected'; Color = 'Yellow' }
    }
    $lines += @{ Text = "Projects: $(Get-ProjectsRoot)"; Color = 'Gray' }
    $owner = Get-ManagedCatalogInfo
    if ($owner) { $lines += @{ Text = "Catalog owner: $($owner.Slug)"; Color = 'Green' } }

    Write-Host ''
    if (Test-InteractiveConsole) {
        $inner = [Math]::Min(74, [Math]::Max(40, [Console]::WindowWidth - 3))
        Write-Host ($script:BoxTL + ($script:BoxH * $inner) + $script:BoxTR) -ForegroundColor DarkCyan
        foreach ($l in $lines) {
            $t = ' ' + $l.Text
            if ($t.Length -gt $inner) { $t = $t.Substring(0, $inner - 3) + '...' }
            Write-Host $script:BoxV -ForegroundColor DarkCyan -NoNewline
            Write-Host $t.PadRight($inner) -ForegroundColor $l.Color -NoNewline
            Write-Host $script:BoxV -ForegroundColor DarkCyan
        }
        Write-Host ($script:BoxBL + ($script:BoxH * $inner) + $script:BoxBR) -ForegroundColor DarkCyan
    } else {
        foreach ($l in $lines) { Write-Host $l.Text -ForegroundColor $l.Color }
    }
    Write-Host 'Prompts show a suggested value in [brackets] - press Enter to accept it, or type your own.' -ForegroundColor DarkGray
    Test-ToolUpdateAvailable
}

function Main {
    Show-Banner
    while ($true) {
        $items = @(
            @{ Label = 'Browse catalog and install';            Desc = 'Pick a project from the online catalog, download and install it';    Action = { Invoke-BrowseCatalogFlow } },
            @{ Label = 'Install from local zip or folder';      Desc = 'Install a project someone sent you - the source is never modified';   Action = { Invoke-LocalInstallFlow } },
            @{ Label = 'Duplicate one of my projects';          Desc = 'Copy a local project as a fresh, independent project';                Action = { Invoke-DuplicateFlow } },
            @{ Label = 'Generate variants of a project';        Desc = 'Create or update variations of a root project from variants.json';    Action = { Invoke-VariantsFlow } },
            @{ Label = 'Export one of my projects for sharing'; Desc = 'Build a shareable zip with your identity stripped';                   Action = { Invoke-ExportFlow } },
            @{ Label = 'Remove an installed project';           Desc = 'Delete a project plus the editor state UEFN keeps for it';            Action = { Invoke-RemoveFlow } }
        )
        # Owner-only: shown when the configured catalog is provably the one in this repo.
        if (Get-ManagedCatalogInfo) {
            $items += @{ Label = 'Manage my catalog'; Desc = 'Delete catalog entries and optionally their GitHub releases'; Action = { Invoke-CatalogManageFlow } }
        }
        $items += @{ Label = 'Settings'; Desc = 'Catalog URL and projects folder override'; Action = { Invoke-SettingsFlow } }
        $items += @{ Label = 'Help'; Desc = 'What each action does and how the catalog works'; Action = { Show-Help } }

        $pick = Read-MenuChoice -Title 'Main menu' -Options @($items | ForEach-Object { $_.Label }) `
            -Descriptions @($items | ForEach-Object { $_.Desc }) -BackLabel 'Quit' -DefaultChoice '1'
        try {
            if ($pick -lt 0) { Remove-AllStagingDirs; return }
            & $items[$pick].Action
        } catch {
            Write-Err $_.Exception.Message
        } finally {
            Remove-AllStagingDirs
        }
    }
}

#endregion

#region CLI (headless commands for automation and AI agents)

function Resolve-CliProject {
    # -Project accepts a project folder path or a project name found in the scan roots.
    param([Parameter(Mandatory)][string]$NameOrPath)
    if (Test-Path -LiteralPath $NameOrPath) {
        return Get-ProjectInfo -FolderPath ([System.IO.Path]::GetFullPath($NameOrPath))
    }
    foreach ($root in (Get-AllProjectRoots)) {
        $candidate = Join-Path $root $NameOrPath
        if (Test-Path -LiteralPath $candidate) { return Get-ProjectInfo -FolderPath $candidate }
    }
    throw "Project '$NameOrPath' not found (searched: $((Get-AllProjectRoots) -join '; '))."
}

function Out-CliJson {
    param([Parameter(Mandatory)]$Object)
    if ($script:Json) { Write-Output ($Object | ConvertTo-Json -Depth 6) }
}

function Install-ProjectHeadless {
    # Non-prompting install core: sanitize a staged project and copy it into the root.
    param(
        [Parameter(Mandatory)][string]$StagedRoot,
        [string]$NewName = '',
        [string]$NewTitle = ''
    )
    $info = Get-ProjectInfo -FolderPath $StagedRoot
    $finalName = if ($NewName -ne '') { $NewName } else { $info.Name }
    if ($finalName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        throw "Project name '$finalName' is invalid (must start with a letter; letters, digits, underscore only)."
    }
    $root = if ($script:ProjectsRoot -ne '') { $script:ProjectsRoot } else { Get-ProjectsRoot }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $dest = Join-Path $root $finalName
    if (Test-Path -LiteralPath $dest) {
        throw "A project folder named '$finalName' already exists in '$root'. Pass -Name to pick another, or remove it first."
    }
    $finalTitle = if ($NewTitle -ne '') { $NewTitle } elseif ($info.Title -ne '') { $info.Title } else { $finalName }

    $installed = Get-InstalledUefnVersion
    if ($installed -and (Test-VersionCompatible -Required $info.CompatibilityVersion -Installed $installed.Version) -eq $false) {
        Write-Warn "Project requires UEFN $($info.CompatibilityVersion); detected $($installed.Version). It may fail to open until UEFN updates."
    }

    $newInfo = Invoke-ProjectSanitize -StagingPath $StagedRoot -NewTitle $finalTitle -Mode Install -NewProjectName $finalName
    if ($finalName -ne $newInfo.Name) {
        Rename-Item -LiteralPath $newInfo.UefnProjectFile -NewName "$finalName.uefnproject"
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Get-ChildItem -LiteralPath $StagedRoot -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
    }
    Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue
    Write-Ok "Installed '$finalTitle' to $dest"
    return [pscustomobject]@{ name = $finalName; title = $finalTitle; path = $dest }
}

function Invoke-CliCommand {
    param([Parameter(Mandatory)][string]$Cmd)
    switch ($Cmd.ToLowerInvariant()) {

        'list' {
            $projects = @(Get-LocalProjects)
            $out = @($projects | ForEach-Object {
                [pscustomobject]@{
                    name = $_.Info.Name; title = $_.Info.Title; path = $_.Info.FolderPath
                    projectId = $_.Info.ProjectId; versePath = $_.Info.ProjectVersePath
                    bound = $_.Info.IsBound; variantOf = $_.VariantOf
                    compatibilityVersion = $_.Info.CompatibilityVersion
                }
            })
            if ($script:Json) { Out-CliJson $out }
            else { foreach ($p in $out) { Write-Output ("{0}`t{1}`t{2}" -f $p.name, $(if ($p.variantOf) { "variant of $($p.variantOf)" } else { 'root' }), $p.path) } }
        }

        'catalog' {
            $url = if ($script:CatalogUrl -ne '') { $script:CatalogUrl } else { (Get-UefnKitSettings).catalogUrl }
            $catalog = Get-Catalog -Url $url
            if ($script:Json) { Out-CliJson $catalog }
            else { foreach ($e in @($catalog.projects)) { Write-Output ("{0}`t{1}`tv{2}`t{3}" -f $e.id, $e.title, $e.version, $e.downloadUrl) } }
        }

        'install' {
            $stagedRoot = $null
            if ($script:Path -ne '') {
                if (-not (Test-Path -LiteralPath $script:Path)) { throw "Path not found: $($script:Path)" }
                $item = Get-Item -LiteralPath $script:Path
                $staging = New-StagingDir
                if ($item.PSIsContainer) {
                    $srcRoot = Resolve-StagedProjectRoot -SearchDir $item.FullName
                    $stagedRoot = Copy-ProjectToStaging -SourceDir $srcRoot -StagingDir $staging -ExcludeTopLevel @('.lore', '.urc')
                } elseif ($item.Extension -ieq '.zip') {
                    $stagedRoot = Expand-ProjectZip -ZipPath $item.FullName -StagingDir $staging
                } else { throw '-Path must be a folder or a .zip file.' }
                $result = Install-ProjectHeadless -StagedRoot $stagedRoot -NewName $script:Name -NewTitle $script:Title
            } elseif ($script:Id -ne '') {
                $url = if ($script:CatalogUrl -ne '') { $script:CatalogUrl } else { (Get-UefnKitSettings).catalogUrl }
                $catalog = Get-Catalog -Url $url
                $entry = @($catalog.projects) | Where-Object { "$($_.id)" -eq $script:Id } | Select-Object -First 1
                if ($null -eq $entry) { throw "No catalog entry with id '$($script:Id)' at $url" }
                $staging = New-StagingDir
                $zipPath = Join-Path $staging 'pkg.zip'
                Save-FileWithProgress -Url $entry.downloadUrl -OutFile $zipPath
                if ($entry.PSObject.Properties['sha256'] -and $entry.sha256) {
                    if (-not (Test-FileSha256 -Path $zipPath -Expected $entry.sha256)) { throw 'SHA-256 checksum mismatch - aborting.' }
                }
                $extract = New-StagingDir
                $stagedRoot = Expand-ProjectZip -ZipPath $zipPath -StagingDir $extract
                $entryTitle = if ($script:Title -ne '') { $script:Title } else { "$($entry.title)" }
                $result = Install-ProjectHeadless -StagedRoot $stagedRoot -NewName $script:Name -NewTitle $entryTitle
            } else {
                throw "install needs -Path <zip-or-folder> or -Id <catalog-entry-id>."
            }
            Out-CliJson $result
        }

        'duplicate' {
            if ($script:Project -eq '') { throw 'duplicate needs -Project <name-or-path>.' }
            if ($script:Name -eq '') { throw 'duplicate needs -Name <new-project-name>.' }
            $info = Resolve-CliProject -NameOrPath $script:Project
            if ($script:ProjectsRoot -eq '') { $script:ProjectsRoot = Split-Path -Parent $info.FolderPath }
            $staging = New-StagingDir
            $stagedRoot = Copy-ProjectToStaging -SourceDir $info.FolderPath -StagingDir $staging -ExcludeTopLevel @('.lore', '.urc', '.git')
            $newTitle = if ($script:Title -ne '') { $script:Title } else { "$($info.Title) Copy" }
            $newInfo = Invoke-ProjectSanitize -StagingPath $stagedRoot -NewTitle $newTitle -Mode Duplicate -NewProjectName $script:Name
            if ($script:Name -ne $newInfo.Name) {
                Rename-Item -LiteralPath $newInfo.UefnProjectFile -NewName "$($script:Name).uefnproject"
            }
            $dest = Join-Path $script:ProjectsRoot $script:Name
            if (Test-Path -LiteralPath $dest) { throw "A project folder named '$($script:Name)' already exists." }
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Get-ChildItem -LiteralPath $stagedRoot -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force }
            Write-Ok "Duplicated '$($info.Name)' as '$($script:Name)' at $dest"
            Out-CliJson ([pscustomobject]@{ name = $script:Name; title = $newTitle; path = $dest; source = $info.Name })
        }

        'variants' {
            if ($script:Project -eq '') { throw 'variants needs -Project <root-name-or-path>.' }
            $info = Resolve-CliProject -NameOrPath $script:Project
            if (-not (Test-Path -LiteralPath (Join-Path $info.FolderPath 'variants.json'))) {
                throw "'$($info.Name)' has no variants.json. Create it (interactive mode can scaffold one) before generating."
            }
            $manifest = Get-VariantsManifest -RootInfo $info
            $parentDir = Split-Path -Parent $info.FolderPath
            $existing = @($manifest.Variants | Where-Object { Test-Path -LiteralPath (Join-Path $parentDir $_.Name) } | ForEach-Object { $_.Name })
            if ($existing.Count -gt 0 -and -not $script:Yes) {
                throw "These variant projects already exist and would be overwritten: $($existing -join ', '). Pass -Yes to confirm."
            }
            $done = Invoke-VariantGeneration -RootInfo $info -Manifest $manifest
            Write-Ok "$done variant(s) generated/updated."
            Out-CliJson ([pscustomobject]@{ root = $info.Name; generated = $done; variants = @($manifest.Variants | ForEach-Object { $_.Name }) })
        }

        'export' {
            if ($script:Project -eq '') { throw 'export needs -Project <name-or-path>.' }
            $info = Resolve-CliProject -NameOrPath $script:Project
            $ver = if ($script:Version -ne '') { $script:Version } else { '1.0.0' }
            $pkgTitle = if ($script:Title -ne '') { $script:Title } elseif ($info.Title -ne '') { $info.Title } else { $info.Name }
            $pkgAuthor = $script:Author
            if ($pkgAuthor -eq '' -and $info.ProjectVersePath -match '^/([^/@]+)@') { $pkgAuthor = $Matches[1] }
            $pkgDesc = if ($script:Description -ne '') { $script:Description } else { $info.Description }
            $outDir = if ($script:OutDir -ne '') { $script:OutDir }
                      elseif ($PSScriptRoot) { Join-Path $PSScriptRoot 'dist' }
                      else { [Environment]::GetFolderPath('Desktop') }

            $staging = New-StagingDir
            $stagedRoot = Copy-ProjectToStaging -SourceDir $info.FolderPath -StagingDir $staging -ExcludeTopLevel @('.lore', '.urc', '.git')
            $post = Invoke-ProjectSanitize -StagingPath $stagedRoot -NewTitle $pkgTitle -Mode Export -NewDescription $pkgDesc
            $zipPath = Join-Path $outDir ("{0}-{1}.zip" -f $post.Name, $ver)
            New-ProjectZip -ProjectDir $stagedRoot -ZipPath $zipPath
            $zipItem = Get-Item -LiteralPath $zipPath
            $sha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $entry = [pscustomobject]@{
                id = ($post.Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
                name = $post.Name; title = $pkgTitle; description = $pkgDesc; author = $pkgAuthor
                version = $ver; uefnCompatibilityVersion = $post.CompatibilityVersion
                sizeMB = [math]::Round($zipItem.Length / 1MB, 1); sha256 = $sha
                downloadUrl = "https://github.com/magnusenebakk-epic/UEFNKit/releases/download/<tag>/$($zipItem.Name)"
            }
            Write-Ok "Packaged: $zipPath"
            $published = $false
            if ($script:Publish) {
                if (-not (Test-PublisherEnvironment)) {
                    throw 'Cannot publish: run from the catalog repo with an authenticated gh CLI.'
                }
                if (-not (Invoke-CatalogPublish -Entry $entry -ZipPath $zipPath)) { throw 'Publish failed.' }
                $published = $true
            }
            Out-CliJson ([pscustomobject]@{ zip = $zipPath; published = $published; entry = $entry })
        }

        'remove' {
            if ($script:Project -eq '') { throw 'remove needs -Project <name-or-path>.' }
            if (-not $script:Yes) { throw "remove permanently deletes the project and UEFN's sidecar state for it. Pass -Yes to confirm." }
            $info = Resolve-CliProject -NameOrPath $script:Project
            $sidecars = @(Get-ProjectSidecarPaths -Info $info)
            Clear-ReadOnlyFlags -Path $info.FolderPath
            Remove-Item -LiteralPath $info.FolderPath -Recurse -Force -ErrorAction Stop
            Write-Ok "Deleted $($info.FolderPath)"
            $cleaned = @()
            foreach ($s in $sidecars) {
                try { Remove-Item -LiteralPath $s -Recurse -Force -ErrorAction Stop; $cleaned += $s }
                catch { Write-Warn "Could not remove $s" }
            }
            Out-CliJson ([pscustomobject]@{ removed = $info.FolderPath; sidecarsCleaned = $cleaned })
        }

        'catalog-remove' {
            if ($script:Id -eq '') { throw 'catalog-remove needs -Id <entry-id>.' }
            if (-not $script:Yes) { throw 'catalog-remove edits and pushes your catalog. Pass -Yes to confirm.' }
            $mc = Get-ManagedCatalogInfo
            if ($null -eq $mc) { throw 'Not the catalog owner here: run from the catalog repo with the matching catalog URL configured.' }
            $catalog = Get-Content -LiteralPath $mc.IndexPath -Raw | ConvertFrom-Json
            $entry = @($catalog.projects) | Where-Object { "$($_.id)" -eq $script:Id } | Select-Object -First 1
            if ($null -eq $entry) { throw "No catalog entry with id '$($script:Id)'." }
            if (-not (Invoke-CatalogEntryDelete -Repo $mc.Repo -EntryId $script:Id)) { throw 'Catalog entry deletion failed.' }
            $releaseDeleted = $false
            if ($script:DeleteRelease -and "$($entry.downloadUrl)" -match ('^https://github\.com/' + [regex]::Escape($mc.Slug) + '/releases/download/([^/]+)/')) {
                $tag = $Matches[1]
                & gh release delete $tag -R $mc.Slug --yes --cleanup-tag
                if ($LASTEXITCODE -eq 0) { $releaseDeleted = $true; Write-Ok "Release '$tag' deleted." }
                else { Write-Warn 'gh release delete failed (is gh signed in?).' }
            }
            Out-CliJson ([pscustomobject]@{ removedId = $script:Id; releaseDeleted = $releaseDeleted })
        }

        'version' {
            if ($script:Json) { Out-CliJson ([pscustomobject]@{ version = $script:ToolVersion }) }
            else { Write-Output $script:ToolVersion }
        }

        'help' { Show-CliHelp }

        default {
            Show-CliHelp
            throw "Unknown command '$Cmd'."
        }
    }
}

function Show-CliHelp {
    Write-Host @"
UEFNKit v$script:ToolVersion - headless commands (see AGENTS.md for full details)

  powershell -ExecutionPolicy Bypass -File UEFNKit.ps1 <command> [options]

  list            [-Json]                              List local projects (name, root/variant, path)
  catalog         [-CatalogUrl <url>] [-Json]          List catalog entries
  install         -Path <zip|folder> | -Id <entryId>   Install a project (identity reset to unbound)
                  [-Name <n>] [-Title <t>] [-ProjectsRoot <dir>] [-CatalogUrl <url>] [-Json]
  duplicate       -Project <n|path> -Name <newName>    Copy a project as a fresh independent project
                  [-Title <t>] [-Json]
  variants        -Project <root> [-Yes] [-Json]       Generate variants from variants.json
                                                       (-Yes required when variants already exist)
  export          -Project <n|path> [-Version <v>]     Package a project for sharing
                  [-Title <t>] [-Author <a>] [-Description <d>] [-OutDir <dir>] [-Publish] [-Json]
  remove          -Project <n|path> -Yes [-Json]       Delete a project + UEFN sidecar state (no undo)
  catalog-remove  -Id <entryId> -Yes [-DeleteRelease]  Delete a catalog entry (owner machine only)
  version         [-Json]
  help

Exit code 0 = success, 1 = failure. With -Json the machine-readable result is the last
JSON block on stdout. Destructive/overwriting commands refuse to run without -Yes.
No command starts the interactive menu.
"@
}

#endregion

# Entry point: a command runs headless; otherwise the interactive menu starts.
# Set UEFNKIT_NO_MAIN=1 to load the functions without running anything (tests).
if ($Command -ne '') {
    $script:NonInteractive = $true
    $cliFailed = $false
    try {
        Invoke-CliCommand -Cmd $Command
    } catch {
        Write-Err $_.Exception.Message
        $cliFailed = $true
    } finally {
        Remove-AllStagingDirs
    }
    exit $(if ($cliFailed) { 1 } else { 0 })
}
if (-not ($env:UEFNKIT_NO_MAIN -or $env:UEFNSHARE_NO_MAIN)) {
    Main
}
