Set-StrictMode -Version 2.0

function Get-WudRecorderProperty {
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        try { return $property.Value }
        catch { return $Default }
    }
    return $Default
}

function Get-WudRecorderRoot {
    param([Parameter(Mandatory = $true)][string]$RunPath)
    return (New-WudDirectory -Path (Join-Path $RunPath 'Evidence\Recorder'))
}

function Write-WudJsonLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject,
        [int]$Depth = 20
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { $null = New-WudDirectory -Path $parent }
    $line = ($InputObject | ConvertTo-Json -Compress -Depth $Depth) + [Environment]::NewLine
    [byte[]]$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $stream = $null
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 5) { Start-Sleep -Milliseconds (100 * $attempt) }
        }
        finally { if ($stream) { $stream.Dispose() } }
    }
    throw $lastError
}

function Read-WudJsonLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    $records = New-Object Collections.ArrayList
    $invalidLines = New-Object Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{ Records = @(); InvalidLines = @(); Path = $Path }
    }
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        try { $null = $records.Add((ConvertFrom-WudJsonText -Text $line)) }
        catch {
            $null = $invalidLines.Add([pscustomobject][ordered]@{
                LineNumber = $lineNumber
                Status = 'InvalidOrTruncatedJsonLine'
                Detail = $_.Exception.Message
            })
        }
    }
    return [pscustomobject][ordered]@{ Records = @($records); InvalidLines = @($invalidLines); Path = $Path }
}

function ConvertTo-WudSetupProgress {
    param($Value)
    if ($null -eq $Value) { return $null }
    $progress = $null
    try {
        if ($Value -is [byte[]]) {
            if ($Value.Length -ge 4) { $progress = [BitConverter]::ToInt32($Value, 0) }
            elseif ($Value.Length -gt 0) { $progress = [int]$Value[0] }
        }
        else { $progress = [int]$Value }
    }
    catch { return $null }
    if ($null -eq $progress -or $progress -lt 0 -or $progress -gt 100) { return $null }
    return [int]$progress
}

function Select-WudRecorderProperties {
    param($Records, [string[]]$Properties)
    $selected = New-Object Collections.ArrayList
    foreach ($record in @($Records)) {
        $item = [ordered]@{}
        foreach ($name in $Properties) { $item[$name] = Get-WudRecorderProperty $record $name }
        $null = $selected.Add([pscustomobject]$item)
    }
    return @($selected)
}

function Invoke-WudRecorderProvider {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string[]]$Properties = @()
    )
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        return [pscustomobject][ordered]@{ Provider = $Name; Status = 'Unavailable'; Records = @(); Error = 'CommandNotFound'; CapturedUtc = [DateTime]::UtcNow.ToString('o') }
    }
    try {
        $records = @(& $ScriptBlock)
        if (@($Properties).Count -gt 0) { $records = @(Select-WudRecorderProperties -Records $records -Properties $Properties) }
        return [pscustomobject][ordered]@{ Provider = $Name; Status = 'Available'; Records = @($records); Error = $null; CapturedUtc = [DateTime]::UtcNow.ToString('o') }
    }
    catch {
        return [pscustomobject][ordered]@{ Provider = $Name; Status = 'Failed'; Records = @(); Error = (Get-WudErrorDetail -ErrorRecord $_); CapturedUtc = [DateTime]::UtcNow.ToString('o') }
    }
}

function Get-WudRecorderState {
    param([Parameter(Mandatory = $true)]$Sample)
    $os = Get-WudRecorderProperty $Sample 'Os'
    if ([bool](Get-WudRecorderProperty $os 'TargetPresent' $false)) { return 'TargetPresent' }

    $markers = Get-WudRecorderProperty $Sample 'Markers'
    if ([bool](Get-WudRecorderProperty $markers 'PostRollback' $false)) { return 'RolledBack' }

    $setup = Get-WudRecorderProperty $Sample 'Setup'
    $processes = @(Get-WudRecorderProperty $Sample 'SetupProcesses' @() | Where-Object { [string](Get-WudRecorderProperty $_ 'Name') -match '^(?i)(setuphost|setupprep|SetupPlatform|WindowsUpdateBox)(\.exe)?$' })
    $setupActive = @($processes).Count -gt 0 -or
        [int](Get-WudRecorderProperty $setup 'SystemSetupInProgress' 0) -eq 1 -or
        [int](Get-WudRecorderProperty $setup 'UpgradeInProgress' 0) -eq 1 -or
        $null -ne (Get-WudRecorderProperty $setup 'SetupProgress')
    $pending = Get-WudRecorderProperty $Sample 'PendingReboot'
    if ($setupActive -and [bool](Get-WudRecorderProperty $pending 'IsPending' $false)) { return 'RebootPending' }
    if ($setupActive) {
        $phaseObservation = Get-WudRecorderProperty $setup 'SourceReportedPhase'
        $phase = [string](Get-WudRecorderProperty $phaseObservation 'Phase')
        if ($phase -in @('Downlevel', 'SafeOS', 'FirstBoot', 'OOBE')) { return "Setup$phase" }
        return 'SetupActive'
    }

    $tracking = Get-WudRecorderProperty $Sample 'UpgradeTracking'
    $boundaries = @(Get-WudRecorderProperty $tracking 'MatchedBoundaries' @())
    if (@($boundaries | Where-Object Boundary -eq 'DownloadStarted').Count -gt 0) { return 'TargetUpdateDownloadObserved' }
    $delivery = Get-WudRecorderProperty $Sample 'DeliveryOptimization'
    $statusProvider = Get-WudRecorderProperty $delivery 'Status'
    if ([string](Get-WudRecorderProperty $statusProvider 'Status') -eq 'Available') {
        $records = @(Get-WudRecorderProperty $statusProvider 'Records' @())
        $active = @($records | Where-Object {
            [string](Get-WudRecorderProperty $_ 'Status') -match '(?i)^Downloading$|^Transferring$' -or
            ([long](Get-WudRecorderProperty $_ 'FileSize' 0) -gt 0 -and [long](Get-WudRecorderProperty $_ 'TotalBytesDownloaded' 0) -lt [long](Get-WudRecorderProperty $_ 'FileSize' 0))
        })
        if (@($active).Count -gt 0) {
            $windowsUpdateOwned = @($active | Where-Object {
                [string](Get-WudRecorderProperty $_ 'CallerApplication') -match '(?i)Windows\s*Update|UpdateOrchestrator|MoUso|UsoClient' -or
                [string](Get-WudRecorderProperty $_ 'SourceURL') -match '(?i)(?:windowsupdate|delivery\.mp\.microsoft|download\.windowsupdate)\.com'
            }).Count -gt 0
            if ($windowsUpdateOwned) { return 'WindowsUpdateTransportObserved' }
            return 'DeliveryOptimizationTransferObserved'
        }
        $complete = @($records | Where-Object {
            [string](Get-WudRecorderProperty $_ 'Status') -match '(?i)^Complete$|^Caching$' -or
            ([long](Get-WudRecorderProperty $_ 'FileSize' 0) -gt 0 -and [long](Get-WudRecorderProperty $_ 'TotalBytesDownloaded' 0) -ge [long](Get-WudRecorderProperty $_ 'FileSize' 0))
        })
        if (@($complete).Count -gt 0) { return 'DownloadObservedComplete' }
    }
    return 'ArmedOrIdle'
}

