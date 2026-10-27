Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script = Join-Path $PSScriptRoot "measure-build-resources.ps1"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("build-resource-summary-test-" + [guid]::NewGuid().ToString("N"))

function Assert-Value {
  param($Actual, $Expected, [string]$Name)

  if ($Actual -ne $Expected) {
    throw "$Name expected $Expected but was $Actual"
  }
}

function Assert-Close {
  param([double]$Actual, [double]$Expected, [string]$Name)

  if ([Math]::Abs($Actual - $Expected) -gt 0.001) {
    throw "$Name expected $Expected but was $Actual"
  }
}

New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  @"
Timestamp,ElapsedSeconds,CpuPercent,ProcessorQueueLength,AvailableMB,CommittedMB,PagingFilePercent,DiskReadBytesPerSecond,DiskWriteBytesPerSecond
2026-01-01T00:00:00.000Z,0,90,1,4000,12000,5,1048576,2097152
2026-01-01T00:00:03.000Z,3,95,2,3000,12000,5,1048576,2097152
2026-01-01T00:00:06.000Z,6,10,3,2000,12000,5,1048576,2097152
"@ | Set-Content -LiteralPath (Join-Path $work "samples.csv") -Encoding utf8NoBOM

  # TotalCpuSeconds repeats the cumulative CPU time of the process. Only the
  # deltas add up to the real total: 10 + 10 + 10 = 30, not 10 + 20 + 30 = 60.
  @"
Timestamp,ElapsedSeconds,ProcessName,Count,CpuSecondsDelta,TotalCpuSeconds,PeakWorkingSetMB,WorkingSetMB
2026-01-01T00:00:00.000Z,0,rustc,2,10,10,512,800
2026-01-01T00:00:03.000Z,3,rustc,4,10,20,2048,2400
2026-01-01T00:00:06.000Z,6,rustc,1,10,30,1024,900
"@ | Set-Content -LiteralPath (Join-Path $work "processes.csv") -Encoding utf8NoBOM

  # -SummarizeOnly must describe the machine that produced the samples, not the
  # machine that recomputes the summary.
  '{"label":"summary-fixture","cores":4,"intervalSeconds":3,"processNames":["rustc"]}' |
    Set-Content -LiteralPath (Join-Path $work "meta.json") -Encoding utf8NoBOM

  $null = & $script -Label "summary-fixture" -OutputDirectory $work -SummarizeOnly
  if ($LASTEXITCODE -ne 0) { throw "summarize-only run failed with exit code $LASTEXITCODE" }

  $summary = Get-Content -LiteralPath (Join-Path $work "summary.json") -Raw | ConvertFrom-Json

  Assert-Value $summary.label "summary-fixture" "label"
  Assert-Value $summary.cores 4 "cores"
  Assert-Close $summary.wallSeconds 6 "wallSeconds"
  Assert-Close $summary.sampleIntervalSeconds 3 "sampleIntervalSeconds"
  Assert-Value $summary.sampleCount 3 "sampleCount"
  Assert-Close $summary.cpuPercent.mean 65 "cpuPercent.mean"
  Assert-Close $summary.cpuPercent.median 90 "cpuPercent.median"
  Assert-Close $summary.cpuPercent.p95 95 "cpuPercent.p95"
  Assert-Close $summary.cpuPercent.secondsAtOrAbove80 6 "secondsAtOrAbove80"
  Assert-Close $summary.cpuPercent.secondsAtOrBelow50 3 "secondsAtOrBelow50"
  Assert-Close $summary.processorQueueLength.mean 2 "processorQueueLength.mean"
  Assert-Close $summary.processorQueueLength.max 3 "processorQueueLength.max"
  Assert-Close $summary.memory.availableMBMin 2000 "memory.availableMBMin"
  Assert-Close $summary.memory.committedMBMax 12000 "memory.committedMBMax"
  Assert-Close $summary.memory.pagingFilePercentMax 5 "memory.pagingFilePercentMax"
  Assert-Close $summary.disk.readMB 9 "disk.readMB"
  Assert-Close $summary.disk.writeMB 18 "disk.writeMB"

  Assert-Value $summary.processes.Count 1 "processes.Count"
  $rustc = $summary.processes[0]
  Assert-Value $rustc.name "rustc" "processes[0].name"
  Assert-Close $rustc.cpuSecondsEstimated 30 "processes[0].cpuSecondsEstimated"
  Assert-Close $rustc.meanCores 5 "processes[0].meanCores"
  Assert-Close $rustc.peakWorkingSetMB 2048 "processes[0].peakWorkingSetMB"
  Assert-Value $rustc.maxConcurrent 4 "processes[0].maxConcurrent"
  Assert-Value $rustc.samplesWithProcess 3 "processes[0].samplesWithProcess"

  $missingWork = Join-Path $work "no-samples"
  New-Item -ItemType Directory -Force -Path $missingWork | Out-Null
  $warning = $null
  $null = & $script -Label "no-samples" -OutputDirectory $missingWork -SummarizeOnly -WarningVariable warning
  if ($LASTEXITCODE -ne 0) { throw "empty summarize-only run failed with exit code $LASTEXITCODE" }
  if ($warning.Count -eq 0) { throw "an empty sample set must write a warning" }
  $emptySummary = Get-Content -LiteralPath (Join-Path $missingWork "summary.json") -Raw | ConvertFrom-Json
  Assert-Value $emptySummary.sampleCount 0 "empty sampleCount"
  Assert-Value $emptySummary.processes.Count 0 "empty processes.Count"

  $rejected = $false
  try {
    $null = & $script -Label "no-invoke" -OutputDirectory (Join-Path $work "no-invoke")
  } catch {
    $rejected = $_.Exception.Message -match "Invoke is required"
  }
  if (-not $rejected) { throw "a run without -Invoke and without -SummarizeOnly must fail" }

  Write-Output "build resource summary tests passed"
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
