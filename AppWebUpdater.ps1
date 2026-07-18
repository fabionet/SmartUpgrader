param(
  [switch]$NoPause
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:StoreDir = Join-Path $env:LOCALAPPDATA "AppWebUpdater"
$script:InstalledCacheFile = Join-Path $script:StoreDir "installed-apps-cache.json"
$script:LastSnapshotFile = Join-Path $script:StoreDir "last-audit-snapshot.json"
$script:LastSummaryFile = Join-Path $script:StoreDir "last-audit-summary.txt"
$script:HistoryDir = Join-Path $script:StoreDir "history"

function Initialize-Store {
  try {
    New-Item -Path $script:StoreDir -ItemType Directory -Force | Out-Null
    New-Item -Path $script:HistoryDir -ItemType Directory -Force | Out-Null
    return $true
  } catch {
    Write-Host "Errore inizializzazione storage locale: $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
}

function Write-Section {
  param([string]$Text)
  Write-Host ""
  Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function ConvertTo-ComparableVersion {
  param([string]$VersionText)
  if (-not $VersionText) { return [version]'0.0.0.0' }

  $v = $VersionText.Trim()
  $v = $v -replace '[^\d\.]', '.'
  $v = $v -replace '\.{2,}', '.'
  $v = $v.Trim('.')
  if (-not $v) { return [version]'0.0.0.0' }

  $parts = $v.Split('.') | Where-Object { $_ -ne '' } | Select-Object -First 4
  while ($parts.Count -lt 4) { $parts += '0' }
  $joined = ($parts -join '.')

  try { return [version]$joined } catch { return [version]'0.0.0.0' }
}

function Compare-VersionText {
  param(
    [string]$LocalVersion,
    [string]$RemoteVersion
  )

  $lv = ConvertTo-ComparableVersion $LocalVersion
  $rv = ConvertTo-ComparableVersion $RemoteVersion
  if ($lv -lt $rv) { return -1 }
  if ($lv -gt $rv) { return 1 }
  return 0
}

function To-Array {
  param([Parameter(ValueFromPipeline = $true)]$InputObject)
  if ($null -eq $InputObject) { return @() }
  if ($InputObject -is [System.Array]) { return $InputObject }
  return @($InputObject)
}

function Get-InstalledAppsFromRegistry {
  $keys = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )

  $priorProgressPreference = $ProgressPreference
  $ProgressPreference = "Continue"

  try {
    $map = @{}
    $totalKeys = [Math]::Max(1, $keys.Count)

    for ($i = 0; $i -lt $keys.Count; $i++) {
      $k = $keys[$i]
      $percent = [int](($i / $totalKeys) * 100)
      Write-Progress -Id 1 -Activity "Ricerca programmi installati" -Status "Lettura registro: $k" -PercentComplete $percent

      $entries = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
      foreach ($entry in $entries) {
        if (-not $entry.DisplayName) { continue }
        if ($entry.SystemComponent) { continue }

        $name = $entry.DisplayName.Trim()
        if (-not $name) { continue }
        $nameKey = $name.ToLowerInvariant()

        $candidate = [pscustomobject]@{
          Name = $name
          Version = if ($entry.DisplayVersion) { $entry.DisplayVersion.Trim() } else { "" }
          Publisher = $entry.Publisher
          UninstallString = $entry.UninstallString
        }

        if (-not $map.ContainsKey($nameKey)) {
          $map[$nameKey] = $candidate
        } else {
          $existing = $map[$nameKey]
          if ((Compare-VersionText -LocalVersion $existing.Version -RemoteVersion $candidate.Version) -lt 0) {
            $map[$nameKey] = $candidate
          }
        }
      }
    }

    Write-Progress -Id 1 -Activity "Ricerca programmi installati" -Status "Completata" -PercentComplete 100 -Completed
    return $map.Values | Sort-Object Name
  } finally {
    $ProgressPreference = $priorProgressPreference
  }
}

function Save-InstalledAppsCache {
  param([array]$InstalledApps)
  if (-not (Initialize-Store)) { return $false }
  try {
    $payload = [pscustomobject]@{
      generated_at = (Get-Date).ToString("s")
      total = $InstalledApps.Count
      apps = $InstalledApps
    }
    $payload | ConvertTo-Json -Depth 6 | Out-File -FilePath $script:InstalledCacheFile -Encoding UTF8
    return $true
  } catch {
    Write-Host "Errore salvataggio cache app installate: $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
}

function Load-InstalledAppsCache {
  if (-not (Test-Path $script:InstalledCacheFile)) { return @() }
  try {
    $obj = Get-Content $script:InstalledCacheFile -Raw | ConvertFrom-Json
    return To-Array $obj.apps
  } catch {
    return @()
  }
}

function Get-LastCacheTimestamp {
  if (-not (Test-Path $script:InstalledCacheFile)) { return $null }
  try {
    $obj = Get-Content $script:InstalledCacheFile -Raw | ConvertFrom-Json
    return $obj.generated_at
  } catch {
    return $null
  }
}

function Get-GitHubLatestReleaseInfo {
  param(
    [string]$Repository,
    [string]$AssetRegex
  )

  $uri = "https://api.github.com/repos/$Repository/releases/latest"
  $headers = @{ "User-Agent" = "AppWebUpdater/1.0" }
  $release = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30
  $latest = ($release.tag_name -replace '^[vV]', '')

  $asset = $null
  if ($AssetRegex) {
    $asset = $release.assets | Where-Object { $_.name -match $AssetRegex } | Select-Object -First 1
  } else {
    $asset = $release.assets | Select-Object -First 1
  }

  [pscustomobject]@{
    LatestVersion = $latest
    DownloadUrl = if ($asset) { $asset.browser_download_url } else { $null }
    ReleasePage = $release.html_url
    InstallerType = Get-InstallerTypeFromUrl (if ($asset) { $asset.browser_download_url } else { $null })
  }
}

function Get-InstallerTypeFromUrl {
  param([string]$Url)
  if (-not $Url) { return "unknown" }
  if ($Url -match '\.msi($|\?)') { return "msi" }
  if ($Url -match '\.exe($|\?)') { return "exe" }
  return "unknown"
}

function Invoke-ChromeCheck {
  $uri = "https://versionhistory.googleapis.com/v1/chrome/platforms/win/channels/stable/versions?pageSize=1"
  $obj = Invoke-RestMethod -Uri $uri -TimeoutSec 30
  $latest = $obj.versions[0].version
  [pscustomobject]@{
    LatestVersion = $latest
    DownloadUrl = "https://dl.google.com/chrome/install/latest/chrome_installer.exe"
    ReleasePage = "https://www.google.com/chrome/"
    InstallerType = "exe"
    SilentArgs = "/silent /install"
  }
}

function Invoke-FirefoxCheck {
  $uri = "https://product-details.mozilla.org/1.0/firefox_versions.json"
  $obj = Invoke-RestMethod -Uri $uri -TimeoutSec 30
  [pscustomobject]@{
    LatestVersion = $obj.LATEST_FIREFOX_VERSION
    DownloadUrl = "https://download.mozilla.org/?product=firefox-latest&os=win64&lang=it"
    ReleasePage = "https://www.mozilla.org/firefox/new/"
    InstallerType = "exe"
    SilentArgs = "/S"
  }
}

function Invoke-NodeCheck {
  $uri = "https://nodejs.org/dist/index.json"
  $list = Invoke-RestMethod -Uri $uri -TimeoutSec 30
  $stable = $list | Where-Object { $_.lts -and $_.lts -ne $false } | Select-Object -First 1
  $latest = ($stable.version -replace '^v', '')
  [pscustomobject]@{
    LatestVersion = $latest
    DownloadUrl = "https://nodejs.org/dist/v$latest/node-v$latest-x64.msi"
    ReleasePage = "https://nodejs.org/en/download"
    InstallerType = "msi"
    SilentArgs = "/qn /norestart"
  }
}

function Invoke-CCleanerCheck {
  $uri = "https://www.ccleaner.com/ccleaner/builds"
  $html = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 30).Content

  $verMatch = [regex]::Match($html, 'CCleaner Free \(v([0-9]+\.[0-9]+\.[0-9]+)\)')
  $latest = if ($verMatch.Success) { $verMatch.Groups[1].Value } else { "" }

  $downloadMatch = [regex]::Match($html, 'href="(https://download\.ccleaner\.com/[^"]*ccsetup[^"]*\.exe)"')
  $download = if ($downloadMatch.Success) { $downloadMatch.Groups[1].Value } else { "https://www.ccleaner.com/ccleaner/download" }

  [pscustomobject]@{
    LatestVersion = $latest
    DownloadUrl = $download
    ReleasePage = $uri
    InstallerType = Get-InstallerTypeFromUrl $download
    SilentArgs = "/S"
  }
}

function Get-WebResolvers {
  @(
    @{
      Match = '(?i)\bollama\b'
      Resolver = {
        $gh = Get-GitHubLatestReleaseInfo -Repository "ollama/ollama" -AssetRegex 'OllamaSetup.*\.exe'
        [pscustomobject]@{
          LatestVersion = $gh.LatestVersion
          DownloadUrl = $gh.DownloadUrl
          ReleasePage = $gh.ReleasePage
          InstallerType = $gh.InstallerType
          SilentArgs = "/S"
        }
      }
    },
    @{
      Match = '(?i)\bnextcloud\b'
      Resolver = {
        $gh = Get-GitHubLatestReleaseInfo -Repository "nextcloud-releases/desktop" -AssetRegex 'Nextcloud-.*-x64\.msi'
        [pscustomobject]@{
          LatestVersion = $gh.LatestVersion
          DownloadUrl = $gh.DownloadUrl
          ReleasePage = $gh.ReleasePage
          InstallerType = $gh.InstallerType
          SilentArgs = "/qn /norestart"
        }
      }
    },
    @{
      Match = '(?i)\bccleaner\b'
      Resolver = { Invoke-CCleanerCheck }
    },
    @{
      Match = '(?i)notepad\+\+'
      Resolver = {
        $gh = Get-GitHubLatestReleaseInfo -Repository "notepad-plus-plus/notepad-plus-plus" -AssetRegex 'npp\..*Installer\.x64\.exe'
        [pscustomobject]@{
          LatestVersion = $gh.LatestVersion
          DownloadUrl = $gh.DownloadUrl
          ReleasePage = $gh.ReleasePage
          InstallerType = $gh.InstallerType
          SilentArgs = "/S"
        }
      }
    },
    @{
      Match = '(?i)\bgit\b'
      Resolver = {
        $gh = Get-GitHubLatestReleaseInfo -Repository "git-for-windows/git" -AssetRegex 'Git-.*-64-bit\.exe'
        [pscustomobject]@{
          LatestVersion = $gh.LatestVersion
          DownloadUrl = $gh.DownloadUrl
          ReleasePage = $gh.ReleasePage
          InstallerType = $gh.InstallerType
          SilentArgs = "/VERYSILENT /NORESTART"
        }
      }
    },
    @{
      Match = '(?i)\bmozilla firefox\b'
      Resolver = { Invoke-FirefoxCheck }
    },
    @{
      Match = '(?i)\bnode\.?js\b'
      Resolver = { Invoke-NodeCheck }
    },
    @{
      Match = '(?i)\bgoogle chrome\b'
      Resolver = { Invoke-ChromeCheck }
    }
  )
}

function Resolve-AppWebStatus {
  param([pscustomobject]$InstalledApp)
  $resolvers = Get-WebResolvers
  $r = $resolvers | Where-Object { $InstalledApp.Name -match $_.Match } | Select-Object -First 1

  if (-not $r) {
    return [pscustomobject]@{
      Name = $InstalledApp.Name
      LocalVersion = $InstalledApp.Version
      LatestVersion = ""
      Status = "Resolver non disponibile"
      UpdateAvailable = $false
      DownloadUrl = ""
      ReleasePage = ""
      InstallerType = ""
      SilentArgs = ""
      AutoUpdatable = $false
    }
  }

  try {
    $remote = & $r.Resolver
    $hasVersion = -not [string]::IsNullOrWhiteSpace($remote.LatestVersion)
    $cmp = if ($hasVersion) { Compare-VersionText -LocalVersion $InstalledApp.Version -RemoteVersion $remote.LatestVersion } else { 0 }
    $update = $hasVersion -and ($cmp -lt 0)
    $auto = $update -and $remote.DownloadUrl -and $remote.SilentArgs

    return [pscustomobject]@{
      Name = $InstalledApp.Name
      LocalVersion = $InstalledApp.Version
      LatestVersion = $remote.LatestVersion
      Status = if ($update) { "Aggiornamento disponibile" } else { "Aggiornata / non determinabile" }
      UpdateAvailable = $update
      DownloadUrl = if ($remote.DownloadUrl) { $remote.DownloadUrl } else { "" }
      ReleasePage = if ($remote.ReleasePage) { $remote.ReleasePage } else { "" }
      InstallerType = if ($remote.InstallerType) { $remote.InstallerType } else { "unknown" }
      SilentArgs = if ($remote.SilentArgs) { $remote.SilentArgs } else { "" }
      AutoUpdatable = [bool]$auto
    }
  } catch {
    return [pscustomobject]@{
      Name = $InstalledApp.Name
      LocalVersion = $InstalledApp.Version
      LatestVersion = ""
      Status = "Errore check web: $($_.Exception.Message)"
      UpdateAvailable = $false
      DownloadUrl = ""
      ReleasePage = ""
      InstallerType = ""
      SilentArgs = ""
      AutoUpdatable = $false
    }
  }
}

function Invoke-WebAuditForApps {
  param(
    [array]$InstalledApps,
    [string]$Title = "Verifica web aggiornamenti (senza winget)"
  )
  if (-not $InstalledApps -or $InstalledApps.Count -eq 0) {
    Write-Host "Nessuna app disponibile per la verifica web." -ForegroundColor Yellow
    return (New-Object System.Collections.Generic.List[object])
  }

  Write-Section $Title
  $results = New-Object System.Collections.Generic.List[object]
  $count = [Math]::Max(1, $InstalledApps.Count)
  $priorProgressPreference = $ProgressPreference
  $ProgressPreference = "Continue"

  try {
    for ($i = 0; $i -lt $InstalledApps.Count; $i++) {
      $app = $InstalledApps[$i]
      $percent = [int](($i / $count) * 100)
      Write-Progress -Id 2 -Activity "Confronto versioni sul web" -Status "[$($i+1)/$($InstalledApps.Count)] $($app.Name)" -PercentComplete $percent
      $results.Add((Resolve-AppWebStatus -InstalledApp $app))
    }
    Write-Progress -Id 2 -Activity "Confronto versioni sul web" -Status "Completata" -PercentComplete 100 -Completed
  } finally {
    $ProgressPreference = $priorProgressPreference
  }

  return $results
}

function Show-AuditSummary {
  param([System.Collections.Generic.List[object]]$Results)

  Write-Section "Riepilogo completo"
  $Results |
    Select-Object Name, LocalVersion, LatestVersion, Status |
    Sort-Object Name |
    Format-Table -AutoSize

  $updatable = $Results | Where-Object { $_.UpdateAvailable -eq $true }
  Write-Host ""
  Write-Host "App con aggiornamento disponibile: $($updatable.Count)" -ForegroundColor Yellow

  if ($updatable.Count -gt 0) {
    Write-Section "Link download/manuale"
    $updatable |
      Select-Object Name, LocalVersion, LatestVersion, DownloadUrl, ReleasePage |
      Sort-Object Name |
      Format-Table -AutoSize
  }
}

function Load-LastSnapshot {
  if (-not (Test-Path $script:LastSnapshotFile)) { return @() }
  try {
    $obj = Get-Content $script:LastSnapshotFile -Raw | ConvertFrom-Json
    return To-Array $obj.results
  } catch {
    return @()
  }
}

function Update-AuditArtifacts {
  param(
    [System.Collections.Generic.List[object]]$Results,
    [string]$ModeLabel
  )

  if (-not (Initialize-Store)) { return @() }
  try {
    $previous = Load-LastSnapshot
    $prevMap = @{}
    foreach ($p in $previous) {
      $prevMap[$p.Name.ToLowerInvariant()] = $p
    }

    $newlyUpdatable = @()
    $currentlyUpdatable = @($Results | Where-Object { $_.UpdateAvailable -eq $true })
    foreach ($r in $currentlyUpdatable) {
      $key = $r.Name.ToLowerInvariant()
      if (-not $prevMap.ContainsKey($key) -or -not $prevMap[$key].UpdateAvailable) {
        $newlyUpdatable += $r
      }
    }

    $snapshotPayload = [pscustomobject]@{
      generated_at = (Get-Date).ToString("s")
      mode = $ModeLabel
      total = $Results.Count
      updatable_total = $currentlyUpdatable.Count
      newly_updatable_total = $newlyUpdatable.Count
      results = $Results
    }
    $snapshotPayload | ConvertTo-Json -Depth 8 | Out-File -FilePath $script:LastSnapshotFile -Encoding UTF8

    $summary = New-Object System.Text.StringBuilder
    [void]$summary.AppendLine("AppWebUpdater - riepilogo")
    [void]$summary.AppendLine("Generato: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$summary.AppendLine("Modalita: $ModeLabel")
    [void]$summary.AppendLine("Totale app analizzate: $($Results.Count)")
    [void]$summary.AppendLine("Aggiornamenti disponibili: $($currentlyUpdatable.Count)")
    [void]$summary.AppendLine("Nuove app da aggiornare rispetto al run precedente: $($newlyUpdatable.Count)")
    [void]$summary.AppendLine("")

    if ($newlyUpdatable.Count -gt 0) {
      [void]$summary.AppendLine("Nuove app da aggiornare:")
      foreach ($n in ($newlyUpdatable | Sort-Object Name)) {
        [void]$summary.AppendLine("- $($n.Name) | Locale: $($n.LocalVersion) | Remota: $($n.LatestVersion)")
      }
      [void]$summary.AppendLine("")
    }

    if ($currentlyUpdatable.Count -gt 0) {
      [void]$summary.AppendLine("Elenco completo app aggiornabili:")
      foreach ($u in ($currentlyUpdatable | Sort-Object Name)) {
        [void]$summary.AppendLine("- $($u.Name) | Locale: $($u.LocalVersion) | Remota: $($u.LatestVersion)")
        [void]$summary.AppendLine("  Download: $($u.DownloadUrl)")
      }
    }

    $summaryText = $summary.ToString()
    $summaryText | Out-File -FilePath $script:LastSummaryFile -Encoding UTF8
    $historyFile = Join-Path $script:HistoryDir ("summary-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
    $summaryText | Out-File -FilePath $historyFile -Encoding UTF8

    Write-Host ""
    Write-Host "Riepilogo salvato in:" -ForegroundColor Cyan
    Write-Host "- $script:LastSummaryFile"
    Write-Host "- $script:LastSnapshotFile"
    return $newlyUpdatable
  } catch {
    Write-Host "Errore aggiornamento file riepilogo/snapshot: $($_.Exception.Message)" -ForegroundColor Red
    return @()
  }
}

function Build-InstalledCacheFromRegistry {
  Write-Section "Lettura app installate da registro"
  $installed = Get-InstalledAppsFromRegistry
  $saved = Save-InstalledAppsCache -InstalledApps $installed
  if ($saved) {
    Write-Host "Trovate $($installed.Count) app. Cache aggiornata: $script:InstalledCacheFile" -ForegroundColor Green
  } else {
    Write-Host "Trovate $($installed.Count) app. Cache NON aggiornata (errore scrittura)." -ForegroundColor Yellow
  }
  return $installed
}

function Invoke-InstalledAppsAudit {
  $installed = Build-InstalledCacheFromRegistry
  return (Invoke-WebAuditForApps -InstalledApps $installed -Title "Verifica web aggiornamenti (senza winget)")
}

function Invoke-FastAuditFromCache {
  $cache = Load-InstalledAppsCache
  if (-not $cache -or $cache.Count -eq 0) {
    Write-Host "Cache assente o vuota. Eseguo prima una scansione completa da registro..." -ForegroundColor Yellow
    $cache = Build-InstalledCacheFromRegistry
  } else {
    $ts = Get-LastCacheTimestamp
    Write-Section "Uso cache app installate"
    Write-Host "Cache caricata: $($cache.Count) app (generata: $ts)"
  }
  return (Invoke-WebAuditForApps -InstalledApps $cache -Title "Verifica rapida aggiornamenti dal dataset in cache")
}

function Download-And-InstallApp {
  param([pscustomobject]$AppStatus)

  if (-not $AppStatus.DownloadUrl) {
    Write-Host "Nessun link disponibile per $($AppStatus.Name)." -ForegroundColor Yellow
    return $false
  }

  $tempRoot = Join-Path $env:TEMP "AppWebUpdater"
  New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

  $safeName = ($AppStatus.Name -replace '[^\w\-]+', '_')
  $ext = if ($AppStatus.DownloadUrl -match '\.msi($|\?)') { ".msi" } elseif ($AppStatus.DownloadUrl -match '\.exe($|\?)') { ".exe" } else { ".bin" }
  $filePath = Join-Path $tempRoot "$safeName-$($AppStatus.LatestVersion)$ext"

  Write-Host "Download: $($AppStatus.Name)"
  Invoke-WebRequest -Uri $AppStatus.DownloadUrl -OutFile $filePath -UseBasicParsing -TimeoutSec 180

  Write-Host "Installazione: $($AppStatus.Name)"
  if ($AppStatus.InstallerType -eq "msi") {
    $args = "/i `"$filePath`" $($AppStatus.SilentArgs)"
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
  } else {
    $p = Start-Process -FilePath $filePath -ArgumentList $AppStatus.SilentArgs -Wait -PassThru
  }

  if ($p.ExitCode -eq 0) {
    Write-Host "OK: $($AppStatus.Name) aggiornata." -ForegroundColor Green
    return $true
  } else {
    Write-Host "ERRORE: $($AppStatus.Name) exit code $($p.ExitCode)" -ForegroundColor Red
    return $false
  }
}

function Ask-YesNo {
  param([string]$Prompt)
  $ans = Read-Host "$Prompt (S/N)"
  return $ans -match '^(?i)(s|si|sì|y|yes)$'
}

function Run-CheckOnlyFlow {
  $results = Invoke-InstalledAppsAudit
  Show-AuditSummary -Results $results
  $newly = Update-AuditArtifacts -Results $results -ModeLabel "Verifica completa (registro + web)"
  Write-Host "Nuove app da aggiornare rispetto al run precedente: $($newly.Count)" -ForegroundColor Yellow
}

function Run-CheckAndUpdateFlow {
  $results = Invoke-InstalledAppsAudit
  Show-AuditSummary -Results $results
  $newly = Update-AuditArtifacts -Results $results -ModeLabel "Verifica completa + aggiornamento"
  Write-Host "Nuove app da aggiornare rispetto al run precedente: $($newly.Count)" -ForegroundColor Yellow

  $targets = $results | Where-Object { $_.UpdateAvailable -eq $true }
  if (-not $targets -or $targets.Count -eq 0) {
    Write-Host "Nessuna app da aggiornare." -ForegroundColor Green
    return
  }

  Write-Host ""
  Write-Host "Modalità aggiornamento:" -ForegroundColor Cyan
  Write-Host "1) Conferma ad ogni app"
  Write-Host "2) Aggiorna tutto automaticamente (dove supportato)"
  Write-Host "0) Annulla"
  $mode = Read-Host "Scelta"
  if ($mode -eq "0") { return }
  if ($mode -ne "1" -and $mode -ne "2") {
    Write-Host "Modalità non valida: aggiornamento annullato." -ForegroundColor Yellow
    return
  }

  $success = 0
  $failed = 0
  $skipped = 0

  foreach ($app in $targets | Sort-Object Name) {
    Write-Host ""
    Write-Host "--- $($app.Name) | Locale: $($app.LocalVersion) -> Remota: $($app.LatestVersion) ---" -ForegroundColor Yellow
    Write-Host "Download: $($app.DownloadUrl)"

    if (-not $app.AutoUpdatable) {
      Write-Host "Auto-update non supportato per questa app (solo link manuale)." -ForegroundColor DarkYellow
      $skipped++
      continue
    }

    if ($mode -eq "1") {
      if (-not (Ask-YesNo -Prompt "Procedere con l'aggiornamento di $($app.Name)?")) {
        $skipped++
        continue
      }
    }

    try {
      if (Download-And-InstallApp -AppStatus $app) { $success++ } else { $failed++ }
    } catch {
      Write-Host "Errore aggiornamento $($app.Name): $($_.Exception.Message)" -ForegroundColor Red
      $failed++
    }
  }

  Write-Section "Esito aggiornamenti"
  Write-Host "Riusciti : $success"
  Write-Host "Falliti  : $failed"
  Write-Host "Saltati  : $skipped"
}

function Run-FastCheckFromCacheFlow {
  $results = Invoke-FastAuditFromCache
  Show-AuditSummary -Results $results
  $newly = Update-AuditArtifacts -Results $results -ModeLabel "Verifica rapida (cache + web)"

  Write-Section "Confronto rapido rispetto al run precedente"
  Write-Host "Nuove app da aggiornare: $($newly.Count)" -ForegroundColor Yellow
  if ($newly.Count -gt 0) {
    $newly | Select-Object Name, LocalVersion, LatestVersion, DownloadUrl | Sort-Object Name | Format-Table -AutoSize
  }
}

function Show-Menu {
  Write-Host ""
  Write-Host "App Web Updater (senza winget)" -ForegroundColor Green
  Write-Host "1) Verifica completa: registro + confronto versioni + link manuali"
  Write-Host "2) Verifica completa e aggiorna (conferma per-app o tutto automatico)"
  Write-Host "3) Verifica rapida da cache + confronto con riepilogo precedente"
  Write-Host "0) Esci"
}

if (-not (Initialize-Store)) {
  Write-Host "Impossibile inizializzare le cartelle locali. Uscita." -ForegroundColor Red
  exit 1
}
$shouldExit = $false

while ($true) {
  Show-Menu
  $choice = Read-Host "Seleziona opzione"
  try {
    switch ($choice) {
      "1" { Run-CheckOnlyFlow }
      "2" { Run-CheckAndUpdateFlow }
      "3" { Run-FastCheckFromCacheFlow }
      "0" { $shouldExit = $true }
      default { Write-Host "Scelta non valida." -ForegroundColor Red }
    }
  } catch {
    Write-Host "Errore durante l'esecuzione dell'operazione: $($_.Exception.Message)" -ForegroundColor Red
  }

  if ($shouldExit) { break }

  if (-not $NoPause) {
    Write-Host ""
    Read-Host "Premi INVIO per tornare al menu" | Out-Null
  }
}

Write-Host "Chiusura programma." -ForegroundColor Cyan
