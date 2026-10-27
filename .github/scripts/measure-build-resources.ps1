[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$Label,
  # The build command to observe. The sampler never changes environment or flags.
  [scriptblock]$Invoke,
  # Recompute summary.json from samples.csv and processes.csv. No build, no sampling.
  [switch]$SummarizeOnly,
  [int]$IntervalSeconds = 3,
  [string[]]$ProcessNames = @("cargo", "rustc", "link", "sccache", "cl", "cc1plus")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$invariant = [System.Globalization.CultureInfo]::InvariantCulture

if (-not $SummarizeOnly -and $null -eq $Invoke) {
  throw "-Invoke is required unless -SummarizeOnly is set."
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$samplesPath = Join-Path $OutputDirectory "samples.csv"
$processesPath = Join-Path $OutputDirectory "processes.csv"
$summaryPath = Join-Path $OutputDirectory "summary.json"
$metaPath = Join-Path $OutputDirectory "meta.json"
$stopFile = Join-Path $OutputDirectory "sampler-stop"

$buildExitCode = 0
$buildError = $null
$buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$samplerWarning = $null

if (-not $SummarizeOnly) {
  Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue

  # Record the sampling environment. A later -SummarizeOnly run reuses these
  # values so the summary describes the machine that produced the samples.
  [ordered]@{
    label = $Label
    cores = [Environment]::ProcessorCount
    intervalSeconds = $IntervalSeconds
    processNames = $ProcessNames
    startedAt = [DateTime]::UtcNow.ToString("o", $invariant)
  } | ConvertTo-Json | Set-Content -LiteralPath $metaPath -Encoding utf8NoBOM

  $sampler = Start-Job -ArgumentList $IntervalSeconds, $ProcessNames, $samplesPath, $processesPath, $stopFile -ScriptBlock {
    param([int]$IntervalSeconds, [string[]]$ProcessNames, [string]$SamplesPath, [string]$ProcessesPath, [string]$StopFile)

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    function Format-Number([double]$Value) { return $Value.ToString("0.###", $invariant) }

    # Read one formatted counter value from a CIM class. A singleton class has no
    # Name property, so an empty -Name skips the instance filter. A missing
    # counter yields $null and never stops the sample loop.
    function Get-PerformanceValue {
      param([object[]]$Rows, [string]$Name, [string]$Property)

      foreach ($row in $Rows) {
        if ($null -eq $row) { continue }
        if ($Name) {
          $nameProperty = $row.PSObject.Properties["Name"]
          if ($null -eq $nameProperty -or $nameProperty.Value -ne $Name) { continue }
        }
        $valueProperty = $row.PSObject.Properties[$Property]
        if ($null -ne $valueProperty -and $null -ne $valueProperty.Value) { return [double]$valueProperty.Value }
      }
      return $null
    }

    function Format-Cell($Value) {
      if ($null -eq $Value) { return "" }
      return Format-Number ([double]$Value)
    }

    $samples = [System.IO.StreamWriter]::new($SamplesPath, $false, [System.Text.UTF8Encoding]::new($false))
    $processRows = [System.IO.StreamWriter]::new($ProcessesPath, $false, [System.Text.UTF8Encoding]::new($false))
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $cpuByInstance = @{}

    try {
      $samples.WriteLine("Timestamp,ElapsedSeconds,CpuPercent,ProcessorQueueLength,AvailableMB,CommittedMB,PagingFilePercent,DiskReadBytesPerSecond,DiskWriteBytesPerSecond")
      $processRows.WriteLine("Timestamp,ElapsedSeconds,ProcessName,Count,CpuSecondsDelta,TotalCpuSeconds,PeakWorkingSetMB,WorkingSetMB")
      $samples.Flush()
      $processRows.Flush()

      while (-not (Test-Path -LiteralPath $StopFile)) {
        $cycle = [System.Diagnostics.Stopwatch]::StartNew()
        $timestamp = [DateTime]::UtcNow.ToString("o", $invariant)
        $elapsed = $stopwatch.Elapsed.TotalSeconds

        $cpu = $null
        $queue = $null
        $availableMB = $null
        $committedMB = $null
        $pagingPercent = $null
        $diskRead = $null
        $diskWrite = $null
        try {
          $processor = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop)
          $cpu = Get-PerformanceValue -Rows $processor -Name "_Total" -Property "PercentProcessorTime"
        } catch { }
        try {
          $system = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction Stop)
          $queue = Get-PerformanceValue -Rows $system -Name "" -Property "ProcessorQueueLength"
        } catch { }
        try {
          $memory = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop)
          $availableMB = Get-PerformanceValue -Rows $memory -Name "" -Property "AvailableMBytes"
          $committed = Get-PerformanceValue -Rows $memory -Name "" -Property "CommittedBytes"
          if ($null -ne $committed) { $committedMB = $committed / 1MB }
        } catch { }
        try {
          $paging = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_PagingFile -ErrorAction Stop)
          $pagingPercent = Get-PerformanceValue -Rows $paging -Name "_Total" -Property "PercentUsage"
        } catch { }
        try {
          $disk = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop)
          $diskRead = Get-PerformanceValue -Rows $disk -Name "_Total" -Property "DiskReadBytesPerSec"
          $diskWrite = Get-PerformanceValue -Rows $disk -Name "_Total" -Property "DiskWriteBytesPerSec"
        } catch { }

        $samples.WriteLine(
          "$timestamp,$(Format-Number $elapsed),$(Format-Cell $cpu),$(Format-Cell $queue),$(Format-Cell $availableMB),$(Format-Cell $committedMB),$(Format-Cell $pagingPercent),$(Format-Cell $diskRead),$(Format-Cell $diskWrite)"
        )

        foreach ($name in $ProcessNames) {
          $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
          if ($processes.Count -eq 0) { continue }

          $cpuDelta = 0.0
          $cpuTotal = 0.0
          $peakWorkingSet = 0.0
          $workingSet = 0.0
          foreach ($process in $processes) {
            try {
              $currentCpu = [double]$process.CPU
            } catch {
              continue
            }
            # A PID can be reused. Pair it with the start time so a new process
            # never inherits the CPU total of the previous owner.
            $instance = "$($process.Id)"
            try { $instance = "$($process.Id):$($process.StartTime.ToUniversalTime().Ticks)" } catch { }
            $previousCpu = 0.0
            if ($cpuByInstance.ContainsKey($instance)) { $previousCpu = [double]$cpuByInstance[$instance] }
            $cpuDelta += [Math]::Max(0.0, $currentCpu - $previousCpu)
            $cpuByInstance[$instance] = $currentCpu
            $cpuTotal += $currentCpu
            $peakWorkingSet = [Math]::Max($peakWorkingSet, [double]$process.PeakWorkingSet64)
            $workingSet += [double]$process.WorkingSet64
          }

          $processRows.WriteLine(
            "$timestamp,$(Format-Number $elapsed),$name,$($processes.Count),$(Format-Number $cpuDelta),$(Format-Number $cpuTotal),$(Format-Number ($peakWorkingSet / 1MB)),$(Format-Number ($workingSet / 1MB))"
          )
        }

        $samples.Flush()
        $processRows.Flush()
        $remaining = $IntervalSeconds - $cycle.Elapsed.TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining * 1000)) }
      }
    } finally {
      $samples.Dispose()
      $processRows.Dispose()
    }
  }

  # A process can exit before the final sample, so counters can under-read by one
  # interval. The build exit code still decides the step result.
  try {
    $global:LASTEXITCODE = 0
    & $Invoke
    if ($null -ne $LASTEXITCODE) { $buildExitCode = $LASTEXITCODE }
  } catch {
    $buildError = $_
  } finally {
    $buildStopwatch.Stop()
    New-Item -ItemType File -Path $stopFile -Force | Out-Null
    Wait-Job -Job $sampler -Timeout 180 | Out-Null

    # A sampler that dies silently would publish empty or partial data. Read the
    # job streams and surface the first error instead.
    $samplerOutput = @(Receive-Job -Job $sampler -ErrorAction SilentlyContinue 2>&1)
    $samplerErrors = @($samplerOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    if ($sampler.State -ne "Completed") {
      $samplerWarning = "sampler did not stop in time (state $($sampler.State))"
    } elseif ($samplerErrors.Count -gt 0) {
      $samplerWarning = $samplerErrors[0].ToString()
    }

    if ($sampler.State -ne "Completed") { Stop-Job -Job $sampler -ErrorAction SilentlyContinue }
    Remove-Job -Job $sampler -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
  }
}

