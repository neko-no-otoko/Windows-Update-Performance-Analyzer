Set-StrictMode -Version 2.0

function Test-WudTargetUpgradeTitle {
    param([string]$Title, [string]$TargetVersion = '25H2')
    # A product/version string also appears in quality-update titles. It is not
    # sufficient to identify an OS upgrade. Unknown/localized titles stay unknown.
    if ($Title -match '(?i)cumulative|security|defender|antivirus|intelligence|driver|\.NET|dynamic update|servicing stack|preview') { return $false }
    $target = [Regex]::Escape($TargetVersion)
    if ($Title -match "(?i)^(?:Feature update to\s+)?Windows 11(?:\s+\((?:business|consumer) editions\))?,?\s+(?:version\s+)?$target\b") { return $true }
    if ($Title -match "(?i)enablement package" -and $Title -match "(?i)Windows 11.*$target\b") { return $true }
    return $TargetVersion -eq '25H2' -and $Title -match '(?i)\bKB5054156\b'
}

function ConvertTo-WudUpdateGuid {
    param($Value)
    $guid = [Guid]::Empty
    if ([Guid]::TryParse([string]$Value, [ref]$guid) -and $guid -ne [Guid]::Empty) { return $guid.ToString('D') }
    return $null
}

function ConvertFrom-WudUpdateEventXml {
    param([Parameter(Mandatory = $true)][string]$Xml, [string]$SourceRef)
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($Xml)), $settings)
    try {
        $document = New-Object Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
    }
    finally { $reader.Dispose() }
    $system = $document.SelectSingleNode("/*[local-name()='Event']/*[local-name()='System']")
    if (-not $system) { return $null }
    $provider = $system.SelectSingleNode("*[local-name()='Provider']")
    if (-not $provider -or $provider.GetAttribute('Name') -ne 'Microsoft-Windows-WindowsUpdateClient') { return $null }
    $data = @{}
    foreach ($node in $document.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']")) {
        $name = $node.GetAttribute('Name')
        if ($name) { $data[$name] = $node.InnerText }
    }
    $updateId = $null
    foreach ($name in @('updateGuid', 'updateID', 'UpdateId')) {
        if ($data.ContainsKey($name)) { $updateId = ConvertTo-WudUpdateGuid $data[$name]; if ($updateId) { break } }
    }
    $revision = $null
    foreach ($name in @('updateRevisionNumber', 'RevisionNumber')) {
        if ($data.ContainsKey($name) -and $data[$name] -match '^\d+$') { $revision = [int]$data[$name]; break }
    }
    $title = if ($data.ContainsKey('updateTitle')) { [string]$data.updateTitle } else { $null }
    $service = if ($data.ContainsKey('serviceGuid')) { ConvertTo-WudUpdateGuid $data.serviceGuid } else { $null }
    $id = [int]$system.SelectSingleNode("*[local-name()='EventID']").InnerText
    $keywordsNode = $system.SelectSingleNode("*[local-name()='Keywords']")
    $keywords = [UInt64]0
    if ($keywordsNode) { try { $keywords = [Convert]::ToUInt64($keywordsNode.InnerText.Replace('0x', ''), 16) } catch { } }
    $boundary = switch ($id) {
        19 { 'InstallReportedSucceeded' }
        20 { 'InstallReportedFailed' }
        21 { 'RebootRequired' }
        31 { 'DownloadFailed' }
        43 { 'InstallStarted' }
        44 { 'DownloadStarted' }
        default { 'UpdateEvent' }
    }
    # Provider keyword masks supply locale-neutral semantics for download
    # completion; do not assume that a generic event number is a completion.
    # WU keyword bits are Download=0x4, Success=0x10 and Started=0x2000.
    # Operational event 41 uses 0x...0014, not the old synthetic 0x...4004.
    if (($keywords -band [UInt64]0x14) -eq [UInt64]0x14) { $boundary = 'DownloadCompleted' }
    elseif (($keywords -band [UInt64]0x2004) -eq [UInt64]0x2004) { $boundary = 'DownloadStarted' }
    $timestamp = $system.SelectSingleNode("*[local-name()='TimeCreated']").GetAttribute('SystemTime')
    $channel = $system.SelectSingleNode("*[local-name()='Channel']").InnerText
    $record = $system.SelectSingleNode("*[local-name()='EventRecordID']").InnerText
    $correlation = $system.SelectSingleNode("*[local-name()='Correlation']")
    return [pscustomobject][ordered]@{
        TimestampUtc = ([DateTimeOffset]::Parse($timestamp)).UtcDateTime.ToString('o')
        Provider = $provider.GetAttribute('Name'); Channel = $channel; RecordId = $record; EventId = $id
        UpdateID = $updateId; RevisionNumber = $revision; ServiceID = $service; Title = $title
        Boundary = $boundary; Keywords = if ($keywordsNode) { $keywordsNode.InnerText } else { $null }
        ActivityId = if ($correlation) { $correlation.GetAttribute('ActivityID') } else { $null }
        Data = $data; SourceRef = $SourceRef; RawXml = $Xml
    }
}

