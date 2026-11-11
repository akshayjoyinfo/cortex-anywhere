<#
Cortex Windows bootstrap (ADR 014). The only imperative step in provisioning.

  1. Installs the pinned DSC CLI (version and SHA256 below).
  2. Stages the Cortex DSC resources, SQL and config under Program Files.
  3. Applies infra/windows/cortex.dsc.yaml, then tests it again (drift check).
  4. Writes JSON evidence for the run to C:\ProgramData\Cortex\logs\runs\<run_id>\
     and appends one summary line to C:\ProgramData\Cortex\logs\runs.jsonl.

Run elevated, from an extracted bundle (repository archive at a pinned tag):
  powershell -NoProfile -ExecutionPolicy Bypass -File infra\windows\bootstrap.ps1

  -Operation set      install or converge, then test (default)
  -Operation test     drift check only, changes nothing
  -Operation prepare  only install dsc and stage resources (Ansible uses this)
  -PgPort 5433        use when the machine already runs its own PostgreSQL on 5432
#>
[CmdletBinding()]
param(
  [ValidateSet('set', 'test', 'prepare')] [string] $Operation = 'set',
  [ValidateRange(1024, 65535)] [int] $PgPort = 5432
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'resources\common.ps1')

# ---------------------------------------------------------------- pins
$Dsc = @{
  Version = '3.3.0'
  Url     = 'https://github.com/PowerShell/DSC/releases/download/v3.3.0/DSC-3.3.0-x86_64-pc-windows-msvc.zip'
  Sha256  = '3f8b27f648661903d066cc19d5a6e7a8c13bd07eb738d4d765ce7239619b8b5f'
}

$ProgramDir = 'C:\Program Files\Cortex'
$DataDir    = 'C:\ProgramData\Cortex'
$ProvDir    = Join-Path $ProgramDir 'provisioning'
$DscDir     = Join-Path $ProgramDir "tools\dsc-$($Dsc.Version)"
$DscExe     = Join-Path $DscDir 'dsc.exe'
$Bundle     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Utf8       = New-Object System.Text.UTF8Encoding $false

$RunId  = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$RunDir = Join-Path $DataDir "logs\runs\$RunId"
$Steps  = New-Object System.Collections.ArrayList
$Started = [DateTime]::UtcNow

function Save-Json([string] $Name, $Obj) {
  [IO.File]::WriteAllText((Join-Path $RunDir $Name), ($Obj | ConvertTo-Json -Depth 10), $Utf8)
}

function Invoke-Step([string] $Name, [scriptblock] $Body) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rec = [ordered]@{ step = $Name; status = 'ok'; seconds = 0; detail = $null }
  try { $rec.detail = & $Body }
  catch { $rec.status = 'failed'; $rec.detail = $_.Exception.Message; throw }
  finally {
    $rec.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    [void]$Steps.Add($rec)
    Write-Host ("[{0,-14}] {1,-6} {2,7}s" -f $Name, $rec.status, $rec.seconds)
  }
}

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'run from an elevated PowerShell'
  }
}

function Get-HostFacts {
  $os = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  $cpu = @(Get-CimInstance Win32_Processor)
  $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
  [ordered]@{
    os = $os.Caption; os_version = $os.Version; os_build = $os.BuildNumber
    cpu = $cpu[0].Name
    cores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
    logical_processors = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    ram_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    c_free_gb = [math]::Round($disk.FreeSpace / 1GB, 1)
    gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
    powershell = $PSVersionTable.PSVersion.ToString()
  }
}

function Install-Dsc {
  if (Test-Path $DscExe) {
    $v = (Invoke-Native $DscExe @('--version')).Out
    if ($v -match [regex]::Escape($Dsc.Version)) { return [ordered]@{ version = $v.Trim(); installed = 'already' } }
  }
  $zip = Get-PinnedFile $Dsc.Url $Dsc.Sha256 "dsc-$($Dsc.Version).zip" (Join-Path $DataDir 'cache')
  $tmp = Join-Path $env:TEMP ('dsc-' + [guid]::NewGuid().ToString('N'))
  Expand-Archive -Path $zip -DestinationPath $tmp
  $found = Get-ChildItem $tmp -Recurse -Filter 'dsc.exe' | Select-Object -First 1
  if (-not $found) { throw 'dsc.exe not found in the DSC archive' }
  if (Test-Path $DscDir) { Remove-Item $DscDir -Recurse -Force }
  New-Item -ItemType Directory -Force (Split-Path $DscDir) | Out-Null
  Move-Item $found.DirectoryName $DscDir
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  $v = (Invoke-Native $DscExe @('--version')).Out
  if ($v -notmatch [regex]::Escape($Dsc.Version)) { throw "dsc reports '$v', expected $($Dsc.Version)" }
  [ordered]@{ version = $v.Trim(); installed = 'now'; sha256 = $Dsc.Sha256 }
}

