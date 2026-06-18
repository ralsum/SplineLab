param(
  [int]$Port = 9222
)

function Get-OpenClawDashboardUrl {
  $fallbackUrl = "http://127.0.0.1:18789/"
  $wslExe = Join-Path $env:WINDIR "System32\wsl.exe"

  if (-not (Test-Path $wslExe)) {
    return $fallbackUrl
  }

  try {
    $output = & $wslExe -- bash -lc 'openclaw dashboard --yes --no-open' 2>&1
    foreach ($line in $output) {
      if ($line -match '^Dashboard URL:\s*(\S+)$') {
        return $matches[1]
      }
    }
  } catch {
    # Fall back to the local dashboard URL if the CLI probe is unavailable.
  }

  return $fallbackUrl
}

function Get-WslHostIp {
  $wslExe = Join-Path $env:WINDIR "System32\wsl.exe"
  if (-not (Test-Path $wslExe)) {
    return $null
  }

  try {
    $output = & $wslExe -- bash -lc "ip route | awk '/default/ {print \$3; exit}'" 2>$null
    $ip = ($output | Out-String).Trim()
    if ($ip) {
      return $ip
    }
  } catch {
    # Ignore and fall back to browser-only launch.
  }

  return $null
}

function Wait-ForBrowserDebugPort {
  param(
    [int]$TimeoutSeconds = 20
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $statusUrl = "http://127.0.0.1:$Port/json/version"

  while ((Get-Date) -lt $deadline) {
    try {
      Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 $statusUrl | Out-Null
      return $true
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }

  return $false
}

function Start-PlaywrightMcp {
  param(
    [string]$CdpHost
  )

  if (-not $CdpHost) {
    return
  }

  $wslExe = Join-Path $env:WINDIR "System32\wsl.exe"
  if (-not (Test-Path $wslExe)) {
    return
  }

  try {
    $existing = & $wslExe -- bash -lc "ss -ltn '( sport = :8931 )' 2>/dev/null | tail -n +2 | wc -l" 2>$null
    if (($existing | Out-String).Trim() -match '^[1-9]\d*$') {
      return
    }
  } catch {
    # Continue and try to launch a fresh MCP server.
  }

  $command = @"
cd ~
nohup npx -y @playwright/mcp@latest --port 8931 --cdp-endpoint=http://${CdpHost}:${Port} >/tmp/playwright-mcp.log 2>&1 &
"@

  try {
    Start-Process -WindowStyle Hidden -FilePath $wslExe -ArgumentList @("--", "bash", "-lc", $command) | Out-Null
  } catch {
    # Best-effort only. The browser should still launch even if MCP startup fails.
  }
}

function Update-OpenClawStatus {
  param(
    [string]$Message
  )

  $wslExe = Join-Path $env:WINDIR "System32\wsl.exe"
  if (-not (Test-Path $wslExe)) {
    return
  }

  $safeMessage = $Message.Replace("'", "'\''")
  try {
    & $wslExe -- bash -lc "printf '%s\n' '$safeMessage' > /tmp/openclaw-control-status.txt" | Out-Null
  } catch {
    # Best-effort only.
  }
}

$Url = Get-OpenClawDashboardUrl
$SplineLabUrl = "http://127.0.0.1:8792/spline-lab.html"
$UserDataDir = "$env:LOCALAPPDATA\OCBrowserProfile"

$candidates = @(
  $env:OC_CHROME_PATH,
  "C:\Program Files\Google\Chrome\Application\chrome.exe",
  "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
  "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
  "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
)

$resolved = $null
foreach ($candidate in $candidates) {
  if ($candidate -and (Test-Path $candidate)) {
    $resolved = $candidate
    break
  }
}

if (-not $resolved) {
  throw "Could not find Chrome or Edge."
}

New-Item -ItemType Directory -Force -Path $UserDataDir | Out-Null

$args = @(
  "--remote-debugging-port=$Port"
  "--remote-debugging-address=0.0.0.0"
  "--user-data-dir=$UserDataDir"
  "--no-first-run"
  "--no-default-browser-check"
  "--new-window"
  $Url
  $SplineLabUrl
)

Start-Process -FilePath $resolved -ArgumentList $args

if (Wait-ForBrowserDebugPort) {
  Start-PlaywrightMcp -CdpHost (Get-WslHostIp)
  $statusMessage = "OpenClaw control ready: Spline Lab open, Playwright MCP attach attempted on port 8931."
  Update-OpenClawStatus -Message $statusMessage
} else {
  $statusMessage = "OpenClaw control ready: browser launched, but Chrome DevTools port $Port did not respond in time."
  Update-OpenClawStatus -Message $statusMessage
}
