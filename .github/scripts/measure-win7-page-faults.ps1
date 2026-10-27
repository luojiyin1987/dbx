param([Parameter(Mandatory = $true)][string]$OutputPath)

$ErrorActionPreference = 'Stop'
$counters = @(
  '\Memory\Page Reads/sec',
  '\Memory\Pages Input/sec',
  '\Memory\Available MBytes',
  '\Processor(_Total)\% Processor Time'
)
$writer = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$writer.WriteLine('timestampUtc,pageReadsPerSec,pagesInputPerSec,availableMBytes,cpuPercent')

try {
  Get-Counter -Counter $counters -SampleInterval 3 -MaxSamples 14400 -ErrorAction Stop | ForEach-Object {
    $values = @{}
    foreach ($counter in $_.CounterSamples) {
      $name = $counter.Path.Split('\')[-1]
      $values[$name] = $counter.CookedValue.ToString('G17', [cultureinfo]::InvariantCulture)
    }
    $timestamp = $_.Timestamp.ToUniversalTime().ToString('o')
    $row = @($timestamp, $values['Page Reads/sec'], $values['Pages Input/sec'],
      $values['Available MBytes'], $values['% Processor Time'])
    $writer.WriteLine(($row -join ','))
  }
} finally {
  $writer.Dispose()
}
