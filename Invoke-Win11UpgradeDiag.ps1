[CmdletBinding()]
param(
    [ValidateSet('Start', 'Resume', 'Finish', 'Analyze', 'Cancel')]
    [string]$Action = 'Start',

    [switch]$NoOpen,

    # Internal resume parameters. They are intentionally accepted by the same entry point
    # so the staged SYSTEM task never needs a second executable or script.
    [string]$RunId,
    [ValidateRange(0, 600)]
    [int]$DelaySeconds = 0,

    # Internal GUI diagnostic so failures before Collector.log exists are durable.
    [string]$BootstrapLogPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$toolVersion = '3.2.2'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetVersion = '25H2'
$OutputPath = $null
$CopyTo = $null
$MediaPath = $null
$AcceptWindowsEula = $false
$IncludeLargeDumps = $false
$NoInternet = $false
$NoSetupHooks = $false
$ArmDays = 30
$Mode = switch ($Action) {
    'Start'   { 'Preflight' }
    'Resume'  { 'Resume' }
    'Finish'  { 'Finalize' }
    'Analyze' { 'Forensic' }
    'Cancel'  { 'Disarm' }
}
$context = $null
$armedState = $null
$state = $null
$finalizationState = $null
$finalizationFinalStatus = $null
$runLock = $null

function Write-WudBootstrapLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([string]::IsNullOrWhiteSpace($BootstrapLogPath)) { return }
    try {
        $bootstrapParent = Split-Path -Parent $BootstrapLogPath
        if ($bootstrapParent -and -not [IO.Directory]::Exists($bootstrapParent)) { $null = [IO.Directory]::CreateDirectory($bootstrapParent) }
        $bootstrapLine = '{0} [{1}] {2}' -f [DateTime]::UtcNow.ToString('o'), $Level.ToUpperInvariant(), $Message
        [IO.File]::AppendAllText($BootstrapLogPath, $bootstrapLine + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
}

Write-WudBootstrapLog -Level INFO -Message ("Entry point started. Version={0}; Action={1}; PowerShell={2}; PID={3}; Elevated={4}" -f $toolVersion, $Action, $PSVersionTable.PSVersion, $PID, $(try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false }))

function Enter-WudRunLock {
    param([Parameter(Mandatory = $true)][string]$RunPath)
    $statePath = Join-Path $RunPath 'State'
    if (-not (Test-Path -LiteralPath $statePath)) { $null = New-Item -ItemType Directory -Path $statePath -Force }
    return [IO.File]::Open((Join-Path $statePath 'run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

$bundleManifest = Join-Path $toolRoot 'BundleManifest.sha256'
if (Test-Path -LiteralPath $bundleManifest) {
    try {
        foreach ($line in Get-Content -LiteralPath $bundleManifest) {
            if ($line -match '^\s*$|^\s*#') { continue }
            if ($line -notmatch '^([A-Fa-f0-9]{64})\s+\*?(.+)$') { throw "Malformed bundle manifest line: $line" }
            $expected = $matches[1].ToLowerInvariant()
            $relative = $matches[2].Trim()
            $candidate = Join-Path $toolRoot $relative
            if (-not (Test-Path -LiteralPath $candidate)) { throw "Bundle file is missing: $relative" }
            $actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $expected) { throw "Bundle integrity check failed for: $relative" }
        }
    }
    catch {
        Write-WudBootstrapLog -Level ERROR -Message $_.Exception.Message
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 40
    }
}

try {
    Import-Module (Join-Path $toolRoot 'Modules\Common.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\UpdateTracking.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\Recorder.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\Collectors.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\Analysis.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\Review.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\Report.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\Persistence.psm1') -Force -ErrorAction Stop
}
catch {
    Write-WudBootstrapLog -Level ERROR -Message ("Module load failed: {0}" -f $_.Exception.Message)
    Write-Host "WUPA modules could not be loaded: $($_.Exception.Message)" -ForegroundColor Red
    exit 40
}

if (-not (Test-WudIsWindows)) {
    Write-WudBootstrapLog -Level ERROR -Message 'Unsupported operating system: Windows is required.'
    Write-Host 'WUPA must run on Windows.' -ForegroundColor Red
    exit 50
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-WudBootstrapLog -Level ERROR -Message ("Unsupported PowerShell version: {0}" -f $PSVersionTable.PSVersion)
    Write-Host 'Windows PowerShell 5.1 or later is required.' -ForegroundColor Red
    exit 50
}
if (-not (Test-WudAdministrator)) {
    if (-not [Environment]::UserInteractive) {
        Write-Host 'WUPA requires an elevated administrator session.' -ForegroundColor Red
        exit 50
    }
    try {
        Write-WudBootstrapLog -Level INFO -Message 'Requesting UAC elevation.'
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $elevationArguments = New-Object Collections.ArrayList
        foreach ($token in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)) {
            $null = $elevationArguments.Add((ConvertTo-WudCommandLineArgument -Value ([string]$token)))
        }
        foreach ($name in @('Action', 'NoOpen', 'RunId', 'DelaySeconds', 'BootstrapLogPath')) {
            if (-not $PSBoundParameters.ContainsKey($name)) { continue }
            $value = $PSBoundParameters[$name]
            if ($value -is [Management.Automation.SwitchParameter]) {
                if ([bool]$value) { $null = $elevationArguments.Add("-$name") }
                continue
            }
            $null = $elevationArguments.Add("-$name")
            $null = $elevationArguments.Add((ConvertTo-WudCommandLineArgument -Value ([string]$value)))
        }
        $elevated = Start-Process -FilePath $powerShell -ArgumentList (@($elevationArguments) -join ' ') -Verb RunAs -Wait -PassThru -ErrorAction Stop
        Write-WudBootstrapLog -Level INFO -Message ("Elevated process completed with exit code {0}." -f $elevated.ExitCode)
        exit $elevated.ExitCode
    }
    catch {
        Write-WudBootstrapLog -Level ERROR -Message ("Elevation failed: {0}" -f $_.Exception.Message)
        Write-Host "Elevation was not completed: $($_.Exception.Message)" -ForegroundColor Red
        exit 50
    }
}

try {
    if ($Mode -eq 'Preflight' -and (Get-WudActiveRunState)) {
        throw 'WUPA is already tracking an update on this computer. Finish or cancel the active case before starting another.'
    }

    if ($Mode -eq 'Disarm') {
        $state = Get-WudActiveRunState
        if (-not $state) {
            Write-Host 'No active WUPA case is being tracked.'
            exit 0
        }
        $context = New-WudRunContext -ToolRoot $toolRoot -ToolVersion $toolVersion -RunId $state.RunId -RunPath $state.RunPath -OutputPath $state.OutputPath -Mode 'Disarm' -PhaseLabel 'Disarm' -TargetVersion $state.TargetVersion -CopyTo $state.CopyTo -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps ([bool]$state.IncludeLargeDumps) -NoInternet ([bool]$state.NoInternet) -NoSetupHooks ([bool]$state.NoSetupHooks) -ArmDays $ArmDays
        try { $runLock = Enter-WudRunLock -RunPath $context.RunPath }
        catch { Write-Host 'The active diagnostic run is busy. Wait for its current collector or resume pass to finish, then run Disarm again.' -ForegroundColor Yellow; exit 10 }
        Write-WudLog -Context $context -Level INFO -Message "Disarming run $($state.RunId). Evidence will be retained."
        $null = Remove-WudPersistence -Context $context -State $state -FinalStatus 'Disarmed'
        exit 0
    }

    try { $targetDefinition = Get-WudTargetDefinition -ToolRoot $toolRoot -TargetVersion $TargetVersion }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 50 }
    try {
        $supportedOs = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ([string]$supportedOs.Caption -notmatch '(?i)Windows 11') { Write-Host "Unsupported operating system: $($supportedOs.Caption). Windows 11 is required." -ForegroundColor Red; exit 50 }
        if ([int]$supportedOs.BuildNumber -lt [int]$targetDefinition.minimumSourceBuild) { Write-Host "Unsupported Windows build $($supportedOs.BuildNumber). Minimum supported source build is $($targetDefinition.minimumSourceBuild)." -ForegroundColor Red; exit 50 }
    }
    catch {
        Write-Host "Windows version validation failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 50
    }

    if ($Mode -in @('Resume', 'Finalize')) {
        $state = Get-WudActiveRunState
        if ($RunId -and (-not $state -or $state.RunId -ne $RunId)) {
            $candidateRunPath = Join-Path (Get-WudProgramDataRoot) ("Runs\{0}" -f $RunId)
            if (Test-Path -LiteralPath $candidateRunPath) { $state = Get-WudRunState -RunPath $candidateRunPath }
        }
        if (-not $state) { throw "$Action was requested, but no matching tracked case was found. Use Analyze for an after-the-fact collection." }
        if ($RunId -and $state.RunId -ne $RunId) { throw "Active run '$($state.RunId)' does not match requested run '$RunId'." }
        $TargetVersion = [string]$state.TargetVersion
        $context = New-WudRunContext -ToolRoot $toolRoot -ToolVersion $toolVersion -RunId $state.RunId -RunPath $state.RunPath -OutputPath $state.OutputPath -Mode $Mode -PhaseLabel $Mode -TargetVersion $TargetVersion -CopyTo $state.CopyTo -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps ([bool]$state.IncludeLargeDumps) -NoInternet ([bool]$state.NoInternet) -NoSetupHooks ([bool]$state.NoSetupHooks) -ArmDays $ArmDays
        try { $runLock = Enter-WudRunLock -RunPath $context.RunPath }
        catch { Write-Host 'Automatic post-reboot finalization or another WUPA process is already handling this run. Wait for the active pass to finish; do not delete State\run.lock.'; exit 10 }
        if ([string]$state.Status -eq 'AwaitingInteractiveCopy') {
            if (-not (Test-WudInteractiveUser)) {
                Write-WudLog -Context $context -Level INFO -Message 'The diagnostic report is complete and is waiting for an interactive technician token to perform the requested UNC copy.'
                exit 10
            }
            $copyResult = Copy-WudOutputToShare -Context $context
            if ($copyResult.Succeeded) {
                Complete-WudDeferredCopyState -Context $context -State $state
                $savedExitCode = if ($state.PSObject.Properties['FinalExitCode']) { [int]$state.FinalExitCode } else { 0 }
                Write-Host ("Deferred copy completed: {0}" -f $copyResult.Destination) -ForegroundColor Cyan
                $savedReport = Join-Path $context.OutputPath 'Report.html'
                if (-not $NoOpen -and (Test-Path -LiteralPath $savedReport)) { Start-Process -FilePath $savedReport | Out-Null }
                exit $savedExitCode
            }
            Write-WudLog -Context $context -Level WARN -Message 'The requested UNC copy is still pending. The local report remains valid and the active pointer was retained.'
            exit 10
        }
        if ($Mode -eq 'Resume') {
            if ([DateTime]::UtcNow -gt (ConvertTo-WudUtcDateTime $state.ExpiresUtc)) {
                Write-WudLog -Context $context -Level WARN -Message 'The armed diagnostic run expired before a stable upgrade outcome was observed.'
                $null = Remove-WudPersistence -Context $context -State $state -FinalStatus 'Expired'
                exit 10
            }
            if ($DelaySeconds -gt 0) {
                Write-WudLog -Context $context -Level INFO -Message "Delaying resume collection for $DelaySeconds seconds to allow Windows services to settle."
                Start-Sleep -Seconds $DelaySeconds
            }
            if (Test-WudSetupInProgress) {
                Write-WudLog -Context $context -Level INFO -Message 'Windows Setup is still active. This resume pass will defer collection until a later startup or daily trigger.'
                exit 10
            }
            $resumeSignal = Get-WudResumeSignal -State $state
            Write-WudJsonAtomic -Path (Join-Path $context.RunPath 'State\last-resume-signal.json') -InputObject $resumeSignal -Depth 10
            if (-not $resumeSignal.Ready) {
                Write-WudLog -Context $context -Level INFO -Message 'No target-build transition, owned hook marker, rollback source, or terminal Windows Update/Setup result newer than the baseline was detected. The run remains armed.'
                exit 10
            }
            Write-WudLog -Context $context -Level INFO -Message ("Resume collection was authorized by: {0}" -f (@($resumeSignal.Signals | ForEach-Object Kind) -join ', '))
        }
        else {
            $setupActiveAtRequest = Test-WudSetupInProgress
            try { $resumeSignal = Get-WudResumeSignal -State $state }
            catch {
                $resumeSignal = [pscustomobject][ordered]@{
                    Ready = $false; CurrentIdentity = $null; Signals = @()
                    Providers = @([pscustomobject]@{ Provider = 'Operator finalization signal evaluation'; Status = 'Failed'; Error = (Get-WudErrorDetail -ErrorRecord $_) })
                    EvaluatedUtc = [DateTime]::UtcNow.ToString('o')
                }
            }
            $operatorName = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { [Environment]::UserName }
            $operatorFinalization = [pscustomobject][ordered]@{
                SchemaVersion = 1
                ToolVersion = $toolVersion
                RunId = $state.RunId
                RequestedUtc = [DateTime]::UtcNow.ToString('o')
                RequestedBy = $operatorName
                OriginalStateStatus = [string]$state.Status
                ArmExpiredAtRequest = [DateTime]::UtcNow -gt (ConvertTo-WudUtcDateTime $state.ExpiresUtc)
                SetupActiveAtRequest = [bool]$setupActiveAtRequest
                AutomaticTerminalSignalPresent = [bool]$resumeSignal.Ready
                AutomaticSignalEvaluation = $resumeSignal
                OverrideScope = 'The operator explicitly requested final collection. Automatic terminal-signal and Setup-in-progress gates were recorded but did not block finalization.'
            }
            Write-WudJsonAtomic -Path (Join-Path $context.RunPath 'State\operator-finalize.json') -InputObject $operatorFinalization -Depth 20
            $state | Add-Member -NotePropertyName OperatorFinalization -NotePropertyValue $operatorFinalization -Force
            Save-WudRunState -Context $context -State $state -SetActive $true
            if ($setupActiveAtRequest) {
                Write-WudLog -Context $context -Level WARN -Message 'Operator finalization was explicitly requested while Windows Setup is active. The result will be a mid-flight factual snapshot, and persistent monitoring will be removed after the report is created.'
            }
            elseif ($resumeSignal.Ready) {
                Write-WudLog -Context $context -Level INFO -Message ("Operator finalization requested; automatic terminal evidence was also present: {0}" -f (@($resumeSignal.Signals | ForEach-Object Kind) -join ', '))
            }
            else {
                Write-WudLog -Context $context -Level WARN -Message 'Operator finalization was explicitly requested without an automatic terminal signal. The report will preserve the observed state and will not infer success or failure.'
            }
        }
    }
    else {
        if (-not $RunId) { $RunId = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8) }
        $programRoot = Get-WudProgramDataRoot
        $runPath = Join-Path $programRoot ("Runs\{0}" -f $RunId)
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $OutputPath = Get-WudPublicDocumentsPath
        }
        $leaf = 'WUPA-{0}-{1}' -f $env:COMPUTERNAME, $RunId
        $finalOutput = Join-Path ([IO.Path]::GetFullPath($OutputPath)) $leaf
        $phaseLabel = if ($Mode -eq 'Preflight') { 'Preflight' } else { 'Forensic' }
        $context = New-WudRunContext -ToolRoot $toolRoot -ToolVersion $toolVersion -RunId $RunId -RunPath $runPath -OutputPath $finalOutput -Mode $Mode -PhaseLabel $phaseLabel -TargetVersion $TargetVersion -CopyTo $CopyTo -MediaPath $MediaPath -AcceptWindowsEula ([bool]$AcceptWindowsEula) -IncludeLargeDumps ([bool]$IncludeLargeDumps) -NoInternet ([bool]$NoInternet) -NoSetupHooks ([bool]$NoSetupHooks) -ArmDays $ArmDays
        $runLock = Enter-WudRunLock -RunPath $context.RunPath
    }

    Write-WudLog -Context $context -Level INFO -Message "WUPA $toolVersion starting action $Action for target $TargetVersion."
    Write-WudLog -Context $context -Level WARN -Message 'Outputs are full-fidelity and sensitive. No repair or upgrade action will be executed.'

    try {
        $systemDisk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        if ([long]$systemDisk.FreeSpace -lt [long]$context.Settings.minimumStagingReserveBytes) {
            $context.CollectionComplete = $false
            Write-WudLog -Context $context -Level WARN -Message 'Less than the configured staging reserve is available. Collection will continue, but large copies may fail and coverage will be marked incomplete.'
        }
    }
    catch { }
    try {
        $outputDriveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($context.OutputPath))
        $outputDrive = New-Object IO.DriveInfo($outputDriveRoot)
        if ([long]$outputDrive.AvailableFreeSpace -lt [long]$context.Settings.minimumStagingReserveBytes) {
            $context.CollectionComplete = $false
            Write-WudLog -Context $context -Level WARN -Message 'The output volume has less than the configured reserve. Final archive generation may be incomplete.'
        }
    }
    catch { }

    if ($Mode -in @('Resume', 'Finalize')) {
        $stopResult = Stop-WudRecorderTask -State $state
        Write-WudLog -Context $context -Level INFO -Message ("Persistent recorder stop request: {0}." -f $stopResult.Status)
        $lockPath = Join-Path $context.RunPath 'State\recorder.lock'
        $lockDeadline = [DateTime]::UtcNow.AddSeconds(15)
        $recorderLockReleased = -not (Test-Path -LiteralPath $lockPath)
        while ((Test-Path -LiteralPath $lockPath) -and [DateTime]::UtcNow -lt $lockDeadline) {
            $probeLock = $null
            try {
                $probeLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $recorderLockReleased = $true
                break
            }
            catch { Start-Sleep -Milliseconds 500 }
            finally { if ($probeLock) { $probeLock.Dispose() } }
        }
        if (-not $recorderLockReleased) { throw 'The persistent recorder did not release its per-run lock within 15 seconds. Final collection was not started, and the recorder will be made retryable.' }
        $boundaryReason = if ($Mode -eq 'Finalize') { 'OperatorFinalizationBoundary' } else { 'FinalCollectionBoundary' }
        $null = Invoke-WudRecorderSample -RunPath $context.RunPath -TargetVersion $context.TargetVersion -TargetBuild ([int]$context.Target.buildFamily) -Reason $boundaryReason -ProgressBucketSize ([int]$context.Settings.recorder.progressBucketPercent) -MaximumCheckpoints ([int]$context.Settings.recorder.maximumCheckpoints) -MaximumCheckpointFileBytes ([long]$context.Settings.recorder.maximumCheckpointFileBytes) -MaximumCheckpointBytes ([long]$context.Settings.recorder.maximumCheckpointBytes) -ForceCheckpoint
    }
    else {
        $reason = if ($Mode -eq 'Preflight') { 'PreflightBaseline' } else { 'ForensicSnapshot' }
        $null = Invoke-WudRecorderSample -RunPath $context.RunPath -TargetVersion $context.TargetVersion -TargetBuild ([int]$context.Target.buildFamily) -Reason $reason -ProgressBucketSize ([int]$context.Settings.recorder.progressBucketPercent) -MaximumCheckpoints ([int]$context.Settings.recorder.maximumCheckpoints) -MaximumCheckpointFileBytes ([long]$context.Settings.recorder.maximumCheckpointFileBytes) -MaximumCheckpointBytes ([long]$context.Settings.recorder.maximumCheckpointBytes) -ForceCheckpoint
    }
    Invoke-WudAllCollectors -Context $context
    $recorderRead = Read-WudJsonLines -Path (Join-Path $context.RunPath 'Evidence\Recorder\ProgressSamples.jsonl')
    $context.Recorder = Get-WudRecorderTelemetrySummary -Samples @($recorderRead.Records)
    if (@($recorderRead.InvalidLines).Count -gt 0) {
        $null = Add-WudCollectionGap -Context $context -Collector 'recorder' -Source $recorderRead.Path -Status 'InvalidOrTruncatedJsonLine' -Detail ("{0} JSONL line(s) could not be parsed; valid records were retained." -f @($recorderRead.InvalidLines).Count)
    }
    $null = Invoke-WudFactAnalysis -Context $context

    if ($Mode -eq 'Preflight') {
        $armedState = Install-WudPersistence -Context $context
        $context.Inventory['Persistence'] = $armedState
        if ($armedState.SetupConfig -and $armedState.SetupConfig.InvalidFormat) {
            $null = Add-WudCollectionGap -Context $context -Collector 'persistence' -Source $armedState.SetupConfig.ConfigPath -Status 'SetupConfigInvalid' -Detail 'The existing SetupConfig did not have a supported [SetupConfig] header; no setup hooks were added.'
        }
        if ($armedState.SetupConfig) {
            foreach ($conflict in @($armedState.SetupConfig.Conflicts)) {
                $null = Add-WudCollectionGap -Context $context -Collector 'persistence' -Source $armedState.SetupConfig.ConfigPath -Status 'SetupConfigConflict' -Detail ("{0} retained existing value: {1}" -f $conflict.Key, $conflict.Existing)
            }
        }
        Write-WudLog -Context $context -Level INFO -Message "Automatic follow-up is armed until $($armedState.ExpiresUtc)."

        # Preflight is the beginning of a persistent case, not a completed
        # investigation. Start the recorder and commit a small status receipt,
        # but deliberately do not create Report.html, ReviewBundle.zip,
        # Evidence.zip, or any other finalized artifact. Resume, Finalize, and
        # Forensic are the only modes allowed to publish a report package.
        $recorderStart = Start-WudRecorderTask -State $armedState
        $armedState | Add-Member -NotePropertyName RecorderStart -NotePropertyValue $recorderStart -Force
        if ($recorderStart.Status -ne 'Started') {
            $null = Add-WudCollectionGap -Context $context -Collector 'persistence' -Source $armedState.RecorderTask.FullName -Status 'RecorderStartFailed' -Detail ([string]$recorderStart.Error) -Impact 'Material'
        }
        $context.Outcome = 'Monitoring Armed'
        $context.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        $context.ExitCode = if ($context.CollectionComplete -and $recorderStart.Status -eq 'Started') { 0 } else { 30 }
        $receiptPath = Join-Path $context.RunPath 'State\preflight-status.json'
        $receipt = [pscustomobject][ordered]@{
            SchemaVersion      = 1
            ToolVersion        = $toolVersion
            RunId              = $context.RunId
            Status             = 'MonitoringArmed'
            TargetVersion      = $context.TargetVersion
            TargetBuild        = $context.Target.buildFamily
            BaselineCompletedUtc = $context.CompletedUtc
            ExpiresUtc         = $armedState.ExpiresUtc
            RunPath            = $context.RunPath
            OutputPath         = $context.OutputPath
            RecorderStart      = $recorderStart
            CollectionComplete = $context.CollectionComplete
            ExitCode           = $context.ExitCode
            FinalReportCreated = $false
            FinalReportReason  = 'The final report is created only after automatic Resume, explicit Finalize, or Forensic collection.'
            CollectorRecords   = @($context.CollectorRecords)
            CollectionGaps     = @($context.CollectionGaps)
        }
        Write-WudJsonAtomic -Path $receiptPath -InputObject $receipt -Depth 30
        $armedState | Add-Member -NotePropertyName PreflightStatusPath -NotePropertyValue $receiptPath -Force
        $armedState | Add-Member -NotePropertyName PreflightCompletedUtc -NotePropertyValue $context.CompletedUtc -Force
        $armedState | Add-Member -NotePropertyName PreflightExitCode -NotePropertyValue ([int]$context.ExitCode) -Force
        Save-WudRunState -Context $context -State $armedState -SetActive $true
        if ($recorderStart.Status -eq 'Started') {
            Write-WudLog -Context $context -Level INFO -Message 'Persistent 60-second progress recorder started. No final report was created because the monitored upgrade has not finished.'
        }
        else {
            Write-WudLog -Context $context -Level WARN -Message ("Persistent recorder did not start immediately: {0}" -f $recorderStart.Error)
        }
        Write-WudBootstrapLog -Level INFO -Message ("Preflight committed. RunId={0}; ExitCode={1}; RunPath={2}; FinalReportCreated=False" -f $context.RunId, $context.ExitCode, $context.RunPath)
        Write-Host ''
        Write-Host 'Monitoring armed. The final report will be created after the upgrade reaches a terminal state or an operator selects Finalize.' -ForegroundColor Cyan
        Write-Host ("Run ID: {0}" -f $context.RunId)
        Write-Host ("Durable evidence: {0}" -f $context.RunPath)
        Write-Host ("Armed until: {0}" -f $armedState.ExpiresUtc)
        exit ([int]$context.ExitCode)
    }
    elseif ($Mode -in @('Resume', 'Finalize')) {
        $finalizationState = Get-WudRunState -RunPath $context.RunPath
        $context.Inventory['Persistence'] = $finalizationState
        $finalizationFinalStatus = if ($context.Outcome -eq 'Upgrade Succeeded') { 'CompletedSuccess' } elseif ($context.Outcome -eq 'Rolled Back') { 'CompletedRollback' } elseif ($context.Outcome -eq 'Failed') { 'CompletedFailure' } elseif ($Mode -eq 'Finalize') { 'CompletedOperatorFinalized' } else { 'CompletedForensic' }
    }

    $reportPath = Export-WudReportArtifacts -Context $context
    if ($Mode -in @('Resume', 'Finalize')) {
        $deferCopy = -not [string]::IsNullOrWhiteSpace($context.CopyTo) -and (-not $context.LastCopyResult -or -not $context.LastCopyResult.Succeeded)
        if ($deferCopy) {
            $finalizationFinalStatus = 'AwaitingInteractiveCopy'
            $finalizationState | Add-Member -NotePropertyName FinalExitCode -NotePropertyValue ([int]$context.ExitCode) -Force
        }
        $null = Remove-WudPersistence -Context $context -State $finalizationState -FinalStatus $finalizationFinalStatus -KeepActivePointer $deferCopy
    }
    Write-WudLog -Context $context -Level INFO -Message "Report complete: $reportPath"
    Write-WudBootstrapLog -Level INFO -Message ("Report complete. ExitCode={0}; Artifacts={1}" -f $context.ExitCode, $context.OutputPath)
    Write-Host ''
    Write-Host ("Outcome: {0}" -f $context.Outcome) -ForegroundColor Cyan
    Write-Host ("Exit code: {0}" -f $context.ExitCode)
    Write-Host ("Artifacts: {0}" -f $context.OutputPath)

    if (-not $NoOpen -and (Test-WudInteractiveUser) -and (Test-Path -LiteralPath $reportPath)) {
        Start-Process -FilePath $reportPath | Out-Null
    }
    exit ([int]$context.ExitCode)
}
catch {
    $message = $_.Exception.Message
    $detail = try { Get-WudErrorDetail -ErrorRecord $_ } catch { ($_ | Out-String) }
    Write-WudBootstrapLog -Level ERROR -Message ("Fatal tool failure: {0}" -f $detail)
    if ($context) {
        $context.CollectionComplete = $false
        try { Write-WudLog -Context $context -Level ERROR -Message ("Fatal tool failure: {0}" -f $detail) } catch { }
        if ($armedState) {
            try { $null = Remove-WudPersistence -Context $context -State $armedState -FinalStatus 'ToolFailureDisarmed' } catch { }
        }
        elseif ($Mode -in @('Resume', 'Finalize') -and $state) {
            try {
                $restart = Start-WudRecorderTask -State $state
                Write-WudLog -Context $context -Level WARN -Message ("Final collection failed; recorder restart status is {0} so the armed run can be retried." -f $restart.Status)
            }
            catch { }
        }
        try {
            $failurePath = Join-Path $context.OutputPath 'Failure.txt'
            Write-WudText -Path $failurePath -Text ("WUPA encountered a fatal tool failure.`r`n`r`n$detail`r`n`r`n$($_ | Out-String)")
        }
        catch { }
    }
    else { Write-Host $message -ForegroundColor Red }
    exit 40
}
