$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-TotalCount($counts) {
  if ($null -eq $counts) {
    return [long] 0
  }

  $sum = [long] 0
  foreach ($property in $counts.PSObject.Properties) {
    $sum += [long] $property.Value
  }
  return $sum
}

function Get-SccacheStats {
  $json = sccache --show-stats --stats-format json | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "sccache failed to return JSON statistics."
  }

  $info = $json | ConvertFrom-Json
  return [pscustomobject]@{
    Hits = Get-TotalCount $info.stats.cache_hits.counts
    Misses = Get-TotalCount $info.stats.cache_misses.counts
    Writes = [long] $info.stats.cache_writes
    WriteErrors = [long] $info.stats.cache_write_errors
  }
}

$before = Get-SccacheStats

cargo clean --package dbx-core --package dbx-mcp --package dbx --release --target x86_64-win7-windows-msvc
if ($LASTEXITCODE -ne 0) {
  throw "Cargo failed to clean the Win7 heavy packages."
}

$env:TAURI_CONFIG = Get-Content src-tauri/tauri.webview2-win7-fixed.conf.json -Raw
$timer = [System.Diagnostics.Stopwatch]::StartNew()
cargo build --locked --package dbx --release --features custom-protocol --target x86_64-win7-windows-msvc -Z build-std=std,panic_abort --timings
$timer.Stop()
if ($LASTEXITCODE -ne 0) {
  throw "The same-job Win7 rebuild failed."
}

$after = Get-SccacheStats
$hits = $after.Hits - $before.Hits
$misses = $after.Misses - $before.Misses
$writes = $after.Writes - $before.Writes
$writeErrors = $after.WriteErrors - $before.WriteErrors
$seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)

"[WIN7-SCCACHE-REBUILD] seconds=$seconds hits=$hits misses=$misses writes=$writes write_errors=$writeErrors"
"## Win7 same-job heavy package rebuild" >> $env:GITHUB_STEP_SUMMARY
"" >> $env:GITHUB_STEP_SUMMARY
"| Seconds | Hits | Misses | Writes | Write errors |" >> $env:GITHUB_STEP_SUMMARY
"| ---: | ---: | ---: | ---: | ---: |" >> $env:GITHUB_STEP_SUMMARY
"| $seconds | $hits | $misses | $writes | $writeErrors |" >> $env:GITHUB_STEP_SUMMARY