function Copy-Bundle {
  New-Item -ItemType Directory -Force $ProvDir | Out-Null
  foreach ($sub in 'resources', 'db') {
    $t = Join-Path $ProvDir $sub
    if (Test-Path $t) { Remove-Item $t -Recurse -Force }
  }
  Copy-Item (Join-Path $Bundle 'infra\windows\resources') (Join-Path $ProvDir 'resources') -Recurse
  Copy-Item (Join-Path $Bundle 'db') (Join-Path $ProvDir 'db') -Recurse
  Copy-Item (Join-Path $Bundle 'infra\windows\cortex.dsc.yaml') (Join-Path $ProvDir 'cortex.dsc.yaml') -Force
  # One hash over every staged file: names the exact bundle this run applied.
  $lines = Get-ChildItem $ProvDir -Recurse -File | Sort-Object FullName | ForEach-Object {
    '{0} {1}' -f $_.FullName.Substring($ProvDir.Length + 1).Replace('\', '/'), (Get-TextSha256 $_.FullName)
  }
  [IO.File]::WriteAllText((Join-Path $RunDir 'bundle.txt'), ($lines -join "`n") + "`n", $Utf8)
  [ordered]@{ source = $Bundle; files = @($lines).Count; sha256 = (Get-TextSha256 (Join-Path $RunDir 'bundle.txt')) }
}

function Invoke-DscConfig([string] $Verb) {
  $params = Join-Path $RunDir 'parameters.json'
  Save-Json 'parameters.json' @{ parameters = @{ pgPort = $PgPort } }
  $dscArgs = @('--trace-level', 'info', '--trace-format', 'json',
               'config', '--parameters-file', $params, $Verb,
               '--file', (Join-Path $ProvDir 'cortex.dsc.yaml'), '--output-format', 'json')
  $envs = @{ DSC_RESOURCE_PATH = (Join-Path $ProvDir 'resources'); CORTEX_RUN_ID = $RunId; CORTEX_LOG_DIR = $RunDir }
  $r = Invoke-Native $DscExe $dscArgs $envs
  [IO.File]::WriteAllText((Join-Path $RunDir "dsc-$Verb.json"), $r.Out, $Utf8)
  [IO.File]::WriteAllText((Join-Path $RunDir "dsc-$Verb.trace.jsonl"), $r.Err, $Utf8)
  if ($r.Code) { throw "dsc config $Verb exited $($r.Code); see $RunDir\dsc-$Verb.trace.jsonl" }
  [ordered]@{ exit = $r.Code; output = "dsc-$Verb.json" }
}

# The cause of a failure, pulled from the run's own evidence: resource errors
# from steps.jsonl and ERROR lines from the dsc traces.
function Get-RunErrors {
  $errors = @()
  $steps = Join-Path $RunDir 'steps.jsonl'
  if (Test-Path $steps) {
    foreach ($l in Get-Content $steps) {
      try { $o = $l | ConvertFrom-Json } catch { continue }
      if ($o.step -eq 'error') { $errors += [ordered]@{ source = $o.resource; op = $o.op; message = $o.detail.message } }
    }
  }
  foreach ($t in @(Get-ChildItem $RunDir -Filter 'dsc-*.trace.jsonl' -ErrorAction SilentlyContinue)) {
    foreach ($l in Get-Content $t.FullName) {
      try { $o = $l | ConvertFrom-Json } catch { continue }
      if ($o.PSObject.Properties['level'] -and $o.level -eq 'ERROR') {
        $msg = "$($o.fields.message)"
        if ($msg.Length -gt 600) { $msg = $msg.Substring(0, 600) + '...' }
        $errors += [ordered]@{ source = 'dsc'; op = $t.BaseName; message = $msg }
      }
    }
  }
  $errors
}

function Get-TestSummary {
  $path = Join-Path $RunDir 'dsc-test.json'
  if (-not (Test-Path $path)) { return @() }
  try {
    $o = Get-Content $path -Raw | ConvertFrom-Json
    @($o.results | ForEach-Object { [ordered]@{ name = $_.name; type = $_.type; inDesiredState = $_.result.inDesiredState } })
  } catch { @([ordered]@{ parse_error = $_.Exception.Message }) }
}

# ---------------------------------------------------------------- run
Assert-Admin
New-Item -ItemType Directory -Force $RunDir | Out-Null
Write-Host "Cortex bootstrap  run=$RunId  operation=$Operation  logs=$RunDir"

$failed = $null
try {
  Invoke-Step 'host-facts' { $f = Get-HostFacts; Save-Json 'host.json' $f; $f.os } | Out-Null
  Invoke-Step 'install-dsc' { Install-Dsc } | Out-Null
  Invoke-Step 'stage-bundle' { Copy-Bundle } | Out-Null
  if ($Operation -eq 'set') { Invoke-Step 'dsc-set' { Invoke-DscConfig 'set' } | Out-Null }
  if ($Operation -in 'set', 'test') { Invoke-Step 'dsc-test' { Invoke-DscConfig 'test' } | Out-Null }
} catch { $failed = $_.Exception.Message }

$resources = @(Get-TestSummary)
$errors = @(Get-RunErrors)
$inDesired = ($Operation -eq 'prepare') -or (@($resources).Count -gt 0 -and -not @($resources | Where-Object { $_['inDesiredState'] -ne $true }).Count)
$summary = [ordered]@{
  run_id = $RunId; operation = $Operation; pg_port = $PgPort
  started = $Started.ToString('o'); finished = [DateTime]::UtcNow.ToString('o')
  minutes = [math]::Round(([DateTime]::UtcNow - $Started).TotalMinutes, 2)
  dsc_version = $Dsc.Version; steps = $Steps; resources = $resources
  ok = ($null -eq $failed -and $inDesired); error = $failed; errors = $errors
}
Save-Json 'run.json' $summary
[IO.File]::AppendAllText((Join-Path $DataDir 'logs\runs.jsonl'), ($summary | ConvertTo-Json -Compress -Depth 10) + "`n", $Utf8)

Write-Host ''
foreach ($r in $resources) { if ($r.Contains('name')) { Write-Host ("  {0,-12} inDesiredState={1}" -f $r['name'], $r['inDesiredState']) } }
Write-Host ("Result: {0}  minutes={1}" -f $(if ($summary.ok) { 'OK' } else { 'FAILED' }), $summary.minutes)
if ($failed) { Write-Host "Error: $failed" }
foreach ($e in $errors) { Write-Host ("  cause [{0} {1}] {2}" -f $e['source'], $e['op'], $e['message']) }
Write-Host "Evidence: $RunDir"
if (-not $summary.ok) { exit 1 }
