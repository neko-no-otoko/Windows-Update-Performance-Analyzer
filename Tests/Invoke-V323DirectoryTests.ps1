[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'Modules/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $toolRoot 'Modules/UpdateTracking.psm1') -Force -DisableNameChecking
function Assert-Directory { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }

# Reproduce the mismatch without executing any uploaded module or ETL.
# This is the actual default wildcard passed by the affected OS module.
$filter = 'WindowsUpdate*.etl'
foreach ($name in @('WindowsUpdate.00001.etl', 'WindowsUpdate.20261001.012218.165.1.etl')) {
    $path = 'C:\ProgramData\WUPA\Runs\fixture\DecodeScratch\owned\' + $name
    Assert-Directory (-not ($path -match $filter) -and $name -like $filter) "Default filter rejects explicit path as regex but accepts $name as wildcard"
}
Assert-Directory (('C:\Evidence\Raw\WindowsUpdate-ETL\WindowsUpdate.00001.etl' -match $filter)) 'A matching parent directory can accidentally hide the explicit-file regex bug'

if (-not (Test-WudIsWindows) -or $PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host 'SKIP: Installed WindowsUpdate module checks require Windows PowerShell 5.1; mandatory in Windows CI.'
    exit 0
}

Import-Module WindowsUpdate -Force
$publicCommand = Get-Command Get-WindowsUpdateLog
$moduleSource = $publicCommand.ScriptBlock.File
$nativeTokens = $null; $nativeErrors = $null
$moduleAst = [Management.Automation.Language.Parser]::ParseFile($moduleSource, [ref]$nativeTokens, [ref]$nativeErrors)
if ($nativeErrors.Count) { throw 'Installed WindowsUpdate module source could not be parsed.' }
$functions = @($moduleAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
$enumerators = @($functions | Where-Object Name -eq 'GetListOfETLs')
$providerHelpers = @($functions | Where-Object Name -eq 'CheckSingleWUProvider')
if ($enumerators.Count -ne 1 -or $providerHelpers.Count -ne 1) { throw 'Installed WindowsUpdate enumeration/helper definitions could not be uniquely resolved.' }
$fixture = New-WudDirectory (Join-Path ([IO.Path]::GetTempPath()) ('WUPA-Directory323-' + [Guid]::NewGuid().ToString('N')))
$current = New-WudDirectory (Join-Path $fixture 'current')
$old = New-WudDirectory (Join-Path $fixture 'old')
foreach ($name in @('WindowsUpdate.00002.etl', 'WindowsUpdate.00001.etl', '00003.etl', 'WindowsUpdate.00004.etl.old', 'inputs.json')) {
    Write-WudText (Join-Path $current $name) 'Enumeration fixture only, not a native ETL.'
}
Write-WudText (Join-Path $old 'WindowsUpdate.00001.etl') 'Separate source-OS enumeration fixture.'
$before = @(Get-ChildItem -LiteralPath $fixture -Recurse -File | ForEach-Object { Get-WudFileHashSafe $_.FullName }) -join ','

# Execute ONLY the installed OS's enumeration and filter-classifier functions
# in an isolated scope. CheckSingleWUProvider classifies the filter string; it
# does not inspect ETL contents. Neither helper is replaced with a stub.
$native = & {
    param($EnumeratorText, $ProviderText, $Current, $Old)
    . ([scriptblock]::Create($ProviderText))
    . ([scriptblock]::Create($EnumeratorText))
    $names = @((Get-Command GetListOfETLs).Parameters.Keys)
    if ($names -notcontains 'ETLFileNameFilter' -or $names -notcontains 'ProviderFilter') { throw 'Installed WindowsUpdate helper lacks the expected filter contract.' }
    $parameters = @{ Paths = @($Current); ETLFileNameFilter = @('WindowsUpdate*.etl'); ProviderFilter = @('WUTraceLogging') }
    $currentFiles = @(GetListOfETLs @parameters)
    $parameters.Paths = @($Old)
    $oldFiles = @(GetListOfETLs @parameters)
    $parameters.Paths = @(Join-Path $Current 'WindowsUpdate.00001.etl')
    $fileRejected = $false
    try { $null = GetListOfETLs @parameters } catch { $fileRejected = $_.Exception.Message -match 'ETL File not found' }
    [pscustomobject]@{ Current = $currentFiles; Old = $oldFiles; ExplicitFileRejected = $fileRejected }
} $enumerators[0].Extent.Text $providerHelpers[0].Extent.Text $current $old
Assert-Directory ($native.Current.Count -eq 2 -and [IO.Path]::GetFileName($native.Current[0]) -eq 'WindowsUpdate.00001.etl' -and [IO.Path]::GetFileName($native.Current[1]) -eq 'WindowsUpdate.00002.etl') 'Actual OS helpers enumerate and order all staged ETLs using the real default wildcard'
Assert-Directory ($native.Old.Count -eq 1 -and (Split-Path -Parent $native.Old[0]) -eq $old) 'Actual OS directory enumeration keeps Current and Windows.old separate'
Write-Host ("INFO: installed module explicit-file rejection reproduced: {0}; module version: {1}" -f $native.ExplicitFileRejected, (Get-Module WindowsUpdate).Version)
Assert-Directory ((@(Get-ChildItem -LiteralPath $fixture -Recurse -File | ForEach-Object { Get-WudFileHashSafe $_.FullName }) -join ',') -eq $before) 'Native enumeration leaves every fixture file unchanged'

# If the isolated CI host retains real Windows Update ETLs, additionally call
# the PUBLIC cmdlet on read-only copies. Never flush/stop services, request
# online symbol downloads, or upload these host logs as release artifacts.
$source = Join-Path $env:SystemRoot 'Logs/WindowsUpdate'
$nativeFiles = @(Get-ChildItem -LiteralPath $source -File -Filter 'WindowsUpdate*.etl' -ErrorAction SilentlyContinue | Where-Object Length -gt 0 | Sort-Object Name | Select-Object -First 3)
if ($nativeFiles.Count) {
    $staged = New-WudDirectory (Join-Path $fixture 'native')
    foreach ($file in $nativeFiles) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $staged $file.Name) -ErrorAction Stop }
    $output = Join-Path $fixture 'NativeWindowsUpdate.log'
    Get-WindowsUpdateLog -ETLPath $staged -LogPath $output -ErrorAction Stop | Out-Null
    $validation = Test-WudDecodedWindowsUpdateLog $output
    Assert-Directory $validation.Valid 'Public OS Get-WindowsUpdateLog decodes staged CI-host ETLs via directory input without ForceFlush'
} else {
    Write-Host 'SKIP: CI host retained no native Windows Update ETLs; enumeration is validated, real ETL content decoding is not claimed.'
}
Write-Output 'PASS: directory/default-filter regression suite complete.'
