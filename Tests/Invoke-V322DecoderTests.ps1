[CmdletBinding()]
param([string]$DatasetZip)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($name in @('Common', 'UpdateTracking', 'Recorder', 'Collectors', 'Analysis', 'Review', 'Report')) { Import-Module (Join-Path $toolRoot ("Modules/{0}.psm1" -f $name)) -Force -DisableNameChecking }
function Assert-Decoder { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('WUPA-Decoder322-' + [Guid]::NewGuid().ToString('N'))
$ctx = New-WudRunContext -ToolRoot $toolRoot -ToolVersion '3.2.2-test' -RunId 'decoder' -RunPath (Join-Path $fixture 'run') -OutputPath (Join-Path $fixture 'out') -Mode 'Forensic' -PhaseLabel 'Forensic' -TargetVersion '25H2' -CopyTo $null -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
$id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$ctx.Inventory['Identity'] = [pscustomobject]@{ DisplayVersion = '25H2'; CurrentBuild = '26200'; TimeZone = 'UTC'; WindowsImageState = 'IMAGE_STATE_COMPLETE' }
function New-DecoderEvent {
    param([int]$EventId, [string]$Utc, [string]$Keywords, [string]$UpdateId = $id, [string]$Title = 'Windows 11, version 25H2')
    $xml = '<Event><System><Provider Name="Microsoft-Windows-WindowsUpdateClient"/><EventID>{0}</EventID><Keywords>{1}</Keywords><TimeCreated SystemTime="{2}"/><EventRecordID>{0}</EventRecordID><Channel>System</Channel></System><EventData><Data Name="updateTitle">{3}</Data><Data Name="updateGuid">{4}</Data><Data Name="updateRevisionNumber">1</Data></EventData></Event>' -f $EventId, $Keywords, $Utc, $Title, $UpdateId
    ConvertFrom-WudUpdateEventXml $xml ('fixture:event-' + $EventId)
}
$start = New-DecoderEvent 44 '2026-10-05T10:00:00Z' '0x8000000000002004'
$end = New-DecoderEvent 41 '2026-10-05T10:02:00Z' '0x4000000000000014'
$install = New-DecoderEvent 43 '2026-10-05T10:03:00Z' '0x8000000000002008'
$lock = Resolve-WudUpgradeIdentity @($start, $end, $install)
$success = [pscustomobject]@{ DateUtc = '2026-10-05T11:00:00Z'; Operation = '1'; ResultCode = '2'; SourceRef = 'fixture:history'; UpdateID = $id; RevisionNumber = 1 }
$ctx.UpgradeTracking = [pscustomobject]@{ Identity = $lock; MatchedEvents = @($start, $end, $install); MatchedHistory = @($success) }
$timing = Get-WudUpgradeTimingModel $ctx $ctx.UpgradeTracking -IncludeRecorderObservations $false
Assert-Decoder ($end.Boundary -eq 'DownloadCompleted' -and $timing.Sessions[0].ElapsedSeconds -eq 120) 'Actual event 41 success/download keyword closes the matching download interval'
Assert-Decoder ($null -eq $timing.Sessions[1].EndUtc -and $null -eq $timing.Sessions[1].ElapsedSeconds) 'History success does not manufacture an exact installation or reboot boundary'
$status = Get-WudUpgradeStatusModel $ctx $ctx.Inventory['Identity'] @($success)
Assert-Decoder ($status.AttemptOutcome -eq 'WindowsUpdateReportedSucceeded' -and -not $status.UnclosedTargetStartRecorded) 'Later history success supersedes the stale archived installation start'
$driver = New-DecoderEvent 43 '2026-10-05T12:00:00Z' '0x8000000000002008' 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' 'HP Inc. Extension Driver Update (1.1.3.0)'
Assert-Decoder (-not (Test-WudUpgradeIdentityMatch $driver $lock)) 'Concurrent HP driver update cannot change target upgrade outcome'
$retry = New-DecoderEvent 43 '2026-10-05T12:00:00Z' '0x8000000000002008'
$ctx.UpgradeTracking.MatchedEvents = @($start, $end, $install, $retry)
$sourceOs = [pscustomobject]@{ DisplayVersion = '23H2'; CurrentBuild = '22631' }
Assert-Decoder ((Get-WudUpgradeStatusModel $ctx $sourceOs @($success)).AttemptOutcome -eq 'InProgress') 'A newer target retry is not hidden by older successful history'
Assert-Decoder ((Get-WudUpgradeStatusModel $ctx $ctx.Inventory['Identity'] @($success)).OutcomeBanner -eq 'Target OS Present') 'Unclosed historical start alone cannot claim an already-target device is upgrading'
$failure = New-DecoderEvent 20 '2026-10-05T12:05:00Z' '0x8000000000000028'
$ctx.UpgradeTracking.MatchedEvents = @($start, $end, $install, $retry, $failure)
Assert-Decoder ((Get-WudUpgradeStatusModel $ctx $ctx.Inventory['Identity'] @($success)).AttemptOutcome -eq 'Failed') 'Newer exact-target failure is not hidden by an earlier success result'
$badTime = New-DecoderEvent 20 '2026-10-05T12:05:00Z' '0x8000000000000028'
$badTime.TimestampUtc = 'invalid timestamp'
$badHistory = [pscustomobject]@{ DateUtc = 'invalid timestamp'; Operation = '1'; ResultCode = '4'; SourceRef = 'fixture:bad-time' }
$ctx.UpgradeTracking.MatchedEvents = @($start, $end, $install, $badTime)
Assert-Decoder ((Get-WudUpgradeStatusModel $ctx $ctx.Inventory['Identity'] @($success, $badHistory)).AttemptOutcome -eq 'WindowsUpdateReportedSucceeded') 'Malformed timestamps cannot crash reconciliation or supersede an ordered terminal result'

$probe = Join-Path $ctx.SnapshotPath 'WindowsUpdate/WindowsUpdate.log'
Write-WudText $probe "Checking write access`r`n"
Assert-Decoder ((Test-WudDecodedWindowsUpdateLog $probe).Status -eq 'WriteAccessProbeOnly') 'Exact 23-byte decoder permission probe is rejected as diagnostic evidence'
$parsed = Read-WudWindowsUpdateLogRecords $ctx
Assert-Decoder ($parsed.Coverage[0].Status -eq 'WriteAccessProbeOnly' -and $parsed.Coverage[0].ParsedLines -eq 0 -and -not $ctx.CollectionComplete) 'Parser does not mislabel permission probe as Parsed with zero target records'
Write-WudText $probe '2026/10/05 10:00:00.1234567 1 2 Agent Unrelated scan status without an UpdateID'
Assert-Decoder ((Test-WudDecodedWindowsUpdateLog $probe).Valid) 'Valid diagnostic log is accepted even when no target GUID appears'
Write-WudText $probe 'No usable diagnostic records'
Assert-Decoder ((Test-WudDecodedWindowsUpdateLog $probe).Status -eq 'NoDecodedRecords') 'Non-diagnostic output is explicitly classified'
Assert-Decoder ((Test-WudDecodedWindowsUpdateLog (Join-Path $fixture 'absent.log')).Status -eq 'MissingOutput') 'Missing decoded output is explicit'

# Exercise the real child-process/quoting/precheck/result path. Only the decoder
# itself is substituted with a small module emulating its filename validation.
$fakeModule = Join-Path $fixture 'DecoderFixture.psm1'
Write-WudText $fakeModule @'
function Get-WindowsUpdateLog {
    [CmdletBinding()]
    param([string[]]$ETLPath, [string]$LogPath)
    [IO.File]::WriteAllText($LogPath, "Checking write access`r`n")
    foreach ($path in $ETLPath) {
        if (-not (Test-Path -LiteralPath $path) -or [IO.Path]::GetFileName($path) -notlike 'WindowsUpdate*.etl') { throw "ETL File not found: $path" }
    }
    if ($env:WUPA_DECODER_FIXTURE_MODE -eq 'Fail') { throw 'Injected decoder failure after output probe.' }
    if ($env:WUPA_DECODER_FIXTURE_MODE -ne 'ProbeOnly') {
        [IO.File]::WriteAllText($LogPath, "2026/10/05 10:00:00.1234567 1 2 Agent Diagnostic fixture record`r`n")
    }
    if ($env:WUPA_DECODER_FIXTURE_MODE -eq 'Partial') { throw 'Injected failure after partial diagnostic output.' }
}
Export-ModuleMember Get-WindowsUpdateLog
'@
$oldSystemRoot = $env:SystemRoot; $oldMode = $env:WUPA_DECODER_FIXTURE_MODE
try {
    if (-not $env:SystemRoot) { $env:SystemRoot = $fixture }
    & (Get-Module Collectors) {
        param($modulePath, $executable)
        $script:DecoderFixtureModule = $modulePath; $script:DecoderFixtureExecutable = $executable
        function script:Invoke-WudProcess {
            param($Context, $FilePath, $ArgumentList, $Name, $TimeoutSeconds, $ExpectedArtifacts)
            $argsCopy = @($ArgumentList)
            $argsCopy[-1] = "Import-Module '" + $script:DecoderFixtureModule.Replace("'", "''") + "' -Force; " + $argsCopy[-1]
            Common\Invoke-WudProcess -Context $Context -FilePath $script:DecoderFixtureExecutable -ArgumentList $argsCopy -Name $Name -TimeoutSeconds $TimeoutSeconds -ExpectedArtifacts $ExpectedArtifacts
        }
    } $fakeModule (Get-Process -Id $PID).Path
    foreach ($name in @('Raw/WindowsUpdate-ETL/WindowsUpdate.1.etl', 'Raw/WindowsUpdate-ETL/WindowsUpdate.2.etl.old', 'Raw/WindowsOld-WindowsUpdate-ETL/WindowsUpdate.1.etl.bak')) { Write-WudText (Join-Path $ctx.SnapshotPath $name) 'Synthetic input, not a native ETL.' }
    foreach ($mode in @('Valid', 'Fail', 'Partial', 'ProbeOnly')) {
        $env:WUPA_DECODER_FIXTURE_MODE = $mode
        & (Get-Module Collectors) { param($c) Invoke-WudWindowsUpdateLogDecode $c } $ctx
        $conversions = Read-WudJson (Join-Path $ctx.SnapshotPath 'WindowsUpdate/conversion-inputs.json')
        foreach ($conversion in $conversions.Sets) {
            Assert-Decoder ($conversion.InputMappings.Count -ge 1 -and @($conversion.InputMappings | Where-Object StagedName -notlike 'WindowsUpdate*.etl').Count -eq 0) 'Staged rotated inputs keep decoder-compatible names and original-source mappings'
            if ($mode -eq 'Valid') { Assert-Decoder ($conversion.Status -eq 'Succeeded' -and $conversion.ExitCode -eq 0 -and $conversion.OutputValidation.Valid) 'Child decoder verifies staged files and returns real diagnostic output' }
            elseif ($mode -eq 'Fail') { Assert-Decoder ($conversion.Status -eq 'ExitedNonzero' -and $conversion.ExitCode -eq 1 -and $conversion.Error -match 'Injected decoder failure' -and $conversion.OutputValidation.Status -eq 'WriteAccessProbeOnly') 'Known failed decoder retains exit code, stderr, and rejected output content' }
            elseif ($mode -eq 'Partial') { Assert-Decoder ($conversion.Status -eq 'ExitedNonzero' -and $conversion.ExitCode -eq 1 -and $conversion.OutputValidation.Valid) 'Usable partial output never upgrades a known failed decoder into a successful conversion' }
            else { Assert-Decoder ($conversion.Status -eq 'InvalidDecodedOutput' -and $conversion.ExitCode -eq 0) 'Even exit zero cannot validate a permission-probe-only output' }
        }
        $parsedConversion = Read-WudWindowsUpdateLogRecords $ctx
        if ($mode -eq 'Partial') { Assert-Decoder (@($parsedConversion.Coverage | Where-Object { $_.Status -eq 'ParsedPartialDecode' -and $_.DecodeExitCode -eq 1 }).Count -eq 2) 'Parser labels usable partial current/Windows.old conversion with its actual failed exit code' }
        if ($mode -eq 'Valid') { Assert-Decoder (@($parsedConversion.Coverage | Where-Object Status -eq 'Parsed').Count -eq 2) 'Complete valid current/Windows.old conversions remain cleanly parsed' }
    }
} finally { $env:SystemRoot = $oldSystemRoot; $env:WUPA_DECODER_FIXTURE_MODE = $oldMode }
Assert-Decoder (@(Get-ChildItem (Join-Path $ctx.RunPath 'DecodeScratch') -Directory).Count -eq 0) 'Only owned scratch folders are cleaned after completed decoding; original ETLs remain'

# Run the actual analysis/export pipeline, not just a string-template assertion.
$reportCtx = New-WudRunContext -ToolRoot $toolRoot -ToolVersion '3.2.2-test' -RunId 'report' -RunPath (Join-Path $fixture 'report-run') -OutputPath (Join-Path $fixture 'report-out') -Mode 'Forensic' -PhaseLabel 'Forensic' -TargetVersion '25H2' -CopyTo $null -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
$reportCtx.Inventory['Identity'] = $ctx.Inventory['Identity']
$reportCtx.Inventory['Servicing'] = [pscustomobject]@{ UpdateHistory = @([pscustomobject]@{ DateUtc = $success.DateUtc; Title = 'Windows 11, version 25H2'; Operation = '1'; ResultCode = '2'; HResultHex = '0x00000000'; UpdateID = $id; RevisionNumber = 1; ServiceID = $null }) }
Write-WudJsonAtomic (Join-Path $reportCtx.SnapshotPath 'Events/update-lifecycle-events.json') ([pscustomobject]@{ Records = @($start, $end, $install); Providers = @() })
Write-WudText (Join-Path $reportCtx.SnapshotPath 'WindowsUpdate/WindowsUpdate.log') "Checking write access`r`n"
$null = Invoke-WudFactAnalysis $reportCtx
$reportPath = Export-WudReportArtifacts $reportCtx
$reportHtml = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
$reportSummary = Read-WudJson (Join-Path $reportCtx.OutputPath 'Summary.json')
Assert-Decoder ($reportSummary.StatusModel.AttemptOutcome -eq 'WindowsUpdateReportedSucceeded' -and $reportSummary.UpgradeTiming.Sessions[0].ElapsedSeconds -eq 120 -and $null -eq $reportSummary.UpgradeTiming.Sessions[1].EndUtc) 'Actual exported summary retains download facts, recorded success, and unknown installation completion independently'
Assert-Decoder ($reportHtml.Contains('Not retained') -and $reportHtml.Contains('Not calculable') -and $reportHtml.Contains('EndBoundaryNotRetained') -and $reportHtml.Contains('WriteAccessProbeOnly') -and -not $reportHtml.Contains('<h1>Upgrade In Progress</h1>')) 'Actual HTML exposes unavailable timings and rejected decoder coverage without claiming active upgrade'
Assert-Decoder ($reportCtx.ExitCode -eq 30) 'Known decoder evidence gap still marks the completed report materially incomplete'
Write-Output "PASS: decoder/status report fixture: $reportPath"

if ((Test-WudIsWindows) -and $PSVersionTable.PSVersion.Major -eq 5) {
    # Query the actual OS module's private input enumeration without decoding
    # synthetic data, flushing logs, or stopping any Windows service.
    Import-Module WindowsUpdate -Force
    $nativeInput = Join-Path $fixture 'WindowsUpdate.00001.etl'
    Write-WudText $nativeInput 'Native filename-enumeration fixture only.'
    $nativeInputs = & (Get-Module WindowsUpdate) {
        param($path)
        # Some Windows builds define this helper inside Get-WindowsUpdateLog,
        # not at module scope. Execute its actual OS-supplied AST body rather
        # than assuming an undocumented private command is directly exported.
        $publicCommand = Get-Command Get-WindowsUpdateLog
        $definitions = @($publicCommand.ScriptBlock.Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'GetListOfETLs' }, $true))
        if ($definitions.Count -ne 1) { throw 'The native decoder input-enumeration helper could not be uniquely located.' }
        $enumerate = $definitions[0].Body.GetScriptBlock()
        $parameterNames = @($definitions[0].Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $parameters = @{ Paths = @($path) }
        if ($parameterNames -contains 'ETLFileNameFilter') { $parameters.ETLFileNameFilter = @('WindowsUpdate.*\.etl$') }
        if ($parameterNames -contains 'ProviderFilter') { $parameters.ProviderFilter = @('WUTraceLogging') }
        & $enumerate @parameters
    } $nativeInput
    Assert-Decoder (@($nativeInputs).Count -eq 1 -and [string]$nativeInputs[0] -eq $nativeInput) 'Actual Windows module accepts the new staged ETL filename'
} else {
    Write-Host 'SKIP: Native module enumeration requires Windows PowerShell 5.1; it is a separate Windows CI check.'
}

