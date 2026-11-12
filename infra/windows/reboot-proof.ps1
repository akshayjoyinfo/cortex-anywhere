<#
Reboot proof (field test Phase 4). Shows that the whole local install comes back by itself.

  -Phase before   records boot time, services, Ollama and app health, then asks for a restart
  -Phase after    after the restart and an RDP login: proves the machine really rebooted,
                  every part started on its own after boot, the app answers as the install
                  tenant, the desired state still holds (bootstrap -Operation test), and one
                  agent run works end to end

Evidence: C:\ProgramData\Cortex\logs\reboot\<run_id>\before.json, after.json, result.json
Run elevated from the extracted bundle:
  powershell -NoProfile -ExecutionPolicy Bypass -File infra\windows\reboot-proof.ps1 -Phase before
  Restart-Computer
  powershell -NoProfile -ExecutionPolicy Bypass -File infra\windows\reboot-proof.ps1 -Phase after
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)] [ValidateSet('before', 'after')] [string] $Phase)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\ProgramData\Cortex\logs\reboot'
$Pending = Join-Path $Root 'pending.json'
$ConfigPath = 'C:\ProgramData\Cortex\config\cortex.json'
$Utf8 = New-Object System.Text.UTF8Encoding $false

function Save-Json([string] $Path, $Obj) { [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 8), $Utf8) }

function Get-Http([string] $Url, [switch] $Windows, [string] $PostJson = '', [int] $Timeout = 15) {
  try {
    $p = @{ Uri = $Url; UseBasicParsing = $true; UseDefaultCredentials = [bool]$Windows; TimeoutSec = $Timeout }
    if ($PostJson -ne '') { $p.Method = 'Post'; $p.Body = [Text.Encoding]::UTF8.GetBytes($PostJson); $p.ContentType = 'application/json; charset=utf-8' }
    $r = Invoke-WebRequest @p
    @{ status = [int]$r.StatusCode; body = $r.Content }
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    @{ status = $(if ($resp) { [int]$resp.StatusCode } else { 0 }); body = '' }
  }
}

function Get-State {
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
  $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
  $port = [int]$cfg.Cortex.Local.Port
  $services = foreach ($n in 'cortex-postgres', 'cortex-web') {
    $s = Get-CimInstance Win32_Service -Filter "Name='$n'"
    $started = $null
    if ($s -and $s.ProcessId) {
      $p = Get-Process -Id $s.ProcessId -ErrorAction SilentlyContinue
      if ($p) { $started = $p.StartTime.ToUniversalTime() }
    }
    [ordered]@{
      name = $n; state = $(if ($s) { $s.State }); start_mode = $(if ($s) { $s.StartMode }); account = $(if ($s) { $s.StartName })
      started = $(if ($started) { $started.ToString('o') }); seconds_after_boot = $(if ($started) { [math]::Round(($started - $boot).TotalSeconds, 1) })
    }
  }
  $ollamaProc = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like 'C:\Program Files\Cortex\ollama\ollama.exe' }) | Select-Object -First 1
  $ollamaVersion = $null
  try { $ollamaVersion = (Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -UseBasicParsing -TimeoutSec 5).version } catch { }
  $task = Get-ScheduledTask -TaskName 'cortex-ollama' -ErrorAction SilentlyContinue
  $who = Get-Http "http://127.0.0.1:$port/api/whoami" -Windows
  [ordered]@{
    taken = [DateTime]::UtcNow.ToString('o'); boot = $boot.ToString('o'); services = @($services)
    ollama = [ordered]@{
      task = $(if ($task) { "$($task.State)" }); serving = $ollamaVersion
      started = $(if ($ollamaProc) { $ollamaProc.StartTime.ToUniversalTime().ToString('o') })
      seconds_after_boot = $(if ($ollamaProc) { [math]::Round(($ollamaProc.StartTime.ToUniversalTime() - $boot).TotalSeconds, 1) })
    }
    app = [ordered]@{ alive = (Get-Http "http://127.0.0.1:$port/alive").status; whoami = $who.status; tenant = $(if ($who.status -eq 200) { ($who.body | ConvertFrom-Json).tenant }) }
    install_tenant = "$($cfg.Cortex.Local.TenantId)"; port = $port
  }
}

New-Item -ItemType Directory -Force $Root | Out-Null

