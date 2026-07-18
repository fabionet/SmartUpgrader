# SmartUpgrader
SmartUpgrader is a local PowerShell project to audit installed Windows applications and compare local versions with latest available web versions (without winget).
## Current contents
- `AppWebUpdater.ps1`: interactive menu for full scan, fast cached scan, and optional guided updates
## Notes
- Project is currently local-only.
- Cache and reports are stored under `%LOCALAPPDATA%\AppWebUpdater`.