function Get-WudSetupPhaseObservation {
    param([Parameter(Mandatory = $true)][string]$RunPath, [long]$MaximumTailBytes = 1048576)
    $createdUtc = $null
    try {
        $state = Read-WudJson -Path (Join-Path $RunPath 'State\run-state.json')
        if ($state -and $state.CreatedUtc) { $createdUtc = ConvertTo-WudUtcDateTime $state.CreatedUtc }
    }
    catch { }
    $candidates = @(
        (Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Panther\setupact.log'),
        (Join-Path $env:SystemRoot 'Panther\setupact.log')
    )
    $phasePatterns = @(
        [pscustomobject]@{ Phase = 'Downlevel'; Pattern = '(?i)SP_EXECUTION_DOWNLEVEL|\bDownlevel\b' },
        [pscustomobject]@{ Phase = 'SafeOS'; Pattern = '(?i)SP_EXECUTION_SAFE_OS|\bSafe[ _-]?OS\b' },
        [pscustomobject]@{ Phase = 'FirstBoot'; Pattern = '(?i)SP_EXECUTION_FIRST_BOOT|\bFirst[ _-]?Boot\b' },
        [pscustomobject]@{ Phase = 'OOBE'; Pattern = '(?i)SP_EXECUTION_OOBE_BOOT|\bOOBE\b' }
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if ($createdUtc -and $item.LastWriteTimeUtc -lt $createdUtc) { continue }
            $stream = Open-WudFileReadStream -Path $candidate
            try {
                $readLength = [int][Math]::Min([long]$stream.Length, $MaximumTailBytes)
                if ($stream.Length -gt $readLength) { $null = $stream.Seek(-$readLength, [IO.SeekOrigin]::End) }
                [byte[]]$buffer = New-Object byte[] $readLength
                $actual = $stream.Read($buffer, 0, $readLength)
                $text = (New-Object Text.UTF8Encoding($false, $false)).GetString($buffer, 0, $actual)
            }
            finally { $stream.Dispose() }
            $best = $null
            foreach ($mapping in $phasePatterns) {
                $matches = [Regex]::Matches($text, $mapping.Pattern)
                if ($matches.Count -eq 0) { continue }
                $match = $matches[$matches.Count - 1]
                if (-not $best -or $match.Index -gt $best.Index) { $best = [pscustomobject]@{ Phase = $mapping.Phase; Marker = $match.Value; Index = $match.Index } }
            }
            if ($best) {
                return [pscustomobject][ordered]@{
                    Status = 'Observed'; Phase = $best.Phase; Marker = $best.Marker; Source = $candidate
                    SourceLastWriteUtc = $item.LastWriteTimeUtc.ToString('o'); EligibleByRunWindow = $true
                }
            }
        }
        catch {
            return [pscustomobject][ordered]@{ Status = 'ReadFailed'; Phase = $null; Marker = $null; Source = $candidate; SourceLastWriteUtc = $null; EligibleByRunWindow = $null; Error = Get-WudErrorDetail $_ }
        }
    }
    return [pscustomobject][ordered]@{ Status = 'NotObserved'; Phase = $null; Marker = $null; Source = $null; SourceLastWriteUtc = $null; EligibleByRunWindow = $null }
}

function Get-WudRecorderSignature {
    param([Parameter(Mandatory = $true)]$Sample, [int]$ProgressBucketSize = 100)
    if ($ProgressBucketSize -lt 1) { $ProgressBucketSize = 100 }
    $setup = Get-WudRecorderProperty $Sample 'Setup'
    $progress = Get-WudRecorderProperty $setup 'SetupProgress'
    $bucket = if ($null -ne $progress) { [Math]::Floor([double]$progress / $ProgressBucketSize) * $ProgressBucketSize } else { $null }
    $os = Get-WudRecorderProperty $Sample 'Os'
    return '{0}|boot={1}|build={2}.{3}|progress={4}' -f
        (Get-WudRecorderState -Sample $Sample),
        (Get-WudRecorderProperty $Sample 'BootId'),
        (Get-WudRecorderProperty $os 'Build'),
        (Get-WudRecorderProperty $os 'UBR'),
        $bucket
}

