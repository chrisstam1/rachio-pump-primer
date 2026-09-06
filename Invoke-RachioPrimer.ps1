<#
.SYNOPSIS
  Runs one front-yard zone for a short "primer" shortly before the back-yard
  controller's next scheduled run, so the well pump is already running when the
  back zones open. The back controller's schedule (weather skips, smart durations,
  shifting start times) is never touched; this script only reads its next-run time.

.HOW IT WORKS
  1. Ask the back controller for its next run time (undocumented Rachio endpoint
     device/getDeviceState, the same one Rachio's own app uses).
  2. If that run starts within -LookaheadMinutes, wait until -LeadSeconds before it.
  3. Re-check: still a real run (not a weather skip)? Front idle? Back not already on?
  4. Start the front zone for -PrimeSeconds via the official zone/start endpoint.
  Otherwise exit quietly. Run it every few minutes from a scheduler.

.CONFIG
  Environment variables (used by GitHub Actions) take priority:
    RACHIO_API_TOKEN, RACHIO_BACK_DEVICE_ID, RACHIO_FRONT_DEVICE_ID, RACHIO_FRONT_ZONE_ID
    RACHIO_PRIME_SECONDS, RACHIO_LEAD_SECONDS (optional)
  Otherwise config.json next to this script (created by Get-RachioIds.ps1).

.EXAMPLES
  .\Invoke-RachioPrimer.ps1                    # normal scheduled run
  .\Invoke-RachioPrimer.ps1 -DryRun            # log what would happen, start nothing
  .\Invoke-RachioPrimer.ps1 -PrimeNow          # start the primer immediately (test the pump)
#>
[CmdletBinding()]
param(
    [int]$LookaheadMinutes = 22,   # act only if the back run starts within this many minutes
    [int]$LeadSeconds,             # start primer this many seconds before the back run (default 105)
    [int]$PrimeSeconds,            # primer length in seconds (default 60)
    [switch]$DryRun,
    [switch]$PrimeNow
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Log($msg) { Write-Host ("{0:u}  {1}" -f (Get-Date).ToUniversalTime(), $msg) }

# ---------- configuration ----------
$cfg = @{}
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $cfgPath) {
    $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
    foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
}
function Cfg($envName, $cfgName, $default) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return $v }
    if ($cfg.ContainsKey($cfgName) -and $cfg[$cfgName]) { return $cfg[$cfgName] }
    return $default
}
$token   = Cfg 'RACHIO_API_TOKEN'       'apiToken'      $null
$backId  = Cfg 'RACHIO_BACK_DEVICE_ID'  'backDeviceId'  $null
$frontId = Cfg 'RACHIO_FRONT_DEVICE_ID' 'frontDeviceId' $null
$zoneId  = Cfg 'RACHIO_FRONT_ZONE_ID'   'frontZoneId'   $null
if (-not $PrimeSeconds) { $PrimeSeconds = [int](Cfg 'RACHIO_PRIME_SECONDS' 'primeSeconds' 60) }
if (-not $LeadSeconds)  { $LeadSeconds  = [int](Cfg 'RACHIO_LEAD_SECONDS'  'leadSeconds'  105) }

foreach ($pair in @(@('token',$token), @('back device id',$backId), @('front device id',$frontId), @('front zone id',$zoneId))) {
    if (-not $pair[1] -or $pair[1] -like 'PASTE-*') { throw "Missing $($pair[0]). Run Get-RachioIds.ps1 or set the environment variables." }
}
if ($LeadSeconds -lt $PrimeSeconds + 15) { throw "leadSeconds ($LeadSeconds) must be at least primeSeconds + 15 so the primer finishes before the back starts." }

$headers = @{ Authorization = "Bearer $token" }
$api   = 'https://api.rach.io/1/public'
$cloud = 'https://cloud-rest.rach.io'

# ---------- API helpers ----------
function Get-NextRunUtc {
    $st = Invoke-RestMethod -Uri "$cloud/device/getDeviceState/$backId" -Headers $headers
    $nr = $st.state.nextRun
    if (-not $nr) { return $null }
    return [DateTime]::Parse($nr, $null, 'AssumeUniversal, AdjustToUniversal')
}

function Get-NextEvent {
    # Returns the next feed entry (type/summary/timestamp) or $null if the call fails.
    try {
        $body = @{ device_id = $backId } | ConvertTo-Json -Compress
        $ev = Invoke-RestMethod -Uri "$cloud/events/next" -Method Post -Headers $headers -ContentType 'application/json' -Body $body
        return $ev.entry
    } catch {
        Log "events/next unavailable ($($_.Exception.Message)); assuming the run is not skipped."
        return $null
    }
}

function Test-Watering($deviceId) {
    $cs = Invoke-RestMethod -Uri "$api/device/$deviceId/current_schedule" -Headers $headers
    return ($cs -and $cs.status -eq 'PROCESSING')
}

function Start-Primer {
    if (Test-Watering $frontId) { Log "Front controller is already watering; pump is on. No primer needed."; return }
    if (Test-Watering $backId)  { Log "Back controller is already watering. Skipping primer."; return }
    if ($DryRun) { Log "DRY RUN: would start front zone $zoneId for $PrimeSeconds s."; return }
    $body = @{ id = $zoneId; duration = $PrimeSeconds } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$api/zone/start" -Method Put -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
    Log "PRIMER STARTED: front zone $zoneId for $PrimeSeconds s."
}

# ---------- main ----------
if ($PrimeNow) { Start-Primer; exit 0 }

$now = (Get-Date).ToUniversalTime()
$nextRun = Get-NextRunUtc
if (-not $nextRun) { Log "Back controller reports no upcoming run."; exit 0 }

$fireAt = $nextRun.AddSeconds(-$LeadSeconds)
$untilRun = ($nextRun - $now).TotalSeconds
Log ("Back next run {0:u} (in {1:N1} min). Primer slot {2:u}." -f $nextRun, ($untilRun/60), $fireAt)

if ($untilRun -lt ($PrimeSeconds + 15)) {
    Log "Back run starts too soon for a primer to finish first (or has started). Nothing to do."
    exit 0
}
if (($fireAt - $now).TotalMinutes -gt $LookaheadMinutes) {
    Log "Outside the $LookaheadMinutes-minute lookahead window. Nothing to do."
    exit 0
}

# Wait for the slot (short sleeps so the process stays responsive).
while (((Get-Date).ToUniversalTime()) -lt $fireAt) {
    $left = ($fireAt - (Get-Date).ToUniversalTime()).TotalSeconds
    Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min(60, [int]$left)))
}

# Re-check right before firing: the run may have been skipped or moved during the wait.
$nextRun2 = Get-NextRunUtc
if (-not $nextRun2 -or [Math]::Abs(($nextRun2 - $nextRun).TotalMinutes) -gt 5) {
    Log ("Next run changed during the wait (now {0}). Skipping primer." -f $nextRun2)
    exit 0
}
$ev = Get-NextEvent
if ($ev) {
    Log "Next event: [$($ev.type)] $($ev.summary)"
    $evTime = $null
    if ($ev.timestamp) { try { $evTime = [DateTime]::Parse($ev.timestamp, $null, 'AssumeUniversal, AdjustToUniversal') } catch {} }
    $sameRun = (-not $evTime) -or ([Math]::Abs(($evTime - $nextRun).TotalMinutes) -le 15)
    if ($ev.type -match 'SKIP' -and $sameRun) { Log "The next back run is a skip. Not priming."; exit 0 }
}

Start-Primer
