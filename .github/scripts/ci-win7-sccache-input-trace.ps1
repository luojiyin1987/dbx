param(
  [switch] $CaptureEnvironment,
  [ValidateSet("dbx_lib", "psm")]
  [string] $Crate,
  [string] $OutputDirectory = (Join-Path $env:RUNNER_TEMP "win7-sccache-input-trace")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-TextHash([string] $Text) {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha256.Dispose()
  }
}

if ($CaptureEnvironment) {
  if ([string]::IsNullOrEmpty($Crate)) {
    throw "Crate is required during environment capture."
  }
  if ([string]::IsNullOrEmpty($env:DBX_SCCACHE_INPUT_ENV_DIR)) {
    throw "DBX_SCCACHE_INPUT_ENV_DIR is not set."
  }

  $cargoEnvironment = @(
    Get-ChildItem Env: |
      Where-Object {
        $_.Name.StartsWith("CARGO_", [System.StringComparison]::Ordinal) -and
        $_.Name -ne "CARGO_MAKEFLAGS" -and
        !$_.Name.StartsWith("CARGO_REGISTRIES_", [System.StringComparison]::Ordinal) -and
        $_.Name -ne "CARGO_BUILD_JOBS" -and
        $_.Name -ne "CARGO_ENCODED_RUSTFLAGS"
      } |
      Sort-Object Name |
      ForEach-Object {
        [pscustomobject]@{
          name = $_.Name
          value_sha256 = Get-TextHash ([string] $_.Value)
        }
      }
  )
  New-Item -ItemType Directory -Force -Path $env:DBX_SCCACHE_INPUT_ENV_DIR | Out-Null
  $record = [pscustomobject]@{
    crate = $Crate
    cargo_env = $cargoEnvironment
  }
  $recordPath = Join-Path $env:DBX_SCCACHE_INPUT_ENV_DIR "$Crate-$PID-$([guid]::NewGuid().ToString('N')).json"
  $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding utf8
  "[DBX-SCCACHE-INPUT] crate=$Crate captured_cargo_env=$($cargoEnvironment.Count)"
  exit 0
}

if (!(Test-Path -LiteralPath $env:SCCACHE_ERROR_LOG -PathType Leaf)) {
  throw "The sccache debug log does not exist."
}

$targetCrates = [System.Collections.Generic.HashSet[string]]::new(
  [string[]] @("dbx_lib", "psm"),
  [System.StringComparer]::Ordinal
)

function ConvertTo-NormalizedPath([string] $Path) {
  $normalized = [System.IO.Path]::GetFullPath($Path)
  if ($normalized.StartsWith("\\?\", [System.StringComparison]::Ordinal)) {
    $normalized = $normalized.Substring(4)
  }
  foreach ($replacement in @(
    @($env:GITHUB_WORKSPACE, "<workspace>"),
    @($env:RUNNER_TEMP, "<runner-temp>"),
    @($env:CARGO_HOME, "<cargo-home>"),
    @($env:RUSTUP_HOME, "<rustup-home>")
  )) {
    if (![string]::IsNullOrEmpty($replacement[0])) {
      $normalized = $normalized.Replace($replacement[0], $replacement[1])
    }
  }
  return $normalized.Replace("\", "/")
}

function Get-ArgumentValue([object[]] $Arguments, [string] $Name) {
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $value = [string] $Arguments[$index]
    if ($value -eq $Name -and $index + 1 -lt $Arguments.Count) {
      return [string] $Arguments[$index + 1]
    }
    if ($value.StartsWith("$Name=", [System.StringComparison]::Ordinal)) {
      return $value.Substring($Name.Length + 1)
    }
  }
  return $null
}

function Get-CodegenValue([object[]] $Arguments, [string] $Name) {
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $value = [string] $Arguments[$index]
    $codegen = $null
    if ($value -eq "-C" -and $index + 1 -lt $Arguments.Count) {
      $codegen = [string] $Arguments[$index + 1]
      $index++
    } elseif ($value.StartsWith("-C", [System.StringComparison]::Ordinal)) {
      $codegen = $value.Substring(2)
    }
    if ($null -ne $codegen -and $codegen.StartsWith("$Name=", [System.StringComparison]::Ordinal)) {
      return $codegen.Substring($Name.Length + 1)
    }
  }
  return $null
}

function Split-DepInfoPaths([string] $Line) {
  $separator = $Line.IndexOf(": ", [System.StringComparison]::Ordinal)
  if ($separator -lt 0) {
    return @()
  }
  $paths = [System.Collections.Generic.List[string]]::new()
  $current = [System.Text.StringBuilder]::new()
  $content = $Line.Substring($separator + 2)
  for ($index = 0; $index -lt $content.Length; $index++) {
    $character = $content[$index]
    if ($character -eq "\" -and $index + 1 -lt $content.Length -and $content[$index + 1] -eq " ") {
      [void] $current.Append(" ")
      $index++
    } elseif ($character -eq " ") {
      if ($current.Length -gt 0) {
        $paths.Add($current.ToString())
        [void] $current.Clear()
      }
    } else {
      [void] $current.Append($character)
    }
  }
  if ($current.Length -gt 0) {
    $paths.Add($current.ToString())
  }
  return @($paths)
}

