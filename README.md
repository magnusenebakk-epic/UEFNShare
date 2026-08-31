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
  [4] Generate variants of a project   - 4v4/3v3/2v2/1v1 variations from one root (see below)
  [5] Export one of my projects        - build a shareable zip with your identity stripped
  [6] Remove an installed project      - delete a project plus UEFN's editor-generated state for it
  [7] Settings                         - catalog URL, projects folder override
  [8] Help
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

## Variants: one root project, many team sizes

Games like "Boxfights 4v4 / 3v3 / 2v2 / 1v1" are usually near-identical projects that differ only in island matchmaking settings, a few gameplay values, and some cosmetics. Instead of duplicating and hand-editing each one, keep a single **root project** with a `variants.json` next to its Content folder (the tool offers to create it interactively):

```json
{
	"defaults": { "TeamSize": 4, "RoundTime": 120.0 },
	"variants": [
		{ "suffix": "4v4", "title": "Boxfights 4v4",
		  "matchmaking": { "maxTeamSize": 4, "maxTeamCount": 2, "maxPlayers": 8 },
		  "verseConfig": { "TeamSize": 4 } },
		{ "suffix": "1v1", "title": "Boxfights 1v1",
		  "matchmaking": { "maxTeamSize": 1, "maxTeamCount": 2, "maxPlayers": 2 },
		  "verseConfig": { "TeamSize": 1, "RoundTime": 60.0 } }
	]
}
```

**Generate variants** then creates `Boxfights4v4`, `Boxfights1v1`, ... next to the root. Each variant gets the root's content, the matchmaking overrides patched into its `.uefnproject`, and a generated `Content\VariantConfig.verse` — a module of constants (`defaults` merged with the variant's `verseConfig`) that your gameplay code reads:

```verse
using { VariantConfig }
# VariantConfig.TeamSize is 4 in the 4v4 project and 1 in the 1v1 project
```

Drive per-variant visuals the same way: author all variant props once and show/hide (or swap materials/UI text) at game start based on the config. The level stays identical across variants; only text differs — which is what makes the whole thing automatable.

**Updating:** edit the root, run Generate variants again. Existing variant projects are overwritten after a per-variant confirmation — their content is replaced by the root's, but their `projectId`, Verse binding and revision-control history are preserved, so a published variant keeps its link to the published island and the update flow in UEFN works as normal. A `variants.lock.json` in the root remembers each variant's identity, so even a deleted variant folder regenerates with the identity it published under.

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

Run UEFNShare **from this repo folder** (e.g. via `UEFNShare.cmd`) → **Export** → pick your project. Export shows a pre-flight report (absolute Verse paths, Fab asset dependencies, required UEFN version), builds the sanitized zip, and — if the [GitHub CLI](https://cli.github.com/) is installed and logged in — offers to **publish in one step**: it creates the GitHub release with the zip attached, adds the entry to `index.json` (replacing an older version of the same demo), commits and pushes. The demo appears in everyone's Browse within ~5 minutes.

Without `gh` (or when declined), Export falls back to manual mode:

1. You get the zip in `dist\` plus a ready-to-paste catalog entry (offered to your clipboard, including the computed `sha256` and `sizeMB`).
2. Upload the zip to a GitHub Release of this repo.
3. Fix the `downloadUrl` in the entry, paste it into `index.json`'s `projects` array, commit and push.

## Requirements

Windows with PowerShell 5.1+ (preinstalled on Windows 10/11). UEFN installed via the Epic Games Launcher. No other dependencies.
