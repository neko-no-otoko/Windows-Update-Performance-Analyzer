[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Assert-WupaV300 {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

$version = (Get-Content -LiteralPath (Join-Path $toolRoot 'VERSION') -Raw).Trim()
$entry = Get-Content -LiteralPath (Join-Path $toolRoot 'Invoke-Win11UpgradeDiag.ps1') -Raw
$gui = Get-Content -LiteralPath (Join-Path $toolRoot 'Gui/Program.cs') -Raw
$project = Get-Content -LiteralPath (Join-Path $toolRoot 'Gui/WindowsUpdateAnalytics.Gui.csproj') -Raw
$collectors = Get-Content -LiteralPath (Join-Path $toolRoot 'Modules/Collectors.psm1') -Raw
$recorder = Get-Content -LiteralPath (Join-Path $toolRoot 'Modules/Recorder.psm1') -Raw
$persistence = Get-Content -LiteralPath (Join-Path $toolRoot 'Modules/Persistence.psm1') -Raw
$settings = Get-Content -LiteralPath (Join-Path $toolRoot 'Data/settings.json') -Raw | ConvertFrom-Json
$report = Get-Content -LiteralPath (Join-Path $toolRoot 'Modules/Report.psm1') -Raw
$readme = Get-Content -LiteralPath (Join-Path $toolRoot 'README.md') -Raw

Assert-WupaV300 ($entry -match ('\$toolVersion\s*=\s*''' + [Regex]::Escape($version) + '''') -and $gui -match ('AppVersion\s*=\s*"' + [Regex]::Escape($version) + '"')) 'Package, engine, and GUI identify the same release'
Assert-WupaV300 ($entry -match "ValidateSet\('Start', 'Resume', 'Finish', 'Analyze', 'Cancel'\)" -and $entry -notmatch "ValidateSet\('Auto'" -and $entry -notmatch '\[string\]\$OutputPath' -and $entry -notmatch '\[string\]\$CopyTo' -and $entry -notmatch '\[string\]\$MediaPath') 'Public engine actions are reduced to the focused lifecycle'
Assert-WupaV300 ($entry -match '\$TargetVersion = ''25H2''' -and $entry -match '\$ArmDays = 30' -and $entry -match '\$leaf = ''WUPA-') 'Target, expiry, and Public Documents case naming are fixed defaults'

Assert-WupaV300 ($gui -match 'Start tracking the 25H2 update' -and $gui -match 'Finish and create report' -and $gui -match 'Analyze the completed 25H2 update') 'GUI primary action follows the current lifecycle state'
Assert-WupaV300 ($gui -notmatch 'Collection settings' -and $gui -notmatch 'Optional UNC copy' -and $gui -notmatch 'Media scan' -and $gui -notmatch 'Include full MEMORY') 'GUI no longer exposes collector implementation switches'
Assert-WupaV300 ($gui -match 'Show technical details' -and $gui -match 'Last collector status' -and $gui -match 'Automatic report is already running') 'Technical progress is available without dominating the simple interface'
Assert-WupaV300 ($project -match '<AssemblyName>WUPA</AssemblyName>' -and $project -match '<ApplicationIcon>Assets\\WUPA\.ico</ApplicationIcon>' -and (Test-Path -LiteralPath (Join-Path $toolRoot 'Gui/Assets/WUPA.svg'))) 'Executable and editable vector logo use the WUPA brand'

$allCollectorBlock = [regex]::Match($collectors, '(?s)function Invoke-WudAllCollectors \{.+?\n\}').Value
Assert-WupaV300 ($allCollectorBlock -notmatch 'Invoke-WudCollector \$Context ''(?:active-health|appraiser|media-compatibility|software)''') 'Removed collectors are not reachable from the focused collection path'
Assert-WupaV300 ($allCollectorBlock -match 'native-update-evidence' -and $allCollectorBlock -match 'update-telemetry' -and $allCollectorBlock -match 'update-events') 'Focused native, transport, and event collectors remain active'
Assert-WupaV300 ($collectors -notmatch "Name = 'Windows-Panther'" -and $collectors -notmatch "Name = 'Windows-CBS'" -and $collectors -notmatch "Name = 'Windows-DISM'" -and $collectors -notmatch "Name = 'ConfigMgr-Logs'" -and $collectors -notmatch "Name = 'WER-ReportArchive'") 'Broad and imaging-contaminated raw sources are excluded'
Assert-WupaV300 ($collectors -notmatch "Name = 'systeminfo'" -and $collectors -notmatch "Name = 'mountvol-list'" -and $collectors -notmatch "Name = 'dism-packages'") 'Slow general-purpose command captures are removed'
Assert-WupaV300 ($collectors -match "Get-DeliveryOptimizationLog" -and $collectors -match 'Select-Object -First 5000') 'Delivery Optimization readable records remain with a bounded result set'

Assert-WupaV300 ([int]$settings.recorder.sampleIntervalSeconds -eq 60 -and [int]$settings.recorder.maximumCheckpoints -eq 8 -and [long]$settings.recorder.maximumCheckpointBytes -eq 67108864) 'Recorder retains 60-second sampling with bounded checkpoints'
Assert-WupaV300 ($recorder -notmatch "WindowsUpdate-ETL'; Path" -and $recorder -notmatch "USOShared-Logs'; Path" -and $recorder -notmatch "EventLogs'\)") 'Boundary checkpoints no longer duplicate transport logs and event channels'
Assert-WupaV300 ($persistence -match "ProgramData 'WUPA'" -and $persistence -match "'\\WUPA\\'" -and $persistence -match '-Action Resume') 'Durable state and cross-reboot tasks use the WUPA lifecycle'

Assert-WupaV300 ($report -match 'Windows Update Performance Analyzer · fact-only evidence' -and $report -match 'WUPA is an independent, diagnostic-only utility') 'Report uses the WUPA brand and factual interpretation boundary'
Assert-WupaV300 ($readme -match ('WUPA-' + [Regex]::Escape($version) + '-win-x64\.exe') -and $readme -match 'no settings page' -and $readme -match 'Windows\\Panther.*excluded') 'Operator documentation matches the simplified executable workflow and evidence safeguards'

Write-Host 'All WUPA v3.0.0 regression tests passed.' -ForegroundColor Cyan