function Resolve-InputPath([string] $Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $env:GITHUB_WORKSPACE $Path))
}

function Get-LinkInputs([object[]] $Arguments) {
  $linkPaths = [System.Collections.Generic.List[string]]::new()
  $libraryNames = [System.Collections.Generic.List[string]]::new()
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $value = [string] $Arguments[$index]
    $linkValue = $null
    $libraryValue = $null
    if ($value -eq "-L" -and $index + 1 -lt $Arguments.Count) {
      $linkValue = [string] $Arguments[++$index]
    } elseif ($value.StartsWith("-L", [System.StringComparison]::Ordinal)) {
      $linkValue = $value.Substring(2)
    } elseif ($value -eq "-l" -and $index + 1 -lt $Arguments.Count) {
      $libraryValue = [string] $Arguments[++$index]
    } elseif ($value.StartsWith("-l", [System.StringComparison]::Ordinal)) {
      $libraryValue = $value.Substring(2)
    }

    if ($null -ne $linkValue) {
      $parts = $linkValue.Split("=", 2)
      if ($parts.Count -eq 1 -or $parts[0] -in @("native", "all")) {
        $path = if ($parts.Count -eq 1) { $parts[0] } else { $parts[1] }
        $linkPaths.Add((Resolve-InputPath $path))
      }
    }
    if ($null -ne $libraryValue) {
      $parts = $libraryValue.Split("=", 2)
      if ($parts.Count -eq 2 -and $parts[0].StartsWith("static", [System.StringComparison]::Ordinal)) {
        $libraryNames.Add($parts[1])
      }
    }
  }
  return [pscustomobject]@{ paths = @($linkPaths); names = @($libraryNames) }
}

$escape = [char] 27
$ansiPattern = [regex]::Escape([string] $escape) + '\[[0-9;]*[A-Za-z]'
$argumentsByCrate = @{}
$keys = @{}
$results = @{}
foreach ($line in Get-Content -LiteralPath $env:SCCACHE_ERROR_LOG) {
  $plainLine = $line -replace $ansiPattern, ""
  if ($plainLine -match '\[(?<crate>[^\]]+)\]: get_cached_or_compile: (?<arguments>.+)$') {
    $crateName = $Matches.crate
    if ($targetCrates.Contains($crateName)) {
      try {
        $values = @($Matches.arguments | ConvertFrom-Json)
      } catch {
        continue
      }
      $argumentText = $values | ConvertTo-Json -Compress
      $argumentsByCrate["$crateName`0$(Get-TextHash $argumentText)"] = [pscustomobject]@{
        crate = $crateName
        values = $values
      }
    }
    continue
  }
  if ($plainLine -match '\[(?<crate>[^\]]+)\]: Hash key: (?<key>[0-9a-f]+)') {
    if ($targetCrates.Contains($Matches.crate)) {
      $keys[$Matches.crate] = $Matches.key
    }
    continue
  }
  if ($plainLine -match '\[(?<crate>[^\]]+)\]: Cache (?<result>hit|miss) in') {
    if ($targetCrates.Contains($Matches.crate)) {
      $results[$Matches.crate] = $Matches.result
    }
  }
}