if ($DatasetZip) {
    # Optional local-only replay. Neither this ZIP nor its private XML is ever
    # committed, copied into fixtures, or uploaded to Windows CI.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($DatasetZip)
    try {
        $entry = $archive.GetEntry('UpdateActivity.json'); $reader = New-Object IO.StreamReader($entry.Open())
        try { $activity = ConvertFrom-WudJsonText $reader.ReadToEnd() } finally { $reader.Dispose() }
        $target = @($activity.Updates | Where-Object Role -eq 'TargetUpgrade')[0]
        $records = @($target.Events | ForEach-Object {
            $e = ConvertFrom-WudUpdateEventXml $_.RawXml $_.SourceRef
            $e | Add-Member SourceKind $_.SourceKind; $e | Add-Member TimingStream $_.TimingStream
            $e
        })
        $ctx.UpgradeTracking = [pscustomobject]@{ Identity = Resolve-WudUpgradeIdentity $records; MatchedEvents = $records; MatchedHistory = $target.History }
        $replayTiming = Get-WudUpgradeTimingModel $ctx $ctx.UpgradeTracking -IncludeRecorderObservations $false
        $replayStatus = Get-WudUpgradeStatusModel $ctx $ctx.Inventory['Identity'] $target.History
        Assert-Decoder ($replayStatus.AttemptOutcome -eq 'WindowsUpdateReportedSucceeded' -and $replayTiming.Sessions[0].ElapsedSeconds -eq 3253.159 -and $null -eq $replayTiming.Sessions[1].ElapsedSeconds) 'Local supplied-capture replay recovers download interval and reported success without fabricating installation duration'
    } finally { $archive.Dispose() }
}
Write-Output 'PASS: decoder/status regression suite complete.'