function Get-WudDeliveryOptimizationSummary {
    param([Parameter(Mandatory = $true)]$Samples)
    $sampleArray = @($Samples | Sort-Object { (ConvertTo-WudUtcDateTime (Get-WudRecorderProperty $_ 'TimestampUtc')).Ticks })
    $observations = New-Object Collections.ArrayList
    $performanceObservations = New-Object Collections.ArrayList
    foreach ($sample in $sampleArray) {
        $delivery = Get-WudRecorderProperty $sample 'DeliveryOptimization'
        $provider = Get-WudRecorderProperty $delivery 'Status'
        if ([string](Get-WudRecorderProperty $provider 'Status') -ne 'Available') { continue }
        foreach ($record in @(Get-WudRecorderProperty $provider 'Records' @())) {
            $null = $observations.Add([pscustomobject][ordered]@{
                TimestampUtc = Get-WudRecorderProperty $sample 'TimestampUtc'
                FileId = [string](Get-WudRecorderProperty $record 'FileId' (Get-WudRecorderProperty $record 'FileID'))
                FileSize = [long](Get-WudRecorderProperty $record 'FileSize' 0)
                TotalBytes = [long](Get-WudRecorderProperty $record 'TotalBytesDownloaded' 0)
                PeerBytes = [long](Get-WudRecorderProperty $record 'BytesFromPeers' 0)
                HttpBytes = [long](Get-WudRecorderProperty $record 'BytesFromHttp' 0)
                CacheBytes = [long](Get-WudRecorderProperty $record 'BytesFromCacheServer' (Get-WudRecorderProperty $record 'BytesFromConnectedCache' 0))
                Status = Get-WudRecorderProperty $record 'Status'
                PercentComplete = if ([long](Get-WudRecorderProperty $record 'FileSize' 0) -gt 0) { [Math]::Round(100 * [double](Get-WudRecorderProperty $record 'TotalBytesDownloaded' 0) / [double](Get-WudRecorderProperty $record 'FileSize' 1), 2) } else { $null }
                CallerApplication = Get-WudRecorderProperty $record 'CallerApplication'
                SourceURL = Get-WudRecorderProperty $record 'SourceURL'
            })
        }
        $performance = Get-WudRecorderProperty $delivery 'Performance'
        if ([string](Get-WudRecorderProperty $performance 'Status') -eq 'Available') {
            foreach ($record in @(Get-WudRecorderProperty $performance 'Records' @())) {
                $null = $performanceObservations.Add([pscustomobject][ordered]@{
                    TimestampUtc = Get-WudRecorderProperty $sample 'TimestampUtc'
                    DownloadRateBps = [long](Get-WudRecorderProperty $record 'DownloadRateBps' 0)
                    UploadRateBps = [long](Get-WudRecorderProperty $record 'UploadRateBps' 0)
                    HttpConnectionCount = Get-WudRecorderProperty $record 'HttpConnectionCount'
                    LanConnectionCount = Get-WudRecorderProperty $record 'LanConnectionCount'
                    GroupConnectionCount = Get-WudRecorderProperty $record 'GroupConnectionCount'
                    InternetConnectionCount = Get-WudRecorderProperty $record 'InternetConnectionCount'
                    CacheHostConnectionCount = Get-WudRecorderProperty $record 'CacheHostConnectionCount'
                })
            }
        }
    }
    $totals = [ordered]@{ DownloadedBytes = 0L; PeerBytes = 0L; HttpBytes = 0L; CacheBytes = 0L }
    $latestTotals = [ordered]@{ DownloadedBytes = 0L; PeerBytes = 0L; HttpBytes = 0L; CacheBytes = 0L }
    foreach ($group in @($observations | Group-Object FileId)) {
        $ordered = @($group.Group | Sort-Object { (ConvertTo-WudUtcDateTime $_.TimestampUtc).Ticks })
        if ($ordered.Count -eq 0) { continue }
        $first = $ordered[0]; $last = $ordered[$ordered.Count - 1]
        $totals.DownloadedBytes += [Math]::Max(0L, ([long]$last.TotalBytes - [long]$first.TotalBytes))
        $totals.PeerBytes += [Math]::Max(0L, ([long]$last.PeerBytes - [long]$first.PeerBytes))
        $totals.HttpBytes += [Math]::Max(0L, ([long]$last.HttpBytes - [long]$first.HttpBytes))
        $totals.CacheBytes += [Math]::Max(0L, ([long]$last.CacheBytes - [long]$first.CacheBytes))
        $latestTotals.DownloadedBytes += [long]$last.TotalBytes
        $latestTotals.PeerBytes += [long]$last.PeerBytes
        $latestTotals.HttpBytes += [long]$last.HttpBytes
        $latestTotals.CacheBytes += [long]$last.CacheBytes
    }
    $firstUtc = if ($observations.Count -gt 0) { ConvertTo-WudUtcDateTime $observations[0].TimestampUtc } else { $null }
    $lastUtc = if ($observations.Count -gt 0) { ConvertTo-WudUtcDateTime $observations[$observations.Count - 1].TimestampUtc } else { $null }
    $seconds = if ($firstUtc -and $lastUtc) { [Math]::Max(0, ($lastUtc - $firstUtc).TotalSeconds) } else { 0 }
    $activeObservation = @($observations | Where-Object { [string]$_.Status -match '(?i)^Downloading$|^Transferring$' } | Select-Object -First 1)
    $completeObservation = @($observations | Where-Object { [string]$_.Status -match '(?i)^Complete$|^Caching$' -or ($_.FileSize -gt 0 -and $_.TotalBytes -ge $_.FileSize) } | Select-Object -First 1)
    # Microsoft defines BytesFromHTTP as including BytesFromCacheServer.
    $sourceTotal = [long]$latestTotals.PeerBytes + [long]$latestTotals.HttpBytes
    $sampleIntervals = New-Object Collections.ArrayList
    for ($index = 1; $index -lt $sampleArray.Count; $index++) {
        $currentUtc = ConvertTo-WudUtcDateTime (Get-WudRecorderProperty $sampleArray[$index] 'TimestampUtc')
        $priorUtc = ConvertTo-WudUtcDateTime (Get-WudRecorderProperty $sampleArray[$index - 1] 'TimestampUtc')
        $null = $sampleIntervals.Add([int][Math]::Max(0, ($currentUtc - $priorUtc).TotalSeconds))
    }
    return [pscustomobject][ordered]@{
        Attribution = 'DeviceWideContext'
        ObservationCount = @($observations).Count
        FirstObservedUtc = if ($firstUtc) { $firstUtc.ToString('o') } else { $null }
        LastObservedUtc = if ($lastUtc) { $lastUtc.ToString('o') } else { $null }
        ObservedSeconds = [int]$seconds
        SamplingResolutionSeconds = if ($sampleIntervals.Count -gt 0) { [int](($sampleIntervals | Measure-Object -Average).Average) } else { $null }
        TransferStartObservedUtc = if (@($activeObservation).Count -gt 0) { $activeObservation[0].TimestampUtc } else { $null }
        TransferCompletionObservedUtc = if (@($completeObservation).Count -gt 0) { $completeObservation[0].TimestampUtc } else { $null }
        DownloadedBytesDelta = [long]$totals.DownloadedBytes
        PeerBytesDelta = [long]$totals.PeerBytes
        HttpBytesDelta = [long]$totals.HttpBytes
        ConnectedCacheBytesDelta = [long]$totals.CacheBytes
        LatestTotalBytesDownloaded = [long]$latestTotals.DownloadedBytes
        LatestPeerBytes = [long]$latestTotals.PeerBytes
        LatestHttpBytes = [long]$latestTotals.HttpBytes
        LatestConnectedCacheBytes = [long]$latestTotals.CacheBytes
        PeerAndConnectedCacheSharePercent = if ($sourceTotal -gt 0) { [Math]::Round(100 * ([double]$latestTotals.PeerBytes + [double]$latestTotals.CacheBytes) / $sourceTotal, 2) } else { $null }
        AverageObservedBytesPerSecond = if ($seconds -gt 0) { [long]([double]$totals.DownloadedBytes / $seconds) } else { $null }
        MaximumReportedDownloadRateBps = if ($performanceObservations.Count -gt 0) { [long](($performanceObservations | Measure-Object DownloadRateBps -Maximum).Maximum) } else { $null }
        Records = @($observations)
        PerformanceRecords = @($performanceObservations)
    }
}