$sources = @{}
$environmentDependencies = @{}
$staticLibraries = @{}
foreach ($argumentEntry in $argumentsByCrate.Values) {
  $crateName = $argumentEntry.crate
  $arguments = $argumentEntry.values
  $compilerOutputDirectory = Get-ArgumentValue $arguments "--out-dir"
  $compilerCrateName = Get-ArgumentValue $arguments "--crate-name"
  $extraFilename = Get-CodegenValue $arguments "extra-filename"
  if ($null -eq $extraFilename) {
    $extraFilename = ""
  }
  if (![string]::IsNullOrEmpty($compilerOutputDirectory) -and ![string]::IsNullOrEmpty($compilerCrateName)) {
    $depInfoPath = Join-Path (Resolve-InputPath $compilerOutputDirectory) "$compilerCrateName$extraFilename.d"
    if (Test-Path -LiteralPath $depInfoPath -PathType Leaf) {
      $depInfo = @(Get-Content -LiteralPath $depInfoPath)
      if ($depInfo.Count -gt 0) {
        foreach ($sourcePath in (Split-DepInfoPaths $depInfo[0])) {
          $resolvedSource = Resolve-InputPath $sourcePath
          if (Test-Path -LiteralPath $resolvedSource -PathType Leaf) {
            $normalizedSource = ConvertTo-NormalizedPath $resolvedSource
            $sources["$crateName`0$normalizedSource"] = [pscustomobject]@{
              crate = $crateName
              path = $normalizedSource
              sha256 = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash.ToLowerInvariant()
            }
          }
        }
      }
      foreach ($line in $depInfo) {
        if (!$line.StartsWith("# env-dep:", [System.StringComparison]::Ordinal)) {
          continue
        }
        $dependency = $line.Substring("# env-dep:".Length)
        $parts = $dependency.Split("=", 2)
        $name = $parts[0]
        $value = if ($parts.Count -eq 2) { $parts[1] } else { "" }
        $valueHash = Get-TextHash $value
        $environmentDependencies["$crateName`0$name`0$valueHash"] = [pscustomobject]@{
          crate = $crateName
          name = $name
          value_sha256 = $valueHash
        }
      }
    } else {
      Write-Warning "Missing dep-info for $crateName at $(ConvertTo-NormalizedPath $depInfoPath)"
    }
  }

  $linkInputs = Get-LinkInputs $arguments
  foreach ($libraryName in $linkInputs.names) {
    foreach ($linkPath in $linkInputs.paths) {
      $libraryPath = @(
        (Join-Path $linkPath "lib$libraryName.a"),
        (Join-Path $linkPath "$libraryName.lib"),
        (Join-Path $linkPath "$libraryName.a")
      ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
      if ($null -ne $libraryPath) {
        $normalizedLibrary = ConvertTo-NormalizedPath $libraryPath
        $staticLibraries["$crateName`0$normalizedLibrary"] = [pscustomobject]@{
          crate = $crateName
          path = $normalizedLibrary
          sha256 = (Get-FileHash -LiteralPath $libraryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        break
      }
    }
  }
}

# psm always builds psm_s in its Cargo build output. Keep this focused fallback
# because Cargo can omit native link flags from the logged rustc argument form.
$psmBuildRoot = Join-Path $env:GITHUB_WORKSPACE "target/x86_64-win7-windows-msvc/release/build"
if (Test-Path -LiteralPath $psmBuildRoot -PathType Container) {
  foreach ($libraryPath in Get-ChildItem -LiteralPath $psmBuildRoot -Recurse -File -Include "psm_s.lib", "libpsm_s.a", "psm_s.a") {
    if ($libraryPath.FullName -notmatch '[\\/]psm-[^\\/]+[\\/]out[\\/]') {
      continue
    }
    $normalizedLibrary = ConvertTo-NormalizedPath $libraryPath.FullName
    $staticLibraries["psm`0$normalizedLibrary"] = [pscustomobject]@{
      crate = "psm"
      path = $normalizedLibrary
      sha256 = (Get-FileHash -LiteralPath $libraryPath.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
}

$cargoEnvironment = @{}
if (Test-Path -LiteralPath $env:DBX_SCCACHE_INPUT_ENV_DIR -PathType Container) {
  foreach ($recordFile in Get-ChildItem -LiteralPath $env:DBX_SCCACHE_INPUT_ENV_DIR -File -Filter "*.json") {
    $record = Get-Content -LiteralPath $recordFile.FullName -Raw | ConvertFrom-Json
    foreach ($variable in $record.cargo_env) {
      $cargoEnvironment["$($record.crate)`0$($variable.name)`0$($variable.value_sha256)"] = [pscustomobject]@{
        crate = $record.crate
        name = $variable.name
        value_sha256 = $variable.value_sha256
      }
    }
  }
}

$sourceEntries = @($sources.Values | Sort-Object crate, path)
$environmentDependencyEntries = @($environmentDependencies.Values | Sort-Object crate, name, value_sha256)
$cargoEnvironmentEntries = @($cargoEnvironment.Values | Sort-Object crate, name, value_sha256)
$staticLibraryEntries = @($staticLibraries.Values | Sort-Object crate, path)
foreach ($entry in $sourceEntries) {
  "[DBX-SCCACHE-INPUT] crate=$($entry.crate) source=$($entry.path) sha256=$($entry.sha256)"
}
foreach ($entry in $environmentDependencyEntries) {
  "[DBX-SCCACHE-INPUT] crate=$($entry.crate) env_dep=$($entry.name) value_sha256=$($entry.value_sha256)"
}
foreach ($entry in $cargoEnvironmentEntries) {
  "[DBX-SCCACHE-INPUT] crate=$($entry.crate) cargo_env=$($entry.name) value_sha256=$($entry.value_sha256)"
}
foreach ($entry in $staticLibraryEntries) {
  "[DBX-SCCACHE-INPUT] crate=$($entry.crate) staticlib=$($entry.path) sha256=$($entry.sha256)"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$tracePath = Join-Path $OutputDirectory "win7-sccache-input-trace.json"
[pscustomobject]@{
  runner = [pscustomobject]@{ image_os = $env:ImageOS; image_version = $env:ImageVersion }
  keys = $keys
  results = $results
  sources = $sourceEntries
  env_deps = $environmentDependencyEntries
  cargo_env = $cargoEnvironmentEntries
  staticlibs = $staticLibraryEntries
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tracePath -Encoding utf8

"[DBX-SCCACHE-INPUT] sources=$($sourceEntries.Count) env_deps=$($environmentDependencyEntries.Count) cargo_env=$($cargoEnvironmentEntries.Count) staticlibs=$($staticLibraryEntries.Count) path=$tracePath"
