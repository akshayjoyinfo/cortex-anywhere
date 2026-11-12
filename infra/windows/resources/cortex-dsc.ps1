<#
Cortex DSC v3 command resources (ADR 014). One script, dispatched by -Resource and -Operation.

Contract with dsc:
- desired state arrives as JSON on stdin
- the resulting state is printed as one JSON object on stdout
- trace goes to stderr and to steps.jsonl (the install evidence)
- exit 0 = ok, anything else = failure

Every resource is idempotent: set reads state first and changes only what drifted.
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('VcRuntime', 'Postgres', 'PgExtension', 'Database', 'DbChecks', 'DotnetSdk', 'LocalInstall', 'Ollama', 'OllamaModel', 'AppService')]
  [string] $Resource,
  [Parameter(Mandatory = $true)]
  [ValidateSet('get', 'test', 'set')]
  [string] $Operation
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'common.ps1')

$CortexData = 'C:\ProgramData\Cortex'
$CacheDir = Join-Path $CortexData 'cache'
$SecretDir = Join-Path $CortexData 'secrets'
$LogDir = if ($env:CORTEX_LOG_DIR) { $env:CORTEX_LOG_DIR } else { Join-Path $CortexData 'logs' }
$RunId = if ($env:CORTEX_RUN_ID) { $env:CORTEX_RUN_ID } else { 'manual' }
$Utf8 = New-Object System.Text.UTF8Encoding $false

# ------------------------------------------------------------------ plumbing

function Write-Step([string] $Name, [System.Collections.IDictionary] $Detail = @{}) {
  $rec = [ordered]@{
    ts = [DateTime]::UtcNow.ToString('o'); run_id = $RunId
    resource = $Resource; op = $Operation; step = $Name; detail = $Detail
  }
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
  [IO.File]::AppendAllText((Join-Path $LogDir 'steps.jsonl'), ($rec | ConvertTo-Json -Compress -Depth 8) + "`n", $Utf8)
  [Console]::Error.WriteLine((@{ info = "$Resource.$Operation $Name" } | ConvertTo-Json -Compress))
}

function Need($Obj, [string] $Name) {
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p -or $null -eq $p.Value -or "$($p.Value)" -eq '') { throw "property '$Name' is required" }
  $p.Value
}

function Assert-Ident([string] $Value, [string] $What) {
  if ($Value -notmatch '^[a-z_][a-z0-9_]{0,62}$') { throw "$What '$Value' is not a plain lower case identifier" }
  $Value
}

function Get-Tail([string] $Text, [int] $Max = 2000) {
  if ($null -eq $Text) { return '' }
  $t = $Text.Trim()
  if ($t.Length -le $Max) { return $t }
  $t.Substring($t.Length - $Max)
}

function Set-AdminOnlyAcl([string] $Path) {
  # SYSTEM and Administrators only, by SID so it works on any OS language.
  $r = Invoke-Native "$env:SystemRoot\System32\icacls.exe" @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
  if ($r.Code) { throw "icacls failed on ${Path}: $($r.Out) $($r.Err)" }
}

# SYSTEM, Administrators and the given extra SIDs ('*S-1-...'), inheritance removed.
function Set-RestrictedAcl([string] $Path, [string[]] $ExtraSids) {
  $grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F') + @($ExtraSids | ForEach-Object { "${_}:(OI)(CI)F" })
  $r = Invoke-Native "$env:SystemRoot\System32\icacls.exe" (@($Path, '/inheritance:r', '/grant:r') + $grants)
  if ($r.Code) { throw "icacls failed on ${Path}: $($r.Out) $($r.Err)" }
  Write-Step 'acl' @{ path = $Path; grants = $grants }
}

function Get-SecretPath([string] $Name) { Join-Path $SecretDir "$Name.dpapi" }

