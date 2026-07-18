# SmartUpgrader
SmartUpgrader is a local PowerShell project to audit installed Windows applications and compare local versions with latest available web versions (without winget).
## Features
- Full installed-app scan from Windows registry (`HKLM/HKCU`)
- Web-based latest-version checks (without winget)
- Fast mode using cached installed-app dataset
- Comparison with previous run to highlight newly updatable apps
- Optional guided/automatic updates for supported installers
- Persistent local summary/snapshot history

## Project contents
- `AppWebUpdater.ps1`: interactive menu for full scan, fast cached scan, and optional guided updates

## Requirements
- Windows with PowerShell
- Internet access (for remote version checks)
- User permissions to read registry uninstall keys
- Administrator PowerShell recommended for update/install workflows

## Setup
1. Open PowerShell.
2. Go to project folder:
   `cd C:\WarpGit\SmartUpgrader`
3. If needed, allow script execution for current session:
   `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`

## Run
From project root:
`PowerShell -NoProfile -ExecutionPolicy Bypass -File .\AppWebUpdater.ps1`

## Menu options
1. **Full check (registry + web)**
   - Reads installed apps directly from registry
   - Refreshes installed-app cache
   - Compares local vs remote versions
   - Writes summary/snapshot files
2. **Full check + update**
   - Runs same full check
   - Offers:
     - per-app confirmation mode
     - bulk automatic mode (where supported)
3. **Fast check (cache + web)**
   - Uses cached installed-app list (faster startup)
   - Compares with previous snapshot
   - Shows newly updatable apps since last run
0. **Exit**

## Local data files
Stored under:
`%LOCALAPPDATA%\AppWebUpdater`

Main files:
- `installed-apps-cache.json` -> cached installed applications
- `last-audit-snapshot.json` -> latest structured audit snapshot
- `last-audit-summary.txt` -> latest human-readable summary
- `history\summary-YYYYMMDD-HHMMSS.txt` -> historical summaries

## Error handling behavior
- Invalid/missing cache: script automatically falls back to full registry scan
- Web lookup errors for specific apps: handled per app without stopping full run
- Storage write errors (cache/snapshot/summary): reported without hard crash
- Invalid menu/update mode input: safely rejected with user-facing message

## Notes
- Local-only project for now (no remote repo required)
- Remote version detection depends on availability/format of source endpoints
- Some apps may be checkable but not auto-updatable; manual links are shown
## Additional documentation
- `ISTRUZIONI.txt` contains the Italian quick-start guide with menu usage and error-handling notes.
