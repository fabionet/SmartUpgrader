# SmartUpgrader
SmartUpgrader is a PowerShell tool for Windows that checks installed applications, compares local versions with latest versions available online, and optionally performs guided updates without using `winget`.

## What it does
- Scans installed applications from Windows registry (`HKLM` / `HKCU`)
- Fetches latest versions from web sources (official endpoints / APIs)
- Compares local vs remote versions
- Provides manual download links
- Supports fast checks using local cache
- Stores run snapshots and human-readable summaries

## Requirements
- Windows
- PowerShell 5.1+ (or PowerShell 7+)
- Internet access for version checks
- Registry read permissions (default user usually enough)
- Administrator PowerShell recommended when performing updates

## Installation
1. Clone or download the repository:
   `git clone https://github.com/fabionet/SmartUpgrader.git`
2. Open PowerShell and move to project folder:
   `cd SmartUpgrader`
3. Allow script execution for current session (if needed):
   `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`

## Usage
Run the tool:
`PowerShell -NoProfile -ExecutionPolicy Bypass -File .\AppWebUpdater.ps1`

### Menu
- `1` Full check (registry + web)
  - Reads installed apps from registry
  - Refreshes app cache
  - Produces comparison report and snapshot
- `2` Full check + update
  - Runs full check, then update flow
  - Supports per-app confirmation or bulk automatic mode (when supported)
- `3` Fast check (cache + web)
  - Uses cached app list for faster startup
  - Highlights newly updatable apps compared to previous run
- `0` Exit

## Output files
SmartUpgrader writes local state under:
`%LOCALAPPDATA%\AppWebUpdater`

Files:
- `installed-apps-cache.json` -> cached installed app inventory
- `last-audit-snapshot.json` -> last structured check result
- `last-audit-summary.txt` -> last text summary
- `history\summary-YYYYMMDD-HHMMSS.txt` -> historical summaries

## Error handling
- Corrupted/missing cache -> automatic fallback to full registry scan
- Per-app web lookup errors -> logged per app, run continues
- Write failures for cache/snapshot/summary -> reported without full crash
- Invalid menu inputs -> safely rejected

## Notes
- Auto-update depends on installer availability and silent-args compatibility.
- Some applications may be check-only (manual update link provided).
- Italian quick guide is available in `ISTRUZIONI.txt`.