function Get-WudUpdateEventRecords {
    param([DateTime]$StartTime, [DateTime]$EndTime = [DateTime]::UtcNow, [int]$MaximumEvents = 2000)
    $records = New-Object Collections.ArrayList
    $providers = New-Object Collections.ArrayList
    foreach ($channel in @('System', 'Microsoft-Windows-WindowsUpdateClient/Operational')) {
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = $channel; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; StartTime = $StartTime; EndTime = $EndTime } -MaxEvents ($MaximumEvents + 1) -ErrorAction Stop)
            $null = $providers.Add([pscustomobject]@{ Channel = $channel; Status = if ($events.Count -gt $MaximumEvents) { 'Truncated' } else { 'Available' }; Error = $null; StartUtc = $StartTime.ToUniversalTime().ToString('o'); EndUtc = $EndTime.ToUniversalTime().ToString('o') })
            foreach ($event in @($events | Select-Object -First $MaximumEvents)) {
                $record = ConvertFrom-WudUpdateEventXml -Xml $event.ToXml() -SourceRef ("$channel#RecordId=$($event.RecordId)")
                if ($record) { $null = $records.Add($record) }
            }
        }
        catch {
            $noEvents = $_.FullyQualifiedErrorId -match 'NoMatchingEventsFound'
            $null = $providers.Add([pscustomobject]@{ Channel = $channel; Status = if ($noEvents) { 'AvailableEmpty' } else { 'Failed' }; Error = if ($noEvents) { $null } else { Get-WudErrorDetail $_ }; StartUtc = $StartTime.ToUniversalTime().ToString('o'); EndUtc = $EndTime.ToUniversalTime().ToString('o') })
        }
    }
    return [pscustomobject]@{ Records = @($records | Sort-Object TimestampUtc); Providers = @($providers) }
}