$wallSeconds = $buildStopwatch.Elapsed.TotalSeconds
$sampleRows = @()
if (Test-Path -LiteralPath $samplesPath) { $sampleRows = @(Import-Csv -LiteralPath $samplesPath) }
$observedProcesses = @()
if (Test-Path -LiteralPath $processesPath) { $observedProcesses = @(Import-Csv -LiteralPath $processesPath) }

$cores = [Environment]::ProcessorCount
if (Test-Path -LiteralPath $metaPath) {
  try {
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    if ($null -ne $meta.PSObject.Properties["cores"] -and $meta.cores) { $cores = [int]$meta.cores }
  } catch { }
}

if ($sampleRows.Count -gt 0) {
  $lastElapsed = [double]::Parse($sampleRows[-1].ElapsedSeconds, $invariant)
  # SummarizeOnly has no build stopwatch. The last sample marks the observed end.
  if ($SummarizeOnly) { $wallSeconds = $lastElapsed }
}

function ConvertTo-Numbers {
  param([object[]]$Rows, [string]$Property)
  $values = @()
  foreach ($row in $Rows) {
    $raw = $row.$Property
    if ($null -ne $raw -and $raw -ne "") { $values += [double]::Parse($raw, $invariant) }
  }
  return $values
}

function Get-Percentile {
  param([double[]]$Values = @(), [double]$Percentile = 50)
  if ($Values.Count -eq 0) { return $null }
  $sorted = @($Values | Sort-Object)
  $index = [Math]::Min($sorted.Count - 1, [Math]::Max(0, [int][Math]::Round(($Percentile / 100) * ($sorted.Count - 1))))
  return $sorted[$index]
}

