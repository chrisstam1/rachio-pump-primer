<#
.SYNOPSIS
  One-time helper: prints your Rachio controllers, zones, schedules and next-run
  times, and writes a starter config.json for Invoke-RachioPrimer.ps1.

.USAGE
  .\Get-RachioIds.ps1                      # prompts for the API token
  .\Get-RachioIds.ps1 -Token <your-token>

  Get the token in the Rachio app: Profile icon -> API key -> Copy.
#>
[CmdletBinding()]
param(
    [string]$Token
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Token) { $Token = $env:RACHIO_API_TOKEN }
if (-not $Token) {
    $secure = Read-Host -Prompt 'Paste your Rachio API token' -AsSecureString
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
$Token = $Token.Trim()

$headers = @{ Authorization = "Bearer $Token" }
$api   = 'https://api.rach.io/1/public'
$cloud = 'https://cloud-rest.rach.io'

Write-Host "Looking up account..." -ForegroundColor Cyan
$person = Invoke-RestMethod -Uri "$api/person/info" -Headers $headers
$me     = Invoke-RestMethod -Uri "$api/person/$($person.id)" -Headers $headers

$front = $null; $back = $null
foreach ($d in $me.devices) {
    Write-Host ""
    Write-Host "CONTROLLER: $($d.name)" -ForegroundColor Green
    Write-Host "  id        : $($d.id)"
    Write-Host "  status    : $($d.status)   timeZone: $($d.timeZone)"

    Write-Host "  zones:"
    foreach ($z in ($d.zones | Sort-Object zoneNumber)) {
        $flag = ''
        if (-not $z.enabled) { $flag = '  (disabled)' }
        Write-Host ("    {0,2}. {1,-28} {2}{3}" -f $z.zoneNumber, $z.name, $z.id, $flag)
    }

    Write-Host "  schedules:"
    foreach ($s in $d.scheduleRules)     { Write-Host ("    fixed : {0,-28} {1}" -f $s.name, $s.id) }
    foreach ($s in $d.flexScheduleRules) { Write-Host ("    flex  : {0,-28} {1}" -f $s.name, $s.id) }

    # Undocumented endpoint: next run time. Same token works.
    try {
        $st = Invoke-RestMethod -Uri "$cloud/device/getDeviceState/$($d.id)" -Headers $headers
        $nr = $st.state.nextRun
        if ($nr) {
            $local = ([DateTime]::Parse($nr, $null, 'AssumeUniversal, AdjustToUniversal')).ToLocalTime()
            Write-Host "  next run  : $nr (UTC)  =  $local (this PC's local time)"
        } else {
            Write-Host "  next run  : none reported"
        }
        if ($st.state.lastRun) { Write-Host "  last run  : $($st.state.lastRun) (UTC)" }
    } catch {
        Write-Warning "  getDeviceState failed for this controller: $($_.Exception.Message)"
    }

    try {
        $body = @{ device_id = $d.id } | ConvertTo-Json -Compress
        $ev = Invoke-RestMethod -Uri "$cloud/events/next" -Method Post -Headers $headers -ContentType 'application/json' -Body $body
        if ($ev.entry) {
            Write-Host "  next event: [$($ev.entry.type)] $($ev.entry.summary)  at $($ev.entry.timestamp)"
        }
    } catch {
        Write-Warning "  events/next failed for this controller: $($_.Exception.Message)"
    }

    if ($d.name -match 'front' -and -not $front) { $front = $d }
    if ($d.name -match 'back'  -and -not $back)  { $back  = $d }
}

# Write a starter config.json (never committed; see .gitignore)
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $cfgPath) {
    Write-Host ""
    Write-Host "config.json already exists; not overwriting it." -ForegroundColor Yellow
} else {
    $frontZone = $null
    if ($front) { $frontZone = $front.zones | Where-Object enabled | Sort-Object zoneNumber | Select-Object -First 1 }
    $cfg = [ordered]@{
        apiToken      = $Token
        backDeviceId  = if ($back)  { $back.id }  else { 'PASTE-BACK-CONTROLLER-ID' }
        frontDeviceId = if ($front) { $front.id } else { 'PASTE-FRONT-CONTROLLER-ID' }
        frontZoneId   = if ($frontZone) { $frontZone.id } else { 'PASTE-FRONT-ZONE-ID' }
        primeSeconds  = 60
        leadSeconds   = 105
    }
    $cfg | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding utf8
    Write-Host ""
    Write-Host "Wrote $cfgPath" -ForegroundColor Green
    if ($front -and $frontZone) { Write-Host "  front zone guessed as '$($frontZone.name)' on '$($front.name)'. Edit if you want a different zone." }
    if (-not $front -or -not $back) { Write-Host "  Could not tell front from back by name. Open config.json and paste the ids from above." -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "For GitHub Actions, add these repository secrets:" -ForegroundColor Cyan
Write-Host "  RACHIO_API_TOKEN      = (your token)"
Write-Host "  RACHIO_BACK_DEVICE_ID = $(if ($back) { $back.id } else { '<back controller id>' })"
Write-Host "  RACHIO_FRONT_DEVICE_ID= $(if ($front) { $front.id } else { '<front controller id>' })"
Write-Host "  RACHIO_FRONT_ZONE_ID  = $(if ($frontZone) { $frontZone.id } else { '<front zone id>' })"