function Get-WudArchivedUpdateEventRecords {
    param($Context, [DateTime]$StartTime, [int]$MaximumEvents = 10000)
    $records = New-Object Collections.ArrayList; $providers = New-Object Collections.ArrayList
    foreach ($name in @('WindowsOld-System.evtx', 'WindowsOld-WindowsUpdateClient.evtx')) {
        $path = Join-Path $Context.SnapshotPath ('Raw/' + $name)
        $relative = (Get-WudRelativePath $Context.EvidencePath $path).Replace('\', '/')
        if (-not (Test-Path -LiteralPath $path)) { $null = $providers.Add([pscustomobject]@{ Channel = $relative; Status = 'ArchiveNotRetained'; Error = $null }); continue }
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ Path = $path; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; StartTime = $StartTime; EndTime = [DateTime]::UtcNow } -MaxEvents ($MaximumEvents + 1) -ErrorAction Stop)
            foreach ($event in @($events | Select-Object -First $MaximumEvents)) {
                $record = ConvertFrom-WudUpdateEventXml -Xml $event.ToXml() -SourceRef ("${relative}#RecordId=$($event.RecordId)")
                if (-not $record) { continue }
                $record.Channel = 'WindowsOld/' + $record.Channel
                $record | Add-Member -NotePropertyName SourceKind -NotePropertyValue 'ArchivedEvent'
                $record | Add-Member -NotePropertyName TimingStream -NotePropertyValue 'WindowsOldNativeEvents'
                $null = $records.Add($record)
            }
            $null = $providers.Add([pscustomobject]@{ Channel = $relative; Status = if ($events.Count -gt $MaximumEvents) { 'Truncated' } else { 'Available' }; Error = $null })
        } catch {
            $empty = $_.FullyQualifiedErrorId -match 'NoMatchingEventsFound'
            $null = $providers.Add([pscustomobject]@{ Channel = $relative; Status = if ($empty) { 'AvailableEmpty' } else { 'Failed' }; Error = if ($empty) { $null } else { Get-WudErrorDetail $_ } })
        }
    }
    [pscustomobject]@{ Records = @($records); Providers = @($providers) }
}

function Resolve-WudUpgradeIdentity {
    param($Records = @(), [string]$TargetVersion = '25H2', $ExistingLock)
    $existingId = ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $ExistingLock 'UpdateID')
    if ($existingId -and (Get-WudObjectPropertyValue $ExistingLock 'Status') -eq 'Locked') { return $ExistingLock }
    $candidates = @($Records | Where-Object {
        (Test-WudTargetUpgradeTitle -Title ([string](Get-WudObjectPropertyValue $_ 'Title')) -TargetVersion $TargetVersion) -and
        (ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $_ 'UpdateID'))
    } | Group-Object { '{0}|{1}' -f (ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $_ 'UpdateID')), (Get-WudObjectPropertyValue $_ 'RevisionNumber') })
    $status = if ($candidates.Count -eq 1 -and $null -ne (Get-WudObjectPropertyValue $candidates[0].Group[0] 'RevisionNumber')) { 'Locked' } elseif ($candidates.Count -eq 1) { 'Incomplete' } elseif ($candidates.Count -gt 1) { 'Ambiguous' } else { 'NotObserved' }
    $selected = if ($candidates.Count -eq 1) { $candidates[0].Group[0] } else { $null }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1; Status = $status; TargetVersion = $TargetVersion
        UpdateID = if ($selected) { ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $selected 'UpdateID') } else { $null }
        RevisionNumber = Get-WudObjectPropertyValue $selected 'RevisionNumber'
        ServiceID = Get-WudObjectPropertyValue $selected 'ServiceID'
        Title = Get-WudObjectPropertyValue $selected 'Title'
        FirstObservedUtc = Get-WudObjectPropertyValue $selected 'TimestampUtc' (Get-WudObjectPropertyValue $selected 'DateUtc')
        EvidenceRef = Get-WudObjectPropertyValue $selected 'SourceRef'
        Candidates = @($candidates | ForEach-Object { [pscustomobject]@{ UpdateID = ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $_.Group[0] 'UpdateID'); RevisionNumber = Get-WudObjectPropertyValue $_.Group[0] 'RevisionNumber'; Title = Get-WudObjectPropertyValue $_.Group[0] 'Title'; EvidenceRef = Get-WudObjectPropertyValue $_.Group[0] 'SourceRef' } })
        Reason = switch ($status) { 'Locked' { 'One target upgrade identity was directly observed; subsequent identities cannot replace it.' }; 'Incomplete' { 'A target GUID was observed without its revision; exact revision matching is not yet possible.' }; 'Ambiguous' { 'Multiple target upgrade identities/revisions were observed. None was selected automatically.' }; default { 'No exact target feature-update identity was observed.' } }
    }
}

