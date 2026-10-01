Set-StrictMode -Version 2.0

function ConvertTo-WudReviewUtc {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('o') }
        if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
        return ([DateTimeOffset]::Parse([string]$Value)).UtcDateTime.ToString('o')
    }
    catch { return $null }
}

function Get-WudReviewProperty {
    param($Object, [string]$Name, $Default = $null)
    return Get-WudObjectPropertyValue -InputObject $Object -Name $Name -Default $Default
}

function Add-WudReviewFact {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [ValidateSet('Observed', 'Decoded', 'SourceReported', 'Computed')][string]$FactType,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Statement,
        $Value,
        [string]$TimestampUtc,
        [string]$AttemptId,
        [string]$SourceRef,
        [string]$EvidenceRef,
        [string]$Code,
        [string]$Phase,
        [string]$Operation,
        [ValidateSet('Included', 'ContextOnly', 'Excluded')][string]$ScopeStatus = 'Included',
        [string]$Excerpt
    )
    $fact = [pscustomobject][ordered]@{
        FactId        = 'FACT-{0:D6}' -f (@($Context.Facts).Count + 1)
        FactType      = $FactType
        Category      = $Category
        Statement     = $Statement
        Value         = $Value
        TimestampUtc  = $TimestampUtc
        AttemptId     = $AttemptId
        SourceRef     = $SourceRef
        EvidenceRef   = if ($EvidenceRef) { $EvidenceRef } else { $SourceRef }
        Code          = $Code
        Phase         = $Phase
        Operation     = $Operation
        ScopeStatus   = $ScopeStatus
        Excerpt       = $Excerpt
        ExcerptFile   = $null
    }
    $null = $Context.Facts.Add($fact)
    return $fact
}

function Get-WudSetupLogProfile {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][int]$Sequence
    )
    $relative = (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $File.FullName).Replace('\', '/')
    $hash = Get-WudFileHashSafe -Path $File.FullName
    $started = $null
    $ended = $null
    $sourceBuild = $null
    $targetBuild = $null
    $codes = New-Object Collections.ArrayList
    $errorRecords = New-Object Collections.ArrayList
    $signals = New-Object Collections.ArrayList
    $updateIds = New-Object Collections.ArrayList
    $targetBuilds = New-Object Collections.ArrayList
    $lineNumber = 0
    $charactersRead = 0L
    $truncated = $false
    $parseFailed = $false
    $maximumBytes = [Math]::Min([long]$Context.Settings.maximumTextParseBytes, 67108864L)
    $reader = $null
    try {
        $reader = New-Object IO.StreamReader($File.FullName, $true)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $lineNumber++
            $charactersRead += ([long]$line.Length + 2L)
            if ($charactersRead -gt $maximumBytes) { $truncated = $true; break }
            $timestamp = $null
            if ($line -match '^(?<date>\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)') {
                $timestampInfo = ConvertTo-WudLogTimestamp -Text $matches.date
                if ($timestampInfo) {
                    $timestamp = [string]$timestampInfo.TimestampUtc
                    if (-not $started) { $started = $timestamp }
                    $ended = $timestamp
                }
            }
            if (-not $sourceBuild -and $line -match '(?i)(?:source(?:\s+os)?|host(?:\s+os)?)\s+(?:build|version)\s*[:=]?\s*(?:10\.0\.)?(\d{5})') { $sourceBuild = $matches[1] }
            if ($line -match '(?i)(?:target(?:\s+os)?|image)\s+(?:build|version)\s*[:=]?\s*(?:10\.0\.)?(\d{5})') {
                $targetBuild = $matches[1]
                if (-not $targetBuilds.Contains($targetBuild)) { $null = $targetBuilds.Add($targetBuild) }
            }
            foreach ($idMatch in [Regex]::Matches($line, '(?i)\bupdate(?:id|guid)\s*[:=]\s*\{?([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\}?')) {
                $id = ConvertTo-WudUpdateGuid $idMatch.Groups[1].Value
                if ($id -and -not $updateIds.Contains($id)) { $null = $updateIds.Add($id) }
            }

            if ($line -match '(?i)/Compat\s+ScanOnly|CompatScanOnly|MOSETUP_E_COMPAT_SCANONLY|0xC1900210') {
                if (-not $signals.Contains('DiagnosticCompatibilityScan')) { $null = $signals.Add('DiagnosticCompatibilityScan') }
            }
            if ($line -match '(?i)\b(?:MOUPG|CSetupHost|SetupHost|Modern Setup Host|SP_EXECUTION_|source\s+(?:os\s+)?build|target\s+(?:os\s+)?build|upgrade platform)\b') {
                if (-not $signals.Contains('FeatureUpgradeSemantics')) { $null = $signals.Add('FeatureUpgradeSemantics') }
            }
            if ($line -match '(?i)\b(?:Windows\s*Update|UpdateSessionOrchestration|Update Orchestrator|UsoClient|UsoSvc|WUClient|WaaS|BlueBox)\b') {
                if (-not $signals.Contains('WindowsUpdateOwnerInSetupLog')) { $null = $signals.Add('WindowsUpdateOwnerInSetupLog') }
            }
            if ($line -match '(?i)\b(?:ConfigMgr|CCMExec|OSDUpgrade|Task Sequence|Windows10UpgraderApp)\b') {
                if (-not $signals.Contains('NonWindowsUpdateOwnerInSetupLog')) { $null = $signals.Add('NonWindowsUpdateOwnerInSetupLog') }
            }
            # Applying an image, specialize, and unattend also occur during
            # in-place feature upgrades. They do not alone prove initial imaging.
            if ($line -match '(?i)\bauditSystem\b|\bIMAGE_STATE_(?:UNDEPLOYABLE|GENERALIZE_RESEAL_TO_OOBE|GENERALIZE_RESEAL_TO_AUDIT)\b|\b(?:Scenario|InstallType)\s*[:=]\s*(?:Clean|Deployment|Imaging)\b') {
                if (-not $signals.Contains('DeploymentOrImagingSemantics')) { $null = $signals.Add('DeploymentOrImagingSemantics') }
            }

            foreach ($match in [Regex]::Matches($line, '(?i)0x(?:[0-9A-F]{8}|[0-5][0-9A-F]{4})(?![0-9A-F])')) {
                $code = '0x' + $match.Value.Substring(2).ToUpperInvariant()
                if (-not $codes.Contains($code)) { $null = $codes.Add($code) }
            }
            if (@($errorRecords).Count -lt 200 -and $line -match '(?i)\b(?:error|fatal|rollback|hardblock|failed|failure|abort(?:ed)?)\b|0x(?:[0-9A-F]{8}|[0-5][0-9A-F]{4})') {
                $excerpt = $line.Trim()
                if ($excerpt.Length -gt 1000) { $excerpt = $excerpt.Substring(0, 1000) + '...' }
                $lineCodes = Get-WudCodesFromText -Text $line
                $decoded = if ($lineCodes.ExtendCode) { Get-WudPhaseOperation -ExtendCode $lineCodes.ExtendCode } else { $null }
                $null = $errorRecords.Add([pscustomobject][ordered]@{
                    LineNumber   = $lineNumber
                    TimestampUtc = $timestamp
                    Reference    = "${relative}:$lineNumber"
                    Excerpt      = $excerpt
                    Codes        = @($lineCodes.Codes)
                    ResultCode   = $lineCodes.ResultCode
                    ExtendCode   = $lineCodes.ExtendCode
                    Phase        = if ($decoded) { $decoded.Phase } else { $null }
                    Operation    = if ($decoded) { $decoded.Operation } else { $null }
                })
            }
        }
    }
    catch {
        $parseFailed = $true
        $null = Add-WudCollectionGap -Context $Context -Collector 'fact-scope' -Source $File.FullName -Status 'ParseFailed' -Detail (Get-WudErrorDetail $_)
    }
    finally { if ($reader) { $reader.Dispose() } }

    if (-not $started) { $started = $File.LastWriteTimeUtc.ToString('o') }
    if (-not $ended) { $ended = $File.LastWriteTimeUtc.ToString('o') }
    $idSeed = if ($hash) { $hash.Substring(0, 12) } else { '{0:D4}' -f $Sequence }
    return [pscustomobject][ordered]@{
        AttemptId       = "attempt-$idSeed"
        SourcePath      = $relative
        SourceDirectory = (Split-Path -Parent $relative).Replace('\', '/')
        Sha256          = $hash
        Length          = $File.Length
        LastWriteUtc    = $File.LastWriteTimeUtc.ToString('o')
        StartedUtc      = $started
        EndedUtc        = $ended
        SourceBuild     = $sourceBuild
        TargetBuild     = $targetBuild
        TargetBuilds    = @($targetBuilds)
        UpdateIDs       = @($updateIds)
        AttributionBasis = $null
        Codes           = @($codes)
        ContentSignals  = @($signals)
        ErrorRecords    = @($errorRecords)
        ParseTruncated  = $truncated
        ParseFailed     = $parseFailed
        DuplicateOf     = $null
        Classification  = $null
        IncludedForUpgradeReview = $false
        ExclusionReason = $null
        Gates           = $null
        CorroboratingEvidence = @()
    }
}

function Get-WudFeatureUpdateHistory {
    param($Context, $CurrentInventory)
    $records = New-Object Collections.ArrayList
    $servicing = Get-WudReviewProperty $CurrentInventory 'Servicing'
    $history = @(Get-WudReviewProperty $servicing 'UpdateHistory' @())
    for ($index = 0; $index -lt $history.Count; $index++) {
        $entry = $history[$index]
        $title = [string](Get-WudReviewProperty $entry 'Title')
        if (-not (Test-WudTargetUpgradeTitle -Title $title -TargetVersion $Context.TargetVersion)) { continue }
        $null = $records.Add([pscustomobject][ordered]@{
            Index               = $index
            DateUtc             = ConvertTo-WudReviewUtc (Get-WudReviewProperty $entry 'DateUtc' (Get-WudReviewProperty $entry 'Date'))
            Title               = $title
            Operation           = [string](Get-WudReviewProperty $entry 'Operation')
            ResultCode          = [string](Get-WudReviewProperty $entry 'ResultCode')
            HResult             = Get-WudReviewProperty $entry 'HResult'
            HResultHex          = Get-WudReviewProperty $entry 'HResultHex'
            ClientApplicationID = Get-WudReviewProperty $entry 'ClientApplicationID'
            ServerSelection     = Get-WudReviewProperty $entry 'ServerSelection'
            ServiceID           = Get-WudReviewProperty $entry 'ServiceID'
            UpdateID            = Get-WudReviewProperty $entry 'UpdateID'
            RevisionNumber      = Get-WudReviewProperty $entry 'RevisionNumber'
            SourceRef           = ('{0}/Servicing/servicing.json#UpdateHistory[{1}]' -f $Context.PhaseLabel, $index)
            Raw                 = $entry
        })
    }
    return @($records)
}

