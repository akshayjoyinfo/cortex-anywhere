<#
Phase 1 verification on a provisioned Windows host (ADR 014: versioned, logged, nothing typed by hand).

  1. Builds the solution with the pinned SDK (C:\Program Files\Cortex\dotnet).
  2. Runs the unit, security and integration test projects.
  3. Starts the app in the LOCAL profile and checks it from outside:
     health, anonymous call refused, Windows auth gives the install tenant,
     the database path sees exactly one tenant through FORCED RLS, and the
     process listens on loopback only even when ASPNETCORE_URLS asks for 0.0.0.0.
  4. Writes C:\ProgramData\Cortex\logs\verify\<run_id>\verify.json plus build, test and app logs.

Run elevated from the extracted bundle, after bootstrap.ps1:
  powershell -NoProfile -ExecutionPolicy Bypass -File infra\windows\verify-app.ps1
#>
[CmdletBinding()]
param([string] $ConfigPath = 'C:\ProgramData\Cortex\config\cortex.json')

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'resources\common.ps1')

$Bundle = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$DotnetDir = 'C:\Program Files\Cortex\dotnet'
$Dotnet = Join-Path $DotnetDir 'dotnet.exe'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$RunId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$RunDir = "C:\ProgramData\Cortex\logs\verify\$RunId"
$Steps = New-Object System.Collections.ArrayList
$Checks = New-Object System.Collections.ArrayList
$Started = [DateTime]::UtcNow
$DotnetEnv = @{ DOTNET_ROOT = $DotnetDir; DOTNET_CLI_TELEMETRY_OPTOUT = '1'; DOTNET_NOLOGO = '1'; DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1' }

function Save-Text([string] $Name, [string] $Text) { [IO.File]::WriteAllText((Join-Path $RunDir $Name), $Text, $Utf8) }

function Invoke-Step([string] $Name, [scriptblock] $Body) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rec = [ordered]@{ step = $Name; status = 'ok'; seconds = 0; detail = $null }
  try { $rec.detail = & $Body }
  catch { $rec.status = 'failed'; $rec.detail = $_.Exception.Message; throw }
  finally {
    $rec.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    [void]$Steps.Add($rec)
    Write-Host ("[{0,-16}] {1,-6} {2,7}s" -f $Name, $rec.status, $rec.seconds)
  }
}

function Add-Check([string] $Name, [bool] $Pass, $Detail, [switch] $Soft) {
  [void]$Checks.Add([ordered]@{ check = $Name; pass = $Pass; soft = [bool]$Soft; detail = $Detail })
  $label = if ($Pass) { 'PASS' } elseif ($Soft) { 'INFO' } else { 'FAIL' }
  Write-Host ("    {0,-4} {1}" -f $label, $Name)
}