function Protect-Secret([string] $Name, [string] $Value) {
  if (-not (Test-Path $SecretDir)) { New-Item -ItemType Directory -Force $SecretDir | Out-Null }
  Set-AdminOnlyAcl $SecretDir
  $enc = [Security.Cryptography.ProtectedData]::Protect($Utf8.GetBytes($Value), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
  [IO.File]::WriteAllBytes((Get-SecretPath $Name), $enc)
  Write-Step 'secret-stored' @{ name = $Name; protection = 'dpapi-localmachine, admin-only acl' }
}

function Unprotect-Secret([string] $Name) {
  $path = Get-SecretPath $Name
  if (-not (Test-Path $path)) { throw "secret '$Name' not found at $path" }
  $dec = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
  $Utf8.GetString($dec)
}

function New-RandomSecret {
  $b = New-Object byte[] 32
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($b) } finally { $rng.Dispose() }
  [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Extract only the listed top level folders; entry names normalised to forward slashes.
function Expand-ZipSubset([string] $Zip, [string] $Dest, [string] $StripPrefix, [string[]] $Include, [string[]] $Exclude = @()) {
  $z = [IO.Compression.ZipFile]::OpenRead($Zip)
  $count = 0
  try {
    foreach ($e in $z.Entries) {
      $n = $e.FullName -replace '\\', '/'
      if (-not $n.StartsWith($StripPrefix)) { continue }
      $rel = $n.Substring($StripPrefix.Length)
      if ($rel -match '(^|/)\.\.(/|$)') { throw "unsafe zip entry $n" }
      # Count matches: an include prefix of '' (everything) is itself falsy in PowerShell.
      if (@($Include | Where-Object { $rel.StartsWith($_) }).Count -eq 0) { continue }
      if (@($Exclude | Where-Object { $_ -ne '' -and $rel.StartsWith($_) }).Count -gt 0) { continue }
      $target = Join-Path $Dest ($rel -replace '/', '\')
      if ($n.EndsWith('/')) { New-Item -ItemType Directory -Force $target | Out-Null; continue }
      New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
      $count++
    }
  } finally { $z.Dispose() }
  Write-Step 'extracted' @{ zip = $Zip; dest = $Dest; files = $count }
  if ($count -eq 0) { throw "extracted 0 files from $Zip (prefix '$StripPrefix', include $($Include -join ','))" }
}

function Get-Listeners([int] $Port) {
  try {
    @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty LocalAddress -Unique)
  } catch { @() }
}

# ------------------------------------------------------------------ VcRuntime

function Get-VcRuntimeVersion {
  $best = $null
  foreach ($k in 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64') {
    if (-not (Test-Path $k)) { continue }
    $p = Get-ItemProperty $k
    if (-not $p.PSObject.Properties['Installed'] -or $p.Installed -ne 1 -or -not $p.PSObject.Properties['Bld']) { continue }
    $v = [version]('{0}.{1}.{2}' -f $p.Major, $p.Minor, $p.Bld)
    if ($null -eq $best -or $v -gt $best) { $best = $v }
  }
  $best
}

function Get-VcRuntimeState($d) {
  $min = [version](Need $d 'minVersion')
  $v = Get-VcRuntimeVersion
  $drift = @()
  if ($null -eq $v) { $drift += 'not-installed' } elseif ($v -lt $min) { $drift += 'too-old' }
  @{ ok = ($drift.Count -eq 0); state = [ordered]@{
      minVersion = "$min"; url = (Need $d 'url'); sha256 = (Need $d 'sha256')
      installedVersion = $(if ($v) { "$v" } else { $null }); drift = $drift } }
}

function Set-VcRuntime($d, $s) {
  $exe = Get-PinnedFile (Need $d 'url') (Need $d 'sha256') 'VC_redist.x64.exe' $CacheDir
  Write-Step 'verified' @{ file = $exe }
  $r = Invoke-Native $exe @('/install', '/quiet', '/norestart')
  Write-Step 'vc-redist' @{ exit = $r.Code }
  # 1638 = a newer version is already installed, 3010 = installed, reboot pending
  if ($r.Code -notin 0, 1638, 3010) { throw "VC_redist exited $($r.Code)" }
}

# ------------------------------------------------------------------ Postgres

function Get-PgService([string] $Name) {
  if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw "bad service name $Name" }
  Get-CimInstance Win32_Service -Filter "Name='$Name'"
}

function Get-CortexConf([int] $Port, [string] $Listen) {
  if ($Listen -notmatch '^[A-Za-z0-9.:, ]+$') { throw "bad listenAddresses $Listen" }
  "# Managed by Cortex provisioning (ADR 014). Local edits are overwritten.`n" +
  "listen_addresses = '$Listen'`nport = $Port`npassword_encryption = 'scram-sha-256'`n"
}

function Get-PostgresState($d) {
  $pgHome = Need $d 'installDir'; $data = Need $d 'dataDir'; $svcName = Need $d 'serviceName'
  $port = [int](Need $d 'port'); $listen = Need $d 'listenAddresses'
  $sha = (Need $d 'sha256').ToLowerInvariant(); $version = Need $d 'version'
  $major = ($version -split '\.')[0]
  $drift = @()

  $marker = Join-Path $pgHome '.cortex-artifact.json'
  $haveSha = $null
  if (Test-Path $marker) { $haveSha = (Get-Content $marker -Raw | ConvertFrom-Json).sha256 }
  if ($haveSha -ne $sha) { $drift += 'binaries' }
  $serverVersion = $null
  $pgExe = Join-Path $pgHome 'bin\postgres.exe'
  if (Test-Path $pgExe) { $serverVersion = (Invoke-Native $pgExe @('--version')).Out.Trim() }

  $pgv = Join-Path $data 'PG_VERSION'
  $clusterMajor = $null
  if (Test-Path $pgv) { $clusterMajor = (Get-Content $pgv -Raw).Trim() }
  if ($clusterMajor -ne $major) { $drift += 'cluster' }

  $confPath = Join-Path $data 'cortex.conf'
  $haveConf = $null
  if (Test-Path $confPath) { $haveConf = [IO.File]::ReadAllText($confPath) }
  if ($haveConf -ne (Get-CortexConf $port $listen)) { $drift += 'config' }

  $secret = Test-Path (Get-SecretPath 'pg-superuser')
  if (-not $secret) { $drift += 'secret' }

  $svc = Get-PgService $svcName
  $svcState = $null; $svcStart = $null
  if ($svc) { $svcState = $svc.State; $svcStart = $svc.StartMode }
  if (-not $svc -or -not $svc.PathName.ToLowerInvariant().Contains($pgHome.ToLowerInvariant())) { $drift += 'service' }
  elseif ($svcState -ne 'Running' -or $svcStart -ne 'Auto') { $drift += 'service-state' }

  $listening = @(Get-Listeners $port)
  if ($svcState -eq 'Running') {
    if (@($listening | Where-Object { $_ -notin '127.0.0.1', '::1' }).Count) { $drift += 'exposed' }
  }

  @{ ok = ($drift.Count -eq 0); state = [ordered]@{
      version = $version; url = (Need $d 'url'); sha256 = $sha; installDir = $pgHome; dataDir = $data
      serviceName = $svcName; port = $port; listenAddresses = $listen
      serverVersion = $serverVersion; clusterMajor = $clusterMajor; serviceState = $svcState
      serviceStartMode = $svcStart; listeningOn = $listening; superuserSecret = $secret; drift = $drift } }
}

function Wait-PgReady([string] $PgHome, [int] $Port) {
  for ($i = 0; $i -lt 60; $i++) {
    $r = Invoke-Native (Join-Path $PgHome 'bin\pg_isready.exe') @('-h', '127.0.0.1', '-p', "$Port")
    if ($r.Code -eq 0) { Write-Step 'ready' @{ seconds = $i }; return }
    Start-Sleep -Seconds 1
  }
  throw "postgres not ready on port $Port after 60s"
}

function Assert-PortFree([int] $Port, [string] $PgHome) {
  foreach ($c in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
    $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    $path = $null
    if ($proc) { $path = $proc.Path }
    if (-not $path -or -not $path.ToLowerInvariant().StartsWith($PgHome.ToLowerInvariant())) {
      throw "port $Port is already used by '$path' (pid $($c.OwningProcess)). Pick another pgPort; Cortex never touches an existing database server."
    }
  }
}

function Set-Postgres($d, $s) {
  $pgHome = Need $d 'installDir'; $data = Need $d 'dataDir'; $svcName = Need $d 'serviceName'
  $port = [int](Need $d 'port'); $listen = Need $d 'listenAddresses'; $version = Need $d 'version'
  $major = ($version -split '\.')[0]
  $bin = Join-Path $pgHome 'bin'
  $drift = @($s.state.drift)
  $restart = $false

  if ($drift -contains 'binaries') {
    $zip = Get-PinnedFile (Need $d 'url') (Need $d 'sha256') "postgresql-$version-windows-x64-binaries.zip" $CacheDir
    Write-Step 'verified' @{ file = $zip }
    $svc = Get-PgService $svcName
    if ($svc -and $svc.State -eq 'Running') { Stop-Service $svcName; $restart = $true }
    Expand-ZipSubset $zip $pgHome 'pgsql/' @('bin/', 'lib/', 'share/', 'include/')
    $marker = [ordered]@{ url = (Need $d 'url'); sha256 = (Need $d 'sha256').ToLowerInvariant(); version = $version; run_id = $RunId }
    [IO.File]::WriteAllText((Join-Path $pgHome '.cortex-artifact.json'), ($marker | ConvertTo-Json), $Utf8)
  }

  $pgv = Join-Path $data 'PG_VERSION'
  if (Test-Path $pgv) {
    $have = (Get-Content $pgv -Raw).Trim()
    if ($have -ne $major) { throw "cluster at $data is major $have, wanted $major. No automatic pg_upgrade; stop." }
    if (-not (Test-Path (Get-SecretPath 'pg-superuser'))) {
      throw "cluster exists but the superuser secret is missing. Refusing to reset credentials automatically."
    }
  } else {
    if ((Test-Path $data) -and @(Get-ChildItem $data -Force).Count) { throw "$data is not empty and is not a cluster; refusing to touch it" }
    if (Test-Path (Get-SecretPath 'pg-superuser')) { $pw = Unprotect-Secret 'pg-superuser' }
    else { $pw = New-RandomSecret; Protect-Secret 'pg-superuser' $pw }
    # initdb drops admin rights when started by an administrator, so the Administrators
    # group no longer counts. Grant the installing account by its own SID instead.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $dataRoot = Split-Path $data
    New-Item -ItemType Directory -Force $dataRoot | Out-Null
    Set-RestrictedAcl $dataRoot @("*${me}", '*S-1-5-20')          # installer + NetworkService
    $tmpDir = Join-Path $CortexData ('tmp\initdb-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmpDir | Out-Null
    Set-RestrictedAcl $tmpDir @("*${me}")
    $pwFile = Join-Path $tmpDir 'pwfile'
    try {
      [IO.File]::WriteAllText($pwFile, $pw, $Utf8)
      $r = Invoke-Native (Join-Path $bin 'initdb.exe') @('-D', $data, '-U', 'postgres', "--pwfile=$pwFile", '-A', 'scram-sha-256', '-E', 'UTF8', '--locale=C')
      Write-Step 'initdb' @{ exit = $r.Code; out = (Get-Tail $r.Out 800); err = (Get-Tail $r.Err 800) }
      if ($r.Code) { throw "initdb failed: $(Get-Tail $r.Err)" }
    } finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    # The service runs as NetworkService and must own its data directory.
    $r = Invoke-Native "$env:SystemRoot\System32\icacls.exe" @($data, '/grant', '*S-1-5-20:(OI)(CI)F')
    if ($r.Code) { throw "icacls on data dir failed: $($r.Out)" }
  }

  $conf = Get-CortexConf $port $listen
  $confPath = Join-Path $data 'cortex.conf'
  if (-not (Test-Path $confPath) -or [IO.File]::ReadAllText($confPath) -ne $conf) {
    [IO.File]::WriteAllText($confPath, $conf, $Utf8); $restart = $true
    Write-Step 'config-written' @{ port = $port; listen = $listen }
  }
  $pgConf = Join-Path $data 'postgresql.conf'
  $include = "include_if_exists = 'cortex.conf'"
  if (-not (Select-String -Path $pgConf -SimpleMatch $include -Quiet)) {
    [IO.File]::AppendAllText($pgConf, "`n$include`n", $Utf8); $restart = $true
  }

  $svc = Get-PgService $svcName
  if ($svc -and -not $svc.PathName.ToLowerInvariant().Contains($pgHome.ToLowerInvariant())) {
    if ($svc.State -eq 'Running') { Stop-Service $svcName }
    $r = Invoke-Native (Join-Path $bin 'pg_ctl.exe') @('unregister', '-N', $svcName)
    Write-Step 'service-unregistered' @{ exit = $r.Code; old = $svc.PathName }
    $svc = $null
  }
  if (-not $svc) {
    Assert-PortFree $port $pgHome
    $r = Invoke-Native (Join-Path $bin 'pg_ctl.exe') @('register', '-N', $svcName, '-U', 'NT AUTHORITY\NetworkService', '-D', $data, '-S', 'auto', '-w')
    Write-Step 'service-registered' @{ exit = $r.Code; err = (Get-Tail $r.Err 800) }
    if ($r.Code) { throw "pg_ctl register failed: $(Get-Tail $r.Err)" }
    $r = Invoke-Native "$env:SystemRoot\System32\sc.exe" @('failure', $svcName, 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/30000')
    Write-Step 'service-recovery' @{ exit = $r.Code }
  }
  Set-Service -Name $svcName -StartupType Automatic
  $svc = Get-PgService $svcName
  if ($svc.State -eq 'Running') { if ($restart) { Restart-Service $svcName; Write-Step 'service-restarted' } }
  else { Assert-PortFree $port $pgHome; Start-Service $svcName; Write-Step 'service-started' }
  Wait-PgReady $pgHome $port
}

# ------------------------------------------------------------------ PgExtension

function Get-PgExtensionState($d) {
  $name = Assert-Ident (Need $d 'name') 'extension'
  $pgHome = Need $d 'pgInstallDir'; $version = Need $d 'version'; $sha = (Need $d 'sha256').ToLowerInvariant()
  $drift = @()
  $marker = Join-Path $pgHome "share\extension\.cortex-$name.json"
  $haveSha = $null
  if (Test-Path $marker) { $haveSha = (Get-Content $marker -Raw | ConvertFrom-Json).sha256 }
  $dll = Test-Path (Join-Path $pgHome "lib\$name.dll")
  $control = Join-Path $pgHome "share\extension\$name.control"
  $ctlVersion = $null
  if (Test-Path $control) {
    $m = Select-String -Path $control -Pattern "^\s*default_version\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($m) { $ctlVersion = $m.Matches[0].Groups[1].Value }
  }
  if ($haveSha -ne $sha -or -not $dll) { $drift += 'files' }
  if ($ctlVersion -ne $version) { $drift += 'version' }
  @{ ok = ($drift.Count -eq 0); state = [ordered]@{
      name = $name; version = $version; url = (Need $d 'url'); sha256 = $sha; pgInstallDir = $pgHome
      installedVersion = $ctlVersion; dllPresent = $dll; drift = $drift } }
}

function Set-PgExtension($d, $s) {
  $name = Assert-Ident (Need $d 'name') 'extension'
  $pgHome = Need $d 'pgInstallDir'
  $zip = Get-PinnedFile (Need $d 'url') (Need $d 'sha256') "$name-$(Need $d 'version')-windows-x64.zip" $CacheDir
  Write-Step 'verified' @{ file = $zip }
  Expand-ZipSubset $zip $pgHome '' @('lib/', 'share/', 'include/')
  $marker = [ordered]@{ url = (Need $d 'url'); sha256 = (Need $d 'sha256').ToLowerInvariant(); version = (Need $d 'version'); run_id = $RunId }
  [IO.File]::WriteAllText((Join-Path $pgHome "share\extension\.cortex-$name.json"), ($marker | ConvertTo-Json), $Utf8)
}

# ------------------------------------------------------------------ psql helper

function Invoke-Psql {
  param($D, [string] $Db, [string[]] $Arguments = @(), [string] $StdIn = '', [hashtable] $Vars = @{}, [switch] $AllowFail)
  $pgHome = Need $D 'pgInstallDir'
  $a = @('-X', '-q', '-tA', '-h', '127.0.0.1', '-p', "$(Need $D 'port')", '-U', 'postgres', '-d', $Db, '-v', 'ON_ERROR_STOP=1')
  foreach ($k in $Vars.Keys) { $a += @('-v', "$k=$($Vars[$k])") }
  $a += $Arguments
  if ($StdIn -ne '') { $a += @('-f', '-') }
  $envs = @{ PGPASSWORD = (Unprotect-Secret 'pg-superuser'); PGCONNECT_TIMEOUT = '10'; PGAPPNAME = 'cortex-provisioning' }
  $r = Invoke-Native (Join-Path $pgHome 'bin\psql.exe') $a $envs $StdIn
  if ($r.Code -and -not $AllowFail) { throw "psql on $Db failed (exit $($r.Code)): $(Get-Tail $r.Err)" }
  $r
}

function Get-Lines([string] $Text) { @($Text -split "`r?`n" | Where-Object { $_ -ne '' }) }

function Get-MigrationFiles([string] $Dir) {
  @(Get-ChildItem -Path $Dir -Filter '*.sql' | Sort-Object Name | ForEach-Object {
      [pscustomobject]@{ name = $_.Name; path = $_.FullName; sha256 = (Get-TextSha256 $_.FullName) } })
}

# ------------------------------------------------------------------ Database

function Get-DatabaseState($d) {
  $db = Assert-Ident (Need $d 'database') 'database'
  $owner = Assert-Ident (Need $d 'ownerRole') 'ownerRole'
  $app = Assert-Ident (Need $d 'appRole') 'appRole'
  $exts = @(Need $d 'extensions' | ForEach-Object { Assert-Ident $_ 'extension' })
  $files = Get-MigrationFiles (Need $d 'migrationsDir')
  $drift = @()

  $roles = @{}
  foreach ($l in (Get-Lines (Invoke-Psql $d 'postgres' @('-c', "SELECT rolname || '|' || rolcanlogin || '|' || rolsuper || '|' || rolbypassrls FROM pg_roles WHERE rolname IN ('$owner', '$app')")).Out)) {
    $p = $l -split '\|'; $roles[$p[0]] = @{ login = $p[1]; super = $p[2]; bypass = $p[3] }
  }
  if (-not $roles.ContainsKey($owner)) { $drift += 'owner-role' }
  if (-not $roles.ContainsKey($app)) { $drift += 'app-role' }
  elseif ($roles[$app].login -ne 'true' -or $roles[$app].super -ne 'false' -or $roles[$app].bypass -ne 'false') { $drift += 'app-role-attributes' }

  $dbExists = (Invoke-Psql $d 'postgres' @('-c', "SELECT count(*) FROM pg_database WHERE datname = '$db'")).Out.Trim() -eq '1'
  $installed = @(); $applied = @{}
  if ($dbExists) {
    $installed = @(Get-Lines (Invoke-Psql $d $db @('-c', 'SELECT extname || $$=$$ || extversion FROM pg_extension ORDER BY 1')).Out)
    $hasOps = (Invoke-Psql $d $db @('-c', "SELECT to_regclass('cortex_ops.schema_migrations') IS NOT NULL")).Out.Trim() -eq 't'
    if ($hasOps) {
      foreach ($l in (Get-Lines (Invoke-Psql $d $db @('-c', "SELECT name || '|' || sha256 FROM cortex_ops.schema_migrations ORDER BY name")).Out)) {
        $p = $l -split '\|'; $applied[$p[0]] = $p[1]
      }
    } else { $drift += 'migrations-table' }
  } else { $drift += 'database' }

  foreach ($e in $exts) { if (-not ($installed | Where-Object { $_ -like "$e=*" })) { $drift += "extension:$e" } }
  $pending = @($files | Where-Object { -not $applied.ContainsKey($_.name) })
  $changed = @($files | Where-Object { $applied.ContainsKey($_.name) -and $applied[$_.name] -ne $_.sha256 })
  if ($pending.Count) { $drift += 'pending-migrations' }
  if ($changed.Count) { $drift += 'changed-migrations' }

  @{ ok = ($drift.Count -eq 0); pending = $pending; changed = $changed; state = [ordered]@{
      database = $db; ownerRole = $owner; appRole = $app; extensions = $exts; migrationsDir = (Need $d 'migrationsDir')
      pgInstallDir = (Need $d 'pgInstallDir'); port = [int](Need $d 'port')
      installedExtensions = $installed; appliedMigrations = @($applied.Keys | Sort-Object)
      pendingMigrations = @($pending | ForEach-Object { $_.name }); drift = $drift } }
}

function Set-Database($d, $s) {
  if ($s.changed.Count) {
    throw "applied migrations changed on disk: $(@($s.changed | ForEach-Object { $_.name }) -join ', '). Migrations are immutable; add a new one."
  }
  $st = $s.state
  $boot = @'
SELECT format('CREATE ROLE %I NOLOGIN', :'owner') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'owner') \gexec
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE', :'app') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app') \gexec
SELECT format('ALTER ROLE %I LOGIN NOSUPERUSER NOBYPASSRLS', :'app') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'owner') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
'@
  Invoke-Psql $d 'postgres' -StdIn $boot -Vars @{ owner = $st.ownerRole; app = $st.appRole; db = $st.database } | Out-Null
  Write-Step 'roles-and-database' @{ database = $st.database; owner = $st.ownerRole; app = $st.appRole }

  $ops = "CREATE SCHEMA IF NOT EXISTS cortex_ops AUTHORIZATION postgres;`n" +
         "REVOKE ALL ON SCHEMA cortex_ops FROM PUBLIC;`n" +
         "CREATE TABLE IF NOT EXISTS cortex_ops.schema_migrations (name text PRIMARY KEY, sha256 text NOT NULL, run_id text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now());`n"
  foreach ($e in $st.extensions) { $ops += "CREATE EXTENSION IF NOT EXISTS $e;`n" }
  Invoke-Psql $d $st.database -StdIn $ops | Out-Null
  Write-Step 'extensions' @{ extensions = @($st.extensions) }

  foreach ($m in $s.pending) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Psql $d $st.database @('-c', "SET ROLE $($st.ownerRole)", '-f', $m.path) | Out-Null
    Invoke-Psql $d $st.database -StdIn "INSERT INTO cortex_ops.schema_migrations (name, sha256, run_id) VALUES (:'name', :'sha', :'run');`n" `
      -Vars @{ name = $m.name; sha = $m.sha256; run = $RunId } | Out-Null
    Write-Step 'migration-applied' @{ name = $m.name; sha256 = $m.sha256; ms = $sw.ElapsedMilliseconds }
  }
}

# ------------------------------------------------------------------ DbChecks
# Runs db/checks against a throwaway database built from the same migrations,
# so checks that seed canary data never touch the real database.

function Invoke-CheckSuite($d) {
  $owner = Assert-Ident (Need $d 'ownerRole') 'ownerRole'
  $exts = @(Need $d 'extensions' | ForEach-Object { Assert-Ident $_ 'extension' })
  $checksDir = Need $d 'checksDir'
  $tmp = 'cortex_check_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $results = @()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    Invoke-Psql $d 'postgres' @('-c', "CREATE DATABASE $tmp OWNER $owner") | Out-Null
    foreach ($e in $exts) { Invoke-Psql $d $tmp @('-c', "CREATE EXTENSION IF NOT EXISTS $e") | Out-Null }
    foreach ($m in (Get-MigrationFiles (Need $d 'migrationsDir'))) { Invoke-Psql $d $tmp @('-c', "SET ROLE $owner", '-f', $m.path) | Out-Null }
    foreach ($c in @(Need $d 'checks')) {
      $file = Need $c 'file'; $expect = Need $c 'expect'
      $r = Invoke-Psql $d $tmp @('-f', (Join-Path $checksDir $file)) -AllowFail
      $out = Get-Tail $r.Out 1000
      $pass = ($r.Code -eq 0) -and ($expect -ne 'empty' -or $out -eq '')
      $results += [ordered]@{ file = $file; expect = $expect; pass = $pass; exit = $r.Code; output = $out; error = (Get-Tail $r.Err 1000) }
      Write-Step 'check' @{ file = $file; pass = $pass; exit = $r.Code }
    }
  } finally {
    Invoke-Psql $d 'postgres' @('-c', "DROP DATABASE IF EXISTS $tmp WITH (FORCE)") -AllowFail | Out-Null
  }
  $summary = [ordered]@{ run_id = $RunId; ts = [DateTime]::UtcNow.ToString('o'); ms = $sw.ElapsedMilliseconds; results = $results }
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
  [IO.File]::WriteAllText((Join-Path $LogDir 'checks.json'), ($summary | ConvertTo-Json -Depth 6), $Utf8)
  $results
}

function Get-DbChecksState($d) {
  $results = @()
  if ($Operation -eq 'get') {
    $last = Join-Path $LogDir 'checks.json'
    if (Test-Path $last) { $results = @((Get-Content $last -Raw | ConvertFrom-Json).results) }
  } else { $results = @(Invoke-CheckSuite $d) }
  $failed = @($results | Where-Object { -not $_.pass } | ForEach-Object { $_.file })
  $drift = @()
  if (-not $results.Count) { $drift += 'not-run' }
  if ($failed.Count) { $drift += $failed | ForEach-Object { "failed:$_" } }
  @{ ok = ($drift.Count -eq 0); state = [ordered]@{
      checks = @(Need $d 'checks'); checksDir = (Need $d 'checksDir'); migrationsDir = (Need $d 'migrationsDir')
      ownerRole = (Need $d 'ownerRole'); extensions = @(Need $d 'extensions')
      pgInstallDir = (Need $d 'pgInstallDir'); port = [int](Need $d 'port')
      passed = @($results | Where-Object { $_.pass }).Count; failed = $failed; results = $results; drift = $drift } }
}

function Set-DbChecks($d, $s) {
  # Nothing to converge: a failing invariant is a defect, never auto-fixed.
  throw "database checks failed: $(@($s.state.failed) -join ', ')"
}

# ------------------------------------------------------------------ DotnetSdk
# Pinned SDK in its own folder, never on PATH and never shared with other software.

function Get-DotnetSdkState($d) {
  $dir = Need $d 'installDir'; $version = Need $d 'version'; $hash = (Need $d 'sha512').ToLowerInvariant()
  $drift = @()
  $marker = Join-Path $dir '.cortex-artifact.json'
  $haveHash = $null
  if (Test-Path $marker) { $haveHash = (Get-Content $marker -Raw | ConvertFrom-Json).sha512 }
  $sdks = @()
  $exe = Join-Path $dir 'dotnet.exe'
  if (Test-Path $exe) { $sdks = @(Get-Lines (Invoke-Native $exe @('--list-sdks')).Out) }   # @(): one SDK must stay an array
  if ($haveHash -ne $hash) { $drift += 'files' }
  if (-not ($sdks | Where-Object { $_ -like "$version *" })) { $drift += 'sdk-version' }
  @{ ok = ($drift.Count -eq 0); state = [ordered]@{
      version = $version; url = (Need $d 'url'); sha512 = $hash; installDir = $dir; installedSdks = $sdks; drift = $drift } }
}

function Set-DotnetSdk($d, $s) {
  $dir = Need $d 'installDir'; $version = Need $d 'version'
  $zip = Get-PinnedFile (Need $d 'url') (Need $d 'sha512') "dotnet-sdk-$version-win-x64.zip" $CacheDir
  Write-Step 'verified' @{ file = $zip }
  Expand-ZipSubset $zip $dir '' @('')
  $marker = [ordered]@{ url = (Need $d 'url'); sha512 = (Need $d 'sha512').ToLowerInvariant(); version = $version; run_id = $RunId }
  [IO.File]::WriteAllText((Join-Path $dir '.cortex-artifact.json'), ($marker | ConvertTo-Json), $Utf8)
}

# ------------------------------------------------------------------ Ollama
# CPU build only (CUDA, ROCm and Vulkan libraries are not unpacked), loopback only,
# started at boot by a scheduled task running as NetworkService.

function Get-OllamaPort([string] $HostPort) {
  if ($HostPort -notmatch '^(127\.0\.0\.1|localhost):(\d{2,5})$') { throw "Ollama host must be loopback host:port, got '$HostPort'" }
  [int]$Matches[2]
}

function Get-OllamaVersion([string] $HostPort) {
  try { (Invoke-RestMethod -Uri "http://$HostPort/api/version" -TimeoutSec 5 -UseBasicParsing).version } catch { $null }
}

function Get-OllamaRunner($d) {
  $dir = Need $d 'installDir'
  "@echo off`r`n" +
  "rem Managed by Cortex provisioning (ADR 014). Local edits are overwritten.`r`n" +
  "set OLLAMA_HOST=$(Need $d 'host')`r`n" +
  "set OLLAMA_MODELS=$(Need $d 'modelsDir')`r`n" +
  "set OLLAMA_KEEP_ALIVE=30m`r`n" +
  "set OLLAMA_NUM_PARALLEL=1`r`n" +
  "set OLLAMA_MAX_LOADED_MODELS=2`r`n" +
  "`"$dir\ollama.exe`" serve >> `"$(Need $d 'logDir')\serve.log`" 2>&1`r`n"
}