function Test-WudUpgradeIdentityMatch {
    param($Record, $Identity)
    if ((Get-WudObjectPropertyValue $Identity 'Status') -ne 'Locked') { return $false }
    $id = ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $Record 'UpdateID')
    if (-not $id -or $id -ne (ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $Identity 'UpdateID'))) { return $false }
    $revision = Get-WudObjectPropertyValue $Record 'RevisionNumber'
    $lockedRevision = Get-WudObjectPropertyValue $Identity 'RevisionNumber'
    if ($null -eq $revision -or $null -eq $lockedRevision -or [string]$revision -ne [string]$lockedRevision) { return $false }
    $service = ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $Record 'ServiceID')
    $lockedService = ConvertTo-WudUpdateGuid (Get-WudObjectPropertyValue $Identity 'ServiceID')
    if ($service -and $lockedService -and $service -ne $lockedService) { return $false }
    $title = [string](Get-WudObjectPropertyValue $Record 'Title')
    if ($title -match '(?i)cumulative|security|defender|antivirus|intelligence|driver|\.NET|dynamic update|servicing stack|preview') { return $false }
    # Once the exact GUID/revision is known, localized or omitted display titles
    # need not be reclassified. Explicitly conflicting release titles still fail.
    if ($title -match '(?i)Windows 11.*\bversion\s+(\d{2}H[12])\b' -and $matches[1] -ne [string](Get-WudObjectPropertyValue $Identity 'TargetVersion' '25H2')) { return $false }
    return $true
}

function Update-WudUpgradeTracking {
    param([string]$RunPath, [string]$TargetVersion = '25H2', [DateTime]$SinceUtc)
    $root = New-WudDirectory -Path (Join-Path $RunPath 'Evidence/Recorder')
    $cursorPath = Join-Path $RunPath 'State/update-event-cursor.json'
    $lockPath = Join-Path $RunPath 'State/upgrade-identity.json'
    $cursor = Read-WudJson -Path $cursorPath
    $previousEnd = Get-WudObjectPropertyValue $cursor 'EndUtc'
    $start = if ($previousEnd) { ([DateTimeOffset]::Parse($previousEnd)).UtcDateTime.AddMinutes(-2) } else { $SinceUtc }
    $end = [DateTime]::UtcNow
    $query = Get-WudUpdateEventRecords -StartTime $start -EndTime $end
    $recentKeys = @(Get-WudObjectPropertyValue $cursor 'RecentKeys' @())
    $keys = New-Object Collections.ArrayList
    foreach ($record in $query.Records) {
        $key = '{0}|{1}|{2}' -f $record.Channel, $record.RecordId, $record.TimestampUtc
        $null = $keys.Add($key)
        if ($key -in $recentKeys) { continue }
        Write-WudJsonLine -Path (Join-Path $root 'UpdateEvents.jsonl') -InputObject $record -Depth 12
    }
    $identity = Resolve-WudUpgradeIdentity -Records $query.Records -TargetVersion $TargetVersion -ExistingLock (Read-WudJson -Path $lockPath)
    Write-WudJsonAtomic -Path $lockPath -InputObject $identity -Depth 12
    # Unsupported channels must not make the shared watermark drift backwards
    # and repeatedly duplicate an ever-growing window. Failed intervals stay
    # explicit; the final native export and run-window query recover retained data.
    Write-WudJsonAtomic -Path $cursorPath -InputObject ([pscustomobject]@{ EndUtc = $end.ToString('o'); RecentKeys = @($keys) })
    Write-WudJsonLine -Path (Join-Path $root 'UpdateEventCoverage.jsonl') -InputObject ([pscustomobject]@{ TimestampUtc = $end.ToString('o'); Providers = $query.Providers }) -Depth 8
    return [pscustomobject]@{ Identity = $identity; Providers = $query.Providers; MatchedBoundaries = @($query.Records | Where-Object { Test-WudUpgradeIdentityMatch $_ $identity } | Select-Object TimestampUtc, UpdateID, RevisionNumber, Boundary, SourceRef) }
}

