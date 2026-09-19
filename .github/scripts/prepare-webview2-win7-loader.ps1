[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# WebView2 static loaders newer than SDK 1.0.1054 import EventSetInformation, which does
# not exist on Windows 7, while 1.0.1054.31 itself fails on Server 2012 R2 with
# ERROR_NOT_SUPPORTED (0x80070032, MicrosoftEdge/WebView2Feedback#2025). SDK 1.0.902.49 is
# the loader verified on both Windows 7 SP1 and Server 2012 R2 real machines, so the single
# win7 + server 2012 r2 offline bundle links it instead of the webview2-com-sys default.
$sdkVersion = "1.0.902.49"
$sdkPackageSha256 = "b483c906b03690267108f4304d456eac0e718131ef994e69aaa5a21532b512c6"
$loaderSha256 = "aa5c26670f1b18d0fa2a56ac3f1ae30110c332a8bfbd555a7be3e548d1b0da3d"
$loaderDllSha256 = "fdf978ba706578b05967d7f0181f462147864a5aa74f36016a62cb3d3dbe6909"
$webView2ComSysVersion = "0.38.2"
$webView2ComSysSha256 = "381336cfffd772377d291702245447a5251a2ffa5bad679c99e61bc48bacbf9c"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dbx-win7-webview2-loader-$([Guid]::NewGuid())"
$sdkPackagePath = Join-Path $temporaryRoot "Microsoft.Web.WebView2.$sdkVersion.nupkg"
$sdkExtractedPath = Join-Path $temporaryRoot "sdk"
$crateArchivePath = Join-Path $temporaryRoot "webview2-com-sys-$webView2ComSysVersion.crate"
$crateExtractedPath = Join-Path $temporaryRoot "crate"
$generatedRoot = Join-Path $repositoryRoot "target/ci-inputs/webview2-com-sys-$webView2ComSysVersion-win7"

try {
  New-Item -ItemType Directory -Path $sdkExtractedPath -Force | Out-Null
  New-Item -ItemType Directory -Path $crateExtractedPath -Force | Out-Null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $packageUrl = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$sdkVersion"
  Write-Host "Downloading WebView2 SDK $sdkVersion for the Windows 7 / Server 2012 R2 loader..."
  Invoke-WebRequest -Uri $packageUrl -OutFile $sdkPackagePath -UseBasicParsing

  $actualPackageSha256 = (Get-FileHash -LiteralPath $sdkPackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualPackageSha256 -ne $sdkPackageSha256) {
    throw "Unexpected WebView2 SDK package SHA256: $actualPackageSha256"
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($sdkPackagePath, $sdkExtractedPath)

  $legacyLoader = Join-Path $sdkExtractedPath "build/native/x64/WebView2LoaderStatic.lib"
  if (!(Test-Path -LiteralPath $legacyLoader -PathType Leaf)) {
    throw "WebView2 SDK $sdkVersion does not contain the x64 static loader."
  }

  $legacyLoaderDll = Join-Path $sdkExtractedPath "build/native/x64/WebView2Loader.dll"
  if (!(Test-Path -LiteralPath $legacyLoaderDll -PathType Leaf)) {
    throw "WebView2 SDK $sdkVersion does not contain the x64 loader DLL."
  }

  $actualLoaderSha256 = (Get-FileHash -LiteralPath $legacyLoader -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualLoaderSha256 -ne $loaderSha256) {
    throw "Unexpected Windows 7 / Server 2012 R2 WebView2 loader SHA256: $actualLoaderSha256"
  }

  $actualLoaderDllSha256 = (Get-FileHash -LiteralPath $legacyLoaderDll -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualLoaderDllSha256 -ne $loaderDllSha256) {
    throw "Unexpected Windows 7 / Server 2012 R2 WebView2 loader DLL SHA256: $actualLoaderDllSha256"
  }

  $crateUrl = "https://static.crates.io/crates/webview2-com-sys/webview2-com-sys-$webView2ComSysVersion.crate"
  Write-Host "Downloading webview2-com-sys $webView2ComSysVersion..."
  Invoke-WebRequest -Uri $crateUrl -OutFile $crateArchivePath -UseBasicParsing

  $actualCrateSha256 = (Get-FileHash -LiteralPath $crateArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualCrateSha256 -ne $webView2ComSysSha256) {
    throw "Unexpected webview2-com-sys crate SHA256: $actualCrateSha256"
  }

  & tar.exe -xzf $crateArchivePath -C $crateExtractedPath
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract webview2-com-sys $webView2ComSysVersion."
  }

  $extractedCrateRoot = Join-Path $crateExtractedPath "webview2-com-sys-$webView2ComSysVersion"
  if (!(Test-Path -LiteralPath (Join-Path $extractedCrateRoot "Cargo.toml") -PathType Leaf)) {
    throw "The webview2-com-sys crate archive has an unexpected layout."
  }

  if (Test-Path -LiteralPath $generatedRoot) {
    Remove-Item -LiteralPath $generatedRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $generatedRoot) -Force | Out-Null
  Move-Item -LiteralPath $extractedCrateRoot -Destination $generatedRoot

  $loaderDestination = Join-Path $generatedRoot "x64/WebView2LoaderStatic.lib"
  if (!(Test-Path -LiteralPath $loaderDestination -PathType Leaf)) {
    throw "webview2-com-sys static loader does not exist: $loaderDestination"
  }

  Copy-Item -LiteralPath $legacyLoader -Destination $loaderDestination -Force

  $installedLoaderSha256 = (Get-FileHash -LiteralPath $loaderDestination -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($installedLoaderSha256 -ne $loaderSha256) {
    throw "Windows 7 WebView2 loader replacement failed: $installedLoaderSha256"
  }

  $cargoConfigPath = Join-Path $repositoryRoot ".cargo/config.toml"
  $cargoConfig = Get-Content -LiteralPath $cargoConfigPath -Raw
  $patchStart = "# DBX_WIN7_WEBVIEW2_PATCH_START"
  $patchEnd = "# DBX_WIN7_WEBVIEW2_PATCH_END"
  $patchPattern = "(?ms)\r?\n?" + [regex]::Escape($patchStart) + ".*?" + [regex]::Escape($patchEnd) + "\r?\n?"
  $cargoConfig = [regex]::Replace($cargoConfig, $patchPattern, "`n")
  $tomlCratePath = $generatedRoot.Replace("\", "/")
  $patchConfig = @"
$patchStart
[patch.crates-io]
webview2-com-sys = { path = '$tomlCratePath' }
$patchEnd
"@
  Set-Content -LiteralPath $cargoConfigPath -Value ($cargoConfig.TrimEnd() + "`n`n" + $patchConfig) -Encoding utf8NoBOM

  Push-Location $repositoryRoot
  try {
    & cargo update --package "webview2-com-sys@$webView2ComSysVersion" --precise $webView2ComSysVersion
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to select the repo-local webview2-com-sys crate."
    }

    $metadataJson = & cargo metadata --locked --format-version 1
    if ($LASTEXITCODE -ne 0) {
      throw "Cargo rejected the locked repo-local WebView2 input."
    }
  }
  finally {
    Pop-Location
  }

  $metadata = $metadataJson | ConvertFrom-Json
  $webView2Packages = @($metadata.packages | Where-Object {
      $_.name -eq "webview2-com-sys" -and $_.version -eq $webView2ComSysVersion
    })
  if ($webView2Packages.Count -ne 1) {
    throw "Expected one repo-local webview2-com-sys package, found $($webView2Packages.Count)."
  }
  $selectedCrateRoot = (Split-Path -Parent $webView2Packages[0].manifest_path).Replace("\", "/")
  if ($selectedCrateRoot -ne $tomlCratePath) {
    throw "Cargo selected an unexpected webview2-com-sys input: $selectedCrateRoot"
  }

  $probeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "dbx-win7-webview2-loader-probe"
  New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
  $probeLoader = Join-Path $probeDirectory "WebView2Loader.dll"
  Copy-Item -LiteralPath $legacyLoaderDll -Destination $probeLoader -Force

  Write-Host "Prepared repo-local webview2-com-sys $webView2ComSysVersion input: $generatedRoot"
  Write-Host "Prepared WebView2 SDK $sdkVersion static loader for Windows 7 / Server 2012 R2: $loaderDestination"
  Write-Host "Prepared WebView2 SDK $sdkVersion loader probe DLL: $probeLoader"
}
finally {
  if (Test-Path -LiteralPath $temporaryRoot) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
  }
}