function Stop-CortexOllama($d) {
  $dir = (Need $d 'installDir').ToLowerInvariant()
  try { Stop-ScheduledTask -TaskName (Need $d 'taskName') -ErrorAction SilentlyContinue } catch { }
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.ToLowerInvariant().StartsWith($dir) })) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Write-Step 'process-stopped' @{ name = $p.ProcessName; pid = $p.Id }
  }
}

function Get-OllamaState($d) {
  $dir = Need $d 'installDir'; $version = Need $d 'version'; $sha = (Need $d 'sha256').ToLowerInvariant()
  $hp = Need $d 'host'; $port = Get-OllamaPort $hp; $task = Need $d 'taskName'
  $drift = @()
  $marker = Join-Path $dir '.cortex-artifact.json'
  $haveSha = $null
  if (Test-Path $marker) { $haveSha = (Get-Content $marker -Raw | ConvertFrom-Json).sha256 }
  if ($haveSha -ne $sha) { $drift += 'binaries' }
  $runner = Join-Path $dir 'cortex-ollama.cmd'
  if (-not (Test-Path $runner) -or [IO.File]::ReadAllText($runner) -ne (Get-OllamaRunner $d)) { $drift += 'runner' }
  $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
  $taskState = $null
  if ($t) { $taskState = "$($t.State)" } else { $drift += 'task' }
  $serving = Get-OllamaVersion $hp
  if ($serving -ne $version) { $drift += 'not-serving' }
  $listening = @(Get-Listeners $port)
  if (@($listening | Where-Object { $_ -notin '127.0.0.1', '::1' }).Count) { $drift += 'exposed' }
  @{ ok = ($drift.Count -eq 0); state = [ordered]@{
      version = $version; url = (Need $d 'url'); sha256 = $sha; installDir = $dir; modelsDir = (Need $d 'modelsDir')
      logDir = (Need $d 'logDir'); host = $hp; taskName = $task
      servingVersion = $serving; taskState = $taskState; listeningOn = $listening; drift = $drift } }
}