function Get-WudUpgradeTrackingModel {
    param($Context, $FeatureHistory = @())
    $records = New-Object Collections.ArrayList
    $providers = New-Object Collections.ArrayList
    $persistent = Read-WudJsonLines -Path (Join-Path $Context.EvidencePath 'Recorder/UpdateEvents.jsonl')
    for ($i = 0; $i -lt @($persistent.Records).Count; $i++) {
        $record = $persistent.Records[$i]
        $record.SourceRef = 'Recorder/UpdateEvents.jsonl:{0}' -f ($i + 1)
        $null = $records.Add($record)
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Context.EvidencePath -Recurse -File -Filter 'update-lifecycle-events.json' -ErrorAction SilentlyContinue)) {
        $query = Read-WudJson -Path $file.FullName
        $relative = (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $file.FullName).Replace('\', '/')
        $index = 0
        foreach ($record in @(Get-WudReviewProperty $query 'Records' @())) {
            $record.SourceRef = "$relative#Records[$index]"; $index++
            $null = $records.Add($record)
        }
        foreach ($provider in @(Get-WudReviewProperty $query 'Providers' @())) { $null = $providers.Add($provider) }
    }
    $state = Read-WudJson -Path (Join-Path $Context.RunPath 'State/run-state.json')
    $windowStart = Get-WudReviewProperty $state 'CreatedUtc'
    if (-not $windowStart -and $Context.Mode -eq 'Preflight') { $windowStart = $Context.StartedUtc }
    $decoded = Read-WudWindowsUpdateLogRecords $Context
    foreach ($record in $decoded.Records) { $null = $records.Add($record) }
    $events = @($records | Where-Object { -not $windowStart -or ([DateTimeOffset]::Parse($_.TimestampUtc)) -ge ([DateTimeOffset]::Parse($windowStart)) } |
        Sort-Object TimestampUtc | Group-Object { '{0}|{1}|{2}' -f $_.Channel, $_.RecordId, $_.TimestampUtc } | ForEach-Object { $_.Group[0] } | Sort-Object TimestampUtc)
    $history = @($FeatureHistory | Where-Object {
        $_.DateUtc -and (-not $windowStart -or ([DateTimeOffset]::Parse($_.DateUtc)) -ge ([DateTimeOffset]::Parse($windowStart))) -and [string]$_.Operation -in @('1', 'Installation')
    })
    $existing = Read-WudJson -Path (Join-Path $Context.RunPath 'State/upgrade-identity.json')
    $identity = Resolve-WudUpgradeIdentity -Records (@($events) + @($history)) -TargetVersion $Context.TargetVersion -ExistingLock $existing
    $matched = @($events | Where-Object { Test-WudUpgradeIdentityMatch $_ $identity })
    $matchedHistory = @($history | Where-Object { Test-WudUpgradeIdentityMatch $_ $identity })
    if ($identity.Status -eq 'Locked') { Write-WudJsonAtomic -Path (Join-Path $Context.RunPath 'State/upgrade-identity.json') -InputObject $identity -Depth 15 }
    return [pscustomobject][ordered]@{
        Identity = $identity; WindowStartUtc = $windowStart; MatchedEvents = $matched; MatchedHistory = $matchedHistory; AllEvents = $events
        OtherEventCount = $events.Count - $matched.Count; Providers = @($providers)
        InvalidRecorderLines = @($persistent.InvalidLines)
        LogCoverage = $decoded.Coverage; UnresolvedLogRecords = $decoded.UnresolvedRecords
        AttributionRule = 'Explicit target upgrade title discovers the identity. GUID/revision and known service must match. Temporal proximity, build strings in quality-update titles, and DO FileId alone do not identify an upgrade.'
    }
}

function Get-WudUpgradeTimingModel {
    param($Context, $Tracking, [bool]$IncludeRecorderObservations = $true)
    $sessions = New-Object Collections.ArrayList
    $pending = @{}
    foreach ($event in @(Get-WudReviewProperty $Tracking 'MatchedEvents' @() | Sort-Object TimestampUtc)) {
        $event.TimestampUtc = ConvertTo-WudReviewUtc $event.TimestampUtc
        $boundary = [string]$event.Boundary
        if ($boundary -notin @('DownloadStarted', 'DownloadCompleted', 'DownloadFailed', 'InstallStarted', 'InstallReportedSucceeded', 'InstallReportedFailed')) { continue }
        $phase = if ($boundary -match '^Download') { 'Download' } elseif ($boundary -match '^Install') { 'WindowsUpdateInstall' } else { $null }
        if (-not $phase) { continue }
        $starts = $boundary -in @('DownloadStarted', 'InstallStarted')
        $stream = [string](Get-WudReviewProperty $event 'TimingStream' 'NativeWindowsUpdateEvents')
        $pendingKey = $phase + '|' + $stream
        if ($starts) {
            if ($pending.ContainsKey($pendingKey)) { $pending[$pendingKey].Result = 'SupersededByNextStart'; $pending.Remove($pendingKey) }
            $session = [pscustomobject][ordered]@{
                SessionId = 'operation-{0:D3}' -f ($sessions.Count + 1); Phase = $phase; UpdateID = $Tracking.Identity.UpdateID
                RevisionNumber = $Tracking.Identity.RevisionNumber; StartUtc = $event.TimestampUtc; EndUtc = $null
                StartKind = Get-WudReviewProperty $event 'SourceKind' 'SourceEvent'; EndKind = 'NotObserved'; Result = 'Open'; ElapsedSeconds = $null; SourceStream = $stream
                StartEvidenceRef = $event.SourceRef; EndEvidenceRef = $null
            }
            $null = $sessions.Add($session); $pending[$pendingKey] = $session
        }
        else {
            if ($pending.ContainsKey($pendingKey)) { $session = $pending[$pendingKey]; $pending.Remove($pendingKey) }
            else {
                $session = [pscustomobject][ordered]@{
                    SessionId = 'operation-{0:D3}' -f ($sessions.Count + 1); Phase = $phase; UpdateID = $Tracking.Identity.UpdateID
                    RevisionNumber = $Tracking.Identity.RevisionNumber; StartUtc = $null; EndUtc = $null
                    StartKind = 'NotObserved'; EndKind = 'NotObserved'; Result = 'Open'; ElapsedSeconds = $null; SourceStream = $stream
                    StartEvidenceRef = $null; EndEvidenceRef = $null
                }
                $null = $sessions.Add($session)
            }
            $session.EndUtc = $event.TimestampUtc; $session.EndKind = Get-WudReviewProperty $event 'SourceKind' 'SourceEvent'; $session.Result = $boundary; $session.EndEvidenceRef = $event.SourceRef
            if ($session.StartUtc) { $session.ElapsedSeconds = [Math]::Round((([DateTimeOffset]::Parse($session.EndUtc)) - ([DateTimeOffset]::Parse($session.StartUtc))).TotalSeconds, 3) }
        }
    }
    $samples = @(if ($IncludeRecorderObservations) { (Read-WudJsonLines -Path (Join-Path $Context.EvidencePath 'Recorder/ProgressSamples.jsonl')).Records })
    $targetObservation = $null
    $lastBeforeTarget = $null
    $downloadObservation = $null
    for ($i = 0; $i -lt $samples.Count; $i++) {
        $sample = $samples[$i]
        $os = Get-WudReviewProperty $sample 'Os'
        if (-not $targetObservation -and [bool](Get-WudReviewProperty $os 'TargetPresent' $false)) {
            $targetObservation = [pscustomobject][ordered]@{
                FirstObservedUtc = ConvertTo-WudReviewUtc $sample.TimestampUtc; LowerBoundUtc = if ($lastBeforeTarget) { ConvertTo-WudReviewUtc $lastBeforeTarget.TimestampUtc } else { $null }
                UpperBoundUtc = ConvertTo-WudReviewUtc $sample.TimestampUtc; Kind = if ($lastBeforeTarget) { 'ObservationBound' } else { 'FirstObservation' }; EvidenceRef = "Recorder/ProgressSamples.jsonl:$($i + 1)"
                Note = 'First observation of the target OS. The transition happened at an unknown point within these bounds; reboot/offline gaps can exceed the sampling interval.'
            }
        }
        if (-not [bool](Get-WudReviewProperty $os 'TargetPresent' $false) -and $null -ne (Get-WudReviewProperty $os 'Build')) { $lastBeforeTarget = $sample }
        $delivery = Get-WudReviewProperty $sample 'DeliveryOptimization'
        $status = Get-WudReviewProperty $delivery 'Status'
        foreach ($file in @(Get-WudReviewProperty $status 'Records' @())) {
            # FileId and the CDN hostname are not an UpdateID mapping.
            $updateId = Get-WudReviewProperty $file 'UpdateID' (Get-WudReviewProperty $file 'UpdateGuid')
            $mapping = [pscustomobject]@{ UpdateID = $updateId; RevisionNumber = Get-WudReviewProperty $file 'RevisionNumber'; ServiceID = $null; Title = $null }
            if (-not (Test-WudUpgradeIdentityMatch $mapping $Tracking.Identity)) { continue }
            if (-not $downloadObservation -and [string](Get-WudReviewProperty $file 'Status') -eq 'Downloading') {
                $downloadObservation = [pscustomobject]@{
                    FirstObservedUtc = ConvertTo-WudReviewUtc $sample.TimestampUtc; LowerBoundUtc = $null; UpperBoundUtc = ConvertTo-WudReviewUtc $sample.TimestampUtc
                    Kind = 'FirstObservation'; FileId = Get-WudReviewProperty $file 'FileId'; EvidenceRef = "Recorder/ProgressSamples.jsonl:$($i + 1)"
                    Note = 'A directly mapped upgrade payload was already downloading at this sample. Earlier start and whole-update completion are not known.'
                }
            }
        }
    }
    return [pscustomobject][ordered]@{
        UpdateID = Get-WudReviewProperty $Tracking.Identity 'UpdateID'; RevisionNumber = Get-WudReviewProperty $Tracking.Identity 'RevisionNumber'
        Sessions = @($sessions); DownloadFirstObserved = $downloadObservation; TargetOsFirstObserved = $targetObservation
        HistoryResults = @(Get-WudReviewProperty $Tracking 'MatchedHistory' @() | ForEach-Object { [pscustomobject]@{ TimestampUtc = $_.DateUtc; ResultCode = $_.ResultCode; EvidenceRef = $_.SourceRef; Meaning = 'WUA history applied-operation timestamp; not a download start, install start, or proof of post-reboot completion.' } })
        Interpretation = 'Elapsed values are wall-clock intervals between matching source events, including any waits and pauses. Each retry is separate. Missing boundaries remain unknown. Unmapped DO traffic remains device-wide context.'
    }
}

