# Rachio pump primer

Interim workaround for a well pump that will not start on a cold call from the
back-yard Rachio, but runs fine once a front-yard zone has kicked it on.

The back controller's schedule stays exactly as it is in the Rachio app:
weather skips, smart durations, and shifting start times all keep working.
A small script reads the back controller's **next run time** and starts one
front zone for about a minute shortly before it, finishing about 45 seconds
before the back zones open.

## Files

| File | Purpose |
|------|---------|
| `Get-RachioIds.ps1` | One-time helper. Prints controllers, zones, schedules and next-run times. Writes `config.json`. |
| `Invoke-RachioPrimer.ps1` | The primer. Run it every few minutes from a scheduler. |
| `.github/workflows/rachio-primer.yml` | Runs the primer on GitHub Actions, no home hardware needed. |
| `config.json` | Created by the helper. Holds your API token. Git-ignored. |

## Step 1: get your IDs

In the Rachio app: Profile icon, then **API key**, then Copy. Then in PowerShell:

```powershell
cd "C:\Users\ChrisStam\OneDrive - Wtmrk\Documents\rachio api"
.\Get-RachioIds.ps1
```

It prints both controllers with their zones and the back controller's next run
time in UTC and local time. It writes `config.json`, guessing front and back by
controller name and picking the lowest-numbered enabled front zone as the primer
zone. Open `config.json` and change `frontZoneId` if you want a different zone.

## Step 2: test from this PC

```powershell
..Invoke-RachioPrimer.ps1 -DryRun -LookaheadMinutes 1440
```

This waits until the primer slot and logs what it would do without starting
anything. Press Ctrl+C to stop the wait. To confirm the pump physically
responds, start the primer immediately:

```powershell
.\Invoke-RachioPrimer.ps1 -PrimeNow
```

## Step 3: schedule it

### Option A: GitHub Actions (recommended if nothing at home stays awake)

1. Create a **private** GitHub repo and push this folder (`config.json` is
   ignored automatically).
2. In the repo go to Settings, Secrets and variables, Actions, and add four
   secrets. The helper script prints their values:
   `RACHIO_API_TOKEN`, `RACHIO_BACK_DEVICE_ID`, `RACHIO_FRONT_DEVICE_ID`,
   `RACHIO_FRONT_ZONE_ID`.
3. Edit the `cron` line in `.github/workflows/rachio-primer.yml` so it covers
   the window in which the back schedule can start. Cron is in UTC. The default
   runs every 10 minutes from 09:00 to 11:50 UTC, which covers a 6:00 AM Eastern start in both daylight and standard time.
4. Test from the Actions tab: run the workflow manually with mode `dry-run`.
   Then `prime-now` to hear the pump start.

Each scheduled run costs about a minute of Actions time unless it is the one
that waits for the slot. With a four-hour daily window that is roughly 40 to 60
minutes per day, inside the free tier for private repos. GitHub cron can lag
and thin out runs at busy times; in practice runs land about every 15 to 20 minutes. The 35-minute lookahead absorbs that.

### Option B: this PC with Task Scheduler

Only if the PC is awake at watering time. Run once in an elevated PowerShell:

```powershell
$here = "C:\Users\ChrisStam\OneDrive - Wtmrk\Documents\rachio api"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$here\Invoke-RachioPrimer.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 40)
Register-ScheduledTask -TaskName 'Rachio pump primer' -Action $action -Trigger $trigger -Settings $settings
```

## Tuning

Settings live in `config.json` (or the matching environment variables):

| Setting | Default | Meaning |
|---------|---------|---------|
| `primeSeconds` | 60 | How long the front zone runs. |
| `leadSeconds` | 105 | How many seconds before the back run the primer starts. Must be at least `primeSeconds` + 15. |

With the defaults the primer ends 45 seconds before the back starts. Rachio
takes a few seconds to relay a start command, so keep the gap at 30 seconds or
more: `leadSeconds` 90 is the practical floor with a 60-second primer. Your
test used a 5-minute front run, so if the back is still weak, try
`primeSeconds` 120 and `leadSeconds` 165.

## How skips are handled

Before starting the primer the script re-reads the next run time and asks the
back controller for its next feed event. If that event is a rain, wind, freeze,
or soil-saturation skip for the same run, no primer runs. It also checks that
neither controller is already watering.

## Caveats

- `device/getDeviceState` and `events/next` on `cloud-rest.rach.io` are the
  endpoints Rachio's own app uses. Rachio allows their use but does not
  document or support them, so they could change without notice. Everything
  else is the official public API.
- If the two controllers ever water at the same time the pump may not keep up.
  Keep the front schedule clear of the back schedule's start window.
- This is a workaround. The real fix from the earlier diagnosis is the pressure
  switch, its sensing nipple, or the tank precharge.
