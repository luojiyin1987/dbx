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

$fileHashCache = @{}

function Get-HashedFile([string] $Path) {
  $Path = [System.IO.Path]::GetFullPath($Path)
  if ($fileHashCache.ContainsKey($Path)) {
    return $fileHashCache[$Path]
  }

  $item = Get-Item -LiteralPath $Path
  $entry = [pscustomobject]@{
    path = ConvertTo-StableText $Path
    bytes = $item.Length
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $fileHashCache[$Path] = $entry
  return $entry
}

$keys = @{}
$results = @{}
$arguments = @{}
$allArguments = @{}
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
    $rawArguments = $Matches.arguments
    $stableArguments = ConvertTo-StableText $rawArguments
    $argumentHash = Get-TextHash $stableArguments
    try {
      $argumentValues = @($rawArguments | ConvertFrom-Json)
    } catch {
      continue
    }

    $argumentEntry = [pscustomobject]@{
      crate = $crateName
      sha256 = $argumentHash
      arguments = $stableArguments
      values = $argumentValues
    }
    $allArguments["$crateName`0$argumentHash"] = $argumentEntry
    if ($argumentCrates.Contains($crateName)) {
      $arguments["$crateName`0$argumentHash"] = [pscustomobject]@{
        crate = $crateName
        sha256 = $argumentHash
        arguments = $stableArguments
      }
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
$missCrates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($crateName in $results.Keys) {
  if ($results[$crateName].misses -gt 0) {
    [void] $missCrates.Add($crateName)
  }
}

$externInputs = @{}
foreach ($argumentEntry in $allArguments.Values) {
  if (!$missCrates.Contains($argumentEntry.crate)) {
    continue
  }

  $values = $argumentEntry.values
  for ($index = 0; $index -lt $values.Count; $index++) {
    $value = [string] $values[$index]
    $externSpec = $null
    if ($value -eq "--extern" -and $index + 1 -lt $values.Count) {
      $externSpec = [string] $values[$index + 1]
      $index++
    } elseif ($value.StartsWith("--extern=")) {
      $externSpec = $value.Substring("--extern=".Length)
    }
    if ([string]::IsNullOrEmpty($externSpec)) {
      continue
    }

    $separator = $externSpec.IndexOf("=")
    if ($separator -le 0) {
      continue
    }
    $externName = $externSpec.Substring(0, $separator)
    $externPath = $externSpec.Substring($separator + 1)
    if (![System.IO.Path]::IsPathRooted($externPath)) {
      $externPath = Join-Path $env:GITHUB_WORKSPACE $externPath
    }
    $extension = [System.IO.Path]::GetExtension($externPath)
    if ($extension -notin @(".dll", ".rlib", ".rmeta") -or !(Test-Path -LiteralPath $externPath -PathType Leaf)) {
      continue
    }

    $file = Get-HashedFile $externPath
    $recordKey = "$($argumentEntry.crate)`0$externName`0$($file.path)"
    $externInputs[$recordKey] = [pscustomobject]@{
      consumer = $argumentEntry.crate
      extern = $externName
      path = $file.path
      bytes = $file.bytes
      sha256 = $file.sha256
    }
  }
}

$outputFiles = @{}
$targetRoot = Join-Path $env:GITHUB_WORKSPACE "target"
if (Test-Path -LiteralPath $targetRoot -PathType Container) {
  foreach ($item in Get-ChildItem -LiteralPath $targetRoot -Recurse -File -Include "*.dll", "*.rlib", "*.rmeta") {
    $stem = $item.BaseName
    if ($stem.StartsWith("lib")) {
      $stem = $stem.Substring(3)
    }
    $separator = $stem.LastIndexOf("-")
    if ($separator -le 0) {
      continue
    }
    $crateName = $stem.Substring(0, $separator)
    if (!$missCrates.Contains($crateName)) {
      continue
    }

    $file = Get-HashedFile $item.FullName
    $outputFiles[$file.path] = [pscustomobject]@{
      crate = $crateName
      path = $file.path
      bytes = $file.bytes
      sha256 = $file.sha256
    }
  }
}

$compilerFiles = @()
$sysroot = ((rustc --print sysroot | Out-String).Trim())
$compilerDirectory = Join-Path $sysroot "bin"
if (Test-Path -LiteralPath $compilerDirectory -PathType Container) {
  $compilerFiles = @(
    foreach ($item in Get-ChildItem -LiteralPath $compilerDirectory -File -Filter "*.dll") {
      Get-HashedFile $item.FullName
    }
  )
}

$jobEnvironment = @(
  foreach ($name in @(
    "CARGO_PROFILE_RELEASE_CODEGEN_UNITS",
    "CARGO_PROFILE_RELEASE_LTO",
    "CARGO_TARGET_DIR",
    "RUSTC",
    "RUSTC_WRAPPER",
    "RUSTFLAGS",
    "TAURI_CONFIG"
  )) {
    $value = [System.Environment]::GetEnvironmentVariable($name)
    if ($null -ne $value) {
      [pscustomobject]@{
        name = $name
        bytes = [System.Text.Encoding]::UTF8.GetByteCount($value)
        value_sha256 = Get-TextHash $value
      }
    }
  }
)

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
  miss_crates = @($missCrates | Sort-Object)
  miss_extern_inputs = @($externInputs.Values | Sort-Object consumer, extern, path)
  miss_output_files = @($outputFiles.Values | Sort-Object crate, path)
  compiler_files = @($compilerFiles | Sort-Object path)
  job_environment = @($jobEnvironment | Sort-Object name)
  cwd = ConvertTo-StableText ([System.IO.Path]::GetFullPath((Get-Location).Path))
}
$trace | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tracePath -Encoding utf8

"[WIN7-SCCACHE-KEY-TRACE] keys=$($keyEntries.Count) crates=$($keys.Count) critical_arguments=$($argumentEntries.Count) extern_inputs=$($externInputs.Count) miss_outputs=$($outputFiles.Count) compiler_files=$($compilerFiles.Count) path=$tracePath"