function Get-WudWindowsUpdateConversionPlan {
    param($Context)
    foreach ($set in @(
        @{ Name = 'Current'; Root = 'WindowsUpdate-ETL'; Log = 'WindowsUpdate.log' },
        @{ Name = 'WindowsOld'; Root = 'WindowsOld-WindowsUpdate-ETL'; Log = 'WindowsUpdate.WindowsOld.log' }
    )) {
        $root = Join-Path $Context.SnapshotPath ('Raw/' + $set.Root)
        $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)\.etl(?:\.(?:old|bak|\d+))*$' } | Sort-Object FullName)
        [pscustomobject]@{ Name = $set.Name; InputRoot = $root; Files = $files; LogPath = Join-Path $Context.SnapshotPath ('WindowsUpdate/' + $set.Log) }
    }
}

function ConvertFrom-WudWindowsUpdateLogLine {
    param([string]$Line, [string]$SourceRef, [string]$TimeZoneId, [string]$Stream, $Rules)
    # An explicit GUID AND revision on the SAME line is required. GUID-less
    # neighboring lines, cached flags, payload file IDs and thread IDs are not joins.
    $ids = @([Regex]::Matches($Line, '(?i)(?<id>[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.(?<rev>\d+)') | ForEach-Object { '{0}|{1}' -f $_.Groups['id'].Value.ToLowerInvariant(), $_.Groups['rev'].Value } | Select-Object -Unique)
    if ($ids.Count -ne 1) { return $null }
    if ($Line -notmatch '^(?<stamp>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})(?:\.(?<fraction>\d+))?\s') { return $null }
    $fraction = $matches['fraction']; if (-not $fraction) { $fraction = '' }
    $stamp = $matches['stamp'] + '.' + $fraction.PadRight(7, '0').Substring(0, 7)
    $local = [DateTime]::SpecifyKind([DateTime]::ParseExact($stamp, 'yyyy/MM/dd HH:mm:ss.fffffff', [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Unspecified)
    $utc = $null; $timeStatus = 'TimeZoneUnavailable'
    try {
        if ($TimeZoneId) {
            $zone = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
            if ($zone.IsInvalidTime($local)) { $timeStatus = 'InvalidLocalTime' }
            elseif ($zone.IsAmbiguousTime($local)) { $timeStatus = 'AmbiguousLocalTime' }
            else { $utc = [TimeZoneInfo]::ConvertTimeToUtc($local, $zone).ToString('o'); $timeStatus = 'SourceLocalTimeNormalized' }
        }
    } catch { $timeStatus = 'TimeZoneUnavailable' }
    $code = $null
    $codes = @([Regex]::Matches($Line, '(?i)(?:error code|errCode|HRESULT)\s*=\s*(0x[0-9a-f]{8})') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant().Replace('0X', '0x') })
    if ($codes.Count) { $code = $codes[0] }
    $conflictingError = @($codes | Where-Object { $_ -ne '0x00000000' }).Count -gt 0
    $boundary = 'UpdateLogContext'; $ruleId = 'WUText.ExactIdentityContext'
    foreach ($rule in $Rules) {
        if ($Line -match $rule.Pattern -and (-not $rule.RequireZeroCode -or ($code -eq '0x00000000' -and -not $conflictingError))) { $boundary = $rule.Boundary; $ruleId = $rule.Id; break }
    }
    $parts = $ids[0].Split('|')
    [pscustomobject][ordered]@{
        TimestampUtc = $utc; TimestampLocal = $local.ToString('yyyy-MM-ddTHH:mm:ss.fffffff'); TimeZoneId = $TimeZoneId; TimestampKind = $timeStatus
        Provider = 'DecodedWindowsUpdateLog'; Channel = $Stream; RecordId = $SourceRef; EventId = $null
        UpdateID = $parts[0]; RevisionNumber = [int]$parts[1]; ServiceID = $null; Title = $null
        Boundary = $boundary; SourceKind = 'SourceLog'; TimingStream = $Stream; RuleId = $ruleId; HResultHex = $code
        SourceRef = $SourceRef; Excerpt = $Line; RawXml = $null
    }
}

function Read-WudWindowsUpdateLogRecords {
    param($Context)
    $records = New-Object Collections.ArrayList; $unresolved = New-Object Collections.ArrayList; $coverage = New-Object Collections.ArrayList
    $catalog = Read-WudJson (Join-Path $Context.ToolRoot 'Data/update-log-rules.json')
    $rules = $catalog.Rules
    $zone = [string](Get-WudObjectPropertyValue $Context.Inventory['Identity'] 'TimeZone')
    foreach ($file in @(Get-ChildItem -LiteralPath $Context.EvidencePath -Recurse -File -Filter 'WindowsUpdate*.log' -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -eq 'WindowsUpdate' })) {
        $relative = (Get-WudRelativePath $Context.EvidencePath $file.FullName).Replace('\', '/')
        $conversionInfo = Read-WudJson (Join-Path $file.Directory.FullName 'conversion-inputs.json')
        $conversion = @(Get-WudObjectPropertyValue $conversionInfo 'Sets' @() | Where-Object { (Split-Path -Leaf ([string]$_.Output)) -eq $file.Name } | Select-Object -First 1)
        $decodeStatus = if ($conversion.Count) { [string]$conversion[0].Status } else { 'NotRecorded' }
        $decodeExit = if ($conversion.Count) { Get-WudObjectPropertyValue $conversion[0] 'ExitCode' } else { $null }
        $validation = Test-WudDecodedWindowsUpdateLog -Path $file.FullName
        if (-not $validation.Valid) {
            $null = $coverage.Add([pscustomobject]@{ SourceRef = $relative; Status = $validation.Status; DecodeExecutionStatus = $decodeStatus; DecodeExitCode = $decodeExit; ParsedLines = 0; ExactIdentityRecords = 0; UnresolvedTimestamps = 0; TimeZoneId = $zone; Error = $validation.Detail })
            $null = Add-WudCollectionGap -Context $Context -Collector 'update-log-parser' -Source $relative -Status $validation.Status -Detail $validation.Detail -Impact 'Material'
            continue
        }
        $reader = $null; $lineNumber = 0; $bytes = 0L; $count = 0; $unknownTimes = 0; $status = if ($decodeStatus -in @('Succeeded', 'NotRecorded')) { 'Parsed' } else { 'ParsedPartialDecode' }; $errorText = if ($status -eq 'ParsedPartialDecode') { 'Diagnostic records were retained, but conversion did not complete successfully; missing boundaries cannot be treated as absent from the native traces.' } else { $null }
        try {
            $reader = New-Object IO.StreamReader($file.FullName, [Text.Encoding]::UTF8, $true)
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine(); $lineNumber++; $bytes += [Text.Encoding]::UTF8.GetByteCount($line)
                if ($bytes -gt [long]$Context.Settings.maximumTextParseBytes -or $count -ge 20000) { $status = 'Truncated'; break }
                $record = ConvertFrom-WudWindowsUpdateLogLine $line "${relative}:$lineNumber" $zone $relative $rules
                if (-not $record) { continue }
                $count++
                if ($record.TimestampUtc) { $null = $records.Add($record) } else { $unknownTimes++; $null = $unresolved.Add($record) }
            }
        } catch { $status = 'Failed'; $errorText = $_.Exception.Message }
        finally { if ($reader) { $reader.Dispose() } }
        $null = $coverage.Add([pscustomobject]@{ SourceRef = $relative; Status = $status; DecodeExecutionStatus = $decodeStatus; DecodeExitCode = $decodeExit; ParsedLines = $lineNumber; ExactIdentityRecords = $count; UnresolvedTimestamps = $unknownTimes; TimeZoneId = $zone; Error = $errorText })
        if ($status -ne 'Parsed' -or $unknownTimes) { $null = Add-WudCollectionGap -Context $Context -Collector 'update-log-parser' -Source $relative -Status $(if ($unknownTimes -and $status -eq 'Parsed') { 'UnresolvedTimestamps' } else { $status }) -Detail ('Decoded log parse/timestamp coverage is incomplete. ' + $errorText) -Impact 'Material' }
    }
    $result = [pscustomobject]@{ GrammarVersion = $catalog.GrammarVersion; Records = @($records); UnresolvedRecords = @($unresolved); Coverage = @($coverage); TimeNormalization = 'Captured device time zone is assumed to apply to source-local timestamps; historical time-zone changes cannot be inferred. Raw timestamp text is preserved in each excerpt.' }
    Write-WudJsonAtomic (Join-Path $Context.SnapshotPath 'WindowsUpdate/windows-update-log-facts.json') $result -Depth 15
    return $result
}

