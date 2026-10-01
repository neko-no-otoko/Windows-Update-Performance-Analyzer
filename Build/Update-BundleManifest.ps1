[CmdletBinding()]
param(
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $toolRoot 'BundleManifest.sha256'
$rootFiles = @(
    'Invoke-Win11UpgradeDiag.ps1',
    'NOTICE.md',
    'VERSION',
    'Watch-Win11Upgrade.ps1'
    'Update-WupaActiveRun.ps1'
)
$folderFiles = @('Assets', 'Data', 'Modules')
$relativeFiles = New-Object Collections.ArrayList
foreach ($relative in $rootFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $toolRoot $relative) -PathType Leaf)) { throw "Required payload file is missing: $relative" }
    $null = $relativeFiles.Add($relative)
}
foreach ($folder in $folderFiles) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $toolRoot $folder) -File -Recurse | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($toolRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
        $null = $relativeFiles.Add($relative)
    }
}
$lines = @($relativeFiles | Sort-Object | ForEach-Object {
    $hash = (Get-FileHash -LiteralPath (Join-Path $toolRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $_"
})
$expected = (@($lines) -join "`n") + "`n"
if ($Verify) {
    $actual = if (Test-Path -LiteralPath $manifestPath) { (Get-Content -LiteralPath $manifestPath -Raw).Replace("`r`n", "`n") } else { '' }
    if ($actual -ne $expected) { throw 'BundleManifest.sha256 is stale. Run Build\Update-BundleManifest.ps1 and commit the result.' }
    Write-Host 'Bundle manifest is current.' -ForegroundColor Green
    exit 0
}
[IO.File]::WriteAllText($manifestPath, $expected, (New-Object Text.UTF8Encoding($false)))
Write-Host ("Updated BundleManifest.sha256 with {0} payload files." -f $lines.Count) -ForegroundColor Green