function Get-WudUpdateActivityModel {
    param($Context, $Tracking, $AllHistory = @())
    $history = New-Object Collections.ArrayList
    $windowStart = Get-WudReviewProperty $Tracking 'WindowStartUtc'
    if (-not $windowStart) { $windowStart = [DateTime]::UtcNow.AddDays(-[int]$Context.Settings.eventLookbackDays).ToString('o') }
    for ($index = 0; $index -lt @($AllHistory).Count; $index++) {
        $entry = $AllHistory[$index]
        $date = ConvertTo-WudReviewUtc (Get-WudReviewProperty $entry 'DateUtc' (Get-WudReviewProperty $entry 'Date'))
        if (-not $date -or ([DateTimeOffset]::Parse($date)) -lt ([DateTimeOffset]::Parse($windowStart))) { continue }
        $null = $history.Add([pscustomobject][ordered]@{
            DateUtc = $date; Title = Get-WudReviewProperty $entry 'Title'; UpdateID = ConvertTo-WudUpdateGuid (Get-WudReviewProperty $entry 'UpdateID')
            RevisionNumber = Get-WudReviewProperty $entry 'RevisionNumber'; ServiceID = ConvertTo-WudUpdateGuid (Get-WudReviewProperty $entry 'ServiceID')
            Operation = Get-WudReviewProperty $entry 'Operation'; ResultCode = Get-WudReviewProperty $entry 'ResultCode'; HResultHex = Get-WudReviewProperty $entry 'HResultHex'
            SourceRef = ('{0}/Servicing/servicing.json#UpdateHistory[{1}]' -f $Context.PhaseLabel, $index)
        })
    }
    $events = @(Get-WudReviewProperty $Tracking 'AllEvents' @())
    $updates = New-Object Collections.ArrayList
    $timeline = New-Object Collections.ArrayList
    $keys = @((@($events) + @($history)) | Where-Object { ConvertTo-WudUpdateGuid (Get-WudReviewProperty $_ 'UpdateID') } | Group-Object { '{0}|{1}' -f (ConvertTo-WudUpdateGuid (Get-WudReviewProperty $_ 'UpdateID')), (Get-WudReviewProperty $_ 'RevisionNumber') })
    foreach ($key in $keys) {
        $id = ConvertTo-WudUpdateGuid (Get-WudReviewProperty $key.Group[0] 'UpdateID')
        $revision = Get-WudReviewProperty $key.Group[0] 'RevisionNumber'
        $keyEvents = @($events | Where-Object { $_.UpdateID -eq $id -and [string]$_.RevisionNumber -eq [string]$revision })
        $keyHistory = @($history | Where-Object { $_.UpdateID -eq $id -and [string]$_.RevisionNumber -eq [string]$revision })
        $knownServices = @((@($keyEvents) + @($keyHistory)) | ForEach-Object { ConvertTo-WudUpdateGuid (Get-WudReviewProperty $_ 'ServiceID') } | Where-Object { $_ } | Select-Object -Unique)
        # Normally one update source is known. If distinct services report the
        # same GUID/revision, keep their operations separate; unknown-source
        # events form their own bucket rather than joining either service.
        $serviceBuckets = if ($knownServices.Count -gt 1) { @('') + @($knownServices) } else { @('') }
        foreach ($service in $serviceBuckets) {
            $serviceEvents = @($keyEvents | Where-Object { $knownServices.Count -le 1 -or [string](ConvertTo-WudUpdateGuid $_.ServiceID) -eq $service })
            $serviceHistory = @($keyHistory | Where-Object { $knownServices.Count -le 1 -or [string](ConvertTo-WudUpdateGuid $_.ServiceID) -eq $service })
            if ($serviceEvents.Count -eq 0 -and $serviceHistory.Count -eq 0) { continue }
            $title = @((@($serviceEvents) + @($serviceHistory)) | ForEach-Object { [string]$_.Title } | Where-Object { $_ } | Select-Object -First 1)
            $identity = [pscustomobject]@{ Status = 'Locked'; UpdateID = $id; RevisionNumber = $revision; ServiceID = if ($service) { $service } elseif ($knownServices.Count -eq 1) { $knownServices[0] } else { $null }; Title = if ($title.Count) { $title[0] } else { $null } }
            $target = Test-WudUpgradeIdentityMatch $identity $Tracking.Identity
            $role = if ($target) { 'TargetUpgrade' } elseif ($identity.Title -and (Test-WudTargetUpgradeTitle $identity.Title $Context.TargetVersion)) { 'OtherTargetCandidate' } else { 'OtherUpdate' }
            $timing = Get-WudUpgradeTimingModel -Context $Context -Tracking ([pscustomobject]@{ Identity = $identity; MatchedEvents = $serviceEvents; MatchedHistory = $serviceHistory }) -IncludeRecorderObservations $false
            $latestEvent = @($serviceEvents | Where-Object Boundary -ne 'UpdateLogContext' | Sort-Object TimestampUtc -Descending | Select-Object -First 1)
            $latestHistory = @($serviceHistory | Sort-Object DateUtc -Descending | Select-Object -First 1)
            $activityKey = '{0}.{1}' -f $id, $(if ($null -ne $revision) { $revision } else { 'revision-unknown' })
            if ($knownServices.Count -gt 1) { $activityKey += '.' + $(if ($service) { $service } else { 'service-unknown' }) }
            $null = $updates.Add([pscustomobject][ordered]@{
                ActivityKey = $activityKey; UpdateID = $id; RevisionNumber = $revision; ServiceID = $identity.ServiceID; Title = $identity.Title; Role = $role
                EventCount = $serviceEvents.Count; HistoryCount = $serviceHistory.Count
                FirstObservedUtc = @(@($serviceEvents | ForEach-Object TimestampUtc) + @($serviceHistory | ForEach-Object DateUtc) | Sort-Object | Select-Object -First 1)[0]
                LatestBoundary = if ($latestEvent.Count) { $latestEvent[0].Boundary } else { 'NotObserved' }
                NativeEventCount = @($serviceEvents | Where-Object { (Get-WudReviewProperty $_ 'SourceKind') -ne 'SourceLog' }).Count
                LogRecordCount = @($serviceEvents | Where-Object { (Get-WudReviewProperty $_ 'SourceKind') -eq 'SourceLog' }).Count
                HistoryResult = if ($latestHistory.Count) { Get-WudOperationResultLabel $latestHistory[0].ResultCode } else { 'NotObserved' }
                HistoryOperation = if ($latestHistory.Count) { $latestHistory[0].Operation } else { $null }
                Timing = $timing; Events = $serviceEvents; History = $serviceHistory
            })
            foreach ($event in $serviceEvents) {
                $null = $timeline.Add([pscustomobject][ordered]@{
                    TimestampUtc = $event.TimestampUtc; ActivityKey = $activityKey; UpdateID = $id; RevisionNumber = $revision; ServiceID = $identity.ServiceID
                    Role = $role; Boundary = $event.Boundary; EventId = $event.EventId; Title = $identity.Title; EvidenceReference = $event.SourceRef; TimingKind = Get-WudReviewProperty $event 'SourceKind' 'SourceEvent'
                })
            }
            foreach ($entry in $serviceHistory) {
                $null = $timeline.Add([pscustomobject][ordered]@{
                    TimestampUtc = $entry.DateUtc; ActivityKey = $activityKey; UpdateID = $id; RevisionNumber = $revision; ServiceID = $identity.ServiceID
                    Role = $role; Boundary = 'HistoryResult: ' + (Get-WudOperationResultLabel $entry.ResultCode); EventId = $null; Title = $identity.Title; EvidenceReference = $entry.SourceRef; TimingKind = 'AppliedOperationHistory'
                })
            }
        }
    }
    return [pscustomobject][ordered]@{
        WindowStartUtc = $windowStart; Updates = @($updates | Sort-Object @{ Expression = { if ($_.Role -eq 'TargetUpgrade') { 0 } else { 1 } } }, FirstObservedUtc)
        Timeline = @($timeline | Sort-Object TimestampUtc); UnattributedEventCount = @($events | Where-Object { -not $_.UpdateID }).Count
        Interpretation = 'Each UpdateID/revision has independent operations and results. Conflicting known services are separate. Other updates never change the target upgrade outcome. No-ID device events and unmapped DO activity stay device context.'
    }
}

function Test-WudReviewTimeOverlap {
    param([string]$AttemptStart, [string]$AttemptEnd, [string]$EvidenceTime, [int]$PaddingHours = 36)
    if (-not $EvidenceTime) { return $false }
    try {
        $start = [DateTimeOffset]::Parse($AttemptStart).UtcDateTime.AddHours(-1 * $PaddingHours)
        $end = [DateTimeOffset]::Parse($AttemptEnd).UtcDateTime.AddHours($PaddingHours)
        $point = [DateTimeOffset]::Parse($EvidenceTime).UtcDateTime
        return $point -ge $start -and $point -le $end
    }
    catch { return $false }
}

function Find-WudUpdateLogSignals {
    param($Context, $Attempt)
    $signals = New-Object Collections.ArrayList
    $targetText = [Regex]::Escape([string]$Context.TargetVersion)
    $targetBuild = [Regex]::Escape([string]$Context.Target.buildFamily)
    $files = @(Get-ChildItem -LiteralPath $Context.EvidencePath -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '(?i)BlueBox.*\.log$|WindowsUpdate\.log$' -or $_.FullName -match '(?i)Windows-MoSetup'
    } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 40)
    foreach ($file in $files) {
        if (-not (Test-WudReviewTimeOverlap $Attempt.StartedUtc $Attempt.EndedUtc $file.LastWriteTimeUtc.ToString('o') 48)) { continue }
        $relative = (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $file.FullName).Replace('\', '/')
        $reader = $null
        try {
            $reader = New-Object IO.StreamReader($file.FullName, $true)
            $lineNumber = 0
            while (-not $reader.EndOfStream -and @($signals).Count -lt 20) {
                $line = $reader.ReadLine(); $lineNumber++
                if ($line -notmatch "(?i)(?:Feature update to Windows 11|Windows 11,?\s+version|$targetText|$targetBuild)") { continue }
                $timestamp = $null
                if ($line -match '^(?<date>\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)') {
                    $timestamp = ConvertTo-WudReviewUtc $matches.date
                    if ($timestamp -and -not (Test-WudReviewTimeOverlap $Attempt.StartedUtc $Attempt.EndedUtc $timestamp 36)) { continue }
                }
                $excerpt = $line.Trim(); if ($excerpt.Length -gt 600) { $excerpt = $excerpt.Substring(0, 600) + '...' }
                $null = $signals.Add([pscustomobject][ordered]@{
                    Kind = if ($file.Name -match '(?i)BlueBox') { 'BlueBoxTargetSignal' } else { 'WindowsUpdateTargetSignal' }
                    TimestampUtc = $timestamp
                    Reference = "${relative}:$lineNumber"
                    Excerpt = $excerpt
                })
            }
        }
        catch { }
        finally { if ($reader) { $reader.Dispose() } }
    }
    return @($signals)
}

function Test-WudImageStateComplete {
    param($Identity)
    $imageState = [string](Get-WudReviewProperty $Identity 'WindowsImageState')
    if ($imageState -match '(?i)^IMAGE_STATE_COMPLETE$') { return $true }
    $setup = Get-WudReviewProperty $Identity 'SystemSetupState'
    if ($setup) {
        $systemSetup = Get-WudReviewProperty $setup 'SystemSetupInProgress'
        $oobe = Get-WudReviewProperty $setup 'OOBEInProgress'
        if ($null -ne $systemSetup -and $null -ne $oobe -and [int]$systemSetup -eq 0 -and [int]$oobe -eq 0) { return $true }
    }
    return $false
}

function Set-WudAttemptScope {
    param($Context, $Attempt, $FeatureHistory, $Identity)
    $tracking = $Context.UpgradeTracking
    if (-not $tracking) { $tracking = Get-WudUpgradeTrackingModel -Context $Context -FeatureHistory $FeatureHistory }
    $locked = $tracking.Identity.Status -eq 'Locked'
    $attemptIds = @(Get-WudReviewProperty $Attempt 'UpdateIDs' @())
    $directId = $locked -and $tracking.Identity.UpdateID -in $attemptIds
    $foreignId = @($attemptIds | Where-Object { $_ -ne $tracking.Identity.UpdateID }).Count -gt 0
    $builds = @(Get-WudReviewProperty $Attempt 'TargetBuilds' @())
    $mixedBuilds = @($builds | Where-Object { [string]$_ -ne [string]$Context.Target.buildFamily }).Count -gt 0
    $installEvents = @($tracking.MatchedEvents | Where-Object {
        $_.Boundary -in @('InstallStarted', 'InstallReportedSucceeded', 'InstallReportedFailed') -and
        (Test-WudReviewTimeOverlap $Attempt.StartedUtc $Attempt.EndedUtc $_.TimestampUtc 0)
    })
    $windowStart = Get-WudReviewProperty $tracking 'WindowStartUtc'
    $runWindow = -not $windowStart -or ([DateTimeOffset]::Parse($Attempt.EndedUtc)) -ge ([DateTimeOffset]::Parse($windowStart))
    $parseComplete = -not [bool](Get-WudReviewProperty $Attempt 'ParseTruncated' $false) -and -not [bool](Get-WudReviewProperty $Attempt 'ParseFailed' $false)
    $historyMatches = New-Object Collections.ArrayList
    foreach ($entry in @($tracking.MatchedHistory)) {
        if (Test-WudReviewTimeOverlap $Attempt.StartedUtc $Attempt.EndedUtc $entry.DateUtc 0) { $null = $historyMatches.Add($entry) }
    }
    $logSignals = @() # Version text in another log is not identity evidence.
    $sameLogOwner = @($Attempt.ContentSignals) -contains 'WindowsUpdateOwnerInSetupLog'
    $featureSemantics = (@($Attempt.ContentSignals) -contains 'FeatureUpgradeSemantics') -or
        (($Attempt.SourcePath -match '(?i)WindowsBT|WindowsOld|SetupCopyLogs') -and ($Attempt.SourceBuild -or $Attempt.TargetBuild))
    $diagnosticScan = @($Attempt.ContentSignals) -contains 'DiagnosticCompatibilityScan'
    $toolGenerated = $Attempt.SourcePath -match '(?i)/(?:Commands|CurrentDiagnostics|Compatibility/MediaScan|SetupDiag)/'
    $imagingPath = $Attempt.SourcePath -match '(?i)/Raw/Windows-Panther/' -and $Attempt.SourcePath -notmatch '(?i)WindowsOld'
    $imagingSemantics = @($Attempt.ContentSignals) -contains 'DeploymentOrImagingSemantics'
    $nonWuOwner = @($Attempt.ContentSignals) -contains 'NonWindowsUpdateOwnerInSetupLog'
    $wuOwnership = $sameLogOwner -and $locked
    $temporalOverlap = $directId -or @($installEvents).Count -gt 0 -or @($historyMatches).Count -gt 0
    $targetEvidence = [string]$Attempt.TargetBuild -eq [string]$Context.Target.buildFamily
    $imageComplete = Test-WudImageStateComplete -Identity $Identity
    $included = (-not $diagnosticScan) -and (-not $toolGenerated) -and (-not $imagingPath) -and (-not $imagingSemantics) -and (-not $nonWuOwner) -and (-not $foreignId) -and (-not $mixedBuilds) -and $parseComplete -and $runWindow -and $featureSemantics -and $wuOwnership -and $temporalOverlap -and $targetEvidence -and $imageComplete
    $Attempt.AttributionBasis = if ($directId) { 'ExplicitSetupUpdateId' } elseif ($included) { 'TargetBuildAndIdentityInstallWindow' } else { 'Unattributed' }

    $classification = 'UnclassifiedSetupEvidence'
    $reason = $null
    if ($diagnosticScan) { $classification = 'DiagnosticCompatibilityScan'; $reason = 'Setup explicitly reported scan-only compatibility execution.' }
    elseif ($toolGenerated) { $classification = 'ToolGenerated'; $reason = 'The evidence path is owned by this diagnostic run.' }
    elseif ($imagingPath -and ($imagingSemantics -or -not $wuOwnership)) { $classification = 'InitialDeploymentOrImaging'; $reason = 'The log is in Windows\\Panther and lacks the complete Windows Update feature-upgrade gate set.' }
    elseif ($imagingPath -or $imagingSemantics) { $classification = 'InitialDeploymentOrImaging'; $reason = 'The source path or log content directly identifies deployment/imaging context, which is excluded even when Windows Update text is also present.' }
    elseif ($included) { $classification = 'WindowsUpdateFeatureUpgrade' }
    elseif ($featureSemantics -and $nonWuOwner) { $classification = 'NonWindowsUpdateFeatureUpgrade'; $reason = 'The setup log directly names a non-Windows-Update deployment owner.' }
    elseif ($Attempt.SourcePath -match '(?i)/Raw/(?:Windows-CBS|Windows-DISM)/') { $classification = 'GeneralWindowsServicing'; $reason = 'The source is general servicing evidence, not a feature-upgrade setup source.' }
    else {
        $missing = New-Object Collections.ArrayList
        if (-not $featureSemantics) { $null = $missing.Add('feature-upgrade semantics') }
        if (-not $wuOwnership) { $null = $missing.Add('Windows Update ownership') }
        if (-not $temporalOverlap) { $null = $missing.Add('temporal overlap') }
        if (-not $targetEvidence) { $null = $missing.Add('target version/build evidence') }
        if (-not $locked) { $null = $missing.Add('unique target update identity') }
        if ($foreignId -or $mixedBuilds) { $null = $missing.Add('uncontaminated target identity/build') }
        if (-not $runWindow) { $null = $missing.Add('current recording window') }
        if (-not $parseComplete) { $null = $missing.Add('complete setup scope parse') }
        if (-not $imageComplete) { $null = $missing.Add('completed Windows image state') }
        $reason = 'Excluded because the following required gate(s) were absent: ' + (@($missing) -join ', ') + '.'
    }

    $corroboration = New-Object Collections.ArrayList
    foreach ($entry in @($historyMatches)) {
        $null = $corroboration.Add([pscustomobject]@{ Kind = 'WindowsUpdateHistory'; Reference = $entry.SourceRef; TimestampUtc = $entry.DateUtc; Value = $entry.Title; UpdateID = $entry.UpdateID })
    }
    foreach ($signal in @($logSignals)) { $null = $corroboration.Add($signal) }
    foreach ($event in $installEvents) { $null = $corroboration.Add([pscustomobject]@{ Kind = 'IdentityMatchedInstallEvent'; Reference = $event.SourceRef; TimestampUtc = $event.TimestampUtc; UpdateID = $event.UpdateID; RevisionNumber = $event.RevisionNumber }) }
    if ($sameLogOwner) { $null = $corroboration.Add([pscustomobject]@{ Kind = 'WindowsUpdateOwnerInSetupLog'; Reference = $Attempt.SourcePath; TimestampUtc = $null; Value = 'Windows Update ownership token present in setupact.' }) }

    $Attempt.Classification = $classification
    $Attempt.IncludedForUpgradeReview = $included
    $Attempt.ExclusionReason = $reason
    $Attempt.Gates = [pscustomobject][ordered]@{
        UniqueEvidence             = $true
        NotDiagnosticScan          = -not $diagnosticScan
        NotToolGenerated           = -not $toolGenerated
        NotInitialDeploymentOrImaging = (-not $imagingPath) -and (-not $imagingSemantics)
        FeatureUpgradeSemantics    = $featureSemantics
        WindowsUpdateOwnership     = $wuOwnership
        TemporalOverlap            = $temporalOverlap
        TargetVersionOrBuild       = $targetEvidence
        CompletedWindowsImageState = $imageComplete
        UniqueTargetIdentity       = $locked
        UncontaminatedTarget       = -not $foreignId -and -not $mixedBuilds
        CurrentRunWindow           = $runWindow
        CompleteScopeParse         = $parseComplete
    }
    $Attempt.CorroboratingEvidence = @($corroboration)
    return $Attempt
}