function Test-WudDecodedWindowsUpdateLog {
    param([Parameter(Mandatory = $true)][string]$Path, [long]$MaximumValidationBytes = 2097152)
    $valid = $false; $status = 'MissingOutput'; $detail = 'No decoded output file was produced.'
    $reader = $null; $lines = 0; $bytes = 0L; $probeOnly = $true; $sawProbe = $false
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $reader = New-Object IO.StreamReader($Path, [Text.Encoding]::UTF8, $true)
            $status = 'NoDecodedRecords'; $detail = 'Output contains no recognizable timestamped Windows Update diagnostic records.'
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine(); $lines++; $bytes += [Text.Encoding]::UTF8.GetByteCount($line)
                if ($bytes -gt $MaximumValidationBytes) { $status = 'ValidationLimitReached'; $detail = 'No diagnostic record was recognized within the bounded output-validation window.'; break }
                if ($line.Trim() -and $line.Trim() -ne 'Checking write access') { $probeOnly = $false }
                if ($line.Trim() -eq 'Checking write access') { $sawProbe = $true }
                # Content validation is not target attribution. Valid logs can
                # contain only unrelated updates and must not be rejected for it.
                if ($line -match '^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?\s+\d+\s+\d+\s+\S+\s+\S') {
                    $valid = $true; $status = 'DecodedRecordsPresent'; $detail = 'Timestamped Windows Update diagnostic output was recognized.'; break
                }
            }
            if (-not $valid -and $probeOnly -and $sawProbe -and $status -ne 'ValidationLimitReached') { $status = 'WriteAccessProbeOnly'; $detail = 'Output contains only the decoder write-access probe, not converted ETL records.' }
        }
    } catch { $status = 'OutputReadFailed'; $detail = $_.Exception.Message }
    finally { if ($reader) { $reader.Dispose() } }
    return [pscustomobject]@{ Valid = $valid; Status = $status; Detail = $detail; InspectedLines = $lines; InspectedBytes = $bytes }
}

Export-ModuleMember -Function @('Test-WudTargetUpgradeTitle', 'ConvertTo-WudUpdateGuid', 'ConvertFrom-WudUpdateEventXml', 'Get-WudUpdateEventRecords', 'Get-WudArchivedUpdateEventRecords', 'Resolve-WudUpgradeIdentity', 'Test-WudUpgradeIdentityMatch', 'Update-WudUpgradeTracking', 'Get-WudWindowsUpdateConversionPlan', 'ConvertFrom-WudWindowsUpdateLogLine', 'Read-WudWindowsUpdateLogRecords', 'Test-WudDecodedWindowsUpdateLog')