function Get-WudRecorderTelemetrySummary {
    param([Parameter(Mandatory = $true)]$Samples)
    $sampleArray = @($Samples | Sort-Object { (ConvertTo-WudUtcDateTime (Get-WudRecorderProperty $_ 'TimestampUtc')).Ticks })
    $transitions = New-Object Collections.ArrayList
    $previous = $null
    foreach ($sample in $sampleArray) {
        $state = [string](Get-WudRecorderProperty $sample 'RecorderState' (Get-WudRecorderState -Sample $sample))
        if ($null -eq $previous -or $state -ne $previous.State -or [string](Get-WudRecorderProperty $sample 'BootId') -ne $previous.BootId) {
            $null = $transitions.Add([pscustomobject][ordered]@{
                TimestampUtc = Get-WudRecorderProperty $sample 'TimestampUtc'
                State = $state
                BootId = Get-WudRecorderProperty $sample 'BootId'
                PreviousState = if ($previous) { $previous.State } else { $null }
                EvidenceReference = 'Recorder/ProgressSamples.jsonl'
            })
        }
        $previous = [pscustomobject]@{ State = $state; BootId = [string](Get-WudRecorderProperty $sample 'BootId') }
    }
    $firstUtc = if ($sampleArray.Count -gt 0) { Get-WudRecorderProperty $sampleArray[0] 'TimestampUtc' } else { $null }
    $lastUtc = if ($sampleArray.Count -gt 0) { Get-WudRecorderProperty $sampleArray[$sampleArray.Count - 1] 'TimestampUtc' } else { $null }
    return [pscustomobject][ordered]@{
        SampleCount = $sampleArray.Count
        FirstSampleUtc = $firstUtc
        LastSampleUtc = $lastUtc
        StatesObserved = @($transitions | ForEach-Object State | Select-Object -Unique)
        StateTransitions = @($transitions)
        DeliveryOptimization = Get-WudDeliveryOptimizationSummary -Samples $sampleArray
    }
}

