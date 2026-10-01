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
    if (($keywords -band [UInt64]0x4004) -eq [UInt64]0x4004) { $boundary = 'DownloadCompleted' }
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

Export-ModuleMember -Function @('Test-WudTargetUpgradeTitle', 'ConvertTo-WudUpdateGuid', 'ConvertFrom-WudUpdateEventXml', 'Get-WudUpdateEventRecords', 'Resolve-WudUpgradeIdentity', 'Test-WudUpgradeIdentityMatch', 'Update-WudUpgradeTracking')