$cpuValues = @(ConvertTo-Numbers -Rows $sampleRows -Property "CpuPercent")
$interval = [double]$IntervalSeconds
if ($sampleRows.Count -gt 1) {
  $firstElapsed = [double]::Parse($sampleRows[0].ElapsedSeconds, $invariant)
  $lastElapsed = [double]::Parse($sampleRows[-1].ElapsedSeconds, $invariant)
  $interval = [Math]::Max(0.5, ($lastElapsed - $firstElapsed) / ($sampleRows.Count - 1))
}
$above80 = @($cpuValues | Where-Object { $_ -ge 80 }).Count * $interval
$below50 = @($cpuValues | Where-Object { $_ -le 50 }).Count * $interval
$availableValues = @(ConvertTo-Numbers -Rows $sampleRows -Property "AvailableMB")
$committedValues = @(ConvertTo-Numbers -Rows $sampleRows -Property "CommittedMB")
$pagingValues = @(ConvertTo-Numbers -Rows $sampleRows -Property "PagingFilePercent")
$queueValues = @(ConvertTo-Numbers -Rows $sampleRows -Property "ProcessorQueueLength")
$diskReadValues = @(ConvertTo-Numbers -Rows $sampleRows -Property "DiskReadBytesPerSecond")
$diskWriteValues = @(ConvertTo-Numbers -Rows $sampleRows -Property "DiskWriteBytesPerSecond")

$processSummary = @()
foreach ($name in $ProcessNames) {
  $rows = @($observedProcesses | Where-Object { $_.ProcessName -eq $name })
  if ($rows.Count -eq 0) { continue }
  $cpuSeconds = 0.0
  $peakWorkingSet = 0.0
  $maxConcurrent = 0
  foreach ($row in $rows) {
    # CpuSecondsDelta is the CPU time added between two samples. TotalCpuSeconds
    # is cumulative, so summing it across rows would count earlier time again.
    $cpuSeconds += [double]::Parse($row.CpuSecondsDelta, $invariant)
    $peakWorkingSet = [Math]::Max($peakWorkingSet, [double]::Parse($row.PeakWorkingSetMB, $invariant))
    $maxConcurrent = [Math]::Max($maxConcurrent, [int]$row.Count)
  }
  $processSummary += [ordered]@{
    name = $name
    cpuSecondsEstimated = [Math]::Round($cpuSeconds, 1)
    meanCores = if ($wallSeconds -gt 0) { [Math]::Round($cpuSeconds / $wallSeconds, 3) } else { 0 }
    peakWorkingSetMB = [Math]::Round($peakWorkingSet, 1)
    maxConcurrent = $maxConcurrent
    samplesWithProcess = $rows.Count
  }
}