function Get-WudReviewInventoryDiff {
    param($Context, $CurrentInventory)
    $snapshots = @(Get-ChildItem -LiteralPath $Context.EvidencePath -Directory -ErrorAction SilentlyContinue)
    $baselineFile = @($snapshots | Where-Object { $_.Name -eq 'Preflight' } | ForEach-Object { Join-Path $_.FullName 'inventory.json' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    $baseline = if (@($baselineFile).Count -gt 0) { Read-WudJson -Path $baselineFile[0] } else { $null }
    $changed = New-Object Collections.ArrayList
    foreach ($section in @('Identity', 'Hardware', 'Drivers', 'Management', 'Servicing')) {
        $beforeValue = Get-WudReviewProperty $baseline $section
        $afterValue = Get-WudReviewProperty $CurrentInventory $section
        if ($null -eq $beforeValue -and $null -eq $afterValue) { continue }
        $beforeJson = if ($null -ne $beforeValue) { $beforeValue | ConvertTo-Json -Compress -Depth 30 } else { $null }
        $afterJson = if ($null -ne $afterValue) { $afterValue | ConvertTo-Json -Compress -Depth 30 } else { $null }
        if ($beforeJson -ne $afterJson) { $null = $changed.Add($section) }
    }
    $baselineIdentity = Get-WudReviewProperty $baseline 'Identity'
    $currentIdentity = Get-WudReviewProperty $CurrentInventory 'Identity'
    return [pscustomobject][ordered]@{
        Available        = $null -ne $baseline
        ChangedSections  = @($changed)
        BaselineSnapshot = if (@($baselineFile).Count -gt 0) { (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $baselineFile[0]).Replace('\', '/') } else { $null }
        SourceVersion    = Get-WudReviewProperty $baselineIdentity 'DisplayVersion'
        SourceBuild      = Get-WudReviewProperty $baselineIdentity 'CurrentBuild'
        CurrentVersion   = Get-WudReviewProperty $currentIdentity 'DisplayVersion'
        CurrentBuild     = Get-WudReviewProperty $currentIdentity 'CurrentBuild'
    }, $baseline
}

function Get-WudOperationResultLabel {
    param([string]$ResultCode)
    switch -Regex ($ResultCode) {
        '^(?:2|orcSucceeded)$' { return 'Succeeded' }
        '^(?:3|orcSucceededWithErrors)$' { return 'SucceededWithErrors' }
        '^(?:4|orcFailed)$' { return 'Failed' }
        '^(?:5|orcAborted)$' { return 'Aborted' }
        '^(?:1|orcInProgress)$' { return 'InProgress' }
        '^(?:0|orcNotStarted)$' { return 'NotStarted' }
        default { return $ResultCode }
    }
}

function Add-WudSetupDiagFacts {
    param($Context, $Attempts)
    foreach ($metadataFile in @(Get-ChildItem -LiteralPath $Context.EvidencePath -File -Recurse -Filter 'setupdiag-tool.json' -ErrorAction SilentlyContinue)) {
        $metadata = Read-WudJson -Path $metadataFile.FullName
        $inputRef = [string](Get-WudReviewProperty $metadata 'InputEvidenceRef')
        if (-not $inputRef) { continue }
        if (-not $Context.UpgradeTracking -or -not (Test-WudUpgradeIdentityMatch ([pscustomobject]@{ UpdateID = Get-WudReviewProperty $metadata 'InputUpdateID'; RevisionNumber = Get-WudReviewProperty $metadata 'InputRevisionNumber' }) $Context.UpgradeTracking.Identity)) { continue }
        $attempt = @($Attempts | Where-Object { $_.IncludedForUpgradeReview -and $_.SourcePath -eq $inputRef } | Select-Object -First 1)
        if (@($attempt).Count -eq 0) { continue }
        $resultPath = Join-Path $metadataFile.DirectoryName 'SetupDiagResults.json'
        if (-not (Test-Path -LiteralPath $resultPath)) { continue }
        $result = Read-WudJson -Path $resultPath
        if (-not $result) { continue }
        $systemInfo = Get-WudReviewProperty $result 'SystemInfo'
        $reportedBuild = [string](Get-WudReviewProperty $systemInfo 'TargetOSBuild')
        if ($reportedBuild -and $reportedBuild -notmatch ('(?<!\d)' + [Regex]::Escape([string]$Context.Target.buildFamily) + '(?!\d)')) {
            $null = Add-WudCollectionGap -Context $Context -Collector 'setupdiag' -Source $resultPath -Status 'TargetMismatch' -Detail ('SetupDiag reported a different target build: ' + $reportedBuild)
            continue
        }
        $scope = if ((Get-WudReviewProperty $metadata 'InputAttributionBasis') -eq 'ExplicitSetupUpdateId') { 'Included' } else { 'ContextOnly' }
        $relative = (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $resultPath).Replace('\', '/')
        foreach ($name in @('ProfileName', 'RuleName', 'RuleId', 'ErrorCode', 'LastPhase', 'LastOperation', 'FailureData', 'FailureDetails', 'MatchingProfile', 'Message', 'Remediation', 'Result', 'SystemInfo')) {
            $value = Get-WudReviewProperty $result $name
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
            $text = if ($value -is [string]) { [string]$value } else { $value | ConvertTo-Json -Compress -Depth 10 }
            if ($text.Length -gt 2000) { $text = $text.Substring(0, 2000) + '...' }
            $null = Add-WudReviewFact -Context $Context -FactType SourceReported -Category 'SetupDiag' -Statement ("SetupDiag reported {0} for its scoped setup input ({1})." -f $name, (Get-WudReviewProperty $metadata 'InputAttributionBasis')) -Value $text -AttemptId $attempt[0].AttemptId -SourceRef ("{0}#{1}" -f $relative, $name) -ScopeStatus $scope -Excerpt $text
        }
    }
}

function Add-WudInventoryFacts {
    param($Context, $CurrentInventory)
    $servicing = Get-WudReviewProperty $CurrentInventory 'Servicing'
    $pending = Get-WudReviewProperty $servicing 'PendingReboot'
    if ($pending -and [bool](Get-WudReviewProperty $pending 'IsPending' $false)) {
        $null = Add-WudReviewFact -Context $Context -FactType Observed -Category 'ServicingState' -Statement 'At least one collected pending-restart indicator is set.' -Value $pending -SourceRef ("{0}/Servicing/servicing.json#PendingReboot" -f $Context.PhaseLabel) -ScopeStatus ContextOnly
    }

    $hardware = Get-WudReviewProperty $CurrentInventory 'Hardware'
    if ($hardware) {
        $logicalDisks = @(Get-WudReviewProperty $hardware 'LogicalDisks' @())
        foreach ($disk in @($logicalDisks | Where-Object { [string](Get-WudReviewProperty $_ 'DeviceID') -eq [string]$env:SystemDrive } | Select-Object -First 1)) {
            $value = [pscustomobject][ordered]@{
                DeviceID = Get-WudReviewProperty $disk 'DeviceID'; Size = Get-WudReviewProperty $disk 'Size'
                FreeSpace = Get-WudReviewProperty $disk 'FreeSpace'; FileSystem = Get-WudReviewProperty $disk 'FileSystem'
                Status = Get-WudReviewProperty $disk 'Status'
            }
            $null = Add-WudReviewFact -Context $Context -FactType Observed -Category 'StorageState' -Statement 'The collector read the operating-system volume capacity and free space.' -Value $value -SourceRef ("{0}/Inventory/hardware.json#LogicalDisks" -f $Context.PhaseLabel) -ScopeStatus ContextOnly
        }
        foreach ($disk in @(Get-WudReviewProperty $hardware 'PhysicalDisks' @())) {
            $health = [string](Get-WudReviewProperty $disk 'HealthStatus')
            if (-not $health -or $health -eq 'Healthy') { continue }
            $null = Add-WudReviewFact -Context $Context -FactType SourceReported -Category 'StorageState' -Statement ("Windows storage health reported physical disk state '{0}'." -f $health) -Value $disk -SourceRef ("{0}/Inventory/hardware.json#PhysicalDisks" -f $Context.PhaseLabel) -ScopeStatus ContextOnly
        }
        $secureBoot = Get-WudReviewProperty $hardware 'SecureBoot'
        if ($null -ne $secureBoot) {
            $null = Add-WudReviewFact -Context $Context -FactType Observed -Category 'SecurityState' -Statement 'The collector read the Secure Boot state.' -Value $secureBoot -SourceRef ("{0}/Inventory/hardware.json#SecureBoot" -f $Context.PhaseLabel) -ScopeStatus ContextOnly
        }
        $tpm = Get-WudReviewProperty $hardware 'Tpm'
        if ($tpm) {
            $null = Add-WudReviewFact -Context $Context -FactType SourceReported -Category 'SecurityState' -Statement 'The Windows TPM provider returned its current state.' -Value $tpm -SourceRef ("{0}/Inventory/hardware.json#Tpm" -f $Context.PhaseLabel) -ScopeStatus ContextOnly
        }
    }

    $drivers = Get-WudReviewProperty $CurrentInventory 'Drivers'
    foreach ($device in @(Get-WudReviewProperty $drivers 'Devices' @())) {
        $problemCode = Get-WudReviewProperty $device 'ConfigManagerErrorCode'
        $number = 0
        if ($null -eq $problemCode -or -not [int]::TryParse([string]$problemCode, [ref]$number) -or $number -eq 0) { continue }
        $name = [string](Get-WudReviewProperty $device 'Name' '<unnamed-device>')
        $null = Add-WudReviewFact -Context $Context -FactType SourceReported -Category 'DeviceState' -Statement ("PnP reported ConfigManager error code {0} for device '{1}'." -f $number, $name) -Value $device -SourceRef ("{0}/Inventory/drivers.json#Devices" -f $Context.PhaseLabel) -Code ([string]$number) -ScopeStatus ContextOnly
    }

    $management = Get-WudReviewProperty $CurrentInventory 'Management'
    foreach ($test in @(Get-WudReviewProperty $management 'Connectivity' @())) {
        if ([bool](Get-WudReviewProperty $test 'Reachable' $false)) { continue }
        $uri = [string](Get-WudReviewProperty $test 'Uri')
        $null = Add-WudReviewFact -Context $Context -FactType Observed -Category 'Connectivity' -Statement ("The bounded endpoint test did not reach '{0}'." -f $uri) -Value $test -SourceRef ("{0}/Management/management-summary.json#Connectivity" -f $Context.PhaseLabel) -ScopeStatus ContextOnly
    }
    $registryExports = Get-WudReviewProperty $management 'RegistryExports'
    if ($registryExports) {
        $importantNames = @('TargetReleaseVersion', 'TargetReleaseVersionInfo', 'ProductVersion', 'DeferFeatureUpdates', 'DeferFeatureUpdatesPeriodInDays', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PausedFeatureStatus', 'WUServer', 'WUStatusServer', 'UseWUServer', 'DisableWUfBSafeguards')
        foreach ($export in $registryExports.PSObject.Properties) {
            foreach ($record in @($export.Value)) {
                $values = Get-WudReviewProperty $record 'Values'
                if (-not $values) { continue }
                $valueEntries = New-Object Collections.ArrayList
                if ($values -is [Collections.IDictionary]) {
                    foreach ($valueName in $values.Keys) { $null = $valueEntries.Add([pscustomobject]@{ Name = [string]$valueName; Value = $values[$valueName] }) }
                }
                else {
                    foreach ($valueProperty in $values.PSObject.Properties) { $null = $valueEntries.Add([pscustomobject]@{ Name = $valueProperty.Name; Value = $valueProperty.Value }) }
                }
                foreach ($valueProperty in @($valueEntries)) {
                    if ($importantNames -notcontains [string]$valueProperty.Name) { continue }
                    $recordPath = [string](Get-WudReviewProperty $record 'Path')
                    $value = [pscustomobject][ordered]@{ RegistryPath = $recordPath; Name = $valueProperty.Name; Value = $valueProperty.Value }
                    $null = Add-WudReviewFact -Context $Context -FactType Observed -Category 'UpdatePolicy' -Statement ("Update-related registry value '{0}' was present." -f $valueProperty.Name) -Value $value -SourceRef ("{0}/Management/{1}#{2}/{3}" -f $Context.PhaseLabel, $export.Name, $recordPath, $valueProperty.Name) -ScopeStatus ContextOnly
                }
            }
        }
    }

    $software = Get-WudReviewProperty $CurrentInventory 'Software'
    $softwareCollection = [string](Get-WudReviewProperty $software 'CollectionStatus' 'Collected')
    $inventoryCounts = [pscustomobject][ordered]@{
        SoftwareCollection = $softwareCollection
        Applications = if ($softwareCollection -eq 'DisabledByDesign') { $null } else { @(Get-WudReviewProperty $software 'Applications' @()).Count }
        Services = if ($softwareCollection -eq 'DisabledByDesign') { $null } else { @(Get-WudReviewProperty $software 'Services' @()).Count }
        SignedDrivers = @(Get-WudReviewProperty $drivers 'SignedDrivers' @()).Count
        Devices = @(Get-WudReviewProperty $drivers 'Devices' @()).Count
        Packages = @(Get-WudReviewProperty $servicing 'Packages' @()).Count
    }
    $null = Add-WudReviewFact -Context $Context -FactType Computed -Category 'InventoryCoverage' -Statement 'The collector recorded normalized inventory coverage and counts; broad installed-software inventory is disabled by design.' -Value $inventoryCounts -SourceRef ("{0}/inventory.json" -f $Context.PhaseLabel) -ScopeStatus ContextOnly
}

function Add-WudActiveDiagnosticFacts {
    param($Context)
    foreach ($process in @($Context.ProcessRecords)) {
        $name = [string](Get-WudReviewProperty $process 'Name' '<unnamed-process>')
        if ($name -notin @('dism-scanhealth', 'sfc-verifyonly', 'setup-compat-scan', 'setupdiag')) { continue }
        $stdout = [string](Get-WudReviewProperty $process 'StandardOut')
        $excerpt = $null
        if ($stdout -and (Test-Path -LiteralPath $stdout)) {
            try {
                $text = [IO.File]::ReadAllText($stdout)
                $matches = @([Regex]::Matches($text, '(?im)^.*(?:component store|Windows Resource Protection|compatib|error|corrupt|repairable).*$') | Select-Object -First 20 | ForEach-Object { $_.Value.Trim() })
                if (@($matches).Count -gt 0) { $excerpt = @($matches) -join [Environment]::NewLine }
            }
            catch { }
        }
        $value = [pscustomobject][ordered]@{
            Name = $name; Succeeded = Get-WudReviewProperty $process 'Succeeded'; ExitCode = Get-WudReviewProperty $process 'ExitCode'
            ExitCodeHex = Get-WudReviewProperty $process 'ExitCodeHex'; TimedOut = Get-WudReviewProperty $process 'TimedOut'; Error = Get-WudReviewProperty $process 'Error'
        }
        $sourceRef = if ($stdout) { (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $stdout).Replace('\', '/') } else { "{0}/Commands/{1}.result.json" -f $Context.PhaseLabel, $name }
        $category = if ($name -eq 'setup-compat-scan') { 'DiagnosticCompatibilityScan' } elseif ($name -eq 'setupdiag') { 'ToolGeneratedSetupDiag' } else { 'CurrentHealthDiagnostic' }
        $null = Add-WudReviewFact -Context $Context -FactType SourceReported -Category $category -Statement ("Diagnostic process '{0}' returned its recorded execution result." -f $name) -Value $value -TimestampUtc (Get-WudReviewProperty $process 'EndedUtc') -SourceRef $sourceRef -Code ([string](Get-WudReviewProperty $process 'ExitCodeHex')) -ScopeStatus ContextOnly -Excerpt $excerpt
    }
}

function Get-WudUpgradeStatusModel {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Identity,
        $FeatureHistory = @(),
        $EligibleAttempts = @()
    )
    $display = [string](Get-WudReviewProperty $Identity 'DisplayVersion')
    $build = 0
    $buildReadable = [int]::TryParse([string](Get-WudReviewProperty $Identity 'CurrentBuild'), [ref]$build)
    $targetPresent = $display -eq [string]$Context.TargetVersion -or ($buildReadable -and $build -eq [int]$Context.Target.buildFamily)
    $currentState = if (-not $Identity -or (-not $display -and -not $buildReadable)) { 'Unreadable' } elseif ($targetPresent) { 'TargetPresent' } else { 'TargetNotPresent' }

    $samples = @()
    $samplePath = Join-Path $Context.RunPath 'Evidence\Recorder\ProgressSamples.jsonl'
    if (Test-Path -LiteralPath $samplePath) {
        try { $samples = @((Read-WudJsonLines -Path $samplePath).Records) }
        catch { $samples = @() }
    }
    $observedBuilds = @($samples | ForEach-Object {
        $os = Get-WudReviewProperty $_ 'Os'
        [string](Get-WudReviewProperty $os 'Build')
    } | Where-Object { $_ } | Select-Object -Unique)
    $buildTransition = if ($observedBuilds.Count -gt 1) { 'Observed' } else { 'NotObserved' }
    $baseline = $null
    try {
        $state = Read-WudJson -Path (Join-Path $Context.RunPath 'State\run-state.json')
        $baseline = Get-WudReviewProperty $state 'BaselineIdentity'
    }
    catch { }
    if ($baseline) {
        $baselineBuild = 0
        $baselineReadable = [int]::TryParse([string](Get-WudReviewProperty $baseline 'CurrentBuild'), [ref]$baselineBuild)
        if ($baselineReadable -and $buildReadable -and $baselineBuild -ne $build) { $buildTransition = 'Observed' }
    }

    $featureRows = @($FeatureHistory)
    $windowsUpdateConfirmed = @($EligibleAttempts).Count -gt 0 -or @($featureRows).Count -gt 0
    $deploymentSource = if ($windowsUpdateConfirmed) { 'WindowsUpdateConfirmed' } else { 'Unattributed' }
    $rollbackMarker = Test-Path -LiteralPath (Join-Path $Context.RunPath 'State\Markers\post-rollback.marker')
    $latestHistory = @($featureRows | Sort-Object DateUtc -Descending | Select-Object -First 1)
    $failedHistory = @($latestHistory | Where-Object { (Get-WudOperationResultLabel $_.ResultCode) -in @('Failed', 'Aborted') })
    $latestEvent = @(Get-WudReviewProperty $Context.UpgradeTracking 'MatchedEvents' @() | Where-Object Boundary -in @('DownloadStarted', 'InstallStarted', 'InstallReportedSucceeded', 'InstallReportedFailed', 'DeploymentReportedSucceeded') | Sort-Object TimestampUtc -Descending | Select-Object -First 1)
    $targetInProgress = $latestEvent.Count -gt 0 -and $latestEvent[0].Boundary -in @('DownloadStarted', 'InstallStarted')
    if ($failedHistory.Count -gt 0 -and $targetInProgress -and ([DateTimeOffset]::Parse($latestEvent[0].TimestampUtc)) -gt ([DateTimeOffset]::Parse($failedHistory[0].DateUtc))) { $failedHistory = @() }
    $lastRecorderState = if ($samples.Count -gt 0) { [string](Get-WudReviewProperty $samples[$samples.Count - 1] 'RecorderState') } else { $null }
    $reportedSuccessHistory = @(Get-WudReviewProperty $Context.UpgradeTracking 'MatchedHistory' @() | Where-Object { [string]$_.Operation -in @('1', 'Installation') -and (Get-WudOperationResultLabel $_.ResultCode) -eq 'Succeeded' })
    $reportedSuccessLogs = @(Get-WudReviewProperty $Context.UpgradeTracking 'MatchedEvents' @() | Where-Object { $_.Boundary -in @('InstallReportedSucceeded', 'DeploymentReportedSucceeded') })
    $reportedSuccess = $reportedSuccessHistory.Count -gt 0 -or $reportedSuccessLogs.Count -gt 0
    $attemptOutcome = if ($rollbackMarker) { 'RolledBack' }
        elseif ($targetPresent -and $buildTransition -eq 'Observed') { 'Succeeded' }
        elseif ($failedHistory.Count -gt 0) { 'Failed' }
        elseif ($targetInProgress -or (@($EligibleAttempts).Count -gt 0 -and $lastRecorderState -in @('SetupActive', 'SetupDownlevel', 'SetupSafeOS', 'SetupFirstBoot', 'SetupOOBE', 'RebootPending'))) { 'InProgress' }
        elseif ($targetPresent -and $reportedSuccess) { 'WindowsUpdateReportedSucceeded' }
        else { 'NotObserved' }
    $outcome = switch ($attemptOutcome) {
        'Succeeded' { 'Upgrade Succeeded' }
        'RolledBack' { 'Rolled Back' }
        'Failed' { 'Failed' }
        'InProgress' { 'Upgrade In Progress' }
        'WindowsUpdateReportedSucceeded' { 'Windows Update Reported Success' }
        default {
            if ($targetPresent) { 'Target OS Present' }
            elseif ($Context.Mode -eq 'Preflight') { 'Monitoring Armed' }
            else { 'No Upgrade Outcome Observed' }
        }
    }
    return [pscustomobject][ordered]@{
        CurrentOsState = $currentState
        BuildTransition = $buildTransition
        AttemptOutcome = $attemptOutcome
        DeploymentSource = $deploymentSource
        OutcomeBanner = $outcome
        TargetPresent = $targetPresent
        WindowsUpdateEvidenceConfirmed = $windowsUpdateConfirmed
        WindowsUpdateReportedSuccess = $reportedSuccess
        SuccessEvidence = @($reportedSuccessHistory | ForEach-Object { [pscustomobject]@{ TimestampUtc = $_.DateUtc; SourceRef = $_.SourceRef; Meaning = 'Installation-operation history reported success, not an exact phase boundary.' } }) + @($reportedSuccessLogs | ForEach-Object { [pscustomobject]@{ TimestampUtc = $_.TimestampUtc; SourceRef = $_.SourceRef; Meaning = 'Exact-identity source record reported success; query time is not necessarily completion time.' } })
        ObservedBuilds = @($observedBuilds)
    }
}

function Invoke-WudFactAnalysis {
    param([Parameter(Mandatory = $true)]$Context)
    Write-WudLog -Context $Context -Level INFO -Message 'Building direct facts and applying strict Windows Update evidence scope gates. No root-cause inference will be performed.'
    $Context.Facts.Clear(); $Context.Attempts.Clear(); $Context.Timeline.Clear(); $Context.Findings.Clear(); $Context.ExcludedEvidence.Clear()
    $currentInventory = [pscustomobject]$Context.Inventory
    $identity = Get-WudReviewProperty $currentInventory 'Identity'
    $featureHistory = @(Get-WudFeatureUpdateHistory -Context $Context -CurrentInventory $currentInventory)
    $Context.UpgradeTracking = Get-WudUpgradeTrackingModel -Context $Context -FeatureHistory $featureHistory
    $Context.UpgradeTiming = Get-WudUpgradeTimingModel -Context $Context -Tracking $Context.UpgradeTracking
    $featureHistory = @($Context.UpgradeTracking.MatchedHistory)
    $currentServicing = Get-WudReviewProperty $currentInventory 'Servicing'
    $allUpdateHistory = @(Get-WudReviewProperty $currentServicing 'UpdateHistory' @())
    $Context.UpdateActivity = Get-WudUpdateActivityModel -Context $Context -Tracking $Context.UpgradeTracking -AllHistory $allUpdateHistory

    $sequence = 0
    $decodedFacts = @{}
    $seenAttemptHashes = @{}
    $setupFiles = @(Get-ChildItem -LiteralPath $Context.EvidencePath -File -Recurse -Filter 'setupact*.log' -ErrorAction SilentlyContinue | Sort-Object `
        @{ Expression = { if ($_.FullName -match '(?i)WindowsBT|SetupCopyLogs') { 4 } elseif ($_.FullName -match '(?i)WindowsOld') { 3 } elseif ($_.FullName -match '(?i)Windows-Panther') { 1 } else { 2 } }; Descending = $true },
        @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true })
    foreach ($file in $setupFiles) {
        $sequence++
        $attempt = Get-WudSetupLogProfile -Context $Context -File $file -Sequence $sequence
        $attempt = Set-WudAttemptScope -Context $Context -Attempt $attempt -FeatureHistory $featureHistory -Identity $identity
        if ($attempt.Sha256 -and $seenAttemptHashes.ContainsKey([string]$attempt.Sha256)) {
            $attempt.DuplicateOf = [string]$seenAttemptHashes[[string]$attempt.Sha256]
            $attempt.IncludedForUpgradeReview = $false
            $attempt.Classification = 'UnclassifiedSetupEvidence'
            $attempt.ExclusionReason = "Byte-identical duplicate of $($attempt.DuplicateOf); retained once for provenance and excluded from duplicate analysis."
            $attempt.Gates.UniqueEvidence = $false
        }
        elseif ($attempt.Sha256) { $seenAttemptHashes[[string]$attempt.Sha256] = $attempt.AttemptId }
        $null = $Context.Attempts.Add($attempt)
        if (-not $attempt.IncludedForUpgradeReview) {
            $null = $Context.ExcludedEvidence.Add([pscustomobject][ordered]@{
                EvidenceRef = $attempt.SourcePath
                Sha256 = $attempt.Sha256
                Classification = $attempt.Classification
                Reason = $attempt.ExclusionReason
                Gates = $attempt.Gates
            })
        }
        $scope = if ($attempt.IncludedForUpgradeReview) { 'Included' } else { 'Excluded' }
        $null = Add-WudReviewFact -Context $Context -FactType Computed -Category 'AttemptScope' -Statement ("Setup evidence was classified as {0}." -f $attempt.Classification) -Value $attempt.Gates -TimestampUtc $attempt.EndedUtc -AttemptId $attempt.AttemptId -SourceRef $attempt.SourcePath -ScopeStatus $scope
        if ($attempt.IncludedForUpgradeReview) {
            foreach ($record in @($attempt.ErrorRecords)) {
                if ($Context.UpgradeTracking.WindowStartUtc -and (-not $record.TimestampUtc -or ([DateTimeOffset]::Parse($record.TimestampUtc)) -lt ([DateTimeOffset]::Parse($Context.UpgradeTracking.WindowStartUtc)))) {
                    $null = $Context.ExcludedEvidence.Add([pscustomobject]@{ EvidenceRef = $record.Reference; Classification = 'OutsideRecordingWindow'; Reason = 'This setup record predates monitoring or lacks a timestamp, even though its containing file was updated later.' })
                    continue
                }
                $code = if (@($record.Codes).Count -gt 0) { @($record.Codes) -join '; ' } else { $null }
                $setupScope = if ($attempt.AttributionBasis -eq 'ExplicitSetupUpdateId') { 'Included' } else { 'ContextOnly' }
                $fact = Add-WudReviewFact -Context $Context -FactType Observed -Category 'WindowsSetup' -Statement ("Windows Setup recorded an error token or code in target-build setup evidence ({0})." -f $attempt.AttributionBasis) -Value $record.Excerpt -TimestampUtc $record.TimestampUtc -AttemptId $attempt.AttemptId -SourceRef $record.Reference -Code $code -Phase $record.Phase -Operation $record.Operation -ScopeStatus $setupScope -Excerpt $record.Excerpt
                $null = $Context.Timeline.Add([pscustomobject][ordered]@{
                    TimestampUtc = $record.TimestampUtc; AttemptId = $attempt.AttemptId; FactId = $fact.FactId
                    EventType = 'SetupLogRecord'; Code = $code; Phase = $record.Phase; Operation = $record.Operation
                    Message = $record.Excerpt; EvidenceReference = $record.Reference
                    ScopeStatus = $setupScope; TimingKind = 'SetupLogTimestamp'; UpdateID = if ($setupScope -eq 'Included') { $Context.UpgradeTracking.Identity.UpdateID } else { $null }; RevisionNumber = $null
                })
                if ($record.ExtendCode -and ($record.Phase -or $record.Operation)) {
                    $decodeKey = '{0}|{1}|{2}' -f $record.ExtendCode, $record.Phase, $record.Operation
                    if (-not $decodedFacts.ContainsKey($decodeKey)) {
                        $decodedFacts[$decodeKey] = $true
                        $null = Add-WudReviewFact -Context $Context -FactType Decoded -Category 'SetupCode' -Statement ("Setup extend code {0} deterministically decodes to phase '{1}' and operation '{2}'." -f $record.ExtendCode, $record.Phase, $record.Operation) -Value ([pscustomobject]@{ ExtendCode = $record.ExtendCode; Phase = $record.Phase; Operation = $record.Operation }) -TimestampUtc $record.TimestampUtc -AttemptId $attempt.AttemptId -SourceRef $record.Reference -Code $record.ExtendCode -Phase $record.Phase -Operation $record.Operation
                    }
                }
                $parsedCodes = Get-WudCodesFromText -Text ([string]$record.Excerpt)
                foreach ($detail in @($parsedCodes.CodeDetails | Where-Object { $_.Name -and [string]$_.Name -match '^[A-Z][A-Z0-9_]+$' })) {
                    $decodeKey = '{0}|{1}' -f $detail.Code, $detail.Name
                    if ($decodedFacts.ContainsKey($decodeKey)) { continue }
                    $decodedFacts[$decodeKey] = $true
                    $null = Add-WudReviewFact -Context $Context -FactType Decoded -Category 'ErrorCode' -Statement ("Code {0} maps to documented symbolic name {1}." -f $detail.Code, $detail.Name) -Value ([pscustomobject]@{ Code = $detail.Code; Type = $detail.Type; SymbolicName = $detail.Name }) -TimestampUtc $record.TimestampUtc -AttemptId $attempt.AttemptId -SourceRef $record.Reference -Code $detail.Code
                }
            }
        }
    }

    $identityRef = '{0}/Inventory/identity.json' -f $Context.PhaseLabel
    if ($identity) {
        $osValue = [pscustomobject][ordered]@{
            DisplayVersion = Get-WudReviewProperty $identity 'DisplayVersion'
            Build = Get-WudReviewProperty $identity 'CurrentBuild'
            UBR = Get-WudReviewProperty $identity 'UBR'
            Edition = Get-WudReviewProperty $identity 'EditionId'
            WindowsImageState = Get-WudReviewProperty $identity 'WindowsImageState'
        }
        $null = Add-WudReviewFact -Context $Context -FactType Observed -Category 'DeviceIdentity' -Statement 'The collector read the current Windows version and image state.' -Value $osValue -TimestampUtc (Get-WudReviewProperty $identity 'CapturedUtc') -SourceRef $identityRef
    }
    Add-WudInventoryFacts -Context $Context -CurrentInventory $currentInventory

    foreach ($entry in $featureHistory) {
        $resultLabel = Get-WudOperationResultLabel -ResultCode $entry.ResultCode
        $statement = 'Windows Update history contains a Windows 11 feature-update entry with result {0}.' -f $resultLabel
        $value = [pscustomobject][ordered]@{
            Title = $entry.Title; Result = $resultLabel; HResultHex = $entry.HResultHex; UpdateID = $entry.UpdateID; RevisionNumber = $entry.RevisionNumber
            ClientApplicationID = $entry.ClientApplicationID; ServerSelection = $entry.ServerSelection; ServiceID = $entry.ServiceID
        }
        $fact = Add-WudReviewFact -Context $Context -FactType SourceReported -Category 'WindowsUpdateHistory' -Statement $statement -Value $value -TimestampUtc $entry.DateUtc -SourceRef $entry.SourceRef -Code $entry.HResultHex -Excerpt ($value | ConvertTo-Json -Compress -Depth 5)
        $null = $Context.Timeline.Add([pscustomobject][ordered]@{
            TimestampUtc = $entry.DateUtc; AttemptId = $null; FactId = $fact.FactId; EventType = 'WindowsUpdateHistory'
            Code = $entry.HResultHex; Phase = $null; Operation = $entry.Operation; Message = $entry.Title; EvidenceReference = $entry.SourceRef
            UpdateID = $entry.UpdateID; RevisionNumber = $entry.RevisionNumber; ScopeStatus = 'Included'; TimingKind = 'AppliedOperationHistory'
        })
    }

    foreach ($process in @($Context.ProcessRecords)) {
        if ([bool](Get-WudReviewProperty $process 'Succeeded' $false)) { continue }
        $name = [string](Get-WudReviewProperty $process 'Name' '<unnamed-process>')
        $value = [pscustomobject][ordered]@{
            ExecutionStatus = Get-WudReviewProperty $process 'ExecutionStatus' 'UnknownStatus'
            ExitCode = Get-WudReviewProperty $process 'ExitCode'; ExitCodeHex = Get-WudReviewProperty $process 'ExitCodeHex'
            ExitCodeAvailable = Get-WudReviewProperty $process 'ExitCodeAvailable'
            TimedOut = Get-WudReviewProperty $process 'TimedOut'; Detail = Get-WudReviewProperty $process 'Detail'; Error = Get-WudReviewProperty $process 'ErrorDetail' (Get-WudReviewProperty $process 'Error')
            ExpectedArtifacts = Get-WudReviewProperty $process 'ExpectedArtifacts' @()
        }
        $null = Add-WudReviewFact -Context $Context -FactType Observed -Category 'CollectorExecution' -Statement ("Collector process '{0}' did not report success." -f $name) -Value $value -TimestampUtc (Get-WudReviewProperty $process 'EndedUtc') -SourceRef ("{0}/Commands/{1}.result.json" -f $Context.PhaseLabel, ($name -replace '[^A-Za-z0-9._-]', '_')) -ScopeStatus ContextOnly
    }
    foreach ($gap in @($Context.CollectionGaps)) {
        $null = Add-WudReviewFact -Context $Context -FactType Observed -Category 'CollectionCoverage' -Statement ("Collector '{0}' recorded coverage status '{1}'." -f (Get-WudReviewProperty $gap 'Collector'), (Get-WudReviewProperty $gap 'Status')) -Value (Get-WudReviewProperty $gap 'Detail') -TimestampUtc (Get-WudReviewProperty $gap 'RecordedUtc') -SourceRef (Get-WudReviewProperty $gap 'Source') -ScopeStatus ContextOnly
    }
    Add-WudActiveDiagnosticFacts -Context $Context

    Add-WudSetupDiagFacts -Context $Context -Attempts @($Context.Attempts)
    foreach ($event in @($Context.UpgradeTracking.MatchedEvents)) {
        $fact = Add-WudReviewFact -Context $Context -FactType SourceReported -Category 'TargetUpdateLifecycle' -Statement ("Windows Update source record: {0} for the locked target upgrade identity." -f $event.Boundary) -Value ([pscustomobject]@{ UpdateID = $event.UpdateID; RevisionNumber = $event.RevisionNumber; ServiceID = $event.ServiceID; EventId = $event.EventId; Boundary = $event.Boundary; TimestampKind = Get-WudReviewProperty $event 'TimestampKind' 'SourceEventUtc'; RuleId = Get-WudReviewProperty $event 'RuleId' }) -TimestampUtc $event.TimestampUtc -SourceRef $event.SourceRef -Excerpt (Get-WudReviewProperty $event 'Excerpt' $event.RawXml)
        $null = $Context.Timeline.Add([pscustomobject][ordered]@{
            TimestampUtc = $event.TimestampUtc; AttemptId = $null; FactId = $fact.FactId; EventType = 'TargetUpdateLifecycle'
            Code = $null; Phase = $event.Boundary; Operation = $null; Message = $event.Title; EvidenceReference = $event.SourceRef
            UpdateID = $event.UpdateID; RevisionNumber = $event.RevisionNumber; ScopeStatus = 'Included'; TimingKind = Get-WudReviewProperty $event 'SourceKind' 'SourceEvent'
        })
    }

    if ($Context.Recorder) {
        $null = Add-WudReviewFact -Context $Context -FactType Computed -Category 'PersistentRecorder' -Statement 'The recorder summarized its timestamped observations without assigning cause.' -Value $Context.Recorder -TimestampUtc (Get-WudReviewProperty $Context.Recorder 'LastSampleUtc') -SourceRef 'Recorder/ProgressSamples.jsonl' -ScopeStatus ContextOnly
        foreach ($transition in @((Get-WudReviewProperty $Context.Recorder 'StateTransitions' @()))) {
            $null = $Context.Timeline.Add([pscustomobject][ordered]@{
                TimestampUtc = Get-WudReviewProperty $transition 'TimestampUtc'; AttemptId = $null; FactId = $null
                EventType = 'RecorderState'; Code = $null; Phase = Get-WudReviewProperty $transition 'State'; Operation = $null
                Message = ('Recorder state changed from {0} to {1}.' -f (Get-WudReviewProperty $transition 'PreviousState'), (Get-WudReviewProperty $transition 'State'))
                EvidenceReference = Get-WudReviewProperty $transition 'EvidenceReference' 'Recorder/ProgressSamples.jsonl'
                ScopeStatus = 'ContextOnly'; TimingKind = 'Observation'; UpdateID = $null; RevisionNumber = $null
            })
        }
    }

    $comparisonResult = @(Get-WudReviewInventoryDiff -Context $Context -CurrentInventory $currentInventory)
    $inventoryDiff = $comparisonResult[0]
    $baselineInventory = if ($comparisonResult.Count -gt 1) { $comparisonResult[1] } else { $null }
    $Context.Inventory = [ordered]@{ Baseline = $baselineInventory; Current = $currentInventory; Diff = $inventoryDiff }

    $eligibleAttempts = @($Context.Attempts | Where-Object IncludedForUpgradeReview)
    $Context.StatusModel = Get-WudUpgradeStatusModel -Context $Context -Identity $identity -FeatureHistory $featureHistory -EligibleAttempts $eligibleAttempts
    $Context.Outcome = $Context.StatusModel.OutcomeBanner
    $Context.PrimaryFinding = $null
    $Context.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    $Context.ExitCode = if (-not $Context.CollectionComplete) { 30 } elseif ($Context.Outcome -in @('Failed', 'Rolled Back')) { 20 } else { 0 }
    $sortedTimeline = @($Context.Timeline | Sort-Object { if ($_.TimestampUtc) { [DateTimeOffset]::Parse([string]$_.TimestampUtc).UtcTicks } else { [long]::MaxValue } })
    $Context.Timeline.Clear(); foreach ($item in $sortedTimeline) { $null = $Context.Timeline.Add($item) }
    $Context.ReviewData = [pscustomobject][ordered]@{
        AnalysisMode = 'FactOnly'
        FeatureUpdateHistory = @($featureHistory)
        AllUpdateHistory = @($allUpdateHistory)
        UpgradeTracking = $Context.UpgradeTracking
        UpgradeTiming = $Context.UpgradeTiming
        UpdateActivity = $Context.UpdateActivity
        InventoryDiff = $inventoryDiff
        Recorder = $Context.Recorder
        StatusModel = $Context.StatusModel
        ValidatedAttemptCount = @($eligibleAttempts).Count
        ExcludedAttemptCount = @($Context.Attempts | Where-Object { -not $_.IncludedForUpgradeReview }).Count
    }
    $analysis = [pscustomobject][ordered]@{
        SchemaVersion = 3; SchemaSemanticVersion = '2.0.0'; ToolVersion = $Context.ToolVersion; RunId = $Context.RunId
        AnalysisMode = 'FactOnly'; Outcome = $Context.Outcome; StatusModel = $Context.StatusModel; Recorder = $Context.Recorder; ExitCode = $Context.ExitCode
        UpgradeTracking = $Context.UpgradeTracking; UpgradeTiming = $Context.UpgradeTiming
        UpdateActivity = $Context.UpdateActivity
        Attempts = @($Context.Attempts); Facts = @($Context.Facts); Findings = @(); Timeline = @($Context.Timeline)
        ExcludedEvidence = @($Context.ExcludedEvidence); Inventory = $Context.Inventory
        StartedUtc = $Context.StartedUtc; CompletedUtc = $Context.CompletedUtc
    }
    Write-WudJsonAtomic -Path (Join-Path $Context.RunPath 'analysis.json') -InputObject $analysis -Depth 50
    return $analysis
}

function Write-WudJsonLines {
    param([string]$Path, $Records)
    $builder = New-Object Text.StringBuilder
    foreach ($record in @($Records)) { $null = $builder.AppendLine(($record | ConvertTo-Json -Compress -Depth 30)) }
    Write-WudText -Path $Path -Text $builder.ToString()
}

function Export-WudReviewCsv {
    param($Records, [string[]]$Headers, [string]$Path)
    $rows = @($Records)
    if ($rows.Count -gt 0) {
        @($rows | Select-Object -Property $Headers) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
    else {
        $line = (@($Headers | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ',') + [Environment]::NewLine
        Write-WudText -Path $Path -Text $line
    }
}

function Get-WudEvidenceScopeClass {
    param([string]$RelativePath, $Attempts)
    $normalized = $RelativePath.Replace('\', '/')
    if ($normalized -match '(?i)/CurrentDiagnostics/' -or $normalized -match '(?i)/Commands/(?:dism-scanhealth|sfc-verifyonly)') { return 'CurrentHealthDiagnostic' }
    if ($normalized -match '(?i)/Compatibility/MediaScan/') { return 'DiagnosticCompatibilityScan' }
    if ($normalized -match '(?i)/(?:Commands|SetupDiag|Compatibility/AppraiserRefresh)/') { return 'ToolGenerated' }
    if ($normalized -match '(?i)/Raw/Windows-Panther/') { return 'InitialDeploymentOrImaging' }
    if ($normalized -match '(?i)/Raw/(?:Windows-CBS|Windows-DISM)/') { return 'GeneralWindowsServicing' }
    foreach ($attempt in @($Attempts)) {
        $prefix = [string]$attempt.SourceDirectory
        if ($prefix -and $normalized.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return [string]$attempt.Classification }
    }
    if ($normalized -match '(?i)/Raw/(?:WindowsBT|WindowsOld|WUPA-SetupCopyLogs)') { return 'UnclassifiedSetupEvidence' }
    return 'ContextEvidence'
}

function Export-WudReviewBundle {
    param([Parameter(Mandatory = $true)]$Context)
    Write-WudLog -Context $Context -Level INFO -Message 'Creating the provider-neutral drag-and-drop ReviewBundle.zip.'
    $staging = Join-Path $Context.RunPath 'ReviewBundleStaging'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    $null = New-WudDirectory -Path $staging
    $excerptPath = New-WudDirectory -Path (Join-Path $staging 'Excerpts')
    $recorderSummary = if ($Context.Recorder) { $Context.Recorder } else { [pscustomobject][ordered]@{ SampleCount = 0; FirstSampleUtc = $null; LastSampleUtc = $null; StatesObserved = @(); StateTransitions = @(); DeliveryOptimization = $null } }

    foreach ($fact in @($Context.Facts)) {
        if ([string]::IsNullOrWhiteSpace([string]$fact.Excerpt)) { continue }
        $name = $fact.FactId + '.txt'
        Write-WudText -Path (Join-Path $excerptPath $name) -Text ([string]$fact.Excerpt)
        $fact.ExcerptFile = 'Excerpts/' + $name
    }

    $current = Get-WudReviewProperty $Context.Inventory 'Current'
    $identity = Get-WudReviewProperty $current 'Identity'
    $case = [pscustomobject][ordered]@{
        SchemaVersion = 2
        SchemaSemanticVersion = '2.0.0'
        ToolVersion = $Context.ToolVersion
        AnalysisMode = 'FactOnly'
        RunId = $Context.RunId
        Mode = $Context.Mode
        PhaseLabel = $Context.PhaseLabel
        StartedUtc = $Context.StartedUtc
        CompletedUtc = $Context.CompletedUtc
        Sensitive = $true
        Device = [pscustomobject][ordered]@{
            ComputerName = Get-WudReviewProperty $identity 'ComputerName'; Manufacturer = Get-WudReviewProperty $identity 'Manufacturer'
            Model = Get-WudReviewProperty $identity 'Model'; SerialNumber = Get-WudReviewProperty $identity 'SerialNumber'
        }
        CurrentOs = [pscustomobject][ordered]@{
            DisplayVersion = Get-WudReviewProperty $identity 'DisplayVersion'; Build = Get-WudReviewProperty $identity 'CurrentBuild'
            UBR = Get-WudReviewProperty $identity 'UBR'; Edition = Get-WudReviewProperty $identity 'EditionId'
            WindowsImageState = Get-WudReviewProperty $identity 'WindowsImageState'
        }
        TargetOs = [pscustomobject][ordered]@{ DisplayVersion = $Context.TargetVersion; BuildFamily = $Context.Target.buildFamily }
        ObservedOutcome = $Context.Outcome
        StatusModel = $Context.StatusModel
        UpgradeIdentity = Get-WudReviewProperty $Context.UpgradeTracking 'Identity'
        UpgradeTiming = $Context.UpgradeTiming
        Recorder = $recorderSummary
        UpdateActivity = $Context.UpdateActivity
        CollectionComplete = $Context.CollectionComplete
        ValidatedWindowsUpdateAttempts = @($Context.Attempts | Where-Object IncludedForUpgradeReview).Count
        ExcludedSetupCandidates = @($Context.Attempts | Where-Object { -not $_.IncludedForUpgradeReview }).Count
        InterpretationBoundary = 'The package emits direct observations, source-reported results, deterministic decodes, and transparent computed scope gates. It does not assert root cause.'
    }
    Write-WudJsonAtomic -Path (Join-Path $staging 'Case.json') -InputObject $case -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $staging 'UpgradeIdentity.json') -InputObject (Get-WudReviewProperty $Context.UpgradeTracking 'Identity') -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $staging 'UpgradeTiming.json') -InputObject $Context.UpgradeTiming -Depth 25
    Write-WudJsonAtomic -Path (Join-Path $staging 'WindowsUpdateLogCoverage.json') -InputObject (Get-WudReviewProperty $Context.UpgradeTracking 'LogCoverage' @()) -Depth 15
    $traceCoverage = @(Get-ChildItem -LiteralPath $Context.EvidencePath -File -Recurse -Filter 'ETLCoverage.json' -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ EvidenceRef = (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $_.FullName).Replace('\', '/'); Coverage = Read-WudJson $_.FullName }
    })
    Write-WudJsonAtomic -Path (Join-Path $staging 'NativeTraceCoverage.json') -InputObject @($traceCoverage) -Depth 30
    Write-WudJsonAtomic -Path (Join-Path $staging 'UpdateActivity.json') -InputObject $Context.UpdateActivity -Depth 30
    Write-WudJsonLines -Path (Join-Path $staging 'AllUpdatesTimeline.jsonl') -Records @(Get-WudReviewProperty $Context.UpdateActivity 'Timeline' @())
    Write-WudJsonLines -Path (Join-Path $staging 'TargetUpdateEvents.jsonl') -Records @(Get-WudReviewProperty $Context.UpgradeTracking 'MatchedEvents' @())
    Write-WudJsonAtomic -Path (Join-Path $staging 'Attempts.json') -InputObject @($Context.Attempts) -Depth 40
    Write-WudJsonAtomic -Path (Join-Path $staging 'Inventory.json') -InputObject $Context.Inventory -Depth 40
    Write-WudJsonAtomic -Path (Join-Path $staging 'InventoryDiff.json') -InputObject $Context.ReviewData.InventoryDiff -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $staging 'CollectionCoverage.json') -InputObject ([pscustomobject]@{ Complete = $Context.CollectionComplete; Collectors = @($Context.CollectorRecords); Gaps = @($Context.CollectionGaps) }) -Depth 30
    Write-WudJsonAtomic -Path (Join-Path $staging 'RecorderSummary.json') -InputObject $recorderSummary -Depth 30
    Write-WudJsonAtomic -Path (Join-Path $staging 'ExcludedEvidence.json') -InputObject @($Context.ExcludedEvidence) -Depth 30
    Write-WudJsonLines -Path (Join-Path $staging 'Facts.jsonl') -Records @($Context.Facts)
    Write-WudJsonLines -Path (Join-Path $staging 'Timeline.jsonl') -Records @($Context.Timeline)
    Write-WudJsonLines -Path (Join-Path $staging 'UpdateHistory.jsonl') -Records @($Context.ReviewData.AllUpdateHistory)
    $recorderRoot = Join-Path $Context.RunPath 'Evidence\Recorder'
    foreach ($name in @('ProgressSamples.jsonl', 'StateTransitions.jsonl', 'UpdateEvents.jsonl', 'UpdateEventCoverage.jsonl', 'CheckpointCoverage.jsonl')) {
        $source = Join-Path $recorderRoot $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $staging $name) -Force }
        else { Write-WudText -Path (Join-Path $staging $name) -Text '' }
    }
    $checkpointManifests = @(Get-ChildItem -LiteralPath (Join-Path $recorderRoot 'Checkpoints') -File -Recurse -Filter 'checkpoint-manifest.json' -ErrorAction SilentlyContinue | ForEach-Object { Read-WudJson -Path $_.FullName })
    Write-WudJsonAtomic -Path (Join-Path $staging 'Checkpoints.json') -InputObject @($checkpointManifests) -Depth 30

    $factRows = @($Context.Facts | ForEach-Object {
        [pscustomobject][ordered]@{
            FactId = $_.FactId; FactType = $_.FactType; Category = $_.Category; ScopeStatus = $_.ScopeStatus
            TimestampUtc = $_.TimestampUtc; AttemptId = $_.AttemptId; Statement = ConvertTo-WudCsvCell $_.Statement
            Value = ConvertTo-WudCsvCell $(if ($_.Value -is [string]) { $_.Value } else { $_.Value | ConvertTo-Json -Compress -Depth 10 })
            Code = $_.Code; Phase = $_.Phase; Operation = $_.Operation; EvidenceRef = ConvertTo-WudCsvCell $_.EvidenceRef; ExcerptFile = $_.ExcerptFile
        }
    })
    Export-WudReviewCsv -Records $factRows -Headers @('FactId', 'FactType', 'Category', 'ScopeStatus', 'TimestampUtc', 'AttemptId', 'Statement', 'Value', 'Code', 'Phase', 'Operation', 'EvidenceRef', 'ExcerptFile') -Path (Join-Path $staging 'Facts.csv')
    Export-WudReviewCsv -Records @($Context.Timeline) -Headers @('TimestampUtc', 'AttemptId', 'FactId', 'EventType', 'Code', 'Phase', 'Operation', 'Message', 'EvidenceReference', 'UpdateID', 'RevisionNumber', 'ScopeStatus', 'TimingKind') -Path (Join-Path $staging 'Timeline.csv')
    Export-WudReviewCsv -Records @(Get-WudReviewProperty $Context.UpdateActivity 'Timeline' @()) -Headers @('TimestampUtc', 'ActivityKey', 'UpdateID', 'RevisionNumber', 'ServiceID', 'Role', 'Boundary', 'EventId', 'Title', 'EvidenceReference', 'TimingKind') -Path (Join-Path $staging 'AllUpdatesTimeline.csv')

    $evidenceIndex = New-Object Collections.ArrayList
    foreach ($item in @(Get-WudFileInventory -RootPath $Context.EvidencePath)) {
        $class = Get-WudEvidenceScopeClass -RelativePath $item.RelativePath -Attempts @($Context.Attempts)
        $null = $evidenceIndex.Add([pscustomobject][ordered]@{
            EvidenceRef = $item.RelativePath.Replace('\', '/'); ScopeClass = $class
            IncludedForUpgradeReview = $class -eq 'WindowsUpdateFeatureUpgrade'
            Length = $item.Length; LastWriteUtc = $item.LastWriteUtc; Sha256 = $item.Sha256
        })
    }
    Write-WudJsonLines -Path (Join-Path $staging 'EvidenceIndex.jsonl') -Records @($evidenceIndex)

    $readMe = @'
# WUPA - external review bundle

This archive is sensitive. It can contain device names, users, domains, paths, network identifiers, serial numbers, software inventory, and bounded log excerpts.

## Interpretation contract

- `Observed`: the collector directly read the value or log record.
- `SourceReported`: Windows Update, Windows Setup, or SetupDiag reported the value.
- `Decoded`: a documented numeric code was deterministically decoded.
- `Computed`: transparent arithmetic, diff, or evidence-scope gates; never a causal claim.
- Only attempts classified `WindowsUpdateFeatureUpgrade` passed every scope gate and are included in the upgrade timeline.
- Imaging, general servicing, compatibility scan-only, and tool-generated evidence remain indexed but are excluded from upgrade conclusions.
- This tool does not determine root cause. A human or external review utility must distinguish direct failure records, contributing conditions, coincidence, and cause.

Start with `Case.json`, `RecorderSummary.json`, `ProgressSamples.jsonl`, `Attempts.json`, `Facts.jsonl`, `Timeline.jsonl`, and `CollectionCoverage.json`. Recorder states are observations, not proof that a delay was caused by download, Setup, reboot, or user activity. Use `EvidenceIndex.jsonl` to resolve hashes and `Excerpts/` for bounded source text. Request `Evidence.zip` separately when full raw logs are necessary.

`UpgradeIdentity.json` fixes the target UpdateID/revision. `TargetUpdateEvents.jsonl` contains matching lifecycle events. `UpdateActivity.json` and `AllUpdatesTimeline.csv`/`.jsonl` separate every observed GUID/revision with independent operations/results. Concurrent updates do not change the target outcome. `UpdateEvents.jsonl` and `UpdateHistory.jsonl` retain original context. `UpgradeTiming.json` separates source-event boundaries, missing boundaries, and observed target-OS bounds. DO FileId is a file identity, not an update identity. SetupDiag statements with `ContextOnly` scope do not have a direct setup-log GUID link. Raw ETLs, root coverage, and per-file capture status are in Evidence.zip; collection cannot recover traces Windows already deleted or guarantee a live trace was flushed.
'@
    Write-WudText -Path (Join-Path $staging 'READ_ME_FIRST.md') -Text $readMe
    $prompt = @'
# Suggested external-review prompt

Review this Windows feature-update evidence bundle. Treat `Facts.jsonl` and `ProgressSamples.jsonl` as statements of record, not as proof of causation. Analyze setup content only for attempts in `Attempts.json` where `IncludedForUpgradeReview` is true. Explicitly ignore excluded imaging, scan-only, general-servicing, and tool-generated records when determining the upgrade sequence. Recorder state changes may segment observed activity but do not prove why an interval was quiet.

Report:
1. The factual upgrade sequence, with evidence references.
2. Every source-reported failure/result code and its deterministic phase/operation decode.
3. Plausible explanations separated into supported, unsupported, and information-needed categories.
4. Contradictory evidence and collection gaps.
5. The smallest next investigative step; do not recommend a repair unless evidence supports it.

Never state root cause without quoting the exact evidence reference that supports the causal link. Temporal proximity alone is not causation.
'@
    Write-WudText -Path (Join-Path $staging 'REVIEW_PROMPT.md') -Text $prompt

    $manifestLines = New-Object Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $staging -File -Recurse | Sort-Object FullName)) {
        $relative = (Get-WudRelativePath -BasePath $staging -Path $file.FullName).Replace('\', '/')
        $hash = Get-WudFileHashSafe -Path $file.FullName
        if ($hash) { $null = $manifestLines.Add("$hash  $relative") }
    }
    Write-WudText -Path (Join-Path $staging 'Manifest.sha256') -Text ((@($manifestLines) -join [Environment]::NewLine) + [Environment]::NewLine)
    $destination = Join-Path $Context.OutputPath 'ReviewBundle.zip'
    New-WudEvidenceArchive -SourcePath $staging -DestinationPath $destination -Context $Context
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archive = [IO.Compression.ZipFile]::OpenRead($destination)
    try {
        $entryNames = @($archive.Entries | ForEach-Object FullName)
        foreach ($required in @('READ_ME_FIRST.md', 'Case.json', 'RecorderSummary.json', 'ProgressSamples.jsonl', 'StateTransitions.jsonl', 'Checkpoints.json', 'Attempts.json', 'Facts.jsonl', 'Timeline.jsonl', 'EvidenceIndex.jsonl', 'Manifest.sha256')) {
            if ($entryNames -notcontains $required) { throw "Review bundle is missing required entry '$required'." }
        }
        $entryMap = @{}
        foreach ($entry in $archive.Entries) { $entryMap[$entry.FullName.ToLowerInvariant()] = $entry }
        foreach ($line in @($manifestLines)) {
            if ($line -notmatch '^([a-f0-9]{64})\s+(.+)$') { throw "Review bundle manifest line is malformed: $line" }
            $expected = $matches[1]
            $entryName = $matches[2]
            $key = $entryName.ToLowerInvariant()
            if (-not $entryMap.ContainsKey($key)) { throw "Review bundle manifest entry is missing from the archive: $entryName" }
            $stream = $null
            $sha = $null
            try {
                $stream = $entryMap[$key].Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
                if ($actual -ne $expected) { throw "Review bundle hash mismatch: $entryName" }
            }
            finally {
                if ($sha) { $sha.Dispose() }
                if ($stream) { $stream.Dispose() }
            }
        }
    }
    finally { $archive.Dispose() }
    $Context.ReviewBundle = [pscustomobject][ordered]@{
        Path = $destination; Sha256 = Get-WudFileHashSafe -Path $destination; Verified = $true; FactCount = @($Context.Facts).Count
        ValidatedAttemptCount = @($Context.Attempts | Where-Object IncludedForUpgradeReview).Count
        ExcludedAttemptCount = @($Context.Attempts | Where-Object { -not $_.IncludedForUpgradeReview }).Count
    }
    return $Context.ReviewBundle
}

Export-ModuleMember -Function @('Invoke-WudFactAnalysis', 'Export-WudReviewBundle', 'Get-WudSetupLogProfile', 'Set-WudAttemptScope', 'Get-WudUpgradeStatusModel', 'Get-WudFeatureUpdateHistory', 'Get-WudUpgradeTrackingModel', 'Get-WudUpgradeTimingModel', 'Get-WudUpdateActivityModel')