if ($Phase -eq 'before') {
  $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
  $dir = Join-Path $Root $runId
  New-Item -ItemType Directory -Force $dir | Out-Null
  $s = Get-State
  Save-Json (Join-Path $dir 'before.json') $s
  Save-Json $Pending @{ run_id = $runId; dir = $dir; boot = $s.boot }
  Write-Host "Cortex reboot proof  run=$runId  phase=before"
  Write-Host "  boot          $($s.boot)"
  foreach ($x in $s.services) { Write-Host ("  {0,-16} {1} ({2}, {3})" -f $x.name, $x.state, $x.start_mode, $x.account) }
  Write-Host "  ollama        task=$($s.ollama.task) serving=$($s.ollama.serving)"
  Write-Host "  app           alive=$($s.app.alive) whoami=$($s.app.whoami)"
  Write-Host ''
  Write-Host 'Now restart the machine:  Restart-Computer'
  Write-Host 'After the restart, log in over RDP and run this script with -Phase after.'
  exit 0
}

# ---------------------------------------------------------------- after
if (-not (Test-Path $Pending)) { throw 'No pending reboot proof. Run -Phase before first.' }
$p = Get-Content $Pending -Raw | ConvertFrom-Json
$before = Get-Content (Join-Path $p.dir 'before.json') -Raw | ConvertFrom-Json
$s = Get-State
Save-Json (Join-Path $p.dir 'after.json') $s
$checks = New-Object System.Collections.ArrayList
function Add-Check([string] $Name, [bool] $Pass, $Detail) {
  [void]$checks.Add([ordered]@{ check = $Name; pass = $Pass; detail = $Detail })
  Write-Host ("    {0,-4} {1}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name)
}

Write-Host "Cortex reboot proof  run=$($p.run_id)  phase=after"
$rebooted = [DateTime]::Parse($s.boot) -gt [DateTime]::Parse($before.boot)
Add-Check "machine really rebooted (boot $($before.boot) -> $($s.boot))" $rebooted @{ before = $before.boot; after = $s.boot }
foreach ($x in $s.services) {
  Add-Check ("{0} running, started by itself {1}s after boot" -f $x.name, $x.seconds_after_boot) `
    ($x.state -eq 'Running' -and $x.start_mode -eq 'Auto' -and $null -ne $x.seconds_after_boot -and $x.seconds_after_boot -ge 0) $x
}
Add-Check ("ollama serving {0}, started by its boot task {1}s after boot" -f $s.ollama.serving, $s.ollama.seconds_after_boot) `
  ($s.ollama.serving -and $null -ne $s.ollama.seconds_after_boot -and $s.ollama.seconds_after_boot -ge 0) $s.ollama
Add-Check 'app answers as the install tenant (Windows auth)' ($s.app.alive -eq 200 -and $s.app.whoami -eq 200 -and "$($s.app.tenant)" -eq $s.install_tenant) $s.app

# Desired state still holds: the same drift check the installer runs.
$bundle = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bundle 'infra\windows\bootstrap.ps1') -Operation test | Out-Host
Add-Check 'desired state holds after reboot (bootstrap -Operation test)' ($LASTEXITCODE -eq 0) @{ exit = $LASTEXITCODE }

# One agent run end to end after the reboot (cold model load included).
$sw = [Diagnostics.Stopwatch]::StartNew()
$run = Get-Http "http://127.0.0.1:$($s.port)/api/agents/assistant/runs" -Windows -PostJson '{"input":"When is our support desk open?"}' -Timeout 900
$body = $null
if ($run.status -eq 200) { $body = $run.body | ConvertFrom-Json }
Add-Check ("agent run after reboot ({0}s wall, {1})" -f [math]::Round($sw.Elapsed.TotalSeconds, 1), $(if ($body) { $body.stop } else { "HTTP $($run.status)" })) `
  ($run.status -eq 200 -and $body.stop -eq 'Answered') @{ status = $run.status; output = $(if ($body) { $body.output }); metrics = $(if ($body) { $body.metrics }) }
if ($body) { Write-Host "         answer: $(("$($body.output)" -replace '\s+', ' '))" }

$ok = -not @($checks | Where-Object { -not $_.pass }).Count
Save-Json (Join-Path $p.dir 'result.json') ([ordered]@{ run_id = $p.run_id; ok = $ok; checks = $checks })
Remove-Item $Pending -Force
Write-Host ''
Write-Host ("Result: {0}" -f $(if ($ok) { 'OK' } else { 'FAILED' }))
Write-Host "Evidence: $($p.dir)"
if (-not $ok) { exit 1 }
