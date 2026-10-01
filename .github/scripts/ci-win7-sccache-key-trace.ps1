param(
  [string] $OutputDirectory = (Join-Path $env:RUNNER_TEMP "win7-sccache-key-trace")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (!(Test-Path -LiteralPath $env:SCCACHE_ERROR_LOG)) {
  throw "The sccache debug log does not exist."
}

$argumentCrates = [System.Collections.Generic.HashSet[string]]::new(
  [string[]] @(
    "std",
    "sqlparser",
    "zstd_sys",
    "mongodb",
    "rmcp",
    "dbx_drivers",
    "dbx_core",
    "dbx_mcp",
    "dbx_lib"
  ),
  [System.StringComparer]::Ordinal
)

function ConvertTo-StableText([string] $text) {
  if (![string]::IsNullOrEmpty($env:GITHUB_WORKSPACE)) {
    $text = $text.Replace($env:GITHUB_WORKSPACE, "<workspace>")
  }
  if (![string]::IsNullOrEmpty($env:RUNNER_TEMP)) {
    $text = $text.Replace($env:RUNNER_TEMP, "<runner-temp>")
  }
  return $text
}

function Get-TextHash([string] $text) {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha256.Dispose()
  }
}

$keys = @{}
$results = @{}
$arguments = @{}
$escape = [char] 27
$ansiPattern = [regex]::Escape([string] $escape) + '\[[0-9;]*[A-Za-z]'

foreach ($line in Get-Content -LiteralPath $env:SCCACHE_ERROR_LOG) {
  $plainLine = $line -replace $ansiPattern, ""

  if ($plainLine -match '\[(?<crate>[^\]]+)\]: Hash key: (?<key>[0-9a-f]+)') {
    $crateName = $Matches.crate
    if (!$keys.ContainsKey($crateName)) {
      $keys[$crateName] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    }
    [void] $keys[$crateName].Add($Matches.key)
    continue
  }

  if ($plainLine -match '\[(?<crate>[^\]]+)\]: Cache hit in') {
    $crateName = $Matches.crate
    if (!$results.ContainsKey($crateName)) {
      $results[$crateName] = @{ hits = 0; misses = 0 }
    }
    $results[$crateName].hits++
    continue
  }

  if ($plainLine -match '\[(?<crate>[^\]]+)\]: Cache miss in') {
    $crateName = $Matches.crate
    if (!$results.ContainsKey($crateName)) {
      $results[$crateName] = @{ hits = 0; misses = 0 }
    }
    $results[$crateName].misses++
    continue
  }

  if ($plainLine -match '\[(?<crate>[^\]]+)\]: get_cached_or_compile: (?<arguments>.+)$') {
    $crateName = $Matches.crate
    if (!$argumentCrates.Contains($crateName)) {
      continue
    }
    $stableArguments = ConvertTo-StableText $Matches.arguments
    $argumentHash = Get-TextHash $stableArguments
    $arguments["$crateName`0$argumentHash"] = [pscustomobject]@{
      crate = $crateName
      sha256 = $argumentHash
      arguments = $stableArguments
    }
  }
}

$keyEntries = @(
  foreach ($crateName in ($keys.Keys | Sort-Object)) {
    foreach ($key in ($keys[$crateName] | Sort-Object)) {
      [pscustomobject]@{ crate = $crateName; key = $key }
    }
  }
)
$resultEntries = @(
  foreach ($crateName in ($results.Keys | Sort-Object)) {
    [pscustomobject]@{
      crate = $crateName
      hits = $results[$crateName].hits
      misses = $results[$crateName].misses
    }
  }
)
$argumentEntries = @($arguments.Values | Sort-Object crate, sha256)

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$tracePath = Join-Path $OutputDirectory "win7-sccache-key-trace.json"
$trace = [pscustomobject]@{
  runner = [pscustomobject]@{
    image_os = $env:ImageOS
    image_version = $env:ImageVersion
  }
  rustc = ConvertTo-StableText ((rustc -vV | Out-String).Trim())
  keys = $keyEntries
  results = $resultEntries
  critical_arguments = $argumentEntries
}
$trace | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tracePath -Encoding utf8

"[WIN7-SCCACHE-KEY-TRACE] keys=$($keyEntries.Count) crates=$($keys.Count) critical_arguments=$($argumentEntries.Count) path=$tracePath"
