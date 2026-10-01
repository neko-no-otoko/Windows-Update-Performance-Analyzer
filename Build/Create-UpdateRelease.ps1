[CmdletBinding()]
param([string]$OutputPath, [string]$SigningKeyPath, [string]$MinimumAppVersion = '3.2.1')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) { $OutputPath = Join-Path $toolRoot 'dist' }
$version = (Get-Content (Join-Path $toolRoot 'VERSION') -Raw).Trim()
$null = New-Item -ItemType Directory -Path $OutputPath -Force
& (Join-Path $PSScriptRoot 'Update-BundleManifest.ps1') -Verify
if ($LASTEXITCODE -ne 0) { throw 'Embedded payload manifest is stale.' }
$compatibility = Get-Content (Join-Path $toolRoot 'Data/update-compatibility.json') -Raw | ConvertFrom-Json
if ($compatibility.EngineVersion -ne $version) { throw 'Engine compatibility declaration does not match VERSION.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipName = "WUPA-engine-$version.zip"
$zipPath = Join-Path $OutputPath $zipName
if (Test-Path $zipPath) { throw "Output already exists: $zipPath. Use a fresh release-staging folder." }
$files = @('BundleManifest.sha256') + @(Get-Content (Join-Path $toolRoot 'BundleManifest.sha256') | ForEach-Object { if ($_ -match '^[a-fA-F0-9]{64}\s+\*?(.+)$') { $matches[1] } })
$archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in $files) { $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $toolRoot $relative), $relative.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal) }
}
finally { $archive.Dispose() }
$build = Get-Content (Join-Path $OutputPath 'WUPA-build.json') -Raw | ConvertFrom-Json
$applications = [ordered]@{}
foreach ($item in $build) {
    $path = Join-Path $OutputPath $item.Name
    if ($item.Version -ne $version -or (Get-Item $path).Length -ne $item.Length -or (Get-FileHash $path).Hash -ne $item.Sha256) { throw 'An executable does not match its build record.' }
    $applications[$item.Runtime] = [ordered]@{ Name = $item.Name; Length = $item.Length; Sha256 = $item.Sha256 }
}
$manifest = [ordered]@{
    SchemaVersion = 1; ReleaseVersion = $version; EngineVersion = $version; MinimumAppVersion = $MinimumAppVersion
    StateSchemas = @($compatibility.StateSchemas); CompatiblePreviousEngines = @($compatibility.CompatiblePreviousEngines)
    Engine = [ordered]@{ Name = $zipName; Length = (Get-Item $zipPath).Length; Sha256 = (Get-FileHash $zipPath).Hash.ToLowerInvariant(); BundleManifestSha256 = (Get-FileHash (Join-Path $toolRoot 'BundleManifest.sha256')).Hash.ToLowerInvariant() }
    Applications = $applications
}
$manifestPath = Join-Path $OutputPath 'WUPA-update.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
if ($SigningKeyPath) {
    if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) { throw 'OpenSSL is required for offline release signing.' }
    $signaturePath = Join-Path $OutputPath 'WUPA-update.sig'
    & openssl dgst -sha256 -sign $SigningKeyPath -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1 -out $signaturePath $manifestPath
    if ($LASTEXITCODE -ne 0) { throw 'Update manifest signing failed.' }
    & openssl dgst -sha256 -verify (Join-Path $toolRoot 'Gui/Assets/UpdatePublicKey.pem') -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-1 -signature $signaturePath $manifestPath
    if ($LASTEXITCODE -ne 0) { throw 'The signature does not match the public key embedded in WUPA.' }
}
Write-Host "Created engine package and update manifest for $version. Only publish as an update after offline signing and verification."