$summary = [ordered]@{
  label = $Label
  wallSeconds = [Math]::Round($wallSeconds, 1)
  cores = $cores
  sampleIntervalSeconds = [Math]::Round($interval, 2)
  sampleCount = $sampleRows.Count
  # CPU seconds are sampled estimates. A process that starts and ends between
  # two samples under-reports, so compare processes instead of exact totals.
  cpuPercent = [ordered]@{
    mean = if ($cpuValues.Count -gt 0) { [Math]::Round(($cpuValues | Measure-Object -Average).Average, 1) } else { $null }
    median = Get-Percentile -Values $cpuValues -Percentile 50
    p95 = Get-Percentile -Values $cpuValues -Percentile 95
    max = if ($cpuValues.Count -gt 0) { [Math]::Round(($cpuValues | Measure-Object -Maximum).Maximum, 1) } else { $null }
    secondsAtOrAbove80 = [Math]::Round($above80, 1)
    secondsAtOrBelow50 = [Math]::Round($below50, 1)
  }
  processorQueueLength = [ordered]@{
    mean = if ($queueValues.Count -gt 0) { [Math]::Round(($queueValues | Measure-Object -Average).Average, 2) } else { $null }
    p95 = Get-Percentile -Values $queueValues -Percentile 95
    max = if ($queueValues.Count -gt 0) { [Math]::Round(($queueValues | Measure-Object -Maximum).Maximum, 1) } else { $null }
  }
  memory = [ordered]@{
    availableMBMin = if ($availableValues.Count -gt 0) { [Math]::Round(($availableValues | Measure-Object -Minimum).Minimum, 1) } else { $null }
    committedMBMax = if ($committedValues.Count -gt 0) { [Math]::Round(($committedValues | Measure-Object -Maximum).Maximum, 1) } else { $null }
    pagingFilePercentMax = if ($pagingValues.Count -gt 0) { [Math]::Round(($pagingValues | Measure-Object -Maximum).Maximum, 1) } else { $null }
  }
  disk = [ordered]@{
    readMB = [Math]::Round((($diskReadValues | Measure-Object -Sum).Sum * $interval) / 1MB, 1)
    writeMB = [Math]::Round((($diskWriteValues | Measure-Object -Sum).Sum * $interval) / 1MB, 1)
    readBytesPerSecondMean = if ($diskReadValues.Count -gt 0) { [Math]::Round(($diskReadValues | Measure-Object -Average).Average, 0) } else { $null }
    writeBytesPerSecondMean = if ($diskWriteValues.Count -gt 0) { [Math]::Round(($diskWriteValues | Measure-Object -Average).Average, 0) } else { $null }
  }
  processes = $processSummary
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM

if ($samplerWarning) { Write-Warning "Build resource sampling failed: $samplerWarning" }
if ($sampleRows.Count -eq 0) { Write-Warning "Build resource sampling produced no samples." }

$markdown = @(
  "### Build resources: $Label",
  "",
  "- Wall time: $([Math]::Round($wallSeconds / 60, 1)) min; $($sampleRows.Count) samples every $([Math]::Round($interval, 1)) s on $($summary.cores) logical cores",
  "- CPU: mean $($summary.cpuPercent.mean)%, median $($summary.cpuPercent.median)%, p95 $($summary.cpuPercent.p95)%, max $($summary.cpuPercent.max)%; $([Math]::Round($above80 / 60, 1)) min at or above 80%, $([Math]::Round($below50 / 60, 1)) min at or below 50%",
  "- Processor queue: mean $($summary.processorQueueLength.mean), p95 $($summary.processorQueueLength.p95), max $($summary.processorQueueLength.max)",
  "- Memory: available min $($summary.memory.availableMBMin) MB; committed max $($summary.memory.committedMBMax) MB; paging file max $($summary.memory.pagingFilePercentMax)%",
  "- Disk: read $($summary.disk.readMB) MB ($($summary.disk.readBytesPerSecondMean) B/s mean), write $($summary.disk.writeMB) MB ($($summary.disk.writeBytesPerSecondMean) B/s mean)"
)
foreach ($process in $processSummary) {
  $markdown += "- $($process.name): $($process.cpuSecondsEstimated) CPU-seconds (sampled estimate, mean $($process.meanCores) cores), peak RSS $($process.peakWorkingSetMB) MB, up to $($process.maxConcurrent) concurrent"
}
$markdown += ""
$markdownText = $markdown -join "`n"
if ($env:GITHUB_STEP_SUMMARY) { $markdownText | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8NoBOM }
Write-Output $markdownText

if ($null -ne $buildError) { throw $buildError }
exit $buildExitCode
