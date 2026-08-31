# UEFNKit — agent / automation guide

UEFNKit manages UEFN (Unreal Editor for Fortnite) projects: install shared projects, duplicate, generate variants, export/publish packages, and remove projects. Every feature is available headless via command-line arguments — **never drive the interactive menu with stdin**; use commands.

## Invocation

```
powershell -NoProfile -ExecutionPolicy Bypass -File UEFNKit.ps1 <command> [options]
```

- Windows only (UEFN is Windows-only). PowerShell 5.1+ — preinstalled everywhere.
- Exit code `0` = success, `1` = failure (error text on stdout/stderr, prefixed `[X]`).
- Add `-Json` to any command for a machine-readable result: **the last JSON block on stdout is the result**; lines before it are human-oriented progress (`[OK]`, `[!]`, indented info).
- Headless mode never prompts. Optional decisions auto-resolve to safe defaults (logged as `(auto) ...`). Missing required parameters fail immediately with exit 1.
- Destructive or overwriting commands refuse to run without `-Yes`.
- Prefer running while UEFN is closed; installs are safe while it runs, but the UEFN Project Browser needs a refresh to see changes.

## Commands

### `list [-Json]`
Lists local UEFN projects from the configured projects root(s).
JSON result: array of `{ name, title, path, projectId, versePath, bound, variantOf, compatibilityVersion }`.
`variantOf` is non-empty when the project is a generated variant of that root project.

### `catalog [-CatalogUrl <url>] [-Json]`
Lists entries of the online catalog (default URL from settings). JSON result: the whole catalog object; entries are in `.projects[]` with `{ id, name, title, description, author, version, uefnCompatibilityVersion, sizeMB, sha256, downloadUrl }`.

### `install (-Path <zip-or-folder> | -Id <catalogEntryId>) [-Name <projectName>] [-Title <title>] [-ProjectsRoot <dir>] [-CatalogUrl <url>] [-Json]`
Installs a project. With `-Id`, downloads from the catalog and verifies sha256 when present. The project's identity is reset to UEFN's unbound state (fresh GUIDs, Verse path sentinel) so it binds to the local user's account on first open in UEFN. Fails if the target folder already exists (choose another `-Name`). `-Name` must match `^[A-Za-z][A-Za-z0-9_]*$` (it becomes part of the Verse module path).
JSON result: `{ name, title, path }`.

### `duplicate -Project <nameOrPath> -Name <newName> [-Title <t>] [-ProjectsRoot <dir>] [-Json]`
Copies a local project as a fresh, independent project (new GUIDs, unbound; revision-control history not copied). JSON result: `{ name, title, path, source }`.

### `variants -Project <rootNameOrPath> [-Yes] [-Json]`
Generates/updates variant projects from the root's `variants.json` (see README for the manifest schema). If any variant project already exists, the command fails unless `-Yes` is passed; overwriting preserves each variant's projectId, Verse binding and revision-control history (published islands keep their update link).
JSON result: `{ root, generated, variants[] }`.

### `export -Project <nameOrPath> [-Version <v=1.0.0>] [-Title <t>] [-Author <a>] [-Description <d>] [-OutDir <dir>] [-Publish] [-Json]`
Packages a project into a shareable zip with the owner's identity stripped. Root-level files outside the standard UEFN layout are removed from the package automatically in headless mode. With `-Publish` (catalog-owner machine with authenticated `gh` only): creates the GitHub release, updates `index.json`, commits and pushes.
JSON result: `{ zip, published, entry }` where `entry` is a ready catalog entry (fix `<tag>` in `downloadUrl` if publishing manually).

### `remove -Project <nameOrPath> -Yes [-Json]`
Permanently deletes the project folder AND UEFN's editor-generated sidecar state for it (per-project config, Verse workspace/snapshots, autosaves, upload temp). No undo. JSON result: `{ removed, sidecarsCleaned[] }`.

### `catalog-remove -Id <entryId> -Yes [-DeleteRelease] [-Json]`
Owner-only (must run from the catalog repo with the matching catalog URL configured): removes the entry from `index.json`, commits and pushes. `-DeleteRelease` also deletes the entry's GitHub release and tag (existing download links stop working).
JSON result: `{ removedId, releaseDeleted }`.

### `version [-Json]`, `help`

## Facts that matter when reasoning about this tool

- A UEFN project = folder containing `<Name>.uefnproject` (JSON), `<PluginName>.uplugin` (JSON), `Content\`, optionally `Resources\`, `References\`. The plugin name may differ from the project name and is never renamed.
- Identity reset means: fresh `projectId`/module GUIDs, `projectVersePath=""`, uplugin `VersePath=/invaliddomain/<ProjectName>`, `using` paths in `.verse` sources rewritten to match, `.lore\` revision-control history deleted. Binary assets are never modified.
- UEFN discovers projects purely by scanning the projects folder; installing = copying a fixed-up folder in. The first open in UEFN binds the project to the local account and shows a Verse trust prompt (expected; it is the security boundary).
- The tool never touches UEFN's central configuration or login tokens.

## Examples

```powershell
# What's installed?
powershell -NoProfile -ExecutionPolicy Bypass -File UEFNKit.ps1 list -Json

# Install a demo from the catalog under a custom name
powershell -NoProfile -ExecutionPolicy Bypass -File UEFNKit.ps1 install -Id mobilegames -Name MobileGamesDemo -Json

# Regenerate all variants of a root after editing it (variants exist, so consent needed)
powershell -NoProfile -ExecutionPolicy Bypass -File UEFNKit.ps1 variants -Project Boxfights -Yes -Json

# Package and publish a demo (owner machine)
powershell -NoProfile -ExecutionPolicy Bypass -File UEFNKit.ps1 export -Project MobileGames -Version 1.1.0 -Publish -Json

# Clean up a test install
powershell -NoProfile -ExecutionPolicy Bypass -File UEFNKit.ps1 remove -Project MobileGamesDemo -Yes
```