function Invoke-HttpPost([string] $Url, [string] $Json) {
  try {
    $r = Invoke-WebRequest -Uri $Url -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($Json)) -ContentType 'application/json; charset=utf-8' `
      -UseBasicParsing -UseDefaultCredentials -TimeoutSec 900
    @{ status = [int]$r.StatusCode; body = $r.Content }
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if ($resp) { @{ status = [int]$resp.StatusCode; body = '' } } else { @{ status = 0; body = $_.Exception.Message } }
  }
}

# Run from the bundle root: dotnet reads global.json (test runner = Microsoft.Testing.Platform)
# from the working directory upward, and `dotnet test --project` only exists in that mode.
function Invoke-Dotnet([string[]] $DotnetArgs, [string] $Log) {
  $r = Invoke-Native $Dotnet $DotnetArgs $DotnetEnv -WorkingDirectory $Bundle
  Save-Text $Log ($r.Out + "`n--- stderr ---`n" + $r.Err)
  $r
}

function Get-TestCounts([string] $Text) {
  $c = [ordered]@{}
  foreach ($k in 'total', 'failed', 'succeeded', 'skipped') {
    $m = [regex]::Match($Text, "(?m)^\s*${k}:\s*(\d+)")
    $c[$k] = $(if ($m.Success) { [int]$m.Groups[1].Value } else { $null })
  }
  $c
}

function Invoke-Http([string] $Url, [switch] $Windows) {
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UseDefaultCredentials:$Windows -TimeoutSec 15
    @{ status = [int]$r.StatusCode; body = $r.Content }
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if ($resp) { @{ status = [int]$resp.StatusCode; body = '' } } else { @{ status = 0; body = $_.Exception.Message } }
  }
}

# ---------------------------------------------------------------- run
New-Item -ItemType Directory -Force $RunDir | Out-Null
Write-Host "Cortex verify  run=$RunId  logs=$RunDir"
$failed = $null
$app = $null
try {
  Invoke-Step 'sdk' {
    if (-not (Test-Path $Dotnet)) { throw "pinned SDK not found at $Dotnet; run bootstrap.ps1 first" }
    (Invoke-Native $Dotnet @('--version') $DotnetEnv).Out.Trim()
  } | Out-Null

  Invoke-Step 'build' {
    $r = Invoke-Dotnet @('build', (Join-Path $Bundle 'Cortex.sln'), '-c', 'Release', '-nologo') 'build.log'
    if ($r.Code) { throw "build failed (exit $($r.Code)); see build.log" }
    'Release'
  } | Out-Null

  Invoke-Step 'tests' {
    $all = [ordered]@{}
    foreach ($p in 'Cortex.UnitTests', 'Cortex.SecurityTests', 'Cortex.IntegrationTests') {
      $r = Invoke-Dotnet @('test', '--project', (Join-Path $Bundle "tests\$p"), '-c', 'Release', '--no-build') "test-$p.log"
      $counts = Get-TestCounts $r.Out
      $counts['exit'] = $r.Code
      $all[$p] = $counts
      Add-Check "tests $p (total $($counts.total), failed $($counts.failed), skipped $($counts.skipped))" ($r.Code -eq 0) $counts
      if ($r.Code) {
        # Show the cause on screen; the full output is in test-$p.log.
        $lines = @(($r.Out + "`n" + $r.Err) -split "`r?`n" | Where-Object { $_ -match 'error|fail|exception|unrecognized|not found' } | Select-Object -First 6)
        foreach ($l in $lines) { Write-Host "         $($l.Trim())" }
      }
    }
    if (@($all.Values | Where-Object { $_.exit -ne 0 }).Count) { throw 'test failures; see test-*.log' }
    $all
  } | Out-Null

  Invoke-Step 'app-start' {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $port = [int]$cfg.Cortex.Local.Port
    $dll = Join-Path $Bundle 'src\Cortex.Web\bin\Release\net10.0\Cortex.Web.dll'
    # Hostile on purpose: the local profile must ignore a request to bind to every interface.
    $env:CORTEX_PROFILE = 'local'; $env:ASPNETCORE_URLS = 'http://0.0.0.0:5081'
    foreach ($k in $DotnetEnv.Keys) { Set-Item "env:$k" $DotnetEnv[$k] }
    $script:app = Start-Process -FilePath $Dotnet -ArgumentList ('"{0}" web' -f $dll) -PassThru -NoNewWindow `
      -RedirectStandardOutput (Join-Path $RunDir 'app.out.log') -RedirectStandardError (Join-Path $RunDir 'app.err.log')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 60) {
      if ($script:app.HasExited) { throw "app exited with $($script:app.ExitCode); see app.err.log" }
      if ((Invoke-Http "http://127.0.0.1:$port/alive").status -eq 200) { break }
      Start-Sleep -Milliseconds 500
    }
    if ($sw.Elapsed.TotalSeconds -ge 60) { throw 'app not healthy after 60s' }
    [ordered]@{ pid = $script:app.Id; port = $port; ready_seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
  } | Out-Null

  Invoke-Step 'app-checks' {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $port = [int]$cfg.Cortex.Local.Port
    $base = "http://127.0.0.1:$port"

    $anon = Invoke-Http "$base/api/whoami"
    Add-Check 'anonymous call is refused (401)' ($anon.status -eq 401) @{ status = $anon.status }

    $who = Invoke-Http "$base/api/whoami" -Windows
    $whoBody = $null
    if ($who.status -eq 200) { $whoBody = $who.body | ConvertFrom-Json }
    Add-Check 'Windows user gets the install tenant' ($who.status -eq 200 -and "$($whoBody.tenant)" -eq "$($cfg.Cortex.Local.TenantId)" -and $whoBody.profile -eq 'local') @{ status = $who.status; body = $whoBody }

    $ten = Invoke-Http "$base/api/tenant" -Windows
    $tenBody = $null
    if ($ten.status -eq 200) { $tenBody = $ten.body | ConvertFrom-Json }
    Add-Check 'cortex_app sees exactly its own tenant (FORCED RLS)' ($ten.status -eq 200 -and $tenBody.visibleTenants -eq 1 -and $tenBody.name -eq $cfg.Cortex.Local.TenantName) @{ status = $ten.status; body = $tenBody }

    $listen = @(Get-NetTCPConnection -OwningProcess $script:app.Id -State Listen -ErrorAction SilentlyContinue | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" })
    $exposed = @($listen | Where-Object { $_ -notmatch '^(127\.0\.0\.1|::1):' })
    Add-Check 'listens on loopback only, ASPNETCORE_URLS=0.0.0.0 ignored' ($listen.Count -gt 0 -and $exposed.Count -eq 0) @{ listening = $listen }

    $p = Get-Process -Id $script:app.Id
    [ordered]@{ working_set_mb = [math]::Round($p.WorkingSet64 / 1MB, 1); private_mb = [math]::Round($p.PrivateMemorySize64 / 1MB, 1) }
  } | Out-Null

  Invoke-Step 'agent-runs' {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $base = "http://127.0.0.1:$([int]$cfg.Cortex.Local.Port)"
    $runs = @()
    $prompts = @(
      'Please remember this for later: our support desk is open 08:00 to 16:00 CET, Monday to Friday.',
      'When is our support desk open?')
    foreach ($prompt in $prompts) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $r = Invoke-HttpPost "$base/api/agents/assistant/runs" (@{ input = $prompt } | ConvertTo-Json -Compress)
      $body = $null
      if ($r.status -eq 200) { $body = $r.body | ConvertFrom-Json }
      $runs += [ordered]@{ input = $prompt; status = $r.status; wall_seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); body = $body; error = $(if ($r.status -ne 200) { $r.body }) }
      Add-Check "agent run completes: '$($prompt.Substring(0, [Math]::Min(40, $prompt.Length)))...'" ($r.status -eq 200 -and $body.stop -eq 'Answered' -and "$($body.output)".Trim() -ne '') @{ status = $r.status; stop = $(if ($body) { $body.stop }) }
      if ($body) {
        $mt = $body.metrics
        Write-Host ("         {0}s wall, model {1} ms, {2} in / {3} out tokens, {4} tok/s, recalled {5}, tools [{6}]" -f `
          [math]::Round($sw.Elapsed.TotalSeconds, 1), $mt.modelMs, $mt.inputTokens, $mt.outputTokens, $mt.outputTokensPerSecond, $mt.recalledItems,
          (@($body.toolCalls | ForEach-Object { "$($_.name):$($_.allowed)" }) -join ', '))
        Write-Host ("         answer: {0}" -f ("$($body.output)" -replace '\s+', ' ').Substring(0, [Math]::Min(160, ("$($body.output)" -replace '\s+', ' ').Length)))
      }
    }

    $second = $runs[1].body
    $recalled = $second -and ("$($second.output)" -match '0?8[:.]00|8\s*(am|a\.m\.)') -and ("$($second.output)" -match '16[:.]00|4\s*(pm|p\.m\.)')
    Add-Check 'second run answers from memory written by the first (model dependent)' $recalled @{ output = $(if ($second) { $second.output }) } -Soft

    $mem = Invoke-Http "$base/api/memory/recent" -Windows
    $m = $null
    if ($mem.status -eq 200) { $m = $mem.body | ConvertFrom-Json }
    $ids = @($runs | Where-Object { $_.body } | ForEach-Object { "$($_.body.runId)" })
    $written = @($(if ($m) { $m.items }) | Where-Object { $ids -contains "$($_.runId)" -and $_.source -eq 'run' -and $_.trust -eq 'user' -and $_.contentBytes -gt 0 })
    Add-Check 'memory written with provenance (run_id, source, trust), content encrypted' ($ids.Count -eq 2 -and $written.Count -eq 2) @{ items = $written }
    Add-Check 'each run audited (agent.run) with an episode' ($m -and $m.agentRunAudits -ge 2 -and $m.episodes -ge 2) @{ audits = $(if ($m) { $m.agentRunAudits }); episodes = $(if ($m) { $m.episodes }) }

    $ollama = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like 'C:\Program Files\Cortex\ollama\*' })
    [ordered]@{
      runs = @($runs | ForEach-Object { [ordered]@{ wall_seconds = $_.wall_seconds; status = $_.status; metrics = $(if ($_.body) { $_.body.metrics }); tool_calls = $(if ($_.body) { $_.body.toolCalls }); output = $(if ($_.body) { $_.body.output }) } })
      ollama_working_set_mb = [math]::Round((($ollama | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 1)
      app_working_set_mb = [math]::Round((Get-Process -Id $script:app.Id).WorkingSet64 / 1MB, 1)
    }
  } | Out-Null
} catch { $failed = $_.Exception.Message }
finally {
  if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force }
  Remove-Item env:ASPNETCORE_URLS -ErrorAction SilentlyContinue
}

$ok = ($null -eq $failed) -and -not @($Checks | Where-Object { -not $_.pass -and -not $_.soft }).Count
$summary = [ordered]@{
  run_id = $RunId; started = $Started.ToString('o'); finished = [DateTime]::UtcNow.ToString('o')
  minutes = [math]::Round(([DateTime]::UtcNow - $Started).TotalMinutes, 2)
  bundle = $Bundle; steps = $Steps; checks = $Checks; ok = $ok; error = $failed
}
[IO.File]::WriteAllText((Join-Path $RunDir 'verify.json'), ($summary | ConvertTo-Json -Depth 10), $Utf8)
Write-Host ''
Write-Host ("Result: {0}  minutes={1}" -f $(if ($ok) { 'OK' } else { 'FAILED' }), $summary.minutes)
if ($failed) { Write-Host "Error: $failed" }
Write-Host "Evidence: $RunDir"
if (-not $ok) { exit 1 }
