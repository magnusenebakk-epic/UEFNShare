# UEFNShare

Install, duplicate and package **UEFN (Unreal Editor for Fortnite) projects** so they can be shared between people.

A UEFN project carries identifiers that tie it to its creator's Epic account: the project and module GUIDs, the account Verse path (`/you@fortnite.com/Project`), and the Unreal Revision Control database (`.lore\`). If you just copy a project to someone else's machine, it stays bound to *you*. UEFNShare resets all of that to the exact state UEFN uses for a brand-new, never-opened project — so on first open, UEFN binds the project to the *new* owner's account and it behaves as if they created it.

## Run it

Paste this into any PowerShell window:

```powershell
irm https://raw.githubusercontent.com/magnusenebakk-epic/UEFNShare/main/UEFNShare.ps1 | iex
```

Or download this repo as a zip, extract it, and double-click **`UEFNShare.cmd`** (no admin rights needed; if Windows shows an "Open File – Security Warning" once, click Run).

## What it does

```
  [1] Browse catalog and install       - pick a project from an online catalog, download, install
  [2] Install from local zip or folder - install a project someone sent you (source is never modified)
  [3] Duplicate one of my projects     - copy a local project as a fresh, independent project
  [4] Export one of my projects        - build a shareable zip with your identity stripped
  [5] Settings                         - catalog URL, projects folder override
  [6] Help
```

Everything is prompted step by step, and every prompt that can be auto-detected (your UEFN projects folder, project titles, versions) offers that value as the default — just press Enter to accept.

### What install/export changes inside a project

- Fresh `projectId` and module GUIDs (`.uefnproject`)
- Verse path reset to UEFN's unbound state (`projectVersePath = ""`, uplugin `VersePath = /invaliddomain/<ProjectName>`)
- `using { /creator@fortnite.com/... }` paths in `.verse` sources rewritten to match the installed project name (UEFN mounts unbound projects at `/invaliddomain/<ProjectName>`)
- Removed: `.lore\` revision-control history, `.git\`, `*.code-workspace`, `Content\Developers\`
- Binary assets (`.umap`/`.uasset`) are **never modified** — UEFN's redirector fixes those on first open

### What it never touches

UEFN's central configuration, your trusted-projects list, and your Epic / revision-control login tokens. When you first open an installed project, UEFN shows its standard **Verse code trust prompt** — review it before accepting; that prompt is the security boundary for running code somebody else wrote.

## Hosting your own catalog

The catalog is just a static JSON file — host it anywhere (GitHub raw, S3, any web server) and point **Settings → Catalog URL** at it. Project zips can live in GitHub Releases or any direct-download URL.

`index.json`:

```json
{
	"schemaVersion": 1,
	"name": "My UEFN Demos",
	"description": "What this catalog contains",
	"updated": "2026-08-25",
	"projects": [
		{
			"id": "my-demo",
			"name": "MyDemo",
			"title": "My Demo Game",
			"description": "A short pitch shown in the browser.",
			"author": "yourname",
			"version": "1.0.0",
			"uefnCompatibilityVersion": "41.30",
			"sizeMB": 7.4,
			"sha256": "<sha256 of the zip, lowercase hex>",
			"downloadUrl": "https://github.com/<user>/<repo>/releases/download/<tag>/MyDemo-1.0.0.zip",
			"tags": [],
			"screenshotUrl": "",
			"readmeUrl": ""
		}
	]
}
```

Required per entry: `id`, `name`, `title`, `version`, `downloadUrl`. Recommended: `description`, `author`, `sizeMB`, `sha256`, `uefnCompatibilityVersion`.

### Publishing workflow

1. Run UEFNShare → **Export** → pick your project. You get a sanitized zip in `dist\` plus a ready-to-paste catalog entry (offered to your clipboard, including the computed `sha256` and `sizeMB`).
2. Upload the zip to a GitHub Release of this repo.
3. Fix the `downloadUrl` in the entry, paste it into `index.json`'s `projects` array, commit and push.

## Requirements

Windows with PowerShell 5.1+ (preinstalled on Windows 10/11). UEFN installed via the Epic Games Launcher. No other dependencies.
