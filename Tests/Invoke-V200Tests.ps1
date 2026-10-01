[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $toolRoot 'Modules/Common.psm1') -Force
Import-Module (Join-Path $toolRoot 'Modules/UpdateTracking.psm1') -Force
Import-Module (Join-Path $toolRoot 'Modules/Recorder.psm1') -Force
Import-Module (Join-Path $toolRoot 'Modules/Analysis.psm1') -Force
Import-Module (Join-Path $toolRoot 'Modules/Review.psm1') -Force
Import-Module (Join-Path $toolRoot 'Modules/Report.psm1') -Force

function Assert-WudV200 {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function New-WudFixtureSample {
    param(
        [string]$TimestampUtc,
        [string]$BootId = 'boot-a',
        [int]$Build = 22631,
        [string]$DisplayVersion = '23H2',
        [int]$SetupProgress = -1,
        [bool]$SetupProcess = $false,
        [bool]$PendingReboot = $false,
        [string]$DeliveryStatus,
        [long]$TotalBytes = 0,
        [long]$HttpBytes = 0,
        [long]$PeerBytes = 0,
        [long]$CacheBytes = 0
    )
    $doRecords = @()
    if ($DeliveryStatus) {
        $doRecords = @([pscustomobject][ordered]@{
            FileId = 'feature-update-payload'; FileSize = 1000L; TotalBytesDownloaded = $TotalBytes
            BytesFromHttp = $HttpBytes; BytesFromPeers = $PeerBytes; BytesFromCacheServer = $CacheBytes; Status = $DeliveryStatus
        })
    }
    $sample = [pscustomobject][ordered]@{
        SchemaVersion = 1; TimestampUtc = $TimestampUtc; BootId = $BootId
        Os = [pscustomobject]@{ DisplayVersion = $DisplayVersion; Build = $Build; UBR = 1; TargetVersion = '25H2'; TargetBuild = 26200; TargetPresent = ($Build -ge 26200) }
        Setup = [pscustomobject]@{ SystemSetupInProgress = $(if ($SetupProcess) { 1 } else { 0 }); UpgradeInProgress = 0; OOBEInProgress = 0; SetupProgress = $(if ($SetupProgress -ge 0) { $SetupProgress } else { $null }) }
        SetupProcesses = $(if ($SetupProcess) { @([pscustomobject]@{ Name = 'setuphost.exe'; ProcessId = 42 }) } else { @() })
        PendingReboot = [pscustomobject]@{ IsPending = $PendingReboot; Signals = @() }
        Markers = [pscustomobject]@{ PostOOBE = $false; PostRollback = $false }
        DeliveryOptimization = [pscustomobject]@{
            Status = [pscustomobject]@{ Provider = 'Get-DeliveryOptimizationStatus'; Status = 'Available'; Records = @($doRecords); Error = $null }
            PeerInfo = [pscustomobject]@{ Status = 'Available'; Records = @() }
            Performance = [pscustomobject]@{ Status = 'Available'; Records = @() }
            PerformanceThisMonth = [pscustomobject]@{ Status = 'Available'; Records = @() }
            Configuration = [pscustomobject]@{ Status = 'Available'; Records = @() }
        }
    }
    $sample | Add-Member -NotePropertyName RecorderState -NotePropertyValue (Get-WudRecorderState -Sample $sample)
    $sample | Add-Member -NotePropertyName Signature -NotePropertyValue (Get-WudRecorderSignature -Sample $sample)
    return $sample
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("Win11UpgradeDiag-v200-tests-{0}" -f [Guid]::NewGuid().ToString('N'))
$oldSystemDrive = $env:SystemDrive
$oldSystemRoot = $env:SystemRoot
$oldProgramData = $env:ProgramData
try {
    $null = New-WudDirectory -Path $testRoot
    $samples = @(
        (New-WudFixtureSample -TimestampUtc '2026-08-26T10:00:00Z'),
        (New-WudFixtureSample -TimestampUtc '2026-08-26T10:01:00Z' -DeliveryStatus 'Downloading' -TotalBytes 100 -HttpBytes 80 -PeerBytes 20),
        (New-WudFixtureSample -TimestampUtc '2026-08-26T10:02:00Z' -DeliveryStatus 'Downloading' -TotalBytes 700 -HttpBytes 480 -PeerBytes 170 -CacheBytes 50),
        (New-WudFixtureSample -TimestampUtc '2026-08-26T10:03:00Z' -SetupProgress 40 -SetupProcess $true),
        (New-WudFixtureSample -TimestampUtc '2026-08-26T10:04:00Z' -SetupProgress 90 -SetupProcess $true -PendingReboot $true),
        (New-WudFixtureSample -TimestampUtc '2026-08-26T10:06:00Z' -BootId 'boot-b' -Build 26200 -DisplayVersion '25H2')
    )
    Assert-WudV200 ($samples[0].RecorderState -eq 'ArmedOrIdle') 'Idle/armed observation remains non-causal'
    Assert-WudV200 ($samples[1].RecorderState -eq 'DeliveryOptimizationTransferObserved') 'Unattributed Delivery Optimization traffic remains transport context, not an upgrade claim'
    Assert-WudV200 ($samples[3].RecorderState -eq 'SetupActive') 'Setup process and progress become an observed setup state'
    $samples[3].Setup | Add-Member -NotePropertyName SourceReportedPhase -NotePropertyValue ([pscustomobject]@{ Status = 'Observed'; Phase = 'SafeOS'; Source = 'fixture/setupact.log'; Marker = 'SP_EXECUTION_SAFE_OS' }) -Force
    Assert-WudV200 ((Get-WudRecorderState -Sample $samples[3]) -eq 'SetupSafeOS') 'Recent source-reported Setup markers segment an active setup phase'
    Assert-WudV200 ($samples[4].RecorderState -eq 'RebootPending') 'Setup plus a native pending-reboot signal is segmented'
    Assert-WudV200 ($samples[5].RecorderState -eq 'TargetPresent') 'Target build presence wins over stale setup context'

    $telemetry = Get-WudRecorderTelemetrySummary -Samples $samples
    Assert-WudV200 ($telemetry.SampleCount -eq 6) 'Telemetry summary retains every valid sample'
    Assert-WudV200 (@($telemetry.StatesObserved).Count -eq 5) 'Recorder transitions preserve the observed phase sequence'
    Assert-WudV200 ($telemetry.DeliveryOptimization.DownloadedBytesDelta -eq 600) 'Delivery Optimization byte delta is computed per file identity'
    Assert-WudV200 ($telemetry.DeliveryOptimization.HttpBytesDelta -eq 400) 'HTTP byte delta is preserved'
    Assert-WudV200 ($telemetry.DeliveryOptimization.PeerBytesDelta -eq 150) 'Peer byte delta is preserved'
    Assert-WudV200 ($telemetry.DeliveryOptimization.ConnectedCacheBytesDelta -eq 50) 'Connected Cache byte delta is preserved'

    $jsonl = Join-Path $testRoot 'telemetry.jsonl'
    foreach ($sample in $samples) { Write-WudJsonLine -Path $jsonl -InputObject $sample -Depth 20 }
    [IO.File]::AppendAllText($jsonl, '{"truncated":', (New-Object Text.UTF8Encoding($false)))
    $read = Read-WudJsonLines -Path $jsonl
    Assert-WudV200 (@($read.Records).Count -eq 6) 'Valid JSONL survives a truncated final write'
    Assert-WudV200 (@($read.InvalidLines).Count -eq 1) 'Truncated JSONL is explicitly reported'

    $runPath = New-WudDirectory -Path (Join-Path $testRoot 'run')
    $recorderPath = New-WudDirectory -Path (Join-Path $runPath 'Evidence/Recorder')
    foreach ($sample in $samples) { Write-WudJsonLine -Path (Join-Path $recorderPath 'ProgressSamples.jsonl') -InputObject $sample -Depth 20 }
    $context = New-WudRunContext -ToolRoot $toolRoot -ToolVersion '2.0.0-test' -RunId 'v200-status' -RunPath $runPath -OutputPath (Join-Path $testRoot 'out') -Mode 'Forensic' -PhaseLabel 'Forensic' -TargetVersion '25H2' -CopyTo $null -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
    $targetIdentity = [pscustomobject]@{ DisplayVersion = '25H2'; CurrentBuild = '26200'; UBR = 1 }
    $status = Get-WudUpgradeStatusModel -Context $context -Identity $targetIdentity -FeatureHistory @() -EligibleAttempts @()
    Assert-WudV200 ($status.CurrentOsState -eq 'TargetPresent') 'Current target state is independent of attempt provenance'
    Assert-WudV200 ($status.BuildTransition -eq 'Observed') 'Build transition is observed from persistent samples'
    Assert-WudV200 ($status.AttemptOutcome -eq 'Succeeded') 'Observed transition to the target is a factual success outcome'
    Assert-WudV200 ($status.DeploymentSource -eq 'Unattributed') 'Deployment source remains unattributed without Windows Update evidence'
    Assert-WudV200 ($status.OutcomeBanner -eq 'Upgrade Succeeded') 'Observed target transition produces a success banner'

    $targetOnlyRun = New-WudDirectory -Path (Join-Path $testRoot 'target-only')
    $targetOnlyContext = New-WudRunContext -ToolRoot $toolRoot -ToolVersion '2.0.0-test' -RunId 'v200-target-only' -RunPath $targetOnlyRun -OutputPath (Join-Path $testRoot 'target-only-out') -Mode 'Forensic' -PhaseLabel 'Forensic' -TargetVersion '25H2' -CopyTo $null -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
    $targetOnly = Get-WudUpgradeStatusModel -Context $targetOnlyContext -Identity $targetIdentity -FeatureHistory @() -EligibleAttempts @()
    Assert-WudV200 ($targetOnly.OutcomeBanner -eq 'Target OS Present') 'A current 25H2 device is never mislabeled Unknown when provenance is absent'
    Assert-WudV200 ($targetOnly.AttemptOutcome -eq 'NotObserved') 'Target presence does not invent an unobserved upgrade attempt'

    $env:SystemDrive = $testRoot
    $env:SystemRoot = Join-Path $testRoot 'Windows'
    $env:ProgramData = Join-Path $testRoot 'ProgramData'
    $imagingSetupLog = Join-Path $env:SystemRoot 'Panther\setupact.log'
    Write-WudText -Path $imagingSetupLog -Text 'SP_EXECUTION_OOBE_BOOT historical imaging marker'
    Write-WudJsonAtomic -Path (Join-Path $runPath 'State/run-state.json') -InputObject ([pscustomobject]@{ CreatedUtc = '2026-08-26T12:00:00Z'; ExpiresUtc = '2026-09-26T12:00:00Z' })
    (Get-Item -LiteralPath $imagingSetupLog).LastWriteTimeUtc = [DateTime]::Parse('2026-08-26T11:00:00Z').ToUniversalTime()
    $oldPhase = Get-WudSetupPhaseObservation -RunPath $runPath
    Assert-WudV200 ($oldPhase.Status -eq 'NotObserved') 'Pre-run imaging phase text cannot activate recorder phase segmentation'
    (Get-Item -LiteralPath $imagingSetupLog).LastWriteTimeUtc = [DateTime]::Parse('2026-08-26T13:00:00Z').ToUniversalTime()
    $currentPhase = Get-WudSetupPhaseObservation -RunPath $runPath
    Assert-WudV200 ($currentPhase.Status -eq 'Observed' -and $currentPhase.Phase -eq 'OOBE') 'Run-window Setup phase marker is preserved with source evidence'
    $checkpointSample = $samples[3]
    $checkpoint = Write-WudRecorderCheckpoint -RunPath $runPath -Sample $checkpointSample -Reason 'FixtureBoundary' -MaximumCheckpoints 2 -MaximumFileBytes 1024 -MaximumCheckpointBytes 4096
    Assert-WudV200 ($checkpoint.Status -eq 'Created') 'State boundary creates a checkpoint'
    Assert-WudV200 (Test-Path -LiteralPath (Join-Path $checkpoint.Path 'sample.json')) 'Checkpoint contains the triggering sample'
    Assert-WudV200 (Test-Path -LiteralPath (Join-Path $checkpoint.Path 'checkpoint-manifest.json')) 'Checkpoint contains explicit native-copy results'

    $context.Inventory = [ordered]@{
        Baseline = [pscustomobject]@{ Identity = [pscustomobject]@{ ComputerName = 'V200-PC'; ProductName = 'Windows 11 Enterprise'; EditionId = 'Enterprise'; DisplayVersion = '23H2'; CurrentBuild = '22631'; UBR = 1 } }
        Current = [pscustomobject]@{ Identity = [pscustomobject]@{ ComputerName = 'V200-PC'; ProductName = 'Windows 11 Enterprise'; EditionId = 'Enterprise'; DisplayVersion = '25H2'; CurrentBuild = '26200'; UBR = 1 } }
        Diff = [pscustomobject]@{}
    }
    $context.Recorder = $telemetry
    $context.StatusModel = $status
    $context.Outcome = $status.OutcomeBanner
    $context.CompletedUtc = '2026-08-26T10:07:00Z'
    $context.ReviewData = [pscustomobject]@{ AnalysisMode = 'FactOnly'; InventoryDiff = [pscustomobject]@{}; AllUpdateHistory = @() }
    $null = $context.CollectorRecords.Add([pscustomobject]@{ Id = 'v200-fixture'; Version = '2.0.0-test'; Description = 'v2 output fixture'; Required = $true; Status = 'Succeeded'; Detail = $null; StartedUtc = $context.StartedUtc; EndedUtc = $context.CompletedUtc; DurationMs = 1 })
    $bundle = Export-WudReviewBundle -Context $context
    $report = Export-WudReportArtifacts -Context $context
    $reportHtml = Get-Content -LiteralPath $report -Raw
    Assert-WudV200 ($bundle.Verified -and $reportHtml -match 'Persistent progress record') 'V2 report renders the persistent recorder contract'
    Assert-WudV200 ($reportHtml -match 'Outcome and provenance contract' -and $reportHtml -match 'TargetPresent') 'V2 report renders separate outcome and provenance dimensions'
    foreach ($artifactName in @('RecorderSummary.json', 'ProgressSamples.jsonl', 'StateTransitions.jsonl', 'Checkpoints.json')) {
        Assert-WudV200 (Test-Path -LiteralPath (Join-Path $context.OutputPath $artifactName)) "V2 output artifact $artifactName"
    }
    $v2Summary = Read-WudJson -Path (Join-Path $context.OutputPath 'Summary.json')
    Assert-WudV200 ($v2Summary.SchemaVersion -eq 2 -and $v2Summary.SchemaSemanticVersion -eq '2.0.0') 'V2 summary schema versions are emitted'
    Assert-WudV200 ($v2Summary.Recorder.SampleCount -eq 6 -and $v2Summary.StatusModel.DeploymentSource -eq 'Unattributed') 'V2 summary preserves recorder and provenance facts'
    $env:SystemDrive = $oldSystemDrive
    $env:SystemRoot = $oldSystemRoot
    $env:ProgramData = $oldProgramData

    $processContext = New-WudRunContext -ToolRoot $toolRoot -ToolVersion '2.0.0-test' -RunId 'v200-process' -RunPath (Join-Path $testRoot 'process-run') -OutputPath (Join-Path $testRoot 'process-out') -Mode 'Forensic' -PhaseLabel 'Forensic' -TargetVersion '25H2' -CopyTo $null -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
    if (Test-WudIsWindows) {
        $successFile = $env:ComSpec
        $successArguments = @('/d', '/c', 'exit 0')
    }
    else {
        $successFile = '/usr/bin/true'
        $successArguments = @()
    }
    $success = Invoke-WudProcess -Context $processContext -FilePath $successFile -ArgumentList $successArguments -Name 'fixture-success' -TimeoutSeconds 30
    Assert-WudV200 ($success.ExecutionStatus -eq 'Succeeded' -and $success.ExitCodeAvailable) 'Process success has an explicit execution status and exit-code availability'
    $startFailure = Invoke-WudProcess -Context $processContext -FilePath (Join-Path $testRoot 'does-not-exist') -Name 'fixture-start-failure' -TimeoutSeconds 30
    Assert-WudV200 ($startFailure.ExecutionStatus -eq 'StartFailed' -and -not [string]::IsNullOrWhiteSpace($startFailure.Detail)) 'Process start failure retains deepest error detail'
    $artifact = Join-Path $testRoot 'uncertain-artifact.txt'
    if (Test-WudIsWindows) {
        $shellScript = Join-Path $testRoot 'artifact-command.ps1'
        Write-WudText -Path $shellScript -Text ("[IO.File]::WriteAllText('{0}', 'changed')`r`nexit 1`r`n" -f $artifact.Replace("'", "''"))
        $artifactFile = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $artifactArguments = @('-NoProfile', '-File', $shellScript)
    }
    else {
        $shellScript = Join-Path $testRoot 'artifact-command.sh'
        Write-WudText -Path $shellScript -Text ("printf changed > '{0}'`nexit 1`n" -f $artifact)
        $artifactFile = '/bin/sh'
        $artifactArguments = @($shellScript)
    }
    $uncertain = Invoke-WudProcess -Context $processContext -FilePath $artifactFile -ArgumentList $artifactArguments -Name 'fixture-artifact-uncertain' -TimeoutSeconds 30 -ExpectedArtifacts @($artifact)
    Assert-WudV200 ($uncertain.ExecutionStatus -eq 'ArtifactCapturedDespiteProcessUncertainty') 'Usable artifacts are distinguished from confirmed process success'
    Assert-WudV200 ($uncertain.ExitCode -eq 1 -and -not [string]::IsNullOrWhiteSpace($uncertain.Detail)) 'Uncertain artifact result retains nonzero exit evidence'

    $collectorSource = Get-Content -LiteralPath (Join-Path $toolRoot 'Modules/Collectors.psm1') -Raw
    $doStart = $collectorSource.IndexOf('function Invoke-WudWindowsUpdateLogCollector')
    $doEnd = $collectorSource.IndexOf('function Invoke-WudEventCollector')
    $doSource = $collectorSource.Substring($doStart, $doEnd - $doStart)
    Assert-WudV200 ($doSource -match 'Get-DeliveryOptimizationPerfSnap' -and $doSource -match 'PeerInfo' -and $doSource -match 'PerformanceThisMonth') 'Final collector captures first-class Delivery Optimization status, peer, and performance data'
    Assert-WudV200 ($doSource -notmatch 'Get-DeliveryOptimization(?:Status|Log)[^\r\n]*catch\s*\{\s*\}') 'Delivery Optimization provider failures are not silently swallowed'
    Assert-WudV200 ($collectorSource.IndexOf("'raw-evidence'") -lt $collectorSource.IndexOf("'windows-update'")) 'Native evidence collection precedes readable conversion'

    $entrySource = Get-Content -LiteralPath (Join-Path $toolRoot 'Invoke-Win11UpgradeDiag.ps1') -Raw
    $persistenceSource = Get-Content -LiteralPath (Join-Path $toolRoot 'Modules/Persistence.psm1') -Raw
    $packageVersion = (Get-Content -LiteralPath (Join-Path $toolRoot 'VERSION') -Raw).Trim()
    Assert-WudV200 ($entrySource -match ('\$toolVersion\s*=\s*''' + [regex]::Escape($packageVersion) + '''') -and $entrySource -match 'FinalCollectionBoundary') 'Current entry point retains the v2 automatic final recorder boundary'
    Assert-WudV200 ($persistenceSource -match 'Recorder-' -and $persistenceSource -match 'Watch-Win11Upgrade\.ps1') 'Persistence registers the cross-reboot recorder task'

    Write-Host 'All v2 persistent-recorder fixture tests passed.' -ForegroundColor Cyan
}
finally {
    $env:SystemDrive = $oldSystemDrive
    $env:SystemRoot = $oldSystemRoot
    $env:ProgramData = $oldProgramData
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
