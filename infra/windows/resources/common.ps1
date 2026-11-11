# Shared helpers for bootstrap.ps1 and cortex-dsc.ps1. Windows PowerShell 5.1 compatible.
# Native processes run through System.Diagnostics.Process so stderr never turns into
# PowerShell errors and stdout stays clean for dsc.

function ConvertTo-ArgString([string] $Value) {
  if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($c in $Value.ToCharArray()) {
    if ($c -eq [char]'\') { $slashes++; continue }
    if ($c -eq [char]'"') {
      [void]$sb.Append([char]'\', 2 * $slashes + 1); [void]$sb.Append('"'); $slashes = 0; continue
    }
    if ($slashes) { [void]$sb.Append([char]'\', $slashes); $slashes = 0 }
    [void]$sb.Append($c)
  }
  [void]$sb.Append([char]'\', 2 * $slashes)
  [void]$sb.Append('"')
  $sb.ToString()
}

function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)] [string] $File,
    [string[]] $Arguments = @(),
    [hashtable] $Environment = @{},
    [string] $StdIn = ''
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $File
  $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-ArgString $_ })) -join ' '
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = ($StdIn -ne '')
  foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
  $p = [System.Diagnostics.Process]::Start($psi)
  if ($StdIn -ne '') { $p.StandardInput.Write($StdIn); $p.StandardInput.Close() }
  $out = $p.StandardOutput.ReadToEndAsync()
  $err = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

function Get-Sha256([string] $Path) {
  (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Hash of text with line endings normalised, so a CRLF checkout hashes like the LF repo.
function Get-TextSha256([string] $Path) {
  $text = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash((New-Object System.Text.UTF8Encoding $false).GetBytes($text))
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
  } finally { $sha.Dispose() }
}

function Assert-Sha256Format([string] $Value, [string] $What) {
  if ($Value -notmatch '^[0-9a-fA-F]{64}$') { throw "$What sha256 is not pinned (got '$Value')" }
}

# Download once into the cache, verify SHA256, return the cached path.
function Get-PinnedFile([string] $Url, [string] $Sha256, [string] $Name, [string] $CacheDir) {
  Assert-Sha256Format $Sha256 $Name
  $want = $Sha256.ToLowerInvariant()
  if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
  $path = Join-Path $CacheDir ('{0}-{1}' -f $want.Substring(0, 12), $Name)
  if ((Test-Path $path) -and (Get-Sha256 $path) -eq $want) { return $path }
  $tmp = "$path.part"
  (New-Object System.Net.WebClient).DownloadFile($Url, $tmp)
  $got = Get-Sha256 $tmp
  if ($got -ne $want) { Remove-Item $tmp -Force; throw "sha256 mismatch for $Url (expected $want, got $got)" }
  Move-Item $tmp $path -Force
  $path
}