function Get-WudProgressSample {
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [string]$TargetVersion = '25H2',
        [int]$TargetBuild = 26200,
        [switch]$IncludeStaticDeliveryData
    )
    $timestamp = [DateTime]::UtcNow
    $version = $null
    $osError = $null
    try { $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop }
    catch { $osError = Get-WudErrorDetail -ErrorRecord $_ }
    $build = 0
    if ($version) { $null = [int]::TryParse([string](Get-WudRecorderProperty $version 'CurrentBuild'), [ref]$build) }

    $bootId = $null
    $bootStatus = 'Available'
    $bootError = $null
    try {
        $osCim = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $bootId = ([DateTime]$osCim.LastBootUpTime).ToUniversalTime().ToString('o')
    }
    catch { $bootId = 'Unavailable'; $bootStatus = 'Failed'; $bootError = Get-WudErrorDetail -ErrorRecord $_ }

    $setupValues = [ordered]@{ SystemSetupInProgress = $null; UpgradeInProgress = $null; OOBEInProgress = $null; SetupProgress = $null; SetupProgressStatus = 'Unavailable'; SetupProgressError = $null; SourceReportedPhase = $null; Error = $null }
    try {
        $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
        foreach ($name in @('SystemSetupInProgress', 'UpgradeInProgress', 'OOBEInProgress')) { $setupValues[$name] = Get-WudRecorderProperty $setup $name }
        try {
            $volatile = Get-ItemProperty 'HKLM:\SYSTEM\Setup\MoSetup\Volatile' -ErrorAction Stop
            $setupValues.SetupProgress = ConvertTo-WudSetupProgress (Get-WudRecorderProperty $volatile 'SetupProgress')
            $setupValues.SetupProgressStatus = 'Available'
        }
        catch { $setupValues.SetupProgressError = Get-WudErrorDetail -ErrorRecord $_ }
    }
    catch { $setupValues.Error = Get-WudErrorDetail -ErrorRecord $_ }
    try { $setupValues.SourceReportedPhase = Get-WudSetupPhaseObservation -RunPath $RunPath }
    catch { $setupValues.SourceReportedPhase = [pscustomobject]@{ Status = 'ReadFailed'; Phase = $null; Error = Get-WudErrorDetail $_ } }

    $setupProcesses = New-Object Collections.ArrayList
    $setupProcessStatus = 'Available'
    $setupProcessError = $null
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -match '^(?i)(setuphost|setupprep|setupprep\.exe|SetupPlatform|WindowsUpdateBox|MoUsoCoreWorker|TiWorker)(\.exe)?$' })) {
            $null = $setupProcesses.Add([pscustomobject][ordered]@{
                Name = $process.Name; ProcessId = $process.ProcessId; ParentProcessId = $process.ParentProcessId
                CreationDate = $process.CreationDate; KernelModeTime = $process.KernelModeTime; UserModeTime = $process.UserModeTime
                ReadTransferCount = $process.ReadTransferCount; WriteTransferCount = $process.WriteTransferCount
                ExecutablePath = $process.ExecutablePath; CommandLine = $process.CommandLine
            })
        }
    }
    catch { $setupProcessStatus = 'Failed'; $setupProcessError = Get-WudErrorDetail -ErrorRecord $_ }

    $pendingSignals = New-Object Collections.ArrayList
    $pendingErrors = New-Object Collections.ArrayList
    foreach ($path in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )) {
        try {
            if ($path -match 'Session Manager') {
                $pendingRenameRecord = Get-ItemProperty -LiteralPath $path -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                $pendingRename = Get-WudObjectPropertyValue $pendingRenameRecord 'PendingFileRenameOperations'
                if ($pendingRename) { $null = $pendingSignals.Add('PendingFileRenameOperations') }
            }
            elseif (Test-Path -LiteralPath $path) { $null = $pendingSignals.Add($path) }
        }
        catch { $null = $pendingErrors.Add([pscustomobject]@{ Source = $path; Error = Get-WudErrorDetail -ErrorRecord $_ }) }
    }

    $sourceFiles = New-Object Collections.ArrayList
    foreach ($sourcePath in @(
        (Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Panther\setupact.log'),
        (Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Rollback\setupact.log'),
        (Join-Path $env:SystemRoot 'Panther\setupact.log'),
        (Join-Path $env:SystemRoot 'Logs\MoSetup\BlueBox.log'),
        (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'),
        (Join-Path $env:SystemRoot 'Logs\DISM\dism.log')
    )) {
        try {
            if (Test-Path -LiteralPath $sourcePath) {
                $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
                $null = $sourceFiles.Add([pscustomobject][ordered]@{ Path = $sourcePath; Status = 'Present'; Length = [long]$sourceItem.Length; LastWriteUtc = $sourceItem.LastWriteTimeUtc.ToString('o'); Error = $null })
            }
            else { $null = $sourceFiles.Add([pscustomobject][ordered]@{ Path = $sourcePath; Status = 'Absent'; Length = $null; LastWriteUtc = $null; Error = $null }) }
        }
        catch { $null = $sourceFiles.Add([pscustomobject][ordered]@{ Path = $sourcePath; Status = 'MetadataFailed'; Length = $null; LastWriteUtc = $null; Error = Get-WudErrorDetail -ErrorRecord $_ }) }
    }

    $doProperties = @('FileId', 'FileID', 'UpdateID', 'UpdateGuid', 'RevisionNumber', 'FileSize', 'FileSizeInCache', 'TotalBytesDownloaded', 'BytesFromPeers', 'BytesFromHttp', 'BytesFromCacheServer', 'BytesFromConnectedCache', 'Status', 'DownloadDuration', 'SourceURL', 'CacheHost', 'CallerApplication', 'PredefinedCallerApplication', 'NumPeers', 'NumConnections')
    $peerProperties = @('IPAddress', 'PeerType', 'ConnectionType', 'BytesSent', 'BytesReceived', 'UploadRate', 'DownloadRate')
    $perfProperties = @('DownloadRatePct', 'UploadRatePct', 'DownloadRateBps', 'UploadRateBps', 'HttpConnectionCount', 'LanConnectionCount', 'GroupConnectionCount', 'InternetConnectionCount', 'CacheHostConnectionCount', 'CacheHostDownloadRateBps')
    $delivery = [pscustomobject][ordered]@{
        Status = Invoke-WudRecorderProvider -Name 'Get-DeliveryOptimizationStatus' -ScriptBlock { Get-DeliveryOptimizationStatus -ErrorAction Stop } -Properties $doProperties
        PeerInfo = Invoke-WudRecorderProvider -Name 'Get-DeliveryOptimizationStatus' -ScriptBlock { Get-DeliveryOptimizationStatus -PeerInfo -ErrorAction Stop } -Properties $peerProperties
        Performance = Invoke-WudRecorderProvider -Name 'Get-DeliveryOptimizationPerfSnap' -ScriptBlock { Get-DeliveryOptimizationPerfSnap -ErrorAction Stop } -Properties $perfProperties
        PerformanceThisMonth = if ($IncludeStaticDeliveryData) { Invoke-WudRecorderProvider -Name 'Get-DeliveryOptimizationPerfSnapThisMonth' -ScriptBlock { Get-DeliveryOptimizationPerfSnapThisMonth -ErrorAction Stop } -Properties $perfProperties } else { [pscustomobject]@{ Provider = 'Get-DeliveryOptimizationPerfSnapThisMonth'; Status = 'NotSampled'; Records = @(); Error = $null; CapturedUtc = $null } }
        Configuration = if ($IncludeStaticDeliveryData) { Invoke-WudRecorderProvider -Name 'Get-DOConfig' -ScriptBlock { Get-DOConfig -Verbose -ErrorAction Stop } } else { [pscustomobject]@{ Provider = 'Get-DOConfig'; Status = 'NotSampled'; Records = @(); Error = $null; CapturedUtc = $null } }
    }

    $markers = [pscustomobject][ordered]@{
        PostOOBE = Test-Path -LiteralPath (Join-Path $RunPath 'State\Markers\post-oobe.marker')
        PostRollback = Test-Path -LiteralPath (Join-Path $RunPath 'State\Markers\post-rollback.marker')
    }
    $sample = [pscustomobject][ordered]@{
        SchemaVersion = 1
        TimestampUtc = $timestamp.ToString('o')
        BootId = $bootId
        BootIdentityProvider = [pscustomobject]@{ Status = $bootStatus; Error = $bootError }
        Os = [pscustomobject][ordered]@{
            DisplayVersion = Get-WudRecorderProperty $version 'DisplayVersion'
            Build = if ($build -gt 0) { $build } else { $null }
            UBR = Get-WudRecorderProperty $version 'UBR'
            TargetVersion = $TargetVersion
            TargetBuild = $TargetBuild
            TargetPresent = (($version -and [string](Get-WudRecorderProperty $version 'DisplayVersion') -eq $TargetVersion) -or $build -eq $TargetBuild)
            Error = $osError
        }
        Setup = [pscustomobject]$setupValues
        SetupProcesses = @($setupProcesses)
        SetupProcessProvider = [pscustomobject]@{ Status = $setupProcessStatus; Error = $setupProcessError }
        PendingReboot = [pscustomobject][ordered]@{ IsPending = @($pendingSignals).Count -gt 0; Signals = @($pendingSignals); ProviderErrors = @($pendingErrors) }
        Markers = $markers
        SourceFileMetadata = @($sourceFiles)
        DeliveryOptimization = $delivery
    }
    $sample | Add-Member -NotePropertyName RecorderState -NotePropertyValue (Get-WudRecorderState -Sample $sample)
    return $sample
}

function Invoke-WudRecorderExternal {
    param([string]$FilePath, [string[]]$Arguments, [string]$ArtifactPath, [int]$TimeoutSeconds = 120)
    $started = [DateTime]::UtcNow
    $process = $null; $errorText = $null; $exitCode = $null; $timedOut = $false
    try {
        $argumentLine = (@($Arguments | ForEach-Object { ConvertTo-WudCommandLineArgument -Value ([string]$_) }) -join ' ')
        $process = Start-Process -FilePath $FilePath -ArgumentList $argumentLine -PassThru -WindowStyle Hidden -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250; $process.Refresh() }
        if (-not $process.HasExited) { $timedOut = $true; Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        else { try { $process.WaitForExit() } catch { }; $exitCode = $process.ExitCode }
    }
    catch { $errorText = Get-WudErrorDetail -ErrorRecord $_ }
    $artifact = Test-Path -LiteralPath $ArtifactPath
    $status = if ($timedOut) { 'TimedOut' } elseif ($errorText) { 'StartFailed' } elseif ($null -eq $exitCode) { 'ExitCodeUnavailable' } elseif ($exitCode -eq 0) { 'Succeeded' } else { 'ExitedNonzero' }
    if ($status -ne 'Succeeded' -and $artifact) { $status = 'ArtifactCapturedDespiteProcessUncertainty' }
    return [pscustomobject][ordered]@{
        ExecutionStatus = $status; ExitCode = $exitCode; TimedOut = $timedOut; Error = $errorText
        ArtifactPath = $ArtifactPath; ArtifactPresent = $artifact; StartedUtc = $started.ToString('o'); EndedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Copy-WudCheckpointNativeEvidence {
    param([string]$CheckpointPath, [long]$MaximumFileBytes = 16777216, [long]$MaximumCheckpointBytes = 67108864, [string]$RunPath)
    $records = New-Object Collections.ArrayList
    $copiedBytes = 0L
    $setupSources = @(
        @{ Name = 'WindowsBT-Panther'; Path = (Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Panther') },
        @{ Name = 'WindowsBT-Rollback'; Path = (Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Rollback') },
        @{ Name = 'Windows-MoSetup'; Path = (Join-Path $env:SystemRoot 'Logs\MoSetup') }
    )
    $sources = @($setupSources) + @(Get-WudNativeTraceSources -RunPath $RunPath | Where-Object { $_.Name -notin @($setupSources | ForEach-Object { $_.Name }) })
    foreach ($source in $sources) {
        try { $sourceItem = Get-Item -LiteralPath $source.Path -Force -ErrorAction Stop }
        catch {
            $status = if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { 'SourceAbsent' } else { 'SourceUnavailable' }
            $null = $records.Add([pscustomobject][ordered]@{ Source = $source.Path; Status = $status; Destination = $null; Length = $null; Sha256 = $null; Error = Get-WudErrorDetail $_ })
            continue
        }
        $files = if ($sourceItem.PSIsContainer) {
            $enumerationContext = [pscustomobject]@{ CollectionGaps = (New-Object Collections.ArrayList) }
            $retained = @(Get-WudFileTreeSafe -RootPath $source.Path -Context $enumerationContext -Collector 'checkpoint-etl')
            foreach ($gap in @($enumerationContext.CollectionGaps)) {
                $null = $records.Add([pscustomobject]@{ Source = $gap.Source; Status = 'EnumerationIncomplete'; Destination = $null; Length = $null; Sha256 = $null; Error = $gap.Detail })
            }
            $etls = @($retained | Where-Object { $_.Name -match '(?i)\.etl(?:\.(?:old|bak|\d+))?$' } | Sort-Object LastWriteTimeUtc -Descending)
            $setupFiles = if ($source.Name -in @($setupSources | ForEach-Object { $_.Name })) { @($retained | Where-Object { $_.Name -match '(?i)\.(?:log|xml|json|dmp)$' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 12) } else { @() }
            @($etls) + @($setupFiles)
        }
        else { @($sourceItem) }
        foreach ($file in $files) {
            $relative = if ($sourceItem.PSIsContainer) { Get-WudRelativePath -BasePath $source.Path -Path $file.FullName } else { $file.Name }
            $destination = Join-Path (Join-Path $CheckpointPath ('Native\' + $source.Name)) $relative
            if ([long]$file.Length -gt $MaximumFileBytes) {
                $null = $records.Add([pscustomobject][ordered]@{ Source = $file.FullName; Status = 'OversizedMetadataOnly'; Destination = $null; Length = $file.Length; Sha256 = $null; Error = 'Hash deferred to the final evidence collection to keep boundary checkpoints lightweight.' })
                continue
            }
            if (($copiedBytes + [long]$file.Length) -gt $MaximumCheckpointBytes) {
                $null = $records.Add([pscustomobject][ordered]@{ Source = $file.FullName; Status = 'CheckpointCapacityReached'; Destination = $null; Length = $file.Length; Sha256 = $null; Error = 'Hash deferred to the final evidence collection.' })
                continue
            }
            try {
                $null = New-WudDirectory -Path (Split-Path -Parent $destination)
                if ($file.Name -match '(?i)\.etl(?:\.(?:old|bak|\d+))?$') {
                    $record = Copy-WudNativeTraceFile -Source $file.FullName -Destination $destination
                    $copiedBytes += [long]$record.CapturedLength
                    $null = $records.Add($record)
                    continue
                }
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
                $copiedBytes += [long]$file.Length
                $null = $records.Add([pscustomobject][ordered]@{ Source = $file.FullName; Status = 'CopiedNative'; Destination = $destination; Length = $file.Length; Sha256 = Get-WudFileHashSafe $destination; Error = $null })
            }
            catch { $null = $records.Add([pscustomobject][ordered]@{ Source = $file.FullName; Status = 'CopyFailed'; Destination = $destination; Length = $file.Length; Sha256 = $null; Error = Get-WudErrorDetail $_ }) }
        }
    }
    return @($records)
}

function Write-WudRecorderCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)]$Sample,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$MaximumCheckpoints = 8,
        [long]$MaximumFileBytes = 16777216,
        [long]$MaximumCheckpointBytes = 67108864
    )
    $root = Get-WudRecorderRoot -RunPath $RunPath
    $checkpointRoot = New-WudDirectory -Path (Join-Path $root 'Checkpoints')
    $existing = @(Get-ChildItem -LiteralPath $checkpointRoot -Directory -ErrorAction SilentlyContinue)
    if ($existing.Count -ge $MaximumCheckpoints) {
        $coverage = [pscustomobject][ordered]@{ Status = 'CheckpointLimitReached'; Path = $null; Reason = $Reason; TimestampUtc = Get-WudRecorderProperty $Sample 'TimestampUtc' }
        Write-WudJsonLine -Path (Join-Path $root 'CheckpointCoverage.jsonl') -InputObject $coverage
        return $coverage
    }
    $state = [string](Get-WudRecorderProperty $Sample 'RecorderState' (Get-WudRecorderState -Sample $Sample))
    $safeState = $state -replace '[^A-Za-z0-9._-]', '_'
    $timestamp = (ConvertTo-WudUtcDateTime (Get-WudRecorderProperty $Sample 'TimestampUtc')).ToString('yyyyMMddTHHmmssfffZ')
    $path = New-WudDirectory -Path (Join-Path $checkpointRoot ("{0}-{1}" -f $timestamp, $safeState))
    Write-WudJsonAtomic -Path (Join-Path $path 'sample.json') -InputObject $Sample -Depth 30
    $native = @(Copy-WudCheckpointNativeEvidence -CheckpointPath $path -MaximumFileBytes $MaximumFileBytes -MaximumCheckpointBytes $MaximumCheckpointBytes -RunPath $RunPath)
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 1; Reason = $Reason; RecorderState = $state; TimestampUtc = Get-WudRecorderProperty $Sample 'TimestampUtc'
        NativeFiles = @($native); EventExports = @(); CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-WudJsonAtomic -Path (Join-Path $path 'checkpoint-manifest.json') -InputObject $manifest -Depth 30
    $coverage = [pscustomobject][ordered]@{ Status = 'Created'; Path = $path; Reason = $Reason; TimestampUtc = Get-WudRecorderProperty $Sample 'TimestampUtc' }
    Write-WudJsonLine -Path (Join-Path $root 'CheckpointCoverage.jsonl') -InputObject $coverage
    return $coverage
}

function Invoke-WudRecorderSample {
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [string]$TargetVersion = '25H2',
        [int]$TargetBuild = 26200,
        [string]$Reason = 'PeriodicSample',
        [int]$ProgressBucketSize = 100,
        [int]$MaximumCheckpoints = 8,
        [long]$MaximumCheckpointFileBytes = 16777216,
        [long]$MaximumCheckpointBytes = 67108864,
        [switch]$ForceCheckpoint
    )
    $root = Get-WudRecorderRoot -RunPath $RunPath
    $samplePath = Join-Path $root 'ProgressSamples.jsonl'
    $transitionPath = Join-Path $root 'StateTransitions.jsonl'
    $read = Read-WudJsonLines -Path $samplePath
    $previous = @($read.Records | Select-Object -Last 1)
    $includeStatic = $ForceCheckpoint -or @($previous).Count -eq 0
    $sample = Get-WudProgressSample -RunPath $RunPath -TargetVersion $TargetVersion -TargetBuild $TargetBuild -IncludeStaticDeliveryData:$includeStatic
    if (Get-Command Update-WudUpgradeTracking -ErrorAction SilentlyContinue) {
        $state = Read-WudJson -Path (Join-Path $RunPath 'State/run-state.json')
        $created = Get-WudRecorderProperty $state 'CreatedUtc'
        $since = if ($created) { ([DateTimeOffset]::Parse($created)).UtcDateTime } else { ([DateTimeOffset]::Parse($sample.TimestampUtc)).UtcDateTime }
        $tracking = Update-WudUpgradeTracking -RunPath $RunPath -TargetVersion $TargetVersion -SinceUtc $since
        $sample | Add-Member -NotePropertyName UpgradeTracking -NotePropertyValue $tracking
        $sample.RecorderState = Get-WudRecorderState -Sample $sample
    }
    $signature = Get-WudRecorderSignature -Sample $sample -ProgressBucketSize $ProgressBucketSize
    $sample | Add-Member -NotePropertyName Signature -NotePropertyValue $signature
    $sample | Add-Member -NotePropertyName SampleReason -NotePropertyValue $Reason
    Write-WudJsonLine -Path $samplePath -InputObject $sample -Depth 30

    $previousSignature = if (@($previous).Count -gt 0) { [string](Get-WudRecorderProperty $previous[0] 'Signature') } else { $null }
    $boundary = $ForceCheckpoint -or $signature -ne $previousSignature
    $checkpoint = $null
    if ($boundary) {
        $transition = [pscustomobject][ordered]@{
            TimestampUtc = Get-WudRecorderProperty $sample 'TimestampUtc'
            State = Get-WudRecorderProperty $sample 'RecorderState'
            PreviousState = if (@($previous).Count -gt 0) { Get-WudRecorderProperty $previous[0] 'RecorderState' } else { $null }
            Signature = $signature
            PreviousSignature = $previousSignature
            Reason = $Reason
            EvidenceReference = 'Recorder/ProgressSamples.jsonl'
        }
        Write-WudJsonLine -Path $transitionPath -InputObject $transition
        $checkpoint = Write-WudRecorderCheckpoint -RunPath $RunPath -Sample $sample -Reason $Reason -MaximumCheckpoints $MaximumCheckpoints -MaximumFileBytes $MaximumCheckpointFileBytes -MaximumCheckpointBytes $MaximumCheckpointBytes
    }
    return [pscustomobject][ordered]@{ Sample = $sample; BoundaryObserved = $boundary; Checkpoint = $checkpoint; InvalidPriorLines = @($read.InvalidLines) }
}

function Start-WudProgressRecorder {
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [string]$TargetVersion = '25H2',
        [int]$TargetBuild = 26200,
        [ValidateRange(30, 3600)][int]$IntervalSeconds = 60,
        [int]$ProgressBucketSize = 100,
        [int]$MaximumCheckpoints = 8,
        [long]$MaximumCheckpointFileBytes = 16777216,
        [long]$MaximumCheckpointBytes = 67108864,
        [switch]$Once
    )
    $statePath = Join-Path $RunPath 'State\run-state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { throw "Recorder state does not exist: $statePath" }
    $stateRoot = New-WudDirectory -Path (Join-Path $RunPath 'State')
    $lock = $null
    try { $lock = [IO.File]::Open((Join-Path $stateRoot 'recorder.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { return 10 }
    try {
        while ($true) {
            if (Test-Path -LiteralPath (Join-Path $stateRoot 'recorder.stop')) { return 0 }
            $state = Read-WudJson -Path $statePath
            if (-not $state) { return 30 }
            if ([DateTime]::UtcNow -gt (ConvertTo-WudUtcDateTime $state.ExpiresUtc)) {
                Write-WudText -Path (Join-Path $stateRoot 'recorder.expired') -Text ([DateTime]::UtcNow.ToString('o'))
                return 10
            }
            $null = Invoke-WudRecorderSample -RunPath $RunPath -TargetVersion $TargetVersion -TargetBuild $TargetBuild -Reason 'PeriodicSample' -ProgressBucketSize $ProgressBucketSize -MaximumCheckpoints $MaximumCheckpoints -MaximumCheckpointFileBytes $MaximumCheckpointFileBytes -MaximumCheckpointBytes $MaximumCheckpointBytes
            if ($Once) { return 0 }
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    finally { if ($lock) { $lock.Dispose() } }
}

Export-ModuleMember -Function @(
    'Get-WudRecorderRoot', 'Write-WudJsonLine', 'Read-WudJsonLines', 'ConvertTo-WudSetupProgress',
    'Get-WudRecorderState', 'Get-WudRecorderSignature', 'Get-WudSetupPhaseObservation', 'Get-WudDeliveryOptimizationSummary',
    'Get-WudRecorderTelemetrySummary', 'Get-WudProgressSample', 'Write-WudRecorderCheckpoint',
    'Invoke-WudRecorderSample', 'Start-WudProgressRecorder'
)