function Set-Ollama($d, $s) {
  $dir = Need $d 'installDir'; $version = Need $d 'version'; $task = Need $d 'taskName'; $hp = Need $d 'host'
  $drift = @($s.state.drift)
  $restart = $false
  if ($drift -contains 'binaries') {
    Stop-CortexOllama $d
    $zip = Get-PinnedFile (Need $d 'url') (Need $d 'sha256') "ollama-$version-windows-amd64.zip" $CacheDir
    Write-Step 'verified' @{ file = $zip }
    Expand-ZipSubset $zip $dir '' @('ollama.exe', 'lib/ollama/') @('lib/ollama/cuda_v12/', 'lib/ollama/cuda_v13/', 'lib/ollama/vulkan/', 'lib/ollama/rocm/')
    $marker = [ordered]@{ url = (Need $d 'url'); sha256 = (Need $d 'sha256').ToLowerInvariant(); version = $version; run_id = $RunId }
    [IO.File]::WriteAllText((Join-Path $dir '.cortex-artifact.json'), ($marker | ConvertTo-Json), $Utf8)
    $restart = $true
  }
  foreach ($p in (Need $d 'modelsDir'), (Need $d 'logDir')) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force $p | Out-Null }
    Set-RestrictedAcl $p @('*S-1-5-20')   # NetworkService runs Ollama
  }
  $runner = Join-Path $dir 'cortex-ollama.cmd'
  $text = Get-OllamaRunner $d
  if (-not (Test-Path $runner) -or [IO.File]::ReadAllText($runner) -ne $text) {
    [IO.File]::WriteAllText($runner, $text, (New-Object System.Text.ASCIIEncoding)); $restart = $true
    Write-Step 'runner-written' @{ path = $runner }
  }
  $action = New-ScheduledTaskAction -Execute $runner
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\NETWORK SERVICE' -LogonType ServiceAccount -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Write-Step 'task-registered' @{ task = $task; account = 'NetworkService'; trigger = 'AtStartup' }

  if ($restart -or (Get-OllamaVersion $hp) -ne $version) {
    Stop-CortexOllama $d
    Start-ScheduledTask -TaskName $task
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-OllamaVersion $hp) -ne $version) {
      if ($sw.Elapsed.TotalSeconds -gt 60) { throw "Ollama did not answer on $hp within 60s; see $(Need $d 'logDir')\serve.log" }
      Start-Sleep -Seconds 1
    }
    Write-Step 'serving' @{ host = $hp; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
  }
}

