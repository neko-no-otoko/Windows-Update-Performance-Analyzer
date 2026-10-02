[CmdletBinding()]
param([string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in @('Common', 'UpdateTracking', 'Recorder', 'Collectors', 'Analysis', 'Review', 'Report')) { Import-Module (Join-Path $toolRoot ("Modules/{0}.psm1" -f $module)) -Force }
function Assert-Retained { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('WUPA-Retained321-' + [Guid]::NewGuid().ToString('N'))
$ctx = New-WudRunContext -ToolRoot $toolRoot -ToolVersion '3.2.1-test' -RunId 'retained' -RunPath (Join-Path $fixture 'run') -OutputPath (Join-Path $fixture 'out') -Mode 'Forensic' -PhaseLabel 'Forensic' -TargetVersion '25H2' -CopyTo $null -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
$id = 'f4ad9cf8-3ef1-40e7-8a1d-f3034b1ded62'
$service = '8b24b027-1dee-babb-9a95-3517dfb9c552'
$ctx.Inventory['Identity'] = [pscustomobject]@{ ComputerName = 'fixture'; DisplayVersion = '25H2'; CurrentBuild = '26200'; TimeZone = 'Central Standard Time'; WindowsImageState = 'IMAGE_STATE_COMPLETE' }
$ctx.Inventory['Servicing'] = [pscustomobject]@{ UpdateHistory = @([pscustomobject]@{ DateUtc = '2026-10-01T06:48:41Z'; Title = 'Windows 11, version 25H2'; Operation = '1'; ResultCode = '2'; HResultHex = '0x00000000'; UpdateID = $id; RevisionNumber = 1; ServiceID = $service }) }
$logPath = Join-Path $ctx.SnapshotPath 'WindowsUpdate/WindowsUpdate.log'
# Sanitized grammar fixture: public update IDs and source-message syntax only.
# No technician/device identifiers or real evidence files enter the repository.
Write-WudText $logPath @"
2026/10/01 01:24:54.3342321 1 2 Deployment QueryUpdateDeploymentStatusInternal status for update $id.1 : callback code = Update success, error code = 0x00000000, extended error code = 0x00000000
2026/10/01 01:24:54.3622071 1 2 Agent Update $id.1 final deployment status: callbackCode = Update success, errCode = 0x00000000, download required = No
2026/10/01 01:24:54.5031054 1 2 Agent Update $id.1 initial deployment status: download required = Yes
"@
if ($EvidenceRoot) {
    $inventory = Read-WudJson (Join-Path $EvidenceRoot 'Forensic/inventory.json')
    $ctx.Inventory['Identity'] = $inventory.Identity
    $ctx.Inventory['Servicing'] = Read-WudJson (Join-Path $EvidenceRoot 'Forensic/Servicing/servicing.json')
    Copy-Item -LiteralPath (Join-Path $EvidenceRoot 'Forensic/WindowsUpdate/WindowsUpdate.log') -Destination $logPath
    $eventsPath = Join-Path $ctx.SnapshotPath 'Events/update-lifecycle-events.json'
    $null = New-WudDirectory (Split-Path -Parent $eventsPath)
    Copy-Item -LiteralPath (Join-Path $EvidenceRoot 'Forensic/Events/update-lifecycle-events.json') -Destination $eventsPath
}
Write-WudText (Join-Path $ctx.SnapshotPath 'Raw/Windows-Panther-Context/setupact.log') '2026-09-28 13:22:56 Info Scenario: Imaging IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE target OS build: 10.0.22631.1'
$null = Invoke-WudFactAnalysis $ctx
Assert-Retained (@($ctx.Attempts | Where-Object IncludedForUpgradeReview).Count -eq 0) 'Retained initial-imaging Panther cannot become the 25H2 upgrade attempt'
$target = @($ctx.UpdateActivity.Updates | Where-Object Role -eq 'TargetUpgrade')
Assert-Retained ($target.Count -eq 1 -and $ctx.UpgradeTracking.Identity.UpdateID -eq $id) 'History discovers the exact target GUID/revision with no matching native target events'
Assert-Retained ($target[0].NativeEventCount -eq 0 -and $target[0].LogRecordCount -ge 2) 'Native target event count and decoded-log records are separate facts'
Assert-Retained ($ctx.StatusModel.AttemptOutcome -eq 'WindowsUpdateReportedSucceeded' -and $ctx.StatusModel.BuildTransition -eq 'NotObserved') 'Reported success does not invent a live build transition'
Assert-Retained ($ctx.StatusModel.SuccessEvidence.Count -ge 3) 'History and direct decoded-log success have exact evidence references'
Assert-Retained ($target[0].Timing.Sessions.Count -eq 0) 'Post-reboot status queries and cached download flags do not invent phase boundaries'
$rules = (Read-WudJson (Join-Path $toolRoot 'Data/update-log-rules.json')).Rules
$good = ConvertFrom-WudWindowsUpdateLogLine "2026/10/01 01:24:54.3342321 1 2 Deployment QueryUpdateDeploymentStatusInternal status for update $id.1 : callback code = Update success, error code = 0x00000000" 'fixture:1' 'Central Standard Time' 'Current' $rules
Assert-Retained ($good.TimestampUtc -eq '2026-10-01T06:24:54.3342321Z') 'Source local time normalizes using the captured device zone, not reviewer/CI zone'
$ambiguous = ConvertFrom-WudWindowsUpdateLogLine "2026/11/01 01:30:00 1 2 Download started for update $id.1" 'fixture:2' 'Central Standard Time' 'Current' $rules
Assert-Retained ($null -eq $ambiguous.TimestampUtc -and $ambiguous.TimestampKind -eq 'AmbiguousLocalTime') 'DST ambiguity is retained without choosing a fabricated UTC time'
$unknown = ConvertFrom-WudWindowsUpdateLogLine "2026/10/01 01:30:00 1 2 Download started for update $id.1" 'fixture:3' '' 'Current' $rules
Assert-Retained ($null -eq $unknown.TimestampUtc) 'Missing device time zone cannot silently use the review host zone'
$conflict = ConvertFrom-WudWindowsUpdateLogLine "2026/10/01 01:30:00 1 2 Download completed for update $id.1 and 11111111-2222-3333-4444-555555555555.1" 'fixture:4' 'UTC' 'Current' $rules
Assert-Retained ($null -eq $conflict) 'A multi-update batch line is not an individual update boundary'
$bad = ConvertFrom-WudWindowsUpdateLogLine "2026/10/01 01:30:00 1 2 Deployment QueryUpdateDeploymentStatusInternal status for update $id.1 : callback code = Update success, error code = 0x80070005" 'fixture:5' 'UTC' 'Current' $rules
Assert-Retained ($bad.Boundary -eq 'UpdateLogContext') 'Contradictory nonzero error cannot become deployment success'
$start = ConvertFrom-WudWindowsUpdateLogLine "2026/10/01 01:30:00 1 2 Download started for update $id.1" 'fixture:6' 'UTC' 'WindowsOld' $rules
$end = ConvertFrom-WudWindowsUpdateLogLine "2026/10/01 01:32:00 1 2 Download completed for update $id.1" 'fixture:7' 'UTC' 'WindowsOld' $rules
$otherEnd = ConvertFrom-WudWindowsUpdateLogLine "2026/10/01 01:32:00 1 2 Download completed for update $id.1" 'fixture:8' 'UTC' 'Current' $rules
$timing = Get-WudUpgradeTimingModel $ctx ([pscustomobject]@{ Identity = $ctx.UpgradeTracking.Identity; MatchedEvents = @($start, $end); MatchedHistory = @() })
Assert-Retained ($timing.Sessions[0].ElapsedSeconds -eq 120 -and $timing.Sessions[0].StartKind -eq 'SourceLog') 'Explicit log boundaries produce an evidence-linked wall-clock interval'
$separate = Get-WudUpgradeTimingModel $ctx ([pscustomobject]@{ Identity = $ctx.UpgradeTracking.Identity; MatchedEvents = @($start, $otherEnd); MatchedHistory = @() })
Assert-Retained ($separate.Sessions.Count -eq 2 -and $null -eq $separate.Sessions[0].ElapsedSeconds -and $null -eq $separate.Sessions[1].ElapsedSeconds) 'Current and Windows.old boundaries cannot be silently paired across streams'
foreach ($name in @('Raw/WindowsUpdate-ETL/one.etl', 'Raw/WindowsUpdate-ETL/two.etl.001', 'Raw/WindowsOld-WindowsUpdate-ETL/old.etl.bak')) { Write-WudText (Join-Path $ctx.SnapshotPath $name) 'Synthetic planning fixture, not a decodable ETL.' }
$plans = @(Get-WudWindowsUpdateConversionPlan $ctx)
Assert-Retained ($plans.Count -eq 2 -and $plans[0].Files.Count -eq 2 -and $plans[1].Files.Count -eq 1 -and $plans[0].LogPath -ne $plans[1].LogPath) 'Current/Windows.old and rotated ETLs enter separate conversion plans'
$oldSystemRoot = $env:SystemRoot
try {
    if (-not $env:SystemRoot) { $env:SystemRoot = $fixture }
    & (Get-Module Collectors) {
        param($c)
        $script:DecodeCalls = New-Object Collections.ArrayList
        function script:Get-WindowsUpdateLog {
            param([string[]]$ETLPath, [string]$LogPath, $ErrorAction)
            if ($ETLPath.Count -ne 1 -or -not (Test-Path -LiteralPath $ETLPath[0] -PathType Container)) { throw 'Decoder must receive one owned staged folder, not explicit ETL files.' }
            $files = @(Get-ChildItem -LiteralPath $ETLPath[0] -Recurse -File | Where-Object Name -like 'WindowsUpdate*.etl')
            if (-not $files.Count) { throw 'Staged folder has no decoder-compatible inputs.' }
            $null = $script:DecodeCalls.Add([pscustomobject]@{ Count = $files.Count; LogPath = $LogPath })
            # Do not overwrite the real retained-log fixture used below.
        }
        function script:Invoke-WudProcess {
            param($Context, $FilePath, $ArgumentList, $Name, $TimeoutSeconds, $ExpectedArtifacts)
            Invoke-Expression $ArgumentList[-1]
            [pscustomobject]@{ Succeeded = $true; ExecutionStatus = 'Succeeded'; Detail = 'Mock decoder exercised real input preparation and PS5 argument binding.' }
        }
        Invoke-WudWindowsUpdateLogDecode $c
        if ($script:DecodeCalls.Count -ne 2 -or $script:DecodeCalls[0].Count -ne 2 -or $script:DecodeCalls[1].Count -ne 1) { throw 'Both independent origins must reach the decoder with every staged input.' }
    } $ctx
} finally { $env:SystemRoot = $oldSystemRoot }
Assert-Retained (@(Get-ChildItem (Join-Path $ctx.RunPath 'DecodeScratch') -Directory).Count -eq 0) 'Decode scratch is removed; original staged evidence is never renamed/deleted'
# Archived event coverage is optional, not a fabricated empty live query.
$archives = Get-WudArchivedUpdateEventRecords $ctx ([DateTime]::UtcNow.AddDays(-7))
Assert-Retained ($archives.Providers.Count -eq 2 -and $archives.Records.Count -eq 0 -and $archives.Providers[0].Status -eq 'ArchiveNotRetained') 'Absent archived event logs are explicitly distinguished from empty queried channels'
if (Test-WudIsWindows) {
    $archivePath = Join-Path $ctx.SnapshotPath 'Raw/WindowsOld-System.evtx'
    & wevtutil.exe epl System $archivePath /ow:true
    if ($LASTEXITCODE -ne 0) { throw 'Could not create a native EVTX fixture on the isolated Windows runner.' }
    $nativeArchive = Get-WudArchivedUpdateEventRecords $ctx ([DateTime]::UtcNow.AddDays(-7))
    Assert-Retained ($nativeArchive.Providers[0].Status -in @('Available', 'AvailableEmpty', 'Truncated')) 'Native Get-WinEvent accepts the archived-path/provider/time filter on Windows'
    foreach ($record in $nativeArchive.Records) { Assert-Retained ($record.SourceKind -eq 'ArchivedEvent' -and $record.Channel.StartsWith('WindowsOld/') -and $record.SourceRef.Contains('WindowsOld-System.evtx')) 'Archived native records retain file provenance and a separate timing stream' }
}
foreach ($file in @(Get-ChildItem (Join-Path $toolRoot 'Modules') -File -Filter '*.psm1')) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
    Assert-Retained (-not $nonAscii -or ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) ($file.Name + ' is PS5 ANSI-safe ASCII or BOM-tagged UTF8')
}
$report = Export-WudReportArtifacts $ctx
$html = Get-Content $report -Raw -Encoding UTF8
Assert-Retained ($html.Contains('SENSITIVE DIAGNOSTIC DATA &mdash;') -and $html.Contains('Windows Update reported results') -and $html.Contains('WindowsUpdateReportedSucceeded')) 'HTML punctuation is ASCII-safe and success is visibly evidence-linked'
Write-Output "PASS: retained-log report fixture: $report"
