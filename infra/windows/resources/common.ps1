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
    [string] $StdIn = '',
    [string] $WorkingDirectory = ''
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $File
  if ($WorkingDirectory -ne '') { $psi.WorkingDirectory = $WorkingDirectory }
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

# A pin is a SHA256 (64 hex) or, where the vendor publishes it, a SHA512 (128 hex).
function Get-PinAlgorithm([string] $Value, [string] $What) {
  if ($Value -match '^[0-9a-fA-F]{64}$') { return 'SHA256' }
  if ($Value -match '^[0-9a-fA-F]{128}$') { return 'SHA512' }
  throw "$What hash is not pinned (got '$Value')"
}

# Download once into the cache, verify the pinned hash, return the cached path.
function Get-PinnedFile([string] $Url, [string] $Hash, [string] $Name, [string] $CacheDir) {
  $alg = Get-PinAlgorithm $Hash $Name
  $want = $Hash.ToLowerInvariant()
  if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
  $path = Join-Path $CacheDir ('{0}-{1}' -f $want.Substring(0, 12), $Name)
  if ((Test-Path $path) -and (Get-FileHash -Path $path -Algorithm $alg).Hash.ToLowerInvariant() -eq $want) { return $path }
  $tmp = "$path.part"
  (New-Object System.Net.WebClient).DownloadFile($Url, $tmp)
  $got = (Get-FileHash -Path $tmp -Algorithm $alg).Hash.ToLowerInvariant()
  if ($got -ne $want) { Remove-Item $tmp -Force; throw "$alg mismatch for $Url (expected $want, got $got)" }
  Move-Item $tmp $path -Force
  $path
}
