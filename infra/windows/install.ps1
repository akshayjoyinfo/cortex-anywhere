<#
Timed install (field test Phase 5): fresh Windows Server to a working agent, in minutes.

  1. Runs bootstrap.ps1 (pinned dsc, every component, drift check).
  2. Waits for the app service, then sends one real agent run as the logged-in Windows user.
  3. Writes C:\ProgramData\Cortex\logs\install\<run_id>\install.json with the total time,
     the time per bootstrap step and per component (from the step logs), host facts,
     and how long the first answer took.

Run elevated from the extracted bundle:
  powershell -NoProfile -ExecutionPolicy Bypass -File infra\windows\install.ps1 [-OperatorAccess]
#>
[CmdletBinding()]
param([switch] $OperatorAccess)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Started = [DateTime]::UtcNow
$clock = [Diagnostics.Stopwatch]::StartNew()
$Utf8 = New-Object System.Text.UTF8Encoding $false
$RunId = $Started.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$Dir = "C:\ProgramData\Cortex\logs\install\$RunId"
New-Item -ItemType Directory -Force $Dir | Out-Null
Write-Host "Cortex timed install  run=$RunId  logs=$Dir"

# 1. Bootstrap ----------------------------------------------------------------
$bootArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'bootstrap.ps1'))
if ($OperatorAccess) { $bootArgs += '-OperatorAccess' }
& powershell @bootArgs | Out-Host
$bootExit = $LASTEXITCODE
$bootMinutes = [math]::Round($clock.Elapsed.TotalMinutes, 2)

# The bootstrap run this install produced: the last line of runs.jsonl.
$bootRun = (Get-Content 'C:\ProgramData\Cortex\logs\runs.jsonl' | Select-Object -Last 1) | ConvertFrom-Json
$stepsFile = "C:\ProgramData\Cortex\logs\runs\$($bootRun.run_id)\steps.jsonl"

# Seconds per component during `dsc config set`: from its first set step to its last.
$components = @()
if (Test-Path $stepsFile) {
  $rows = @(Get-Content $stepsFile | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.op -eq 'set' })
  foreach ($g in ($rows | Group-Object resource)) {
    $t = @($g.Group | ForEach-Object { [DateTime]::Parse($_.ts) } | Sort-Object)
    $components += [ordered]@{ component = $g.Name; seconds = [math]::Round(($t[-1] - $t[0]).TotalSeconds, 1)
      changed = [bool](@($g.Group | Where-Object { $_.step -eq 'drift' }).Count) }
  }
  $components = @($components | Sort-Object { $_.seconds } -Descending)
}

# 2. First answer ---------------------------------------------------------------
$first = [ordered]@{ status = 0; seconds = $null; stop = $null; output = $null; metrics = $null }
if ($bootExit -eq 0) {
  $cfg = Get-Content 'C:\ProgramData\Cortex\config\cortex.json' -Raw | ConvertFrom-Json
  $base = "http://127.0.0.1:$([int]$cfg.Cortex.Local.Port)"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-WebRequest -Uri "$base/api/agents/assistant/runs" -Method Post -UseBasicParsing -UseDefaultCredentials -TimeoutSec 900 `
      -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes('{"input":"Please remember: our support desk is open 08:00 to 16:00 CET, Monday to Friday."}'))
    $b = $r.Content | ConvertFrom-Json
    $first = [ordered]@{ status = [int]$r.StatusCode; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); stop = $b.stop; output = $b.output; metrics = $b.metrics }
  } catch {
    $first.status = -1; $first.output = $_.Exception.Message
  }
}
$totalMinutes = [math]::Round($clock.Elapsed.TotalMinutes, 2)
$ok = ($bootExit -eq 0) -and ($first.status -eq 200) -and ($first.stop -eq 'Answered')

$host_ = $null
$hostFile = "C:\ProgramData\Cortex\logs\runs\$($bootRun.run_id)\host.json"
if (Test-Path $hostFile) { $host_ = Get-Content $hostFile -Raw | ConvertFrom-Json }
$summary = [ordered]@{
  run_id = $RunId; started = $Started.ToString('o'); ok = $ok
  minutes_total = $totalMinutes; minutes_bootstrap = $bootMinutes; bootstrap_run = $bootRun.run_id; bootstrap_exit = $bootExit
  first_answer = $first; components = $components; host = $host_; operator_access = [bool]$OperatorAccess
}
[IO.File]::WriteAllText((Join-Path $Dir 'install.json'), ($summary | ConvertTo-Json -Depth 8), $Utf8)

Write-Host ''
Write-Host 'Time per component (dsc set):'
foreach ($c in $components) { Write-Host ("  {0,-22} {1,7}s {2}" -f $c.component, $c.seconds, $(if ($c.changed) { 'installed' } else { 'already in place' })) }
Write-Host ''
Write-Host ("Bootstrap:      {0} min" -f $bootMinutes)
Write-Host ("First answer:   {0}s  ({1}, {2} tok/s)" -f $first.seconds, $first.stop, $(if ($first.metrics) { $first.metrics.outputTokensPerSecond } else { '-' }))
Write-Host ("TOTAL:          {0} min  fresh server to working agent" -f $totalMinutes)
Write-Host ("Result: {0}" -f $(if ($ok) { 'OK' } else { 'FAILED' }))
Write-Host "Evidence: $Dir"
if (-not $ok) { exit 1 }