# ------------------------------------------------------------------ OllamaModel
# A model is pinned by its manifest digest. The registry only serves tags, so the pull
# is verified after the fact: a different digest fails the run.

function Get-OllamaModelState($d) {
  $name = Need $d 'name'; $digest = (Need $d 'digest').ToLowerInvariant(); $hp = Need $d 'host'
  [void](Get-OllamaPort $hp)
  $have = $null; $size = $null
  try {
    $tags = Invoke-RestMethod -Uri "http://$hp/api/tags" -TimeoutSec 10 -UseBasicParsing
    $m = @($tags.models | Where-Object { $_.name -eq $name }) | Select-Object -First 1
    if ($m) { $have = $m.digest; $size = $m.size }
  } catch { }
  $drift = @()
  if (-not $have) { $drift += 'not-pulled' } elseif ($have -ne $digest) { $drift += 'digest' }
  @{ ok = ($drift.Count -eq 0); state = [ordered]@{
      name = $name; digest = $digest; host = $hp; installedDigest = $have; sizeBytes = $size; drift = $drift } }
}

function Set-OllamaModel($d, $s) {
  $name = Need $d 'name'; $hp = Need $d 'host'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $body = @{ model = $name; stream = $false } | ConvertTo-Json -Compress
  $r = Invoke-RestMethod -Method Post -Uri "http://$hp/api/pull" -Body $body -ContentType 'application/json' -TimeoutSec 3600 -UseBasicParsing
  Write-Step 'pulled' @{ name = $name; status = "$($r.status)"; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
  $after = Get-OllamaModelState $d
  if ($after.state.installedDigest -and $after.state.installedDigest -ne $after.state.digest) {
    throw "registry served $name with digest $($after.state.installedDigest), pinned $($after.state.digest). Not accepted."
  }
}

# ------------------------------------------------------------------ AppService
# The app, CI built (self contained, pinned by SHA256), as the Windows service cortex-web
# under its own virtual account. That account may read exactly the app's config and the
# two secrets the app needs; the database superuser secret must stay out of its reach.

function Get-AppDir($d) { Join-Path (Need $d 'installDir') (Need $d 'version') }
function Get-AppAccount($d) { 'NT SERVICE\' + (Need $d 'serviceName') }

function Get-AppEnv($d) {
  @("CORTEX_PROFILE=local", "CORTEX_CONFIG=$(Need $d 'configPath')")
}

function Get-AclAccounts([string] $Path) {
  if (-not (Test-Path $Path)) { return @() }
  @((Get-Acl $Path).Access | ForEach-Object { "$($_.IdentityReference)" })
}

function Test-AppAlive([int] $Port) {
  try { (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/alive" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { $false }
}

function Get-AppServiceState($d) {
  $name = Need $d 'serviceName'
  if ($name -notmatch '^[A-Za-z0-9_-]+$') { throw "bad service name $name" }
  $dir = Get-AppDir $d; $sha = (Need $d 'sha256').ToLowerInvariant(); $account = Get-AppAccount $d
  $port = [int](Need $d 'httpPort')
  $drift = @()
  $marker = Join-Path $dir '.cortex-artifact.json'
  $haveSha = $null
  if (Test-Path $marker) { $haveSha = (Get-Content $marker -Raw | ConvertFrom-Json).sha256 }
  if ($haveSha -ne $sha) { $drift += 'binaries' }

  $svc = Get-CimInstance Win32_Service -Filter "Name='$name'"
  $deps = @()
  if ($svc) { $deps = @((Get-Service -Name $name).ServicesDependedOn | ForEach-Object { $_.Name }) }
  $exe = Join-Path $dir 'Cortex.Web.exe'
  if (-not $svc) { $drift += 'service' }
  else {
    if (-not $svc.PathName.ToLowerInvariant().Contains($exe.ToLowerInvariant()) -or $svc.StartName -ne $account -or $svc.StartMode -ne 'Auto' -or $deps -notcontains (Need $d 'dependsOn')) { $drift += 'service-config' }
    if ($svc.State -ne 'Running') { $drift += 'not-running' }
  }
  $envHave = @()
  $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
  if ((Test-Path $key) -and (Get-ItemProperty $key).PSObject.Properties['Environment']) { $envHave = @((Get-ItemProperty $key).Environment) }
  if (($envHave -join "`n") -ne ((Get-AppEnv $d) -join "`n")) { $drift += 'environment' }

  $readable = @(@(Need $d 'readFiles') | Where-Object { (Get-AclAccounts $_) -contains $account })
  if ($readable.Count -ne @(Need $d 'readFiles').Count) { $drift += 'acl-read' }
  $leaky = @(@(Need $d 'denyFiles') | Where-Object { (Get-AclAccounts $_) -contains $account })
  if ($leaky.Count) { $drift += 'acl-deny' }

  $alive = Test-AppAlive $port
  if (-not $alive) { $drift += 'not-alive' }
  $listening = @(Get-Listeners $port)
  if (@($listening | Where-Object { $_ -notin '127.0.0.1', '::1' }).Count) { $drift += 'exposed' }

  @{ ok = ($drift.Count -eq 0); state = [ordered]@{
      version = (Need $d 'version'); url = (Need $d 'url'); sha256 = (Need $d 'sha256'); installDir = (Need $d 'installDir')
      serviceName = $name; dependsOn = (Need $d 'dependsOn'); configPath = (Need $d 'configPath'); httpPort = $port
      readFiles = @(Need $d 'readFiles'); denyFiles = @(Need $d 'denyFiles')
      # Explicit else: an if without one yields AutomationNull, which ConvertTo-Json writes as {}.
      account = $(if ($svc) { $svc.StartName } else { $null }); serviceState = $(if ($svc) { $svc.State } else { $null })
      processId = $(if ($svc) { [int]$svc.ProcessId } else { $null })
      alive = $alive; listeningOn = $listening; drift = $drift } }
}

function Set-AppService($d, $s) {
  $name = Need $d 'serviceName'; $dir = Get-AppDir $d; $account = Get-AppAccount $d; $port = [int](Need $d 'httpPort')
  $drift = @($s.state.drift)
  $sc = "$env:SystemRoot\System32\sc.exe"
  $restart = $false

  if ($drift -contains 'binaries') {
    if (Get-Service -Name $name -ErrorAction SilentlyContinue) { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
    $zip = Get-PinnedFile (Need $d 'url') (Need $d 'sha256') "cortex-app-$(Need $d 'version')-win-x64.zip" $CacheDir
    Write-Step 'verified' @{ file = $zip }
    Expand-ZipSubset $zip $dir '' @('')
    $marker = [ordered]@{ url = (Need $d 'url'); sha256 = (Need $d 'sha256').ToLowerInvariant(); version = (Need $d 'version'); run_id = $RunId }
    [IO.File]::WriteAllText((Join-Path $dir '.cortex-artifact.json'), ($marker | ConvertTo-Json), $Utf8)
    $restart = $true
  }

  $binPath = '"' + (Join-Path $dir 'Cortex.Web.exe') + '" web'
  $verb = if (Get-Service -Name $name -ErrorAction SilentlyContinue) { 'config' } else { 'create' }
  $r = Invoke-Native $sc @($verb, $name, 'binPath=', $binPath, 'obj=', $account, 'start=', 'auto', 'depend=', (Need $d 'dependsOn'), 'DisplayName=', 'Cortex app')
  Write-Step "service-$verb" @{ exit = $r.Code; out = (Get-Tail $r.Out 300) }
  if ($r.Code) { throw "sc $verb failed: $($r.Out) $($r.Err)" }
  Invoke-Native $sc @('description', $name, 'Cortex local profile app (managed by Cortex provisioning).') | Out-Null
  $r = Invoke-Native $sc @('failure', $name, 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/30000')
  Write-Step 'service-recovery' @{ exit = $r.Code }

  $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
  Set-ItemProperty -Path $key -Name Environment -Type MultiString -Value (Get-AppEnv $d)
  if ($drift -contains 'environment' -or $drift -contains 'service-config') { $restart = $true }

  foreach ($f in @(Need $d 'readFiles')) {
    $r = Invoke-Native "$env:SystemRoot\System32\icacls.exe" @($f, '/grant', "${account}:(R)")
    if ($r.Code) { throw "icacls grant on $f failed: $($r.Out)" }
  }
  foreach ($f in @(Need $d 'denyFiles')) {
    if (Test-Path $f) { Invoke-Native "$env:SystemRoot\System32\icacls.exe" @($f, '/remove:g', $account) | Out-Null }
  }
  Write-Step 'acl' @{ account = $account; read = @(Need $d 'readFiles'); denied = @(Need $d 'denyFiles') }

  $svc = Get-Service -Name $name
  if ($svc.Status -eq 'Running' -and $restart) { Restart-Service -Name $name -Force; Write-Step 'service-restarted' }
  elseif ($svc.Status -ne 'Running') {
    foreach ($c in @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
      throw "port $port is already used by pid $($c.OwningProcess); stop it first"
    }
    Start-Service -Name $name; Write-Step 'service-started'
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-AppAlive $port)) {
    if ($sw.Elapsed.TotalSeconds -gt 60) { throw "app not alive on port $port within 60s; see the Application event log (source cortex-web)" }
    Start-Sleep -Seconds 1
  }
  Write-Step 'alive' @{ seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

# ------------------------------------------------------------------ LocalInstall
# The local profile's identity: one customer, one fixed tenant, the app role's password
# (DPAPI) and the install config the app reads (no secrets in it).

function Get-JsonPath($Obj, [string] $Path) {
  $cur = $Obj
  foreach ($part in $Path -split '\.') {
    if ($null -eq $cur -or -not $cur.PSObject.Properties[$part]) { return $null }
    $cur = $cur.PSObject.Properties[$part].Value
  }
  $cur
}

function Get-InstallConfigText($d, [string] $CustomerId, [string] $TenantId) {
  $cfg = [ordered]@{
    Cortex = [ordered]@{
      Local = [ordered]@{ TenantId = $TenantId; TenantName = (Need $d 'tenantName'); Port = [int](Need $d 'httpPort'); SecretsDirectory = $SecretDir; MemoryKeySecret = (Need $d 'memoryKeySecret') }
      Database = [ordered]@{ Host = '127.0.0.1'; Port = [int](Need $d 'port'); Database = (Need $d 'database'); Username = (Need $d 'appRole'); PasswordSecret = (Need $d 'appSecret') }
      Model = [ordered]@{ Endpoint = (Need $d 'modelEndpoint'); Name = (Need $d 'modelName'); EmbeddingName = (Need $d 'embeddingModelName') }
    }
    Install = [ordered]@{ CustomerId = $CustomerId; CustomerName = (Need $d 'customerName') }
  }
  ($cfg | ConvertTo-Json -Depth 6) + "`n"
}

function Test-AppLogin($d) {
  $app = Assert-Ident (Need $d 'appRole') 'appRole'
  $db = Assert-Ident (Need $d 'database') 'database'
  if (-not (Test-Path (Get-SecretPath (Need $d 'appSecret')))) { return $false }
  $a = @('-X', '-q', '-tA', '-h', '127.0.0.1', '-p', "$(Need $d 'port')", '-U', $app, '-d', $db, '-c', 'SELECT current_user')
  $r = Invoke-Native (Join-Path (Need $d 'pgInstallDir') 'bin\psql.exe') $a @{ PGPASSWORD = (Unprotect-Secret (Need $d 'appSecret')); PGCONNECT_TIMEOUT = '10' }
  $r.Code -eq 0 -and $r.Out.Trim() -eq $app
}

function Get-AgentVars($d) {
  $tools = @(Need $d 'agentTools' | ForEach-Object { Assert-Ident $_ 'tool' })
  @{ n = (Need $d 'agentName'); p = (Need $d 'agentPrompt'); m = (Need $d 'modelName'); t = ($tools -join ',') }
}

function Get-LocalInstallState($d) {
  $path = Need $d 'configPath'
  $db = Assert-Ident (Need $d 'database') 'database'
  $cfg = $null
  if (Test-Path $path) { $cfg = Get-Content $path -Raw | ConvertFrom-Json }
  $tenantId = Get-JsonPath $cfg 'Cortex.Local.TenantId'
  $customerId = Get-JsonPath $cfg 'Install.CustomerId'
  $drift = @()
  if (-not $tenantId -or -not $customerId) { $drift += 'ids' }
  elseif ([IO.File]::ReadAllText($path) -ne (Get-InstallConfigText $d $customerId $tenantId)) { $drift += 'config' }
  if (-not (Test-Path (Get-SecretPath (Need $d 'appSecret')))) { $drift += 'secret' }
  $login = Test-AppLogin $d
  if (-not $login) { $drift += 'app-login' }
  $row = $false
  if ($tenantId -and $tenantId -match '^[0-9a-fA-F-]{36}$') {
    $row = (Invoke-Psql $d $db @('-c', "SELECT count(*) FROM cortex.tenants WHERE id = '$tenantId'")).Out.Trim() -eq '1'
  }
  if (-not $row) { $drift += 'tenant-row' }
  if (-not (Test-Path (Get-SecretPath (Need $d 'memoryKeySecret')))) { $drift += 'memory-key' }
  $agentOk = $false
  if ($row) {
    $r = Invoke-Psql $d $db -StdIn (
      "SELECT count(*) FILTER (WHERE system_prompt = :'p' AND model = :'m' AND tools = string_to_array(:'t', ',')) " +
      "FROM cortex.agents WHERE tenant_id = '$tenantId' AND name = :'n';`n") -Vars (Get-AgentVars $d)
    $agentOk = $r.Out.Trim() -eq '1'
  }
  if (-not $agentOk) { $drift += 'agent' }
  @{ ok = ($drift.Count -eq 0); customerId = $customerId; tenantId = $tenantId; state = [ordered]@{
      configPath = $path; customerName = (Need $d 'customerName'); tenantName = (Need $d 'tenantName')
      database = $db; appRole = (Need $d 'appRole'); appSecret = (Need $d 'appSecret')
      pgInstallDir = (Need $d 'pgInstallDir'); port = [int](Need $d 'port'); httpPort = [int](Need $d 'httpPort')
      modelEndpoint = (Need $d 'modelEndpoint'); modelName = (Need $d 'modelName')
      embeddingModelName = (Need $d 'embeddingModelName'); memoryKeySecret = (Need $d 'memoryKeySecret')
      agentName = (Need $d 'agentName'); agentPrompt = (Need $d 'agentPrompt'); agentTools = @(Need $d 'agentTools')
      tenantId = $tenantId; appLogin = $login; tenantRow = $row; agentSeeded = $agentOk; drift = $drift } }
}

function Set-LocalInstall($d, $s) {
  $db = Assert-Ident (Need $d 'database') 'database'
  $app = Assert-Ident (Need $d 'appRole') 'appRole'
  $secret = Need $d 'appSecret'
  $tenantId = if ($s.tenantId) { $s.tenantId } else { [guid]::NewGuid().ToString() }
  $customerId = if ($s.customerId) { $s.customerId } else { [guid]::NewGuid().ToString() }

  if (-not (Test-Path (Get-SecretPath $secret))) { Protect-Secret $secret (New-RandomSecret) }
  if (-not (Test-AppLogin $d)) {
    # Password travels on stdin only (never argv); base64url has no quote characters.
    Invoke-Psql $d 'postgres' -StdIn "ALTER ROLE $app WITH LOGIN PASSWORD '$(Unprotect-Secret $secret)';`n" | Out-Null
    Write-Step 'app-password-set' @{ role = $app; secret = $secret }
  }

  $sql = "INSERT INTO cortex.customers (id, legal_name) VALUES ('$customerId', :'customer') ON CONFLICT (id) DO NOTHING;`n" +
         "INSERT INTO cortex.tenants (id, customer_id, name, tier) VALUES ('$tenantId', '$customerId', :'tenant', 'silo') ON CONFLICT (id) DO NOTHING;`n"
  Invoke-Psql $d $db -StdIn $sql -Vars @{ customer = (Need $d 'customerName'); tenant = (Need $d 'tenantName') } | Out-Null
  Write-Step 'tenant-row' @{ tenant_id = $tenantId; customer_id = $customerId }

  # Memory content key (AES-256), DPAPI protected like every other local secret.
  if (-not (Test-Path (Get-SecretPath (Need $d 'memoryKeySecret')))) { Protect-Secret (Need $d 'memoryKeySecret') (New-RandomSecret) }

  # The agent is desired state too: prompt, model and allow list converge on every run.
  $agentSql = "UPDATE cortex.agents SET system_prompt = :'p', model = :'m', tools = string_to_array(:'t', ',') WHERE tenant_id = '$tenantId' AND name = :'n';`n" +
              "INSERT INTO cortex.agents (tenant_id, name, system_prompt, model, tools, max_steps, token_budget) " +
              "SELECT '$tenantId', :'n', :'p', :'m', string_to_array(:'t', ','), 4, 8000 " +
              "WHERE NOT EXISTS (SELECT 1 FROM cortex.agents WHERE tenant_id = '$tenantId' AND name = :'n');`n"
  Invoke-Psql $d $db -StdIn $agentSql -Vars (Get-AgentVars $d) | Out-Null
  Write-Step 'agent' @{ name = (Need $d 'agentName'); tools = @(Need $d 'agentTools') }

  $path = Need $d 'configPath'
  $dir = Split-Path $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  Set-RestrictedAcl $dir @()
  [IO.File]::WriteAllText($path, (Get-InstallConfigText $d $customerId $tenantId), $Utf8)
  Write-Step 'config-written' @{ path = $path }
}

# ------------------------------------------------------------------ main

try {
  $raw = [Console]::In.ReadToEnd()
  $desired = if ($raw -and $raw.Trim()) { $raw | ConvertFrom-Json } else { New-Object psobject }
  Write-Step 'start'
  $s = & "Get-$($Resource)State" $desired
  if ($Operation -eq 'set') {
    if ($s.ok) { Write-Step 'no-change' }
    else {
      Write-Step 'drift' @{ drift = @($s.state.drift) }
      & "Set-$Resource" $desired $s
      $s = & "Get-$($Resource)State" $desired
      if (-not $s.ok) { throw "still out of desired state after set: $(@($s.state.drift) -join ', ')" }
      Write-Step 'converged'
    }
  }
  $out = $s.state
  if ($Operation -eq 'test') { $out['_inDesiredState'] = [bool]$s.ok }
  Write-Step 'end' @{ ok = [bool]$s.ok; drift = @($s.state.drift) }
  [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 8))
  exit 0
} catch {
  $msg = $_.Exception.Message
  try { Write-Step 'error' @{ message = $msg; at = "$($_.InvocationInfo.ScriptLineNumber)" } } catch { }
  [Console]::Error.WriteLine((@{ error = "$Resource.$Operation $msg" } | ConvertTo-Json -Compress))
  exit 1
}
