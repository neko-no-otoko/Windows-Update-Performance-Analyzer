[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($name in @('Common', 'UpdateTracking', 'Recorder', 'Analysis', 'Review', 'Collectors', 'Report')) { Import-Module (Join-Path $toolRoot "Modules/$name.psm1") -Force }
function Assert-Upgrade { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "ASSERTION FAILED: $Message" }; Write-Host "PASS: $Message" }
function New-UpdateEvent {
    param([int]$Id, [string]$Time, [string]$Title = 'Windows 11, version 25H2', [string]$Guid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', [int]$Revision = 101, [string]$Keywords = '0x8000000000002004', [int]$RecordId = 1)
    $titleXml = [Security.SecurityElement]::Escape($Title)
    $xml = @"
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="Microsoft-Windows-WindowsUpdateClient"/><EventID>$Id</EventID><Keywords>$Keywords</Keywords><TimeCreated SystemTime="$Time"/><EventRecordID>$RecordId</EventRecordID><Correlation ActivityID="{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}"/><Channel>System</Channel></System><EventData><Data Name="updateTitle">$titleXml</Data><Data Name="updateGuid">{$Guid}</Data><Data Name="updateRevisionNumber">$Revision</Data></EventData></Event>
"@
    ConvertFrom-WudUpdateEventXml -Xml $xml -SourceRef "fixture/event-$RecordId.xml"
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('WUPA-identity-tests-' + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-WudDirectory $root
    foreach ($title in @('2026-09 Cumulative Update for Windows 11 Version 25H2 (KB1234567)', 'Security Update for Windows 11, version 25H2', 'Intel driver for Windows 11 25H2', '.NET update for Windows 11, version 25H2', 'Windows 11, version 24H2', 'Windows 11, version 25H2 Dynamic Update')) {
        Assert-Upgrade (-not (Test-WudTargetUpgradeTitle $title)) "Unrelated update is not an upgrade: $title"
    }
    Assert-Upgrade (Test-WudTargetUpgradeTitle 'Windows 11, version 25H2') 'Actual feature update title is accepted'
    Assert-Upgrade (Test-WudTargetUpgradeTitle 'Feature update to Windows 11, version 25H2 x64') 'Full feature update title is accepted'
    Assert-Upgrade (Test-WudTargetUpgradeTitle 'Windows 11 (business editions), version 25H2') 'Business-edition feature update title is accepted'
    Assert-Upgrade (Test-WudTargetUpgradeTitle 'KB5054156: Feature update to Windows 11, version 25H2 by using an enablement package') 'Documented enablement package is accepted'
    $events = @(
        (New-UpdateEvent 44 '2026-10-01T10:00:00Z' -RecordId 1),
        (New-UpdateEvent 17 '2026-10-01T10:03:00Z' -Keywords '0x8000000000004004' -RecordId 2),
        (New-UpdateEvent 43 '2026-10-01T10:04:00Z' -Keywords '0x8000000000002008' -RecordId 3),
        (New-UpdateEvent 20 '2026-10-01T10:05:00Z' -Keywords '0x8000000000008008' -RecordId 4),
        (New-UpdateEvent 43 '2026-10-01T10:07:00Z' -Keywords '0x8000000000002008' -RecordId 5),
        (New-UpdateEvent 19 '2026-10-01T10:09:00Z' -Keywords '0x8000000000004008' -RecordId 6),
        (New-UpdateEvent 20 '2026-10-01T10:10:00Z' -Title 'Security Update for Windows 11, version 25H2' -Guid 'cccccccc-cccc-cccc-cccc-cccccccccccc' -Keywords '0x8000000000008008' -RecordId 7)
    )
    Assert-Upgrade ($events[0].Boundary -eq 'DownloadStarted' -and $events[1].Boundary -eq 'DownloadCompleted') 'Locale-neutral provider fields identify download boundaries'
    Assert-Upgrade ($events[2].Boundary -eq 'InstallStarted' -and $events[5].Boundary -eq 'InstallReportedSucceeded') 'Install start and applied-operation success are distinct source events'
    Assert-Upgrade ($events[0].UpdateID -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -and $events[0].RevisionNumber -eq 101) 'GUID/revision are extracted from XML, not display text'
    $identity = Resolve-WudUpgradeIdentity -Records $events
    Assert-Upgrade ($identity.Status -eq 'Locked') 'Quality/security updates do not create competing upgrade candidates'
    Assert-Upgrade (-not (Test-WudUpgradeIdentityMatch $events[6] $identity)) 'Concurrent security update failure cannot enter the upgrade timeline'
    $changedRevision = New-UpdateEvent 44 '2026-10-01T10:11:00Z' -Revision 102
    Assert-Upgrade (-not (Test-WudUpgradeIdentityMatch $changedRevision $identity)) 'A different revision cannot silently join a locked attempt'
    $noRevision = $events[0].PSObject.Copy()
    $noRevision.RevisionNumber = $null
    Assert-Upgrade (-not (Test-WudUpgradeIdentityMatch $noRevision $identity) -and (Resolve-WudUpgradeIdentity -Records @($noRevision)).Status -eq 'Incomplete') 'Missing revision metadata cannot establish an exact identity match'
    $otherUpgrade = New-UpdateEvent 44 '2026-10-01T10:11:00Z' -Guid 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    Assert-Upgrade ((Resolve-WudUpgradeIdentity -Records @($events[0], $otherUpgrade)).Status -eq 'Ambiguous') 'Multiple genuine target update identities are explicitly ambiguous'
    Assert-Upgrade ((Resolve-WudUpgradeIdentity -Records @($otherUpgrade) -ExistingLock $identity).UpdateID -eq $identity.UpdateID) 'A later update cannot replace the persisted identity'
    $serviceMismatch = $events[0].PSObject.Copy()
    $serviceMismatch.ServiceID = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
    $serviceLock = $identity.PSObject.Copy()
    $serviceLock.ServiceID = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    Assert-Upgrade (-not (Test-WudUpgradeIdentityMatch $serviceMismatch $serviceLock)) 'Conflicting known update services are excluded'
    $unsafeXml = '<!DOCTYPE Event [<!ENTITY x SYSTEM "file:///nonexistent">]><Event>&x;</Event>'
    $rejected = $false
    try { $null = ConvertFrom-WudUpdateEventXml $unsafeXml } catch { $rejected = $true }
    Assert-Upgrade $rejected 'External XML entities are rejected'

    $trackingModule = Get-Module UpdateTracking
    $pollPath = Join-Path $root 'polling'
    & $trackingModule {
        param($fixture)
        $script:IdentityTestQuery = [pscustomobject]@{ Records = @($fixture); Providers = @([pscustomobject]@{ Channel = 'System'; Status = 'Available'; Error = $null }, [pscustomobject]@{ Channel = 'UnavailableOperational'; Status = 'Failed'; Error = 'Fixture unavailable channel' }) }
        function script:Get-WudUpdateEventRecords { param($StartTime, $EndTime, $MaximumEvents) return $script:IdentityTestQuery }
    } $events[0]
    $null = Update-WudUpgradeTracking -RunPath $pollPath -SinceUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $firstCursor = Read-WudJson -Path (Join-Path $pollPath 'State/update-event-cursor.json')
    $null = Update-WudUpgradeTracking -RunPath $pollPath -SinceUtc ([DateTime]::UtcNow.AddMinutes(-1))
    $secondCursor = Read-WudJson -Path (Join-Path $pollPath 'State/update-event-cursor.json')
    Assert-Upgrade (@((Read-WudJsonLines -Path (Join-Path $pollPath 'Evidence/Recorder/UpdateEvents.jsonl')).Records).Count -eq 1) 'Overlapping polls append a source event once'
    Assert-Upgrade (([DateTimeOffset]::Parse($secondCursor.EndUtc)) -ge ([DateTimeOffset]::Parse($firstCursor.EndUtc))) 'An unavailable channel cannot move the polling watermark backwards'
    Assert-Upgrade (@((Read-WudJsonLines -Path (Join-Path $pollPath 'Evidence/Recorder/UpdateEventCoverage.jsonl')).Records).Count -eq 2) 'Each poll preserves provider failure coverage'

    $context = New-WudRunContext -ToolRoot $toolRoot -ToolVersion '3.1.0-test' -RunId 'identity' -RunPath (Join-Path $root 'run') -OutputPath (Join-Path $root 'out') -Mode 'Forensic' -PhaseLabel 'Forensic' -TargetVersion '25H2' -CopyTo $null -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
    Write-WudJsonAtomic -Path (Join-Path $context.RunPath 'State/run-state.json') -InputObject ([pscustomobject]@{ CreatedUtc = '2026-10-01T09:00:00Z' })
    $recorder = New-WudDirectory (Join-Path $context.EvidencePath 'Recorder')
    foreach ($event in $events) { Write-WudJsonLine -Path (Join-Path $recorder 'UpdateEvents.jsonl') -InputObject $event -Depth 12 }
    $history = @([pscustomobject]@{ Date = '2026-10-01T10:10:00Z'; Title = $events[6].Title; UpdateID = $events[6].UpdateID; RevisionNumber = 101; Operation = '1'; ResultCode = '4' })
    $context.Inventory['Identity'] = [pscustomobject]@{ DisplayVersion = '25H2'; CurrentBuild = '26200'; WindowsImageState = 'IMAGE_STATE_COMPLETE' }
    $context.Inventory['Servicing'] = [pscustomobject]@{ UpdateHistory = $history }
    Assert-Upgrade (@(Get-WudFeatureUpdateHistory $context ([pscustomobject]$context.Inventory)).Count -eq 0) 'WUA history security titles do not become feature history'
    $samples = @(
        [pscustomobject]@{ TimestampUtc = '2026-10-01T09:59:00Z'; Os = [pscustomobject]@{ Build = 22631; TargetPresent = $false }; SetupProcesses = @([pscustomobject]@{ Name = 'TiWorker.exe' }); Setup = [pscustomobject]@{} },
        [pscustomobject]@{ TimestampUtc = '2026-10-01T10:08:00Z'; Os = [pscustomobject]@{ Build = 22631; TargetPresent = $false } },
        [pscustomobject]@{ TimestampUtc = '2026-10-01T10:15:00Z'; Os = [pscustomobject]@{ Build = 26200; TargetPresent = $true } }
    )
    Assert-Upgrade ((Get-WudRecorderState $samples[0]) -eq 'ArmedOrIdle') 'TiWorker alone is not a feature-upgrade setup observation'
    foreach ($sample in $samples) { Write-WudJsonLine -Path (Join-Path $recorder 'ProgressSamples.jsonl') -InputObject $sample }
    $context.UpgradeTracking = Get-WudUpgradeTrackingModel $context
    $timing = Get-WudUpgradeTimingModel $context $context.UpgradeTracking
    Assert-Upgrade ($timing.Sessions.Count -eq 3 -and $timing.Sessions[0].ElapsedSeconds -eq 180) 'Download duration comes from matched start/end events'
    Assert-Upgrade ($timing.Sessions[1].Result -eq 'InstallReportedFailed' -and $timing.Sessions[2].ElapsedSeconds -eq 120) 'A failed install and its subsequent install retain separate intervals'
    Assert-Upgrade (([DateTimeOffset]::Parse($timing.TargetOsFirstObserved.LowerBoundUtc)) -eq ([DateTimeOffset]::Parse('2026-10-01T10:08:00Z')) -and ([DateTimeOffset]::Parse($timing.TargetOsFirstObserved.UpperBoundUtc)) -eq ([DateTimeOffset]::Parse('2026-10-01T10:15:00Z'))) 'Post-reboot completion retains the actual seven-minute observation bounds'
    $partial = Get-WudUpgradeTimingModel $context ([pscustomobject]@{ Identity = $identity; MatchedEvents = @($events[5]); MatchedHistory = @() })
    Assert-Upgrade ($null -eq $partial.Sessions[0].StartUtc -and $null -eq $partial.Sessions[0].ElapsedSeconds) 'A completion-only event cannot invent an install start or duration'
    Assert-Upgrade ($null -eq $timing.DownloadFirstObserved) 'Unmapped device-wide Delivery Optimization traffic cannot supply upgrade timing'

    $setupPath = Join-Path $context.SnapshotPath 'Raw/WindowsBT-Panther/setupact.log'
    Write-WudText -Path $setupPath -Text "2026-09-30T10:04:00Z Error historical record`n2026-10-01T10:04:00Z MOUPG WindowsUpdate target OS build: 10.0.26200.1 UpdateID=$($identity.UpdateID)`n2026-10-01T10:05:00Z Applying Windows image; specialize; unattend.xml`n2026-10-01T10:09:00Z Error 0x80070005"
    $profile = Get-WudSetupLogProfile $context (Get-Item $setupPath) 1
    $profile = Set-WudAttemptScope $context $profile @() $context.Inventory['Identity']
    Assert-Upgrade ($profile.IncludedForUpgradeReview -and $profile.AttributionBasis -eq 'ExplicitSetupUpdateId') ("Target-build setup evidence with the exact GUID passes direct attribution gates: {0}" -f $profile.ExclusionReason)
    $truncatedProfile = $profile.PSObject.Copy()
    $truncatedProfile.ParseTruncated = $true
    $truncatedProfile = Set-WudAttemptScope $context $truncatedProfile @() $context.Inventory['Identity']
    Assert-Upgrade (-not $truncatedProfile.IncludedForUpgradeReview) 'A truncated scope parse cannot prove the remainder is uncontaminated'
    $foreignPath = Join-Path $context.SnapshotPath 'Raw/WindowsBT-Panther/setupact_1.log'
    Write-WudText -Path $foreignPath -Text '2026-10-01T10:04:00Z MOUPG Windows Update target OS build 26100 UpdateID=cccccccc-cccc-cccc-cccc-cccccccccccc'
    $foreign = Set-WudAttemptScope $context (Get-WudSetupLogProfile $context (Get-Item $foreignPath) 2) @() $context.Inventory['Identity']
    Assert-Upgrade (-not $foreign.IncludedForUpgradeReview) 'A nearby setup record for another build/GUID is excluded'
    $collectorModule = Get-Module Collectors
    & $collectorModule { param($ctx) Invoke-WudSetupDiagCollector $ctx } $context
    $setupMetadata = Read-WudJson -Path (Join-Path $context.SnapshotPath 'SetupDiag/setupdiag-tool.json')
    Assert-Upgrade (-not $setupMetadata.Executed -and $setupMetadata.RejectedInputs.Count -gt 0) 'SetupDiag refuses a recursive input root containing unrelated setup sessions'
    $null = Invoke-WudFactAnalysis $context
    Assert-Upgrade (@($context.Timeline | Where-Object { $_.EventType -eq 'TargetUpdateLifecycle' }).Count -eq 6) 'Final analysis includes exactly the target lifecycle events'
    Assert-Upgrade (@($context.Facts | Where-Object { $_.Category -eq 'WindowsUpdateHistory' }).Count -eq 0) 'Concurrent security failure never becomes a feature-upgrade history fact'
    Assert-Upgrade (@($context.Timeline | Where-Object { $_.Message -match 'historical record' }).Count -eq 0) 'Old records in a newly modified setup log remain outside the monitored timeline'
    $null = Export-WudReviewBundle $context
    $report = Export-WudReportArtifacts $context
    $summary = Read-WudJson -Path (Join-Path $context.OutputPath 'Summary.json')
    if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
        Assert-Upgrade (Test-Json -Json (Get-Content (Join-Path $context.OutputPath 'Summary.json') -Raw) -SchemaFile (Join-Path $toolRoot 'Data/Summary.schema.json')) 'Exported summary passes its schema'
    }
    Assert-Upgrade ($summary.UpgradeIdentity.UpdateID -eq $identity.UpdateID -and $summary.UpgradeTiming.Sessions.Count -eq 3) 'Summary exports locked identity and phase intervals'
    Assert-Upgrade ((Get-Content $report -Raw) -match 'Target upgrade identity and phase timing') 'HTML renders the identity-scoped timing table'
    Assert-Upgrade (Test-Path (Join-Path $context.OutputPath 'UpgradeTiming.json')) 'Standalone phase timing artifact is included'
    Write-Host 'All upgrade identity and phase timing fixture tests passed.'
}
finally { if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
